import Foundation

/// 软件自己向系统登记的开机启动：在软件自己的设置里打开“开机启动”时，软件用 SMAppService 等方式登记，
/// 系统记在后台任务管理（BTM）的账本里，系统设置“登录项与扩展”就是读这份账本。
/// `sfltool dumpbtm` 不用管理员密码就能读出来（macOS 27 实测）。输出是诊断用的文本，没有公开格式，
/// 所以只认几个字段，读不到或认不出时整块不显示，不报错。
/// 这些项只有软件自己或系统设置能改，Adieu 只显示状态、带人去系统设置
enum RegisteredItems {
    struct Item: Identifiable, Hashable, Sendable {
        enum Kind: Sendable { case app, loginItem, agent }
        let id: String
        let name: String
        let kind: Kind
        /// 软件登记了（在它自己的设置里开着）
        let enabled: Bool
        /// 系统设置里允许它运行
        let allowed: Bool
        /// 属于哪个应用；app 类就是它自己
        let appName: String
        let appPath: String
        let appExists: Bool

        var running: Bool { enabled && allowed }
    }

    static func scan() -> [Item] {
        guard let r = Shell.run("/usr/bin/sfltool", ["dumpbtm"], timeout: 20), r.status == 0 else { return [] }
        return parse(r.out, uid: getuid(), home: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    /// 只看当前用户那一段。每条记录以 “#数字:” 开头，下面是 “字段: 值”
    static func parse(_ text: String, uid: uid_t, home: String) -> [Item] {
        var records: [[String: String]] = []
        var current: [String: String]?
        var mine = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Records for UID ") {
                if let c = current, mine { records.append(c) }
                current = nil
                mine = line.hasPrefix("Records for UID \(uid) ")
                continue
            }
            guard mine else { continue }
            if line.hasPrefix("#"), line.hasSuffix(":"), Int(line.dropFirst().dropLast()) != nil {
                if let c = current { records.append(c) }
                current = [:]
                continue
            }
            guard current != nil, let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            current?[key] = value
        }
        if let c = current, mine { records.append(c) }

        // 路径里的用户目录写成了 /Users/<uid>
        func fix(_ path: String) -> String {
            let prefix = "/Users/\(uid)/"
            return path.hasPrefix(prefix) ? home + "/" + path.dropFirst(prefix.count) : path
        }
        var parents: [String: (name: String, path: String)] = [:]
        for r in records where r["Type"]?.hasPrefix("app ") == true {
            if let id = r["Identifier"], let url = r["URL"] { parents[id] = (r["Name"] ?? "", fix(url)) }
        }

        return records.compactMap { r -> Item? in
            guard let type = r["Type"], let name = r["Name"], name != "(null)", let url = r["URL"], url != "(null)" else { return nil }
            let kind: Item.Kind
            switch type {
            case _ where type.hasPrefix("app "): kind = .app
            case _ where type.hasPrefix("login item "): kind = .loginItem
            case _ where type.hasPrefix("agent "): kind = .agent  // “legacy agent” 是 LaunchAgents 里的 plist，下面那块已经管了
            default: return nil
            }
            let tokens = Set((r["Disposition"] ?? "").drop { $0 != "[" }.dropFirst().prefix { $0 != "]" }
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            let enabled = tokens.contains("enabled"), allowed = tokens.contains("allowed")
            // app 类数量很多（装过的、开过的都在），只有登记了开机启动的才算
            if kind == .app && !enabled { return nil }
            let app: (name: String, path: String)
            if kind == .app {
                app = (name, fix(url))
            } else if let parent = r["Parent Identifier"].flatMap({ parents[$0] }) {
                app = parent
            } else {
                return nil
            }
            return Item(id: r["UUID"] ?? "\(app.path)#\(name)", name: name, kind: kind, enabled: enabled, allowed: allowed,
                        appName: app.name, appPath: app.path, appExists: FileManager.default.fileExists(atPath: app.path))
        }
        // 正在起作用的排前面，同一组按应用名
        .sorted { a, b in
            if a.running != b.running { return a.running }
            return a.appName.localizedStandardCompare(b.appName) == .orderedAscending
        }
    }
}
