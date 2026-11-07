import Foundation

/// 缓存只是上次看到的结果；真正删除仍重新读取 Git 状态。
enum WorktreeCacheStore {
    static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Adieu/worktrees.json")
    }

    private static let queue = DispatchQueue(label: "com.ljy.adieu.worktree-cache")

    static func load(from file: URL = file) -> WorktreeSnapshot? {
        guard let data = try? Data(contentsOf: file),
              let snapshot = try? JSONDecoder().decode(WorktreeSnapshot.self, from: data),
              snapshot.version == 2 else { return nil }
        return snapshot
    }

    static func saveLater(_ snapshot: WorktreeSnapshot, to file: URL = file) {
        queue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    static func flush() { queue.sync {} }
}
