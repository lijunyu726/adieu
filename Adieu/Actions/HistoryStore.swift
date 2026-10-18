import Foundation

/// 一次清理操作。存在 ~/Library/Application Support/Adieu/history.json
struct HistoryEntry: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    let date: Date
    let title: String
    /// 从哪里发起的，如“大文件”“卸载”
    let source: String
    var files: [TrashedFile]
    var restored = false
    /// 通过工具命令清理时的说明（命令清理不经过废纸篓，不能放回）
    var commandNote: String? = nil
    /// 卸载应用时直接删除，没进废纸篓，不能放回
    var deleted: Bool? = nil
    /// 命令清理前后对比得到的释放量（GB）
    var commandFreed: Double? = nil

    var total: Double { commandFreed ?? files.compactMap(\.size).reduce(0, +) }
    var canRestore: Bool { !restored && files.contains(where: \.isInTrash) }
}

enum HistoryStore {
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Adieu")
    }
    private static var file: URL { folder.appending(path: "history.json") }

    static func load() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    static func save(_ entries: [HistoryEntry]) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: file, options: .atomic) }
    }
}
