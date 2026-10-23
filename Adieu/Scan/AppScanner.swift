import Foundation

/// 读取已安装的应用。只读，不改动任何文件。
/// 数据目录只收 Bundle ID 完全匹配的几处；按开发者或名称推断的归“残留文件”处理。
enum AppScanner {
    /// 第一步：列出应用，不统计大小，很快
    static func list(running: Set<String>) -> [AppItem] {
        let fm = FileManager.default
        let roots = [URL(filePath: "/Applications"), fm.homeDirectoryForCurrentUser.appending(path: "Applications")]
        var seen: Set<String> = []
        var result: [AppItem] = []
        let agents = LaunchScanner.entries().filter(\.isUser)
        for root in roots {
            for url in bundles(in: root, depth: 1) {
                guard let item = item(at: url, running: running, agents: agents), seen.insert(item.id).inserted else { continue }
                result.append(item)
            }
        }
        return result
    }

    /// 第二步：统计每个部分占用的空间，应用越大越慢
    static func measured(_ app: AppItem) -> AppItem {
        var app = app
        app.isMeasured = true
        app.parts = app.parts.map { p in
            AppPart(id: p.id, kind: p.kind, label: p.label, path: p.path,
                    size: allocatedSize(URL(filePath: (p.path as NSString).expandingTildeInPath)),
                    evidence: p.evidence, defaultOn: p.defaultOn)
        }
        return app
    }

    /// 根目录下的 .app；普通文件夹（如 Utilities、Adobe 的套件目录）再往下看一层
    private static func bundles(in dir: URL, depth: Int) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return urls.flatMap { url -> [URL] in
            if url.pathExtension == "app" { return [url] }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDir && depth > 0 ? bundles(in: url, depth: depth - 1) : []
        }
    }

    /// 重新读一个应用（清理过数据后用），已经不在了返回 nil
    static func rescan(_ app: AppItem, running: Set<String>) -> AppItem? {
        guard let path = app.path else { return app }
        return item(at: URL(filePath: path), running: running, agents: LaunchScanner.entries().filter(\.isUser)).map(measured)
    }

    private static func item(at url: URL, running: Set<String>, agents: [LaunchScanner.Entry]) -> AppItem? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        let fm = FileManager.default
        let fromAppStore = fm.fileExists(atPath: url.appending(path: "Contents/_MASReceipt").path)
        // 系统自带的应用受签名保护，不能也不需要卸载
        if id.hasPrefix("com.apple.") && !fromAppStore { return nil }

        let name = fm.displayName(atPath: url.path).replacing(/\.app$/, with: "")
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        let home = fm.homeDirectoryForCurrentUser.path
        let tilde = { (abs: String) in abs.hasPrefix(home) ? "~" + abs.dropFirst(home.count) : abs }

        var parts = [AppPart(id: "app", kind: .app, label: url.lastPathComponent, path: tilde(url.path),
                             size: nil, evidence: .bundle, defaultOn: true)]
        for (key, label, sub) in dataLocations(for: id) {
            let path = "\(home)/Library/\(sub)"
            if fm.fileExists(atPath: path) {
                parts.append(AppPart(id: key, kind: .data, label: label, path: tilde(path),
                                     size: nil, evidence: .exact, defaultOn: true))
            }
        }

        // 组容器：名字去掉开发者前缀后正好是这个标识符（或 group.标识符）
        let groups = "\(home)/Library/Group Containers"
        for g in (try? fm.contentsOfDirectory(atPath: groups)) ?? [] {
            let bare = LeftoverScanner.stripTeam(g)
            if bare == id || bare == "group.\(id)" {
                parts.append(AppPart(id: "group.\(g)", kind: .data, label: "共享容器", path: tilde("\(groups)/\(g)"),
                                     size: nil, evidence: .exact, defaultOn: true))
            }
        }
        // 这个应用自己装的开机启动项（只限 ~/Library/LaunchAgents，系统目录里的要管理员密码）
        for a in agents where a.program?.hasPrefix(url.path + "/") == true {
            parts.append(AppPart(id: "agent.\(a.label)", kind: .background, label: String(localized: "开机启动项 \(a.label)"), path: tilde(a.plist),
                                 size: nil, evidence: .bundle, defaultOn: true))
        }

        return AppItem(id: id, name: name, monogram: String(name.prefix(1)), color: .gray,
                       meta: fromAppStore ? String(localized: "App Store · 随时可以重新下载") : [version.map { String(localized: "版本 \($0)") }, id].compactMap(\.self).joined(separator: " · "),
                       isRunning: running.contains(id),
                       notice: fromAppStore ? String(localized: "这是 App Store 应用，卸载后可以在 App Store 免费重新下载。") : nil,
                       parts: parts, path: url.path, isMeasured: false)
    }

    /// 以 Bundle ID 命名、只属于这个应用的位置（相对 ~/Library）
    private static func dataLocations(for id: String) -> [(String, String, String)] {
        [("container", "沙盒数据", "Containers/\(id)"),
         ("support", "应用支持文件", "Application Support/\(id)"),
         ("caches", "缓存", "Caches/\(id)"),
         ("http", "网络缓存", "HTTPStorages/\(id)"),
         ("webkit", "网页数据", "WebKit/\(id)"),
         ("logs", "日志", "Logs/\(id)"),
         ("prefs", "偏好设置", "Preferences/\(id).plist"),
         ("state", "窗口状态", "Saved Application State/\(id).savedState")]
    }

    /// 实际占用的磁盘空间（GB）；读不了的子项跳过，整项不存在时返回 nil
    static func allocatedSize(_ url: URL) -> Double? {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey]
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        guard isDir.boolValue else {
            return (try? url.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize).map { Double($0) / bytesPerGB }
        }
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, errorHandler: { _, _ in true }) else { return nil }
        var bytes = 0
        while let f = e.nextObject() as? URL {
            bytes += (try? f.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize) ?? 0
        }
        return Double(bytes) / bytesPerGB
    }
}
