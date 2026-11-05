import Foundation

// 命令行验证不编译 SwiftUI 窗口；导航值与 RootView 保持一致。
enum AppSection: String, Hashable, Sendable {
    case home, apps, leftovers, launch, installers, captures, bigFiles, stale, devTools
}

@main
struct WorktreeTests {
    @MainActor
    static func main() async throws {
        precondition(WorktreeScanner.versionIsVerified, "This Git version has not been verified for cleanup; update the verified version only after testing it.")
        let fm = FileManager.default
        let base = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "scratch/worktree-test-" + UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let repo = base.appending(path: "main").path
        try fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        func git(_ path: String, _ args: [String]) throws -> String {
            guard let out = WorktreeScanner.git(path, args), out.status == 0 else {
                throw NSError(domain: "Git test setup failed: \(args)", code: 1)
            }
            return out.out
        }
        func write(_ path: String, _ text: String = "test\n") throws {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        _ = try git(repo, ["init", "-b", "main"])
        _ = try git(repo, ["config", "user.name", "Adieu test"])
        _ = try git(repo, ["config", "user.email", "adieu-test@example.invalid"])
        try write(repo + "/tracked")
        try write(repo + "/.gitignore", "cache/\n.env\n")
        _ = try git(repo, ["add", "."])
        _ = try git(repo, ["commit", "-m", "initial"])
        var branches: [String: String] = [:]
        func add(_ name: String, detached: Bool = false) throws -> String {
            let path = base.appending(path: name).path
            let branch = "test-" + String(branches.count)
            branches[path] = branch
            _ = try git(repo, ["worktree", "add"] + (detached ? ["--detach"] : ["-b", branch]) + [path, "HEAD"])
            return path
        }
        let clean = try add("clean space 'quote'\nline")
        let dirty = try add("dirty")
        try write(dirty + "/tracked", "changed\n")
        let untracked = try add("untracked")
        try write(untracked + "/new-file")
        let locked = try add("locked")
        _ = try git(repo, ["worktree", "lock", locked])
        let detached = try add("detached", detached: true)
        let unmerged = try add("unmerged")
        try write(unmerged + "/tracked", "new commit\n")
        _ = try git(unmerged, ["add", "."])
        _ = try git(unmerged, ["commit", "-m", "unmerged"])
        let ignored = try add("ignored")
        try fm.createDirectory(atPath: ignored + "/cache", withIntermediateDirectories: true)
        try write(ignored + "/cache/build")
        let submodule = try add("submodule")
        try write(submodule + "/.gitmodules", "")
        let missing = try add("missing")
        try fm.removeItem(atPath: missing)
        let nested = try add("nested")
        _ = try git(repo, ["worktree", "add", "-b", "child", nested + "/child", "HEAD"])
        let hiddenChange = try add("hidden-change")
        _ = try git(hiddenChange, ["update-index", "--assume-unchanged", "tracked"])
        try write(hiddenChange + "/tracked", "hidden work\n")
        let operation = try add("operation")
        let gitDir = try git(operation, ["rev-parse", "--absolute-git-dir"]).trimmingCharacters(in: .newlines)
        try fm.createDirectory(atPath: gitDir + "/rebase-merge", withIntermediateDirectories: true)
        let project = WorktreeScanner.scan(repo)
        precondition(project.error == nil)
        func item(_ path: String) -> WorktreeItem { project.items.first { $0.path == path }! }
        precondition(item(clean).blocked == nil, "Spaces, quotes and newlines in paths must survive porcelain parsing")
        precondition(item(ignored).blocked == nil && item(ignored).hasIgnoredFiles)
        for path in [repo, dirty, untracked, locked, detached, unmerged, submodule, missing, nested, hiddenChange, operation] {
            precondition(item(path).blocked != nil, "Must preserve \(path)")
        }
        func remove(_ candidate: WorktreeItem, mode: WorktreeRemovalMode = .safe, protected: [String] = []) -> TrashService.Outcome {
            TrashService.delete([URL(filePath: candidate.path)], protected: protected, worktree: candidate, worktreeMode: mode)
        }
        let protectedResult = remove(item(clean), protected: [clean + "/tracked"])
        precondition(protectedResult.done.isEmpty && !protectedResult.failed.isEmpty && fm.fileExists(atPath: clean))
        for path in [repo, dirty, untracked, locked, detached, unmerged, submodule, nested, hiddenChange, operation] {
            let r = remove(item(path))
            precondition(r.done.isEmpty && !r.failed.isEmpty && fm.fileExists(atPath: path))
        }
        let success = remove(item(clean))
        precondition(success.done.count == 1 && success.failed.isEmpty && !fm.fileExists(atPath: clean))
        let registered = try git(repo, ["worktree", "list", "--porcelain", "-z"])
        precondition(!WorktreeScanner.parse(registered).contains { $0["worktree"] == clean })
        _ = try git(repo, ["show-ref", "--verify", "refs/heads/" + branches[clean]!])
        // 扫描后才加锁或出现未跟踪文件，必须拒绝。
        _ = try git(repo, ["worktree", "lock", ignored])
        let lateLock = remove(item(ignored))
        precondition(lateLock.done.isEmpty && !lateLock.failed.isEmpty && fm.fileExists(atPath: ignored))
        _ = try git(repo, ["worktree", "unlock", ignored])
        try write(ignored + "/late-change")
        let stale = remove(item(ignored))
        precondition(stale.done.isEmpty && !stale.failed.isEmpty && fm.fileExists(atPath: ignored))
        try fm.removeItem(atPath: ignored + "/late-change")
        let ignoredResult = remove(item(ignored))
        precondition(ignoredResult.done.count == 1 && !fm.fileExists(atPath: ignored))
        // 强制移除必须明确选择，仍不能绕过主工作区、主分支、嵌套与保护名单。
        let protectedForce = remove(item(dirty), mode: .force, protected: [dirty + "/tracked"])
        precondition(protectedForce.done.isEmpty && !protectedForce.failed.isEmpty && fm.fileExists(atPath: dirty))
        _ = try git(repo, ["worktree", "lock", dirty])
        let staleForce = remove(item(dirty), mode: .force)
        precondition(staleForce.done.isEmpty && !staleForce.failed.isEmpty && fm.fileExists(atPath: dirty), "Force must not escalate to deleting a newly locked worktree")
        _ = try git(repo, ["worktree", "unlock", dirty])
        _ = try git(dirty, ["add", "."])
        _ = try git(dirty, ["commit", "-m", "changed after confirmation"])
        let changedHead = remove(item(dirty), mode: .force)
        precondition(changedHead.done.isEmpty && !changedHead.failed.isEmpty, "Force must refuse a changed HEAD")

        let linkedMain = base.appending(path: "linked-main").path
        _ = try git(repo, ["worktree", "add", "--force", linkedMain, "main"])
        _ = try git(repo, ["update-ref", "refs/remotes/origin/production", "HEAD"])
        _ = try git(repo, ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/production"])
        let production = base.appending(path: "production").path
        _ = try git(repo, ["worktree", "add", "-b", "production", production, "HEAD"])
        let protectedProject = WorktreeScanner.scan(repo, measure: false)
        for path in [repo, linkedMain, production, nested] {
            var forged = protectedProject.items.first { $0.path == path }!
            precondition(forged.removalMode == nil)
            forged.allowsForceRemoval = true
            let refusal = remove(forged, mode: .force)
            precondition(refusal.done.isEmpty && !refusal.failed.isEmpty && fm.fileExists(atPath: path), "Force must never remove \(path)")
        }

        // 含真实、已经初始化的子模块，也只让 Git 自己移除。
        let moduleSource = base.appending(path: "module-source").path
        try fm.createDirectory(atPath: moduleSource, withIntermediateDirectories: true)
        _ = try git(moduleSource, ["init", "-b", "main"])
        _ = try git(moduleSource, ["config", "user.name", "Adieu test"])
        _ = try git(moduleSource, ["config", "user.email", "adieu-test@example.invalid"])
        try write(moduleSource + "/source")
        _ = try git(moduleSource, ["add", "."])
        _ = try git(moduleSource, ["commit", "-m", "module"])
        let initializedModule = try add("initialized-module")
        _ = try git(initializedModule, ["-c", "protocol.file.allow=always", "submodule", "add", moduleSource, "deps"])
        _ = try git(initializedModule, ["commit", "-am", "add module"])
        let forcedProject = WorktreeScanner.scan(repo, measure: false)
        for path in [dirty, untracked, locked, detached, unmerged, submodule, hiddenChange, operation, initializedModule] {
            let candidate = forcedProject.items.first { $0.path == path }!
            precondition(candidate.removalMode == .force, "Risky worktree needs an explicit force choice")
            if path == locked { precondition(candidate.command.contains("--force --force")) }
            let outcome = remove(candidate, mode: .force)
            precondition(outcome.done.count == 1 && outcome.failed.isEmpty && !fm.fileExists(atPath: path), "Force removal failed: \(path) \(outcome.failed)")
            let remaining = WorktreeScanner.parse(try git(repo, ["worktree", "list", "--porcelain", "-z"]))
            precondition(!remaining.contains { $0["worktree"] == path })
            if let branch = candidate.branch { _ = try git(repo, ["show-ref", "--verify", "refs/heads/" + branch]) }
        }
        precondition(fm.fileExists(atPath: repo) && fm.fileExists(atPath: linkedMain) && fm.fileExists(atPath: moduleSource))
        // 不区分大小写的 APFS：登记字符串的大小写不同，实际仍是嵌套目录。
        let caseSensitive = try base.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames ?? true
        if !caseSensitive {
            let caseParent = try add("CaseParent")
            let caseChild = base.appending(path: "caseparent/Child").path
            _ = try git(repo, ["worktree", "add", "-b", "case-child", caseChild, "HEAD"])
            let childGit = try git(caseChild, ["rev-parse", "--absolute-git-dir"]).trimmingCharacters(in: .newlines)
            // Git 版本可能规范化传入路径；保留一个实际有效、大小写不同的登记用于回归。
            try write(childGit + "/gitdir", caseChild + "/.git\n")
            let raw = WorktreeScanner.parse(try git(repo, ["worktree", "list", "--porcelain", "-z"]))
            precondition(raw.contains { $0["worktree"] == caseChild })
            let cases = WorktreeScanner.scan(repo, measure: false)
            var parent = cases.items.first { $0.path == caseParent }!
            precondition(parent.removalMode == nil, "Case variants must not hide a nested worktree")
            parent.allowsForceRemoval = true
            let refused = remove(parent, mode: .force)
            precondition(refused.done.isEmpty && !refused.failed.isEmpty)
            precondition(fm.fileExists(atPath: caseParent) && fm.fileExists(atPath: caseChild))
            // 相同前缀但不同目录，不应被误判为嵌套。
            let sibling = try add("CaseParent-backup")
            precondition(WorktreeScanner.scan(repo, measure: false).items.first { $0.path == sibling }!.removalMode == .safe)
        }
        precondition(WorktreeScanner.scan(base.path + "/does-not-exist").error != nil)
        precondition(WorktreeScanner.parse("worktree /a\0HEAD 123\0branch refs/heads/main\0\0worktree /b\0locked\0\0").count == 2)
        try await WorktreeCacheTests.run(in: base)
        print("Worktree tests passed: scan, status guards, protection, stale-state refusal, safe and force removal, branch preservation, protected main branches and unusual paths.")
    }
}
