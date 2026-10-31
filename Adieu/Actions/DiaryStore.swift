import Foundation

/// 存储日记的数据：每天记一次快照（同一天多次扫描只保留最后一次），最多留 60 天。
/// 存在 ~/Library/Application Support/Adieu/snapshots.json
struct Snapshot: Codable, Sendable {
    let day: Date
    let free: Double
    let used: Double
    /// 首页各分类：名称 → GB
    let categories: [String: Double]
    /// 最大的 30 个应用：名称 → GB（应用本体 + 数据）
    let apps: [String: Double]
    /// 分类里能说出名字的那一层：分类 → 文件夹 → GB，如“你的文件 → 下载”。2026-10-21 起才记，旧快照没有
    var parts: [String: [String: Double]]? = nil
}

@MainActor
enum DiaryStore {
    private static var file: URL { HistoryStore.folder.appending(path: "snapshots.json") }

    /// 读过一次就留在内存里：首页每次重画都要用，扫描时一会儿就重画一次，不能每次都读盘解码
    private static var cache: [Snapshot]?
    private static let queue = DispatchQueue(label: "com.ljy.adieu.diary")

    static func load() -> [Snapshot] {
        if let cache { return cache }
        let all = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Snapshot].self, from: $0) } ?? []
        cache = all
        return all
    }

    /// 空间分布算完才记，否则分类不全
    static func record(_ m: AppModel) {
        guard !m.useSample, m.space != nil else { return }
        let today = Calendar.current.startOfDay(for: .now)
        var cats: [String: Double] = [:]
        var parts: [String: [String: Double]] = [:]
        for c in m.spaceCategories where c.id != "free" {
            cats[c.label] = c.size
            // 应用数据的细分是“最大的两个应用”，名单会变，应用已经单独记了；“其他”说不出是什么
            guard c.id == "mine" || c.id == "other" else { continue }
            for p in c.parts where p.label != "其他" { if let size = p.size { parts[c.label, default: [:]][p.label] = size } }
        }
        var apps: [String: Double] = [:]
        for a in m.apps.filter(\.isMeasured).sorted(by: { $0.total > $1.total }).prefix(30) { apps[a.name] = a.total }
        var all = load().filter { $0.day != today }
        all.append(Snapshot(day: today, free: m.disk.free, used: m.disk.used, categories: cats, apps: apps, parts: parts))
        all = Array(all.sorted { $0.day < $1.day }.suffix(60))
        cache = all
        let file = file, snapshots = all
        // 写盘排成一队放到后台，后写的不会被先写的盖掉
        queue.async {
            try? FileManager.default.createDirectory(at: HistoryStore.folder, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshots) { try? data.write(to: file, options: .atomic) }
        }
    }

    struct Week {
        let range: String
        /// 正数表示磁盘多用了
        let change: Double
        let days: [(day: String, gb: Double)]
        let movers: [Mover]
        let cleaned: Double
        let headline: String
    }

    /// 这周变化大的一项。能说到应用、文件夹就不只说分类
    struct Mover {
        let delta: Double
        let name: String
        let why: String
        /// 去哪一页处理
        var link: AppSection? = nil
    }

    /// 最近 7 天的变化；记录不到两天时返回 nil
    static func week(_ m: AppModel) -> Week? {
        let cal = Calendar.current
        let start = cal.startOfDay(for: .now.addingTimeInterval(-7 * 86400))
        let snaps = load().filter { $0.day >= start }
        guard let first = snaps.first, let last = snaps.last, snaps.count >= 2 else { return nil }
        let change = last.used - first.used
        var days: [(String, Double)] = []
        for (a, b) in zip(snaps, snaps.dropFirst()) {
            days.append((b.day.formatted(.dateTime.weekday(.abbreviated)), b.used - a.used))
        }
        // 谁变了：应用、文件夹比分类具体，先列它们；分类只报它们解释不了的那部分
        let links = Dictionary(m.spaceCategories.compactMap { c in c.link.map { (c.label, $0) } }, uniquingKeysWith: { a, _ in a })
        var movers: [Mover] = []
        for (name, size) in last.apps {
            let before = first.apps[name]
            let d = size - (before ?? 0)
            guard abs(d) >= 0.3 else { continue }
            let why = before == nil ? String(localized: "一周前还不在最大的 30 个应用里，可能是新装的。") : d > 0 ? String(localized: "应用和它的数据一共长大了这么多。") : String(localized: "比一周前小了。")
            movers.append(.init(delta: d, name: name, why: why, link: .apps))
        }
        // 从名单里消失、现在也找不到的，是卸载了；只是掉出前 30 名的不算
        for (name, size) in first.apps where size >= 0.3 && last.apps[name] == nil && !m.apps.contains(where: { $0.name == name }) {
            movers.append(.init(delta: -size, name: name, why: String(localized: "这周卸载了。")))
        }
        // 文件夹只能跟同样记了细分的那天比；新冒出来的（比如刚进前几名的隐藏文件夹）没有对照，不报。
        // 对照的那天晚于这周第一天时（刚开始记细分），写明从哪天算起，分类照旧整段报，不相减
        var explained: [String: Double] = [:]
        if let base = snaps.first(where: { $0.parts != nil }), base.day < last.day, let then = base.parts, let now = last.parts {
            let sameDay = base.day == first.day
            let sinceDate = base.day.formatted(.dateTime.month().day())
            for (cat, folders) in now {
                for (label, size) in folders {
                    guard let before = then[cat]?[label], abs(size - before) >= 0.5 else { continue }
                    let d = size - before
                    let catName = Copy.text(cat)
                    let why: String
                    if sameDay {
                        why = d > 0 ? String(localized: "在“\(catName)”里，这个文件夹多了这么多。") : String(localized: "在“\(catName)”里，这个文件夹少了这么多。")
                    } else {
                        why = d > 0 ? String(localized: "在“\(catName)”里，这个文件夹从 \(sinceDate) 起多了这么多。") : String(localized: "在“\(catName)”里，这个文件夹从 \(sinceDate) 起少了这么多。")
                    }
                    movers.append(.init(delta: d, name: label, why: why, link: links[cat]))
                    if sameDay { explained[cat, default: 0] += d }
                }
            }
        }
        for (name, size) in last.categories where name != "macOS 系统与其他" {
            let d = size - (first.categories[name] ?? size) - (explained[name] ?? 0)
            guard abs(d) >= 0.5, !movers.contains(where: { $0.name == name }) else { continue }
            let why = explained[name] == nil ? (d > 0 ? String(localized: "这一类整体多了这么多。") : String(localized: "这一类整体少了。"))
                : (d > 0 ? String(localized: "上面几项以外，这一类别处还多了这么多。") : String(localized: "上面几项以外，这一类别处少了这么多。"))
            movers.append(.init(delta: d, name: name, why: why, link: links[name]))
        }
        movers.sort { abs($0.delta) > abs($1.delta) }
        let cleaned = m.history.filter { $0.date >= start && !$0.restored }.map(\.total).reduce(0, +)
        let top = movers.first { $0.delta > 0 }
        let headline: String
        if change > 0.05, let top {
            headline = String(localized: "磁盘多用了 \(change.gbText)，最多的是\(Copy.text(top.name))（+\(top.delta.gbText)）。")
        } else if change > 0.05 {
            headline = String(localized: "磁盘多用了 \(change.gbText)。")
        } else if change < -0.05 {
            headline = String(localized: "磁盘空出了 \((-change).gbText)。")
        } else {
            headline = String(localized: "磁盘几乎没有变化。")
        }
        let range = "\(first.day.formatted(.dateTime.month().day())) – \(last.day.formatted(.dateTime.month().day()))"
        return Week(range: range, change: change, days: days, movers: Array(movers.prefix(5)), cleaned: cleaned, headline: headline)
    }
}
