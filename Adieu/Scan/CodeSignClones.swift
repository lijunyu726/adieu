import AppKit

/// 应用的“签名副本”：Chrome 等应用启动时把自己整个复制一份到 /var/folders/…/X/<bundle id>.code_sign_clone/ 下，
/// 这样它在后台原地更新时，正在运行的那份签名仍然有效。正常退出会删掉；被强制结束（自动化测试、崩溃）就会留下。
/// 副本是 APFS 克隆，和复制时的应用本体共用存储块：同一个版本的副本几乎不占真实空间，
/// 只有应用更新后，旧版本的副本才独占旧版本的那份数据（同一旧版本的多个副本之间仍然共用）
enum CodeSignClones {
    struct Summary: Sendable, Hashable {
        /// 副本份数
        var count = 0
        /// 按每份完整大小加起来（各种工具看到的“几百 GB”）
        var logical = 0.0
        /// 按克隆去重后的估算真实占用
        var real = 0.0
        /// 可以删的副本：对应的应用没在运行，或副本早于应用这次启动
        var removable: [String] = []
        /// 删掉 removable 估计腾出的空间，按路径记，交给删除确认和删后核对
        var removableSizes: [String: Double] = [:]
        /// 涉及的应用名，如“Google Chrome”
        var apps: [String] = []
    }

    private struct Clone {
        let path: String
        let bundleID: String
        let version: String
        let created: Date
    }

    /// 放副本的目录，和 DARWIN_USER_TEMP_DIR（…/T/）同级
    static var root: URL? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count) > 0 else { return nil }
        let path = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let temp = URL(filePath: path, directoryHint: .isDirectory)
        return temp.deletingLastPathComponent().appending(path: "X", directoryHint: .isDirectory)
    }

    /// 是不是 X/<bundle id>.code_sign_clone/code_sign_clone.XXXXXX 这一层。删除前的安全检查用
    static func isClone(_ path: String) -> Bool {
        guard let root else { return false }
        let base = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let parts = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard parts.count == base.count + 2, parts.starts(with: base) else { return false }
        return parts[base.count].hasSuffix(".code_sign_clone") && parts[base.count + 1].hasPrefix("code_sign_clone.")
    }

    static func scan() -> Summary {
        guard let root else { return Summary() }
        let fm = FileManager.default
        var clones: [Clone] = []
        for folder in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where folder.hasSuffix(".code_sign_clone") {
            let bundleID = String(folder.dropLast(".code_sign_clone".count))
            let dir = root.appending(path: folder)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix("code_sign_clone.") {
                let url = dir.appending(path: name)
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                clones.append(Clone(path: url.path, bundleID: bundleID, version: version(in: url) ?? "", created: created))
            }
        }
        guard !clones.isEmpty else { return Summary() }

        var s = Summary(count: clones.count)
        for (bundleID, group) in Dictionary(grouping: clones, by: \.bundleID) {
            let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            let installedVersion = installed.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
            s.apps.append(installed.map { $0.deletingPathExtension().lastPathComponent } ?? bundleID)
            // 应用开着时，它这次启动后做的副本可能正在用，留着；多开时按最早那次算
            let launched = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).compactMap(\.launchDate).min()
            for (version, same) in Dictionary(grouping: group, by: \.version) {
                // 同一版本的副本互相共用存储，量一份就够
                let one = same.first.flatMap { AppScanner.allocatedSize(URL(filePath: $0.path)) } ?? 0
                s.logical += one * Double(same.count)
                let own = version == installedVersion ? 0 : one
                s.real += own
                let removable = same.filter { c in launched.map { c.created < $0.addingTimeInterval(-60) } ?? true }
                s.removable += removable.map(\.path)
                // 独占的那份记在第一份可删的副本上；版本里还有留着的副本时，删了也腾不出来
                if removable.count == same.count, let first = removable.first { s.removableSizes[first.path] = own }
                for c in removable where s.removableSizes[c.path] == nil { s.removableSizes[c.path] = 0 }
            }
        }
        s.apps.sort()
        return s
    }

    /// 副本里应用的版本号：X/…/code_sign_clone.XXXXXX/<名字>.app.bundle/Contents/Info.plist
    private static func version(in clone: URL) -> String? {
        let inner = (try? FileManager.default.contentsOfDirectory(at: clone, includingPropertiesForKeys: nil))?.first
        guard let plist = inner?.appending(path: "Contents/Info.plist"),
              let info = NSDictionary(contentsOf: plist) else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }
}
