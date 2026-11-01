import Foundation

/// 主程序扫描完写给桌面组件的数据：分类大小、能腾出多少、可以清理的几项。
/// 剩余空间组件自己现读；这里的分类是上次扫描的结果，按 `date` 标“统计于”。
/// 组件在沙盒里，只能读这一个文件夹（见 AdieuWidget.entitlements）
struct WidgetFeed: Codable, Sendable {
    struct Category: Codable, Sendable {
        let label: String
        let size: Double
        /// sRGB，0–1
        let rgb: [Double]
    }
    struct Item: Codable, Sendable {
        let title: String
        let size: Double?
    }
    let date: Date
    let categories: [Category]
    /// 建议里加起来能腾出的空间（GB）
    let reclaimable: Double
    let items: [Item]
    /// 这一周多用（正）或空出（负）了多少；记录不到两天时为 nil
    let weekChange: Double?

    /// 真正的主目录：沙盒里 homeDirectoryForCurrentUser 指向自己的容器
    static var file: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(filePath: home).appending(path: "Library/Application Support/Adieu/widget.json")
    }

    static func load() -> WidgetFeed? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(WidgetFeed.self, from: data)
    }

    func save() {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(self) else { return }
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.file, options: .atomic)
    }
}
