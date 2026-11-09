import Foundation

/// 读取已安装的应用。只读，不改动任何文件。
/// 数据目录只认应用包内实际声明的 Bundle ID 和共享组，不按名称猜归属。
enum AppScanner {
    /// 第一步：列出应用，不统计大小，很快。running 是正在运行的应用包路径
    static func list(running: Set<String>) -> [AppItem] {
        let fm = FileManager.default
        let roots = [URL(filePath: "/Applications"), fm.homeDirectoryForCurrentUser.appending(path: "Applications")]
            + InputMethods.roots(home: fm.homeDirectoryForCurrentUser)
        let urls = roots.flatMap { AppBundleIndex.installed(in: $0) }
        let index = AppBundleIndex(urls: urls + AppBundleIndex.installed(in: URL(filePath: "/System/Applications")),
                                   runningURLs: AppBundleIndex.runningURLs())
        var seen: Set<String> = []
        var result: [AppItem] = []
        let agents = LaunchScanner.entries().filter(\.isUser)
        let listed = Set(urls.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        for app in index.applications where listed.contains(app.url.path) {
            guard let item = item(app, running: running, agents: agents, index: index), seen.insert(item.id).inserted else { continue }
            result.append(item)
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
                    evidence: p.evidence, defaultOn: p.defaultOn, ownerIDs: p.ownerIDs)
        }
        return app
    }

    /// 重新读一个应用（清理过数据后用），已经不在了返回 nil
    static func rescan(_ app: AppItem, running: Set<String>) -> AppItem? {
        guard let path = app.path else { return app }
        let url = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath()
        let urls = AppBundleIndex.roots(home: FileManager.default.homeDirectoryForCurrentUser).flatMap { AppBundleIndex.installed(in: $0) }
        let index = AppBundleIndex(urls: urls + [url], runningURLs: AppBundleIndex.runningURLs())
        guard let application = index.applications.first(where: { $0.url == url }) else { return nil }
        return item(application, running: running, agents: LaunchScanner.entries().filter(\.isUser), index: index).map(measured)
    }

    private static func item(_ app: AppBundleIndex.Application, running: Set<String>, agents: [LaunchScanner.Entry], index: AppBundleIndex) -> AppItem? {
        let url = app.url, id = app.id
        guard let bundle = Bundle(url: url) else { return nil }
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
        parts += dataParts(for: app, index: index)
        // 这个应用自己装的开机启动项（只限 ~/Library/LaunchAgents，系统目录里的要管理员密码）
        for a in agents where a.program?.hasPrefix(url.path + "/") == true {
            parts.append(AppPart(id: "agent.\(a.label)", kind: .background, label: String(localized: "开机启动项 \(a.label)"), path: tilde(a.plist),
                                 size: nil, evidence: .bundle, defaultOn: true))
        }

        let inputMethod = InputMethods.isInputMethod(url, info: bundle.infoDictionary)
        var meta = fromAppStore ? String(localized: "App Store · 随时可以重新下载") : [version.map { String(localized: "版本 \($0)") }, id].compactMap(\.self).joined(separator: " · ")
        if inputMethod { meta = String(localized: "输入法") + " · " + meta }
        var notice = fromAppStore ? String(localized: "这是 App Store 应用，卸载后可以在 App Store 免费重新下载。") : nil
        if inputMethod {
            notice = String(localized: "这是输入法。卸载时 Adieu 会先在系统里停用它；删完注销或重启一次，输入法菜单里才会彻底消失。")
        }

        return AppItem(id: url.path, name: name, monogram: String(name.prefix(1)), color: .gray,
                       meta: meta,
                       isRunning: running.contains(url.path),
                       notice: notice,
                       parts: parts, path: url.path, isMeasured: false, bundle: id)
    }

