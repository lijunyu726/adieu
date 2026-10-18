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
}

@MainActor
enum DiaryStore {
    private static var file: URL { HistoryStore.folder.appending(path: "snapshots.json") }

    static func load() -> [Snapshot] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Snapshot].self, from: data)) ?? []
    }

    /// 空间分布算完才记，否则分类不全
    static func record(_ m: AppModel) {
        guard !m.useSample, m.space != nil else { return }
        let today = Calendar.current.startOfDay(for: .now)
        var cats: [String: Double] = [:]
        for c in m.spaceCategories where c.id != "free" { cats[c.label] = c.size }
        var apps: [String: Double] = [:]
        for a in m.apps.filter(\.isMeasured).sorted(by: { $0.total > $1.total }).prefix(30) { apps[a.name] = a.total }
        var all = load().filter { $0.day != today }
        all.append(Snapshot(day: today, free: m.disk.free, used: m.disk.used, categories: cats, apps: apps))
        all = Array(all.sorted { $0.day < $1.day }.suffix(60))
        try? FileManager.default.createDirectory(at: HistoryStore.folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: file, options: .atomic) }
    }

    struct Week {
        let range: String
        /// 正数表示磁盘多用了
        let change: Double
        let days: [(day: String, gb: Double)]
        let movers: [(delta: Double, name: String, why: String)]
        let cleaned: Double
        let headline: String
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
        // 谁变了：应用优先（更具体），再看分类
        var movers: [(Double, String, String)] = []
        for (name, size) in last.apps {
            let d = size - (first.apps[name] ?? 0)
            if abs(d) >= 0.3 { movers.append((d, name, d > 0 ? "应用和它的数据一共长大了这么多。" : "比一周前小了。")) }
        }
        for (name, size) in last.categories where name != "macOS 系统与其他" {
            let d = size - (first.categories[name] ?? size)
            if abs(d) >= 0.5 && !movers.contains(where: { $0.1 == name }) {
                movers.append((d, name, d > 0 ? "这一类整体多了这么多。" : "这一类整体少了。"))
            }
        }
        movers.sort { abs($0.0) > abs($1.0) }
        let cleaned = m.history.filter { $0.date >= start && !$0.restored }.map(\.total).reduce(0, +)
        let top = movers.first { $0.0 > 0 }
        let headline = change > 0.05
            ? "磁盘多用了 \(change.gbText)" + (top.map { "，变化最大的是\($0.1)" } ?? "") + "。"
            : (change < -0.05 ? "磁盘空出了 \((-change).gbText)。" : "磁盘几乎没有变化。")
        let range = "\(first.day.formatted(.dateTime.month().day())) – \(last.day.formatted(.dateTime.month().day()))"
        return Week(range: range, change: change, days: days, movers: Array(movers.prefix(5)), cleaned: cleaned, headline: headline)
    }
}
