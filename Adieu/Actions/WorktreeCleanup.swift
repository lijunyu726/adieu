import Foundation

/// 仅由 TrashService.delete 调用。Git 自己移除目录及登记，强制移除必须由用户单独确认，不删除分支。
enum WorktreeCleanup {
    static func remove(_ item: WorktreeItem, mode: WorktreeRemovalMode = .safe, protected: [String]) throws {
        guard item.removalMode == mode else {
            throw TrashService.Refusal.notAllowed(item.blocked ?? String(localized: "工作区状态已经变化，请重新统计后再试。"))
        }
        let url = URL(filePath: item.path)
        try TrashService.check(url, protected: protected)
        let project = WorktreeScanner.scan(item.projectPath, measure: false)
        guard project.error == nil,
              let current = project.items.first(where: { $0.path == item.path }),
              current.head == item.head, current.branch == item.branch,
              current.removalMode == mode, current.isLocked == item.isLocked,
              current.blocked == item.blocked else {
            throw TrashService.Refusal.notAllowed(String(localized: "工作区状态已经变化，请重新统计后再试。"))
        }
        // .git 必须仍是指向共享仓库的普通文件；主仓库、符号链接、被替换的目录不能走这里。
        let marker = url.appending(path: ".git")
        let values = try marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else {
            throw TrashService.Refusal.notAllowed(String(localized: "工作区路径发生变化，已保留。"))
        }
        let common = WorktreeScanner.git(item.path, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        let primary = WorktreeScanner.git(item.projectPath, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        guard common?.status == 0, primary?.status == 0, common?.out == primary?.out else {
            throw TrashService.Refusal.notAllowed(String(localized: "工作区路径发生变化，已保留。"))
        }
        // 再过一遍保护名单，紧接着让 Git 做最终的脏状态与锁检查。
        try TrashService.check(url, protected: protected)
        guard let result = WorktreeScanner.git(item.projectPath, item.removalArguments(mode: mode)) else {
            throw TrashService.Refusal.notAllowed(String(localized: "Git 没有完成移除，请重新统计后检查。"))
        }
        guard result.status == 0 else {
            throw TrashService.Refusal.notAllowed(result.err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