    /// 只查库内的独立数据目录，不把主容器里的数据库、缓存再列一次。
    static func dataParts(for app: AppBundleIndex.Application, index: AppBundleIndex,
                          home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [AppPart] {
        let fm = FileManager.default
        let library = home.appending(path: "Library").standardizedFileURL.resolvingSymlinksInPath()
        let homePath = home.standardizedFileURL.resolvingSymlinksInPath().path
        var parts: [AppPart] = []
        var positions: [String: Int] = [:]
        let ids = app.bundleIDs.filter { $0 == app.id || !$0.lowercased().hasPrefix("com.apple.") }.sorted()
        let lowerIDs = Set(ids.map { $0.lowercased() })
        let groups = Set(app.groupIDs.map { $0.lowercased() })

        func add(_ key: String, _ label: String, _ sub: String, shared: Bool, owners: Set<String>, byName: Bool = false) {
            let url = library.appending(path: sub).standardizedFileURL
            // TrashService 会解析链接后删除目标；此处不收指向别处的替身，防止误归属或重复计算。
            guard fm.fileExists(atPath: url.path), url.resolvingSymlinksInPath().path == url.path else { return }
            let path = url.path.hasPrefix(homePath + "/") ? "~" + url.path.dropFirst(homePath.count) : url.path
            let part = AppPart(id: key, kind: shared ? .shared : .data, label: label,
                               path: path, size: nil,
                               evidence: shared ? .shared : byName ? .name : .exact, defaultOn: !shared, ownerIDs: owners.union([app.id]))
            if let position = positions[url.path] {
                // 已经按标识符找到的，不再按名字重复列
                if byName { return }
                let combined = parts[position].ownerIDs.union(part.ownerIDs)
                if shared { parts[position] = part }
                parts[position].ownerIDs = combined
            } else {
                positions[url.path] = parts.count
                parts.append(part)
            }
        }

        for id in ids {
            let shared = index.otherAppsUse(bundleID: id, than: app)
            for (key, label, sub) in dataLocations(for: id) {
                add(id == app.id ? key : "\(key).\(id)", id == app.id ? label : label + " · " + id, sub,
                    shared: shared, owners: index.ownerIDs(bundleID: id))
            }
        }
        for (place, key, label) in [("Group Containers", "group", String(localized: "共享容器")),
                                     ("Application Scripts", "scripts.group", String(localized: "应用脚本"))] {
            for name in ((try? fm.contentsOfDirectory(atPath: library.appending(path: place).path)) ?? []).sorted() {
                guard AppBundleIndex.validIdentifier(name) else { continue }
                let bare = LeftoverScanner.stripTeam(name).lowercased()
                let ownerID = bare.hasPrefix("group.") ? String(bare.dropFirst(6)) : bare
                guard groups.contains(name.lowercased()) || lowerIDs.contains(ownerID) else { continue }
                let shared = index.otherAppsUse(groupID: name, than: app)
                    || index.otherAppsUse(bundleID: ownerID, than: app)
                add("\(key).\(name)", label, "\(place)/\(name)", shared: shared,
                    owners: index.ownerIDs(groupID: name).union(index.ownerIDs(bundleID: ownerID)))
            }
        }
        // 有的应用按名字建文件夹（如微信输入法的 Application Support/WeType）。只认整名相等（不分大小写），
        // 别的已装应用也叫这个名字时不列
        let names = AppBundleIndex.matchNames(app.url).filter { !index.otherAppsUse(name: $0, than: app) }
        if !names.isEmpty {
            for (place, key, label) in [("Application Support", "support", String(localized: "应用支持文件")),
                                         ("Caches", "caches", String(localized: "缓存")),
                                         ("HTTPStorages", "http", String(localized: "网络缓存")),
                                         ("Logs", "logs", String(localized: "日志"))] {
                for entry in ((try? fm.contentsOfDirectory(atPath: library.appending(path: place).path)) ?? []).sorted()
                where names.contains(entry.lowercased()) {
                    add("\(key).name.\(entry)", label + " · " + entry, "\(place)/\(entry)", shared: false, owners: [], byName: true)
                }
            }
        }
        return parts
    }

    /// 以 Bundle ID 命名、只属于这个应用的位置（相对 ~/Library）
    private static func dataLocations(for id: String) -> [(String, String, String)] {
        [("container", String(localized: "沙盒数据"), "Containers/\(id)"),
         ("support", String(localized: "应用支持文件"), "Application Support/\(id)"),
         ("caches", String(localized: "缓存"), "Caches/\(id)"),
         ("http", String(localized: "网络缓存"), "HTTPStorages/\(id)"),
         ("webkit", String(localized: "网页数据"), "WebKit/\(id)"),
         ("logs", String(localized: "日志"), "Logs/\(id)"),
         ("prefs", String(localized: "偏好设置"), "Preferences/\(id).plist"),
         ("state", String(localized: "窗口状态"), "Saved Application State/\(id).savedState"),
         ("scripts", String(localized: "应用脚本"), "Application Scripts/\(id)")]
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
