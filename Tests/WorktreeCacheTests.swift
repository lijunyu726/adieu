import Foundation

/// 阻塞只发生在被测扫描器的 GCD 线程；主线程可在扫描在途时操作目录列表。
private final class ControlledScan: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String: WorktreeProject]
    private var counts: [String: Int] = [:]
    private var gates: [String: DispatchSemaphore] = [:]

    init(_ projects: [WorktreeProject]) { results = Dictionary(uniqueKeysWithValues: projects.map { ($0.path, $0) }) }
    func scan(_ path: String) -> WorktreeProject {
        let (result, gate) = lock.withLock {
            counts[path, default: 0] += 1
            return (results[path]!, gates[path])
        }
        gate?.wait()
        return result
    }
    func count(_ path: String) -> Int { lock.withLock { counts[path, default: 0] } }
    func set(_ project: WorktreeProject) { lock.withLock { results[project.path] = project } }
    func pause(_ path: String) { lock.withLock { gates[path] = DispatchSemaphore(value: 0) } }
    func release(_ path: String) { lock.withLock { gates.removeValue(forKey: path) }?.signal() }
}

@MainActor
private func waitForScan(_ scanner: ControlledScan, _ path: String, after count: Int) async throws {
    for _ in 0..<1000 {
        if scanner.count(path) > count { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    preconditionFailure("Background scan did not start")
}

@MainActor
enum WorktreeCacheTests {
    static func run(in base: URL) async throws {
        let suite = "adieu-worktree-cache-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = base.appending(path: "cache/worktrees.json")
        let examples = Array(Sample.worktreeProjects.prefix(2))
        let first = examples[0], second = examples[1]
        let scanner = ControlledScan(examples)
        defaults.set(examples.map(\.path), forKey: "worktreeProjects")
        func catalog() -> WorktreeCatalog {
            WorktreeCatalog(defaults: defaults, cacheURL: file, scan: { scanner.scan($0) })
        }

        let initial = catalog()
        precondition(initial.projects.map(\.id) == examples.map(\.id), "Projects appear before scanning")
        await initial.load()
        precondition(scanner.count(first.path) == 1 && scanner.count(second.path) == 1)
        initial.selectedID = second.id
        initial.showsWorktrees = true
        await initial.load()
        precondition(scanner.count(first.path) == 1 && scanner.count(second.path) == 1, "Reopening must not rescan fresh projects")
        WorktreeCacheStore.flush()

        let reopened = catalog()
        precondition(reopened.selectedID == second.id && reopened.showsWorktrees)
        await reopened.load()
        precondition(reopened.projects[0].items == first.items)
        precondition(scanner.count(first.path) == 1 && scanner.count(second.path) == 1, "Disk cache must survive a new model")
        let saved = WorktreeCacheStore.load(from: file)!
        WorktreeCacheStore.saveLater(.init(language: saved.language, projects: saved.projects,
                                          updatedAt: [first.path: .distantPast, second.path: .distantPast]), to: file)
        WorktreeCacheStore.flush()

        let stale = catalog()
        scanner.pause(second.path)
        let firstCount = scanner.count(first.path), secondCount = scanner.count(second.path)
        let refresh = Task { await stale.load() }
        try await waitForScan(scanner, second.path, after: secondCount)
        precondition(stale.projects[1].items == second.items && stale.loaded.contains(second.path), "Cached content stays visible during refresh")
        stale.selectedID = first.id
        let duplicate = Task { await stale.load() }
        scanner.release(second.path)
        await refresh.value
        await duplicate.value
        precondition(scanner.count(first.path) == firstCount + 1 && scanner.count(second.path) == secondCount + 1, "Concurrent page loads must share scans")

        scanner.set(.init(path: first.path, items: [], error: "test: disk offline"))
        await stale.refresh(first.path, force: true)
        precondition(stale.projects[0].items == first.items && stale.projects[0].error != nil, "Failed refresh preserves prior rows")
        scanner.set(first)
        await stale.refresh(first.path, force: true)
        precondition(stale.projects[0].error == nil)

        let candidate = first.items[1]
        scanner.pause(first.path)
        let previous = scanner.count(first.path)
        let racingRefresh = Task { await stale.refresh(first.path, force: true) }
        try await waitForScan(scanner, first.path, after: previous)
        precondition(stale.beginRemoval(candidate))
        precondition(!stale.projects[0].items.contains { $0.id == candidate.id }, "Confirmed removal updates the list immediately")
        stale.finishRemoval(candidate, succeeded: true)
        scanner.release(first.path)
        await racingRefresh.value
        precondition(!stale.projects[0].items.contains { $0.id == candidate.id }, "A stale scan must not resurrect a deleted row")
        var afterDelete = first
        afterDelete.items.removeAll { $0.id == candidate.id }
        scanner.set(afterDelete)
        await stale.refresh(first.path, force: true)
        WorktreeCacheStore.flush()
        let afterRestart = catalog()
        await afterRestart.load()
        precondition(!afterRestart.projects[0].items.contains { $0.id == candidate.id }, "Confirmed removal also updates disk cache")

        let risky = first.items[2]
        precondition(!stale.beginRemoval(risky), "Risky removal requires an explicit force mode")
        precondition(stale.beginRemoval(risky, mode: .force))
        stale.finishRemoval(risky, succeeded: false)
        precondition(stale.projects[0].items == afterDelete.items, "Failed force removal rolls back the cached row")

        let rollback = second.items[1]
        precondition(stale.beginRemoval(rollback))
        stale.finishRemoval(rollback, succeeded: false)
        precondition(stale.projects[1].items == second.items, "Failed deletion restores the original row and ordering")

        scanner.pause(second.path)
        let beforeForget = scanner.count(second.path)
        let forgettingRefresh = Task { await stale.refresh(second.path, force: true) }
        try await waitForScan(scanner, second.path, after: beforeForget)
        stale.selectedID = second.id
        stale.forget(second.path)
        scanner.release(second.path)
        await forgettingRefresh.value
        precondition(stale.projects.map(\.id) == [first.id] && stale.selectedID == first.id, "Removed projects stay removed despite in-flight scans")
        WorktreeCacheStore.flush()
        precondition(WorktreeCacheStore.load(from: file)!.projects.map(\.id) == [first.id])

        try Data("invalid json".utf8).write(to: file)
        let corrupt = catalog()
        await corrupt.load()
        precondition(corrupt.projects[0].items == afterDelete.items, "Corrupt cache falls back to a scan")
        WorktreeCacheStore.flush()
        let beforeSample = try Data(contentsOf: file)
        let sample = WorktreeCatalog(defaults: defaults, sample: examples, cacheURL: file, scan: { _ in preconditionFailure("Sample mode must not scan") })
        sample.selectedID = second.id
        sample.showsWorktrees = false
        await sample.load(force: true)
        precondition(sample.beginRemoval(candidate))
        sample.finishRemoval(candidate, succeeded: true)
        sample.forget(second.path)
        WorktreeCacheStore.flush()
        let afterSample = try Data(contentsOf: file)
        precondition(afterSample == beforeSample)
        precondition(defaults.string(forKey: "worktreeSelectedProject") == first.id && defaults.bool(forKey: "devSpaceShowsWorktrees"))
        print("Worktree cache tests passed: reuse, persistence, selection, background refresh, deduplication, failure fallback, optimistic rollback and stale scan rejection.")
    }
}
