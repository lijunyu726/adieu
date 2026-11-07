import Foundation
import SwiftUI
@testable import ReviewAppData

@main
struct AppDataBrowserTests {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let root = URL(filePath: fm.currentDirectoryPath).appending(path: "scratch/app-data-model-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let cache = root.appending(path: "cache")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let keep = root.appending(path: "messages.db")
        try Data(repeating: 2, count: 8192).write(to: cache.appending(path: "preview.bin"))
        try Data(repeating: 3, count: 4096).write(to: keep)
        let part = AppPart(id: "data", kind: .data, label: "应用数据", path: root.path, size: nil, evidence: .exact, defaultOn: true)
        if !UserDefaults.standard.bool(forKey: "AdieuSample") {
            await verifyOwnershipForCleanup(part: part, file: keep)
            return
        }
        let target = AppDataTarget(appID: "com.fixture.App", appName: "Fixture", part: part)
        let browser = AppDataBrowser()
        browser.open(target)
        await browser.refresh()
        precondition(!browser.loading && !browser.measuring && browser.entries.count == 2 && browser.selected.isEmpty)
        let folder = browser.entries.first { $0.path == cache.path }!
        precondition(folder.size != nil && folder.evidence == .exact)
        browser.toggle(folder)
        precondition(browser.chosen.map(\.path) == [cache.path])
        await browser.enter(folder)
        precondition(browser.path == cache.path && browser.entries.count == 1 && browser.selected.isEmpty && browser.canGoBack)
        await browser.goBack()
        precondition(browser.path == root.path && !browser.canGoBack && browser.selected.isEmpty)
        browser.toggleAll()
        precondition(browser.selected.count == 2)
        browser.toggleAll()
        precondition(browser.selected.isEmpty)

        let delayed = DelayedAppDataScan()
        let slowPath = root.appending(path: "slow").path
        let racing = AppDataBrowser(scan: { target, path in
            if path == slowPath { delayed.wait(); return .init(path: path, entries: [folder]) }
            return AppDataScanner.list(target, path: path)
        })
        racing.open(target)
        let stale = Task { await racing.refresh(at: slowPath) }
        for _ in 0..<1000 {
            if delayed.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(delayed.started)
        await racing.refresh(at: root.path)
        delayed.release()
        await stale.value
        precondition(racing.path == root.path && racing.entries.count == 2 && !racing.loading && !racing.measuring,
                     "An older scan must not replace the folder the user is viewing")
        racing.close()
        precondition(racing.target == nil && racing.entries.isEmpty)

        // 即使用户关了普通删除确认，精细清理仍先确认；演示模式不会碰同一路径下的真实文件。
        precondition(UserDefaults.standard.bool(forKey: "AdieuSample"))
        precondition(!UserDefaults.standard.bool(forKey: "confirmAlways"))
        let model = AppModel()
        let app = AppItem(id: "fixture", name: "Fixture", monogram: "F", color: .gray, meta: "fixture", parts: [part])
        model.apps = [app]
        model.openAppData(app, part: part)
        await model.appData.refresh()
        precondition(model.appData.selected.isEmpty)
        model.appData.toggle(model.appData.entries[0])
        let picked = model.appData.chosen[0].path
        model.cleanAppDataSelection()
        guard let pending = model.pendingTrash else { preconditionFailure("Granular deletion must await confirmation") }
        precondition(pending.urls.map(\.path) == [picked] && pending.dataRoot == root.path)
        model.perform(pending)
        for _ in 0..<1000 {
            if model.appData.entries.allSatisfy({ $0.path != picked }) && !model.appData.loading && !model.appData.deleting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(model.appData.entries.allSatisfy { $0.path != picked })
        precondition(fm.fileExists(atPath: keep.path) && fm.fileExists(atPath: cache.appending(path: "preview.bin").path))
        try AppDataScannerTests.run(root: root)
        await sharedOwners(root: root)
        try await measurementLimit(root: root)
        print("App data model tests passed: navigation, measured sizes, no default selection, stale scans, forced confirmation and sample-mode isolation.")
    }

    @MainActor
    static func verifyOwnershipForCleanup(part: AppPart, file: URL) async {
        let model = AppModel(runningAppNames: { [:] })
        var part = part
        for hasOwners in [false, true] {
            if hasOwners { part.ownerIDs = ["com.fixture.App"] }
            let app = AppItem(id: "com.fixture.App", name: "Fixture", monogram: "F", color: .gray, meta: "", parts: [part])
            model.openAppData(app, part: part)
            await model.appData.refresh()
            let entry = model.appData.entries.first { $0.path == file.path }!
            model.appData.toggle(entry)
            model.cleanAppDataSelection()
            if hasOwners {
                precondition(model.pendingTrash?.urls == [file])
            } else {
                precondition(model.pendingTrash == nil && model.notice != nil)
            }
            precondition(FileManager.default.fileExists(atPath: file.path))
            model.appData.close()
        }
        print("Verified that real data can be browsed with unknown owners and cleanup requires identified owners.")
    }

    @MainActor
    static func sharedOwners(root: URL) async {
        var running: [String: String] = ["com.fixture.B": "Owner B"]
        let model = AppModel(runningAppNames: { running })
        let part = AppPart(id: "shared", kind: .shared, label: "Shared", path: root.path, size: nil,
                           evidence: .shared, defaultOn: false, ownerIDs: ["com.fixture.A", "com.fixture.B"])
        let app = AppItem(id: "com.fixture.A", name: "Owner A", monogram: "A", color: .gray, meta: "fixture", parts: [part])
        model.apps = [app]
        model.openAppData(app, part: part)
        await model.appData.refresh()
        model.appData.toggle(model.appData.entries[0])
        model.cleanAppDataSelection()
        precondition(model.pendingTrash == nil && model.notice?.contains("Owner B") == true,
                     "Stopped A must not authorize deletion while shared-data owner B is running")
        running = [:]
        model.notice = nil
        model.cleanAppDataSelection()
        let request = model.pendingTrash!
        precondition(request.dataTarget?.ownerIDs.isSuperset(of: [app.id, "com.fixture.B"]) == true)
        // 确认期间 B 又启动了；即使浏览面板已经关闭，请求本身仍必须阻止执行。
        running = ["COM.FIXTURE.B": "Owner B"]
        model.appData.close()
        model.perform(request)
        precondition(!model.appData.deleting && model.notice?.contains("Owner B") == true)
        precondition(model.removedKeys.isEmpty && model.history == Sample.history)
    }

    @MainActor
    static func measurementLimit(root: URL) async throws {
        let probe = MeasurementProbe()
        let browser = AppDataBrowser(scan: { target, path in
            .init(path: path, entries: (0..<6).map { index in
                let p = URL(filePath: path).appending(path: "folder\(index)").path
                return AppDataEntry(path: p, name: "folder\(index)", isDirectory: true, isPackage: false,
                                    modified: nil, evidence: target.part.evidence)
            })
        }, measure: { item, _, cancellation in
            probe.measure(item, cancellation: cancellation)
        })
        let part = AppPart(id: "data", kind: .data, label: "Data", path: root.path, size: nil, evidence: .exact, defaultOn: true)
        let target = AppDataTarget(appID: "fixture", appName: "Fixture", part: part)
        browser.open(target)
        let first = Task { await browser.refresh() }
        for _ in 0..<1000 {
            if probe.active == 6 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(probe.active == 6)
        let secondPath = root.appending(path: "second").path
        let second = Task { await browser.refresh(at: secondPath) }
        for _ in 0..<1000 {
            if browser.path == secondPath && browser.measuring { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(100))
        precondition(probe.peak == 6 && probe.starts == 6, "Navigation must not start six more blocking measurements")
        let thirdPath = root.appending(path: "third").path
        let third = Task { await browser.refresh(at: thirdPath) }
        for _ in 0..<1000 {
            if browser.path == thirdPath && browser.measuring { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        browser.close()
        probe.releaseAll()
        await first.value
        await second.value
        await third.value
        precondition(probe.peak == 6 && probe.active == 0 && probe.starts == 6)
        precondition(probe.cancelled == 6, "Every obsolete running measurement must receive cancellation")
        browser.open(target)
        await browser.refresh()
        precondition(browser.entries.count == 6 && !browser.measuring && probe.active == 0 && probe.peak == 6,
                     "Cancelled work must release all permits for a later scan")

        let cooperative = CooperativeMeasurements()
        let cancelBrowser = AppDataBrowser(scan: { _, path in
            .init(path: path, entries: [AppDataEntry(path: path + "/folder", name: "folder", isDirectory: true,
                                                   isPackage: false, modified: nil, evidence: .exact)])
        }, measure: { item, _, cancellation in cooperative.measure(item, cancellation: cancellation) })
        cancelBrowser.open(target)
        let job = Task { await cancelBrowser.refresh() }
        for _ in 0..<1000 {
            if cooperative.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(cooperative.started)
        cancelBrowser.close()
        await job.value
        precondition(cooperative.stopped, "Closing the browser must interrupt cooperative traversal without an external release")
    }
}

private final class MeasurementProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var count = 0
    private var maximum = 0
    private var begun = 0
    private var obsolete = 0
    private var released = false
    var active: Int { lock.withLock { count } }
    var peak: Int { lock.withLock { maximum } }
    var starts: Int { lock.withLock { begun } }
    var cancelled: Int { lock.withLock { obsolete } }
    func measure(_ item: AppDataEntry, cancellation: AppDataScanCancellation) -> AppDataEntry {
        let waits = lock.withLock { count += 1; begun += 1; maximum = max(maximum, count); return !released }
        if waits { gate.wait() }
        lock.withLock { count -= 1; if cancellation.isCancelled { obsolete += 1 } }
        var result = item
        result.size = 1
        result.isMeasured = true
        return result
    }
    func releaseAll() {
        lock.withLock { released = true }
        for _ in 0..<64 { gate.signal() }
    }
}

private final class CooperativeMeasurements: @unchecked Sendable {
    private let lock = NSLock()
    private var began = false
    private var ended = false
    var started: Bool { lock.withLock { began } }
    var stopped: Bool { lock.withLock { ended } }
    func measure(_ item: AppDataEntry, cancellation: AppDataScanCancellation) -> AppDataEntry {
        lock.withLock { began = true }
        while !cancellation.isCancelled { Thread.sleep(forTimeInterval: 0.001) }
        lock.withLock { ended = true }
        return item
    }
}

private final class DelayedAppDataScan: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var began = false
    var started: Bool { lock.withLock { began } }
    func wait() { lock.withLock { began = true }; semaphore.wait() }
    func release() { semaphore.signal() }
}
