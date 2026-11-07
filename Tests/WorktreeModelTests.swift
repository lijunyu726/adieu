import Foundation
@testable import ReviewAdieu

private final class DelayedFileScan: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private let gate = DispatchSemaphore(value: 0)
    var hasStarted: Bool { lock.withLock { started } }
    func run(_ snapshot: FileScanner.Result) -> FileScanner.Result {
        lock.withLock { started = true }
        gate.wait()
        return snapshot
    }
    func release() { gate.signal() }
}

@main
struct WorktreeModelTests {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let base = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "scratch/worktree-model-test-" + UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let home = base.appending(path: "home")
        let documents = home.appending(path: "Documents")
        let repo = base.appending(path: "repo")
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        func git(_ path: URL, _ args: [String]) throws {
            guard WorktreeScanner.git(path.path, args)?.status == 0 else {
                throw NSError(domain: "Git setup failed: \(args)", code: 1)
            }
        }
        try git(repo, ["init", "-b", "main"])
        try git(repo, ["config", "user.name", "Adieu test"])
        try git(repo, ["config", "user.email", "adieu-test@example.invalid"])
        try Data("fixture".utf8).write(to: repo.appending(path: "README"))
        try git(repo, ["add", "."])
        try git(repo, ["commit", "-m", "initial"])
        let tree = documents.appending(path: "review-worktree")
        try git(repo, ["worktree", "add", "-b", "review", tree.path])
        try fm.createDirectory(at: tree.appending(path: "assets"), withIntermediateDirectories: true)
        let image = tree.appending(path: "assets/preview.png")
        let installer = tree.appending(path: "build.dmg")
        try Data(repeating: 0x41, count: 4096).write(to: image)
        try Data(repeating: 0x5a, count: 60_000_000).write(to: installer)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -400 * 86400)], ofItemAtPath: installer.path)
        let sibling = documents.appending(path: "review-worktree-backup")
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        let keep = sibling.appending(path: "keep.png")
        try Data(repeating: 0x42, count: 4096).write(to: keep)

        // 使用实际 AppModel 与分类、建议逻辑，扫描仅指向隔离的临时家目录。
        let model = AppModel()
        precondition(!model.useSample)
        let before = FileScanner.scan(home: home)
        await model.loadFiles(using: { before })
        precondition(model.category(.captures)!.items.count == 2)
        precondition(model.category(.bigFiles)!.items.contains { $0.path == installer.path })
        precondition(model.category(.stale)!.items.contains { $0.path == installer.path })
        precondition(Suggestion.make(model).contains { $0.files.contains(installer.path) })
        let badgeBefore = model.badge(for: .bigFiles)
        let rootBefore = model.fileScan!.rootSizes.first { $0.name == "文稿" }!.size

        let delayed = DelayedFileScan()
        let oldScan = Task { await model.loadFiles(using: { delayed.run(before) }) }
        var started = false
        for _ in 0..<1000 {
            if delayed.hasStarted { started = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(started)
        let candidate = WorktreeScanner.scan(repo.path, measure: false).items.first { $0.path == tree.path }!
        let result = TrashService.delete([tree], protected: [], worktree: candidate, worktreeMode: .force)
        precondition(result.done.count == 1 && result.failed.isEmpty)
        // 与成功回调相同的文件重扫入口；旧扫描此时仍未结束。
        await model.loadFiles(using: { FileScanner.scan(home: home) })
        precondition(!model.filesLoading)
        precondition(model.fileScan!.files.map(\.path) == [keep.path])
        precondition(model.category(.captures)!.items.map(\.path) == [keep.path])
        precondition(model.category(.bigFiles)!.items.isEmpty && model.category(.stale)!.items.isEmpty)
        precondition(model.badge(for: .bigFiles) != badgeBefore)
        precondition(!Suggestion.make(model).contains { $0.files.contains(installer.path) })
        precondition(model.fileScan!.rootSizes.first { $0.name == "文稿" }!.size < rootBefore)
        delayed.release()
        await oldScan.value
        precondition(!model.filesLoading && model.fileScan!.files.map(\.path) == [keep.path], "An older scan must not resurrect deleted descendants")
        precondition(model.category(.bigFiles)!.items.isEmpty && Suggestion.make(model).isEmpty)
        print("Worktree model tests passed: removed descendants, categories, sidebar totals, suggestions, root sizes and stale scan rejection.")
    }
}
