import Foundation

enum CloudDriveCleanup {
    struct Outcome: Sendable {
        var removed: Set<CloudDriveFile.ID> = []
        var failed: [(path: String, reason: String)] = []
    }

    static func removeDownloads(_ files: [CloudDriveFile], protected: [String], root: URL = CloudDriveScanner.root) -> Outcome {
        var outcome = Outcome()
        for file in files {
            do {
                let url = file.url
                guard file.canEvict, url.standardizedFileURL.path == url.resolvingSymlinksInPath().path,
                      let current = try CloudDriveScanner.inspect(url, under: root),
                      current.canEvict, current.identity == file.identity else {
                    throw TrashService.Refusal.notAllowed(String(localized: "同步状态或文件已变化，请刷新后重试。"))
                }
                try TrashService.check(url, protected: protected)
                try FileManager.default.evictUbiquitousItem(at: url)
                outcome.removed.insert(file.id)
            } catch {
                outcome.failed.append((file.relativePath, error.localizedDescription))
            }
        }
        return outcome
    }
}
