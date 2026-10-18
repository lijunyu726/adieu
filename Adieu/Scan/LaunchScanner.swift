import Foundation

/// 开机与后台：读 LaunchAgents / LaunchDaemons 里的 plist。只读
enum LaunchScanner {
    struct Entry {
        let label: String
        let plist: String
        let program: String?
        let isUser: Bool
        let isDaemon: Bool
    }

    static func entries() -> [Entry] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let dirs: [(String, Bool, Bool)] = [("\(home)/Library/LaunchAgents", true, false), ("/Library/LaunchAgents", false, false), ("/Library/LaunchDaemons", false, true)]
        var result: [Entry] = []
        for (dir, user, daemon) in dirs {
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".plist") {
                let path = "\(dir)/\(name)"
                let dict = NSDictionary(contentsOfFile: path) as? [String: Any] ?? [:]
                let label = dict["Label"] as? String ?? String(name.dropLast(6))
                let program = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first
                result.append(Entry(label: label, plist: path, program: program, isUser: user, isDaemon: daemon))
            }
        }
        return result
    }

    /// 程序在哪个 .app 里就用应用名，否则用标签
    static func owner(_ e: Entry) -> String {
        if let p = e.program, let r = p.range(of: ".app/") {
            return ((String(p[..<r.lowerBound]) as NSString).lastPathComponent)
        }
        let generic: Set<String> = ["sh", "bash", "zsh", "env", "python", "python3", "node", "ssh", "open", "ruby", "perl", "bun"]
        if let p = e.program, !generic.contains((p as NSString).lastPathComponent) { return (p as NSString).lastPathComponent }
        let parts = e.label.split(separator: ".")
        return parts.count > 2 ? parts.dropFirst().joined(separator: ".") : e.label
    }

    static func scan() -> [LaunchGroup] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let loaded = Set((SpaceScanner.run("/bin/launchctl", ["list"]) ?? "").split(separator: "\n").compactMap { $0.split(separator: "\t").last.map(String.init) })
        var broken: [LaunchItem] = [], root: [LaunchItem] = [], updater: [LaunchItem] = [], mine: [LaunchItem] = [], other: [LaunchItem] = []
        for e in entries() {
            let item = LaunchItem(owner: owner(e), label: e.label, plist: e.plist, isUser: e.isUser, loaded: loaded.contains(e.label))
            let lower = e.label.lowercased()
            // 程序路径里可能带参数占位，只检查绝对路径
            if let p = e.program, p.hasPrefix("/"), !fm.fileExists(atPath: p) { broken.append(item) }
            else if !e.isUser { root.append(item) }
            else if ["update", "keystone", "shipit"].contains(where: lower.contains) { updater.append(item) }
            else if let p = e.program, !p.contains(".app/") || p.hasPrefix(home) { mine.append(item) }
            else { other.append(item) }
        }
        let t = Dictionary(uniqueKeysWithValues: Sample.launchGroups.map { ($0.id, $0) })
        return [
            LaunchGroup(id: "broken", title: "已失效", note: t["broken"]!.note, color: .red, action: "可以移除", items: broken),
            LaunchGroup(id: "root", title: "系统级（需要管理员密码）", note: "装在系统目录里，权限很高。确认是你信任、正在用的软件。移除需要管理员密码，Adieu 只帮你在访达里找到它。", color: .orange, action: "需要密码", items: root),
            LaunchGroup(id: "updater", title: "自动更新程序", note: t["updater"]!.note, color: .blue, action: "可以关闭", items: updater),
            LaunchGroup(id: "mine", title: "你自己创建的", note: t["mine"]!.note, color: .green, action: "保留", items: mine),
            LaunchGroup(id: "other", title: "其他应用的后台程序", note: "应用自己装的后台程序。不再用这个应用的话可以移除。", color: .purple, action: "可以移除", items: other)
        ].filter { !$0.items.isEmpty }
    }

    /// 停用（只限 ~/Library/LaunchAgents），之后 plist 由调用方删除
    static func unload(_ item: LaunchItem) {
        guard item.isUser else { return }
        // 有标签就按标签停用（plist 已经移走也行），否则按 plist 路径
        if !item.label.isEmpty {
            _ = SpaceScanner.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(item.label)"])
        } else if let plist = item.plist {
            _ = SpaceScanner.run("/bin/launchctl", ["bootout", "gui/\(getuid())", plist])
        }
    }
}
