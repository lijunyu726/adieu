import Foundation

/// Claude Code 官方的技能开关：settings.json 里的 skillOverrides。
/// 值为 "user-invocable-only" 时 Claude 不会自己调用这个技能，用户输入 /名字 仍然能用。
/// 用它来做“仅点名调用”，就不用改技能文件（技能常是链接到别的仓库的）
enum ClaudeSkillOverrides {
    static let explicit = "user-invocable-only"

    enum EditError: LocalizedError {
        case unreadable(URL)
        case changed(URL)

        var errorDescription: String? {
            switch self {
            case .unreadable(let url): String(localized: "读不懂 Claude Code 的设置文件，没有改动：\(url.path)")
            case .changed(let url): String(localized: "文件在保存前发生了变化：\(url.path)")
            }
        }
    }

    /// 没有设置文件或没有这一项时返回空
    static func read(_ settings: URL) throws -> [String: String] {
        guard let data = try? Data(contentsOf: settings) else { return [:] }
        let root = try object(data, settings)
        return (root["skillOverrides"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
    }

    /// value 为 nil 时去掉这个技能的条目；skillOverrides 空了就整个去掉。
    /// 设置文件是链接时改链接指向的文件，不把链接换成普通文件
    static func set(_ name: String, to value: String?, in settings: URL) throws {
        let file = settings.resolvingSymlinksInPath()
        let before = try? Data(contentsOf: file)
        var root = try before.map { try object($0, settings) } ?? [:]
        if root["skillOverrides"] != nil && root["skillOverrides"] as? [String: Any] == nil { throw EditError.unreadable(settings) }
        var overrides = root["skillOverrides"] as? [String: Any] ?? [:]
        let current = overrides[name]
        if value == nil ? current == nil : (current as? String) == value { return }
        overrides[name] = value
        root["skillOverrides"] = overrides.isEmpty ? nil : overrides
        let after = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        // 读和写之间文件被 Claude Code 自己改了，就不覆盖
        guard (try? Data(contentsOf: file)) == before else { throw EditError.changed(settings) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 设置文件里常有密钥，原子写入会换成新文件，要把原来的权限（通常是 600）带过去
        let permissions = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions] ?? NSNumber(value: 0o600)
        try (after + Data("\n".utf8)).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
    }

    private static func object(_ data: Data, _ url: URL) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw EditError.unreadable(url) }
        return root
    }
}
