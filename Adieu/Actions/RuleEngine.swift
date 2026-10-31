import Foundation

/// 自动规则：Adieu 在运行时（包括只在菜单栏）每小时、每次扫描完时检查一遍。
/// 提醒类每条每天最多提醒一次；自动执行的只有能重新生成的缓存，以及只移动不删除的截图归档
@MainActor
enum RuleEngine {
    private static let defaults = UserDefaults.standard

    /// 规则卡片上的一句现状
    static func status(_ id: String, _ m: AppModel) -> String {
        if m.useSample { return Sample.rules.first { $0.id == id }?.status ?? "" }
        switch id {
        case "pkg":
            let fs = oldInstallers(m)
            let n = fs.count
            let size = fs.map(\.size).reduce(0, +).gbText
            return fs.isEmpty ? String(localized: "目前没有符合的") : String(localized: "目前有 \(n) 个符合，共 \(size)")
        case "low":
            let pct = Int((m.disk.free / m.disk.total * 100).rounded())
            return String(localized: "现在可用 \(pct)%") + (pct < 10 ? String(localized: "，已触发") : "")
        case "cache":
            let r = m.devTools.filter { ["brew", "node", "python"].contains($0.id) }.map(\.reclaimable).reduce(0, +)
            let last = defaults.object(forKey: "rule.cache.lastRun") as? Date
            let size = r.gbText
            let when = last.map { String(localized: " · 上次 \($0.formatted(.dateTime.month().day()))") } ?? ""
            return String(localized: "现在可回收约 \(size)") + when
        case "shot":
            let n = m.oldShotCount ?? 0
            return n == 0 ? String(localized: "桌面上没有放了 30 天的截图 · 只移动，不删除") : String(localized: "\(n) 张截图可以归档 · 只移动，不删除")
        case "wx":
            let wx = m.apps.first { $0.id == "com.tencent.xinWeChat" }?.dataSize
            return wx.map { let size = $0.gbText; return String(localized: "现在是 \(size)") } ?? String(localized: "没有找到微信")
        default: return ""
        }
    }

    /// 下载里对应应用已装好、文件放了 7 天以上的安装包
    static func oldInstallers(_ m: AppModel) -> [FileItem] {
        let week = Date.now.addingTimeInterval(-7 * 86400)
        return (m.category(.installers)?.items ?? []).filter { f in
            guard f.modified.hasSuffix("已安装"), let p = f.path,
                  let d = try? URL(filePath: p).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return false }
            return d < week
        }
    }

    /// 桌面上放了 30 天以上的截图（只看桌面第一层）。要把桌面列一遍，在后台调用
    nonisolated static func oldScreenshots() -> [URL] {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop")
        let month = Date.now.addingTimeInterval(-30 * 86400)
        let urls = (try? FileManager.default.contentsOfDirectory(at: desktop, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls.filter { u in
            guard FileScanner.screenshotExts.contains(u.pathExtension.lowercased()),
                  let d = try? u.resourceValues(forKeys: [.creationDateKey]).creationDate else { return false }
            return d < month
        }
    }

    /// 同一条提醒每天最多一次
    private static func remindOnce(_ id: String, every interval: TimeInterval = 86400, title: String, body: String) {
        let key = "rule.\(id).lastNotified"
        if let last = defaults.object(forKey: key) as? Date, Date.now.timeIntervalSince(last) < interval { return }
        defaults.set(Date.now, forKey: key)
        Notifier.post(id: "rule.\(id)", title: title, body: body)
    }

    static func evaluate(_ m: AppModel) async {
        guard !m.useSample else { return }
        let on = m.enabledRules
        if on.contains("low"), m.disk.free / m.disk.total < 0.1 {
            remindOnce("low", title: String(localized: "磁盘空间只剩 \(m.disk.free.gbText)"),
                       body: String(localized: "低于 10% 时系统会变慢，更新也可能装不上。打开 Adieu，用“腾出空间”一键处理。"))
        }
        if on.contains("pkg") {
            let fs = oldInstallers(m)
            if !fs.isEmpty {
                remindOnce("pkg", title: String(localized: "\(fs.count) 个安装包可以删了"), body: String(localized: "对应的应用都已经装好超过 7 天，共 \(fs.map(\.size).reduce(0, +).gbText)。"))
            }
        }
        if on.contains("wx"), let wx = m.apps.first(where: { $0.id == "com.tencent.xinWeChat" }), wx.dataSize > 20 {
            remindOnce("wx", every: 7 * 86400, title: String(localized: "微信的数据有 \(wx.dataSize.gbText) 了"),
                       body: String(localized: "在微信的“设置 › 通用 › 存储空间”里可以按聊天清理。"))
        }
        if on.contains("shot") { await archiveScreenshots(m) }
        if on.contains("cache") { await weeklyCache(m) }
        await countScreenshots(m)
    }

    /// 规则卡片上的张数：界面重画时不现数桌面，规则检查时数一遍记下
    static func countScreenshots(_ m: AppModel) async {
        guard !m.useSample else { return }
        m.oldShotCount = await blocking { oldScreenshots().count }
    }

    /// 周日 21:00 以后，距上次超过 6 天就跑一次 Homebrew、npm、uv 的清理命令
    private static func weeklyCache(_ m: AppModel) async {
        let cal = Calendar.current
        let now = Date.now
        guard cal.component(.weekday, from: now) == 1, cal.component(.hour, from: now) >= 21 else { return }
        if let last = defaults.object(forKey: "rule.cache.lastRun") as? Date, now.timeIntervalSince(last) < 6 * 86400 { return }
        defaults.set(now, forKey: "rule.cache.lastRun")
        let before = m.disk.free
        for tool in m.devTools where ["brew", "node", "python"].contains(tool.id) && tool.blocked == nil {
            await m.runDev(tool)
        }
        Notifier.post(id: "rule.cache", title: String(localized: "每周清理开发缓存：完成"), body: String(localized: "腾出约 \(max(0, m.disk.free - before).gbText)。记录在“最近”里。"))
    }

    /// 桌面上放了 30 天的截图移到“图片/截图归档/年-月”，只移动
    private static func archiveScreenshots(_ m: AppModel) async {
        let moved = await blocking { () -> Int in
            let shots = oldScreenshots()
            let fm = FileManager.default
            let root = fm.homeDirectoryForCurrentUser.appending(path: "Pictures/截图归档")
            var moved = 0
            for u in shots {
                let d = (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
                let folder = root.appending(path: d.formatted(.iso8601.year().month()))
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let dest = folder.appending(path: u.lastPathComponent)
                if !fm.fileExists(atPath: dest.path), (try? fm.moveItem(at: u, to: dest)) != nil { moved += 1 }
            }
            return moved
        }
        if moved > 0 {
            var entry = HistoryEntry(date: .now, title: String(localized: "把 \(moved) 张截图移到“截图归档”"), source: "自动规则", files: [])
            entry.commandNote = String(localized: "只移动，没有删除：~/Pictures/截图归档")
            entry.commandFreed = 0
            m.history.insert(entry, at: 0)
            HistoryStore.saveLater(m.history)
        }
    }
}
