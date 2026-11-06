import Foundation

enum AppDataScannerTests {
    static func run(root testRoot: URL) throws {
        let fm = FileManager.default
        let root = testRoot.appending(path: "granular-data")
        let cache = root.appending(path: "Cache")
        let documents = root.appending(path: "Documents")
        let outside = testRoot.appending(path: "outside-data")
        for dir in [cache, documents, outside] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let disposable = cache.appending(path: "preview.bin")
        let keep = documents.appending(path: "messages.db")
        let external = outside.appending(path: "keep.bin")
        try Data(repeating: 1, count: 8192).write(to: disposable)
        try Data(repeating: 2, count: 4096).write(to: keep)
        try Data(repeating: 3, count: 16384).write(to: external)
        let metadata = root.appending(path: ".com.apple.containermanagerd.metadata.plist")
        try Data(repeating: 4, count: 4096).write(to: metadata)
        try fm.createSymbolicLink(at: cache.appending(path: "External"), withDestinationURL: outside)
        let part = AppPart(id: "container", kind: .data, label: "沙盒数据", path: root.path, size: nil, evidence: .exact, defaultOn: true)
        let target = AppDataTarget(appID: "com.test.Data", appName: "Fixture", part: part)
        let listing = AppDataScanner.list(target, path: root.path)
        precondition(listing.error == nil && listing.entries.count == 3)
        precondition(listing.entries.first { $0.path == metadata.path }?.canSelect == false)
        let cacheEntry = listing.entries.first { $0.path == cache.path }!
        precondition(cacheEntry.canEnter && cacheEntry.size == nil)
        let cancellation = AppDataScanCancellation()
        cancellation.cancel()
        precondition(AppDataScanner.measured(cacheEntry, root: root.path, cancellation: cancellation).size == nil)
        let measured = AppDataScanner.measured(cacheEntry, root: root.path)
        precondition(measured.size == AppScanner.allocatedSize(disposable), "Directory sizes must not include linked external files")
        let children = AppDataScanner.list(target, path: cache.path)
        precondition(children.entries.count == 2)
        precondition(children.entries.first { $0.name == "External" }?.restriction != nil)
        precondition(AppDataScanner.list(target, path: outside.path).error != nil)
        precondition(AppDataScanner.list(target, path: cache.appending(path: "External").path).error != nil)

        // 在确认之后才把目录换成链接：删除阶段必须重新验证边界。
        let moved = root.appending(path: "MovedCache")
        try fm.moveItem(at: cache, to: moved)
        try fm.createSymbolicLink(at: cache, withDestinationURL: outside)
        let changed = TrashService.delete([cache.appending(path: "keep.bin")], protected: [], dataRoot: root.path)
        precondition(changed.done.isEmpty && changed.failed.count == 1 && fm.fileExists(atPath: external.path))
        let preserved = TrashService.delete([keep], protected: [documents.path], dataRoot: root.path)
        precondition(preserved.done.isEmpty && preserved.failed.count == 1 && fm.fileExists(atPath: keep.path))
        let control = TrashService.delete([metadata], protected: [], dataRoot: root.path)
        precondition(control.done.isEmpty && control.failed.count == 1)
        let escape = TrashService.delete([external], protected: [], dataRoot: root.path)
        precondition(escape.done.isEmpty && escape.failed.count == 1)
        let adminEscape = TrashService.deleteAsAdmin([external], protected: [], dataRoot: root.path)
        precondition(adminEscape.done.isEmpty && adminEscape.failed.count == 1, "An invalid administrator request must be rejected without an authorization prompt")
        let deletion = TrashService.delete([moved.appending(path: "preview.bin")], protected: [], dataRoot: root.path)
        precondition(deletion.done.count == 1 && deletion.failed.isEmpty)
        precondition(fm.fileExists(atPath: keep.path) && fm.fileExists(atPath: external.path))
        precondition(!AppDataScanner.contains(root.path, root: root.path), "The browser must not delete its entire directory root")

        // 偏好设置等单个文件也能预览、明确勾选后清理；不会被当成目录枚举。
        let filePart = AppPart(id: "prefs", kind: .data, label: "偏好设置", path: keep.path, size: nil, evidence: .exact, defaultOn: true)
        let fileListing = AppDataScanner.list(.init(appID: target.appID, appName: target.appName, part: filePart), path: keep.path)
        precondition(fileListing.entries.count == 1 && fileListing.entries[0].isDirectory == false)
        precondition(AppDataScanner.contains(keep.path, root: keep.path))
        print("App data scanner tests passed: lazy children, nested sizes, external links, changed paths, protected metadata, scoped deletion and single-file inspection.")
    }
}
