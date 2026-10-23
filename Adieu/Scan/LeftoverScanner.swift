import Foundation
import AppKit

/// 找“应用已经删了、数据还在”的东西。只读。
/// 只认标识符：找不到任何已装应用、同一开发者也没有别的应用还在，才算残留。只有名字的文件夹猜不准，不列
enum LeftoverScanner {
    /// 资源库里按应用存数据的位置（相对 ~/Library）
    static let places = ["Application Support", "Containers", "Caches", "Preferences", "Saved Application State",
                         "HTTPStorages", "WebKit", "Logs"]

    /// 系统自己的、名字不像标识符的文件夹
    static let systemNames: Set<String> = ["AddressBook", "Analytics", "Animoji", "AppExit", "AskPermission", "CallHistoryDB",
        "CallHistoryTransactions", "Categories", "CloudDocs", "ContextStore", "CrashReporter", "DifferentialPrivacy", "DiskImages",
        "DynamicIsland", "FaceTime", "FileProvider", "GNPDataStore", "IntelligenceFlow", "Knowledge", "MobileSync", "Music",
        "SESStorage", "SyncServices", "homeenergyd", "icdd", "iCloud", "locationaccessstored", "networkserviceproxy",
        "lifecycle", "default", "CloudKit", "ConversationCache", "Contrl_Ability_Cache", "CorePatch"]

    struct Owners {
        var ids: [String] = []
        var vendors: Set<String> = []
        var names: Set<String> = []
    }

