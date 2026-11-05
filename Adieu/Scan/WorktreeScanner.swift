import Foundation

/// 只读取用户添加的项目；不遍历整块磁盘，也不按目录名猜测 worktree。
enum WorktreeScanner {
    /// 本机的临时仓库测试覆盖这一版本；其他版本先只展示。
    static let verifiedVersion = "git version 2.50.1 (Apple Git-155)"
    static let versionIsVerified: Bool = {
        git(FileManager.default.homeDirectoryForCurrentUser.path, ["--version"])?.out
            .trimmingCharacters(in: .whitespacesAndNewlines) == verifiedVersion
    }()

    static func git(_ path: String, _ args: [String]) -> Shell.Output? {
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_TERMINAL_PROMPT"] = "0"
        return Shell.run("/usr/bin/git", ["--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-C", path] + args,
                         timeout: 30, environment: env)
    }

    static func scan(_ path: String, measure: Bool = true) -> WorktreeProject {
        guard let out = git(path, ["worktree", "list", "--porcelain", "-z"]), out.status == 0 else {
            return WorktreeProject(path: path, items: [], error: String(localized: "无法读取项目，请确认目录存在且是 Git 仓库。"))
        }
        let records = parse(out.out)
        guard let main = records.first, main["bare"] == nil, let mainPath = main["worktree"] else {
            return WorktreeProject(path: path, items: [], error: String(localized: "暂不支持裸仓库。"))
        }
        var mainBranches: Set<String> = ["refs/heads/main", "refs/heads/master"]
        if let refs = git(mainPath, ["for-each-ref", "--format=%(symref)", "refs/remotes"]), refs.status == 0 {
            for ref in refs.out.split(separator: "\n") where ref.hasPrefix("refs/remotes/") {
                let branch = ref.split(separator: "/").dropFirst(3).joined(separator: "/")
                if !branch.isEmpty { mainBranches.insert("refs/heads/" + branch) }
            }
        }
        let items = records.enumerated().compactMap { index, record -> WorktreeItem? in
            guard let location = record["worktree"] else { return nil }
            let branch = record["branch"].map { String($0.dropFirst("refs/heads/".count)) }
            var reason: String?
            var ignored = false
            var canForce = false
            let exists = FileManager.default.fileExists(atPath: location)
            if index == 0 { reason = String(localized: "主工作区，保留") }
            else if let ref = record["branch"], mainBranches.contains(ref) { reason = String(localized: "主分支，保留") }
            else if !exists { reason = String(localized: "目录已不存在，保留登记") }
            else if !versionIsVerified { reason = String(localized: "Git 版本尚未验证，只展示") }
            else if records.contains(where: { other in
                guard let p = other["worktree"], p != location else { return false }
                return containsRegisteredWorktree(location, child: p)
            }) { reason = String(localized: "包含其他工作区，保留") }
            else if record["locked"] != nil { reason = String(localized: "工作区已锁定"); canForce = true }
            else if branch == nil { reason = String(localized: "游离 HEAD"); canForce = true }
            else if FileManager.default.fileExists(atPath: location + "/.gitmodules") {
                reason = String(localized: "包含子模块"); canForce = true
            } else {
                let status = git(location, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none"])
                let indexFlags = git(location, ["ls-files", "-v", "-z"])
                let ignoredFiles = git(location, ["ls-files", "--others", "--ignored", "--exclude-standard", "-z", "--directory"])
                ignored = !(ignoredFiles?.out.isEmpty ?? true)
                if status?.status != 0 || ignoredFiles?.status != 0 || indexFlags?.status != 0 {
                    reason = String(localized: "无法确认文件状态，保留")
                } else if indexFlags!.out.split(separator: "\0").contains(where: {
                    guard let flag = $0.first else { return false }
                    return flag == "S" || flag.isLowercase
                }) {
                    reason = String(localized: "有跳过状态检查的文件"); canForce = true
                } else if status?.out.isEmpty != true {
                    reason = String(localized: "有未提交改动或未跟踪文件"); canForce = true
                } else if operationInProgress(location) {
                    reason = String(localized: "Git 操作尚未结束"); canForce = true
                } else if let head = record["HEAD"], let target = main["HEAD"],
                          git(mainPath, ["merge-base", "--is-ancestor", head, target])?.status == 0 {
                    // 只说明提交关系，不把“已合并”当成用户已经结束任务。
                } else { reason = String(localized: "尚未合并到主工作区当前提交"); canForce = true }
            }
            return WorktreeItem(projectPath: mainPath, path: location, branch: branch, head: record["HEAD"] ?? "",
                                size: measure && exists ? AppScanner.allocatedSize(URL(filePath: location)) : nil,
                                blocked: reason, hasIgnoredFiles: ignored, allowsForceRemoval: canForce, isLocked: record["locked"] != nil)
        }
        return WorktreeProject(path: mainPath, items: items)
    }

    /// 根据文件系统身份判断嵌套，兼容不区分大小写的卷、路径别名和缺失的登记目录。
    /// 子目录已不存在时检查它最近的现存上级；无法确定关系时保守地禁止删除。
    private static func containsRegisteredWorktree(_ parent: String, child: String) -> Bool {
        let fm = FileManager.default
        let parentURL = URL(filePath: parent).standardizedFileURL.resolvingSymlinksInPath()
        var childURL = URL(filePath: child).standardizedFileURL
        while !fm.fileExists(atPath: childURL.path), childURL.path != "/" {
            childURL.deleteLastPathComponent()
        }
        childURL = childURL.resolvingSymlinksInPath()
        var relationship = FileManager.URLRelationship.other
        do {
            try fm.getRelationship(&relationship, ofDirectoryAt: parentURL, toItemAt: childURL)
            return relationship == .contains || relationship == .same
        } catch {
            return true
        }
    }

    private static func operationInProgress(_ path: String) -> Bool {
        guard let out = git(path, ["rev-parse", "--absolute-git-dir"]), out.status == 0 else { return true }
        let dir = out.out.trimmingCharacters(in: .newlines)
        return ["rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG", "sequencer", "index.lock"]
            .contains { FileManager.default.fileExists(atPath: dir + "/" + $0) }
    }

    /// -z 保留路径里的换行和引号；空字段分隔每条 worktree 记录。
    static func parse(_ text: String) -> [[String: String]] {
        var records: [[String: String]] = [], record: [String: String] = [:]
        for field in text.split(separator: "\0", omittingEmptySubsequences: false) {
            if field.isEmpty {
                if !record.isEmpty { records.append(record); record = [:] }
            } else if let space = field.firstIndex(of: " ") {
                record[String(field[..<space])] = String(field[field.index(after: space)...])
            } else { record[String(field)] = "" }
        }
        if !record.isEmpty { records.append(record) }
        return records
    }
}
