import AppKit

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

    /// 一次删几千个文件，记录就有几 MB，编码和写盘放到后台；排成一队，后存的不会被先存的盖掉
    private static let queue = DispatchQueue(label: "com.ljy.adieu.history")

    static func saveLater(_ entries: [HistoryEntry]) {
        queue.async { save(entries) }
    }

    static func flush() { queue.sync {} }
}

/// 卸载掉的应用在“最近”里还显示原来的图标：删之前存一张 128 像素的 PNG，按应用包的名字存
enum IconStore {
    private static var folder: URL { HistoryStore.folder.appending(path: "icons") }
    private static func file(_ path: String) -> URL { folder.appending(path: (path as NSString).lastPathComponent + ".png") }

    static func remember(_ path: String) {
        guard path.hasSuffix(".app"), FileManager.default.fileExists(atPath: path),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSWorkspace.shared.icon(forFile: path).draw(in: NSRect(x: 0, y: 0, width: 128, height: 128))
        NSGraphicsContext.restoreGraphicsState()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: file(path), options: .atomic)
    }

    static func load(_ path: String) -> NSImage? {
        guard path.hasSuffix(".app") else { return nil }
        return NSImage(contentsOf: file(path))
    }
}