    /// 所有已装应用（含系统自带）的标识符和名字，外加命令行工具名
    static func owners() -> Owners {
        var o = Owners()
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities", home.appending(path: "Applications").path]
        func add(_ url: URL) {
            guard let b = Bundle(url: url) else { return }
            if let id = b.bundleIdentifier {
                o.ids.append(id)
                o.vendors.insert(vendor(id))
            }
            for key in ["CFBundleName", "CFBundleExecutable", "CFBundleDisplayName"] {
                if let n = b.infoDictionary?[key] as? String { o.names.insert(FileCategorizer.normalize(n)) }
            }
            o.names.insert(FileCategorizer.normalize(url.deletingPathExtension().lastPathComponent))
        }
        for root in roots {
            for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
                let url = URL(filePath: root).appending(path: name)
                if name.hasSuffix(".app") { add(url) }
                else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    for sub in (try? fm.contentsOfDirectory(atPath: url.path)) ?? [] where sub.hasSuffix(".app") { add(url.appending(path: sub)) }
                }
            }
        }
        // 命令行工具也算“还在用”：它们的数据常放在 Application Support
        for dir in Shell.userPATH.split(separator: ":") {
            for n in (try? fm.contentsOfDirectory(atPath: (String(dir) as NSString).expandingTildeInPath)) ?? [] {
                o.names.insert(FileCategorizer.normalize(n))
            }
        }
        o.names.remove("")
        return o
    }

    /// com.tencent.xinWeChat → com.tencent；88L2Q4487U.com.x.y 先去掉开发者前缀
    static func vendor(_ id: String) -> String {
        id.split(separator: ".").prefix(2).joined(separator: ".").lowercased()
    }

    static func stripTeam(_ s: String) -> String {
        let parts = s.split(separator: ".", maxSplits: 1)
        if parts.count == 2, parts[0].count == 10, parts[0].allSatisfy({ $0.isUppercase || $0.isNumber }) { return String(parts[1]) }
        return s
    }

    /// com.adobe.dunamis → dunamis；Dev.ServBay.macOS.ServBay → ServBay
    static func readableName(_ id: String) -> String {
        let generic: Set<String> = ["mac", "macos", "osx", "desktop", "app", "client", "helper"]
        let words = id.split(separator: ".").dropFirst(2).map(String.init)
        return words.first { !generic.contains($0.lowercased()) } ?? words.last ?? id
    }

    static func looksLikeID(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        return parts.count >= 3 && ["com", "org", "io", "net", "ai", "dev", "app", "cn", "me", "co", "jp", "ws", "de", "uk", "us", "tv"].contains(parts[0].lowercased())
    }

    static func scan() -> [LeftoverGroup] {
        let fm = FileManager.default
        let lib = fm.homeDirectoryForCurrentUser.appending(path: "Library")
        let o = owners()
        // 同一个标识符在几个位置的数据合成一项
        var byKey: [String: [String]] = [:]
        for place in places {
            for name in (try? fm.contentsOfDirectory(atPath: lib.appending(path: place).path)) ?? [] where !name.hasPrefix(".") {
                var key = name
                for ext in [".plist", ".savedState", ".binarycookies"] where key.hasSuffix(ext) { key = String(key.dropLast(ext.count)) }
                key = stripTeam(key)
                if key.lowercased().hasPrefix("com.apple.") || systemNames.contains(key) || key.hasPrefix("Analytics") || key.hasPrefix("default.store") { continue }
                if place == "Preferences" && !looksLikeID(key) { continue }
                byKey[key, default: []].append(lib.appending(path: place).appending(path: name).path)
            }
        }

        // 正在运行的程序（可能装在别处、或者是命令行工具起的）的数据一律不算残留
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() }
        var gone: [LeftoverItem] = []
        for (key, paths) in byKey {
            let lower = key.lowercased()
            guard looksLikeID(key), !o.vendors.contains(vendor(key)) else { continue }
            // 应用本身或它的扩展、辅助程序
            if o.ids.contains(where: { lower == $0.lowercased() || lower.hasPrefix($0.lowercased() + ".") }) { continue }
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) != nil { continue }
            if running.contains(where: { lower == $0 || lower.hasPrefix($0 + ".") }) { continue }
            // 标识符里藏着应用名，如 com.citrolabs.EgoUpdater
            let words = key.split(separator: ".").dropFirst(2).map { FileCategorizer.normalize(String($0)) }
            if words.contains(where: { $0.count >= 4 && o.names.contains($0) }) { continue }
            let size = paths.compactMap { AppScanner.allocatedSize(URL(filePath: $0)) }.reduce(0, +)
            guard size >= 1.0 / 1000 else { continue }
            let home = fm.homeDirectoryForCurrentUser.path
            let shown = paths.map { "~" + $0.dropFirst(home.count) }
            let display = shown[0] + (paths.count > 1 ? String(localized: " 等 \(paths.count) 处") : "")
            // 找不到应用不等于没人在用：最近 30 天还有改动的照样列出来，但不替人勾上
            let touched = paths.compactMap { try? URL(filePath: $0).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
            let idle = touched.map { FileCategorizer.days(since: $0) }
            let fresh = idle.map { $0 < 30 } ?? false
            let evidence = fresh ? String(localized: "标识符 \(key) 找不到对应的应用，但 \(idle!) 天前还有改动，可能还有程序在用")
                                 : String(localized: "标识符 \(key) 找不到对应的应用")
            gone.append(.init(id: key, name: String(localized: "\(readableName(key)) 的数据"), path: display, evidence: evidence, size: size, defaultOn: !fresh, paths: paths))
        }

        let broken = LaunchScanner.scan().first { $0.id == "broken" }?.items.filter(\.isUser) ?? []
        gone += broken.compactMap { item in
            item.plist.map { .init(id: $0, name: String(localized: "\(item.owner) 的开机启动项"), path: "~/Library/LaunchAgents/" + ($0 as NSString).lastPathComponent,
                                   evidence: String(localized: "它要启动的程序已经不存在"), size: nil, defaultOn: true, paths: [$0]) }
        }

        func sorted(_ items: [LeftoverItem]) -> [LeftoverItem] { items.sorted { ($0.size ?? 0) > ($1.size ?? 0) } }
        return [
            LeftoverGroup(id: "gone", title: "应用已经不在了", subtitle: "标识符找不到任何已装应用，默认勾选；最近还有改动的不勾", items: sorted(gone))
        ].filter { !$0.items.isEmpty }
    }
}
