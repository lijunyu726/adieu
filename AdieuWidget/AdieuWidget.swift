import WidgetKit
import SwiftUI

/// 桌面小组件。剩余空间自己现读（随时准）；空间分布和可以清理的几项来自主程序上次扫描写下的 `WidgetFeed`，
/// 读不到（还没扫过、文件被删）时只显示剩余空间
struct DiskEntry: TimelineEntry {
    let date: Date
    let free: Double
    let total: Double
    let feed: WidgetFeed?
    var usedRatio: Double { total > 0 ? 1 - free / total : 0 }
}

struct DiskProvider: TimelineProvider {
    func placeholder(in context: Context) -> DiskEntry { DiskEntry(date: .now, free: 81.5, total: 460.4, feed: nil) }

    func getSnapshot(in context: Context, completion: @escaping (DiskEntry) -> Void) { completion(read()) }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DiskEntry>) -> Void) {
        completion(Timeline(entries: [read()], policy: .after(.now.addingTimeInterval(30 * 60))))
    }

    private func read() -> DiskEntry {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        let v = try? URL(filePath: "/").resourceValues(forKeys: keys)
        let bytesPerGB = 1_000_000_000.0
        return DiskEntry(date: .now,
                         free: Double(v?.volumeAvailableCapacityForImportantUsage ?? 0) / bytesPerGB,
                         total: Double(v?.volumeTotalCapacity ?? 0) / bytesPerGB,
                         feed: WidgetFeed.load())
    }
}

private func gb(_ x: Double) -> String {
    if x >= 1 { return String(format: "%.1f GB", x) }
    return x <= 0 ? "0 MB" : "\(Int((x * 1000).rounded())) MB"
}

struct DiskWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DiskEntry

    private var low: Bool { entry.usedRatio > 0.9 }
    private var tint: Color { low ? .red : (entry.usedRatio > 0.8 ? .orange : .accentColor) }
    private var pct: Int { Int(((1 - entry.usedRatio) * 100).rounded()) }
    /// 分类按磁盘总量占比，剩下的是可用
    private var segments: [(Color, Double)] {
        guard let feed = entry.feed, entry.total > 0 else { return [] }
        let cats = feed.categories.map { (Color(red: $0.rgb[0], green: $0.rgb[1], blue: $0.rgb[2]), $0.size / entry.total) }
        return cats + [(Color.secondary.opacity(0.25), entry.free / entry.total)]
    }

    var body: some View {
        switch family {
        case .systemLarge: large
        case .systemMedium: medium
        default: small
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("可用").font(.caption).foregroundStyle(.secondary)
            Text(gb(entry.free)).font(.title.bold()).monospacedDigit().minimumScaleFactor(0.6).foregroundStyle(low ? .red : .primary)
            ProgressView(value: entry.usedRatio).tint(tint)
            Spacer(minLength: 0)
            if let feed = entry.feed, feed.reclaimable > 0.05 {
                Text("能腾出").font(.caption).foregroundStyle(.secondary)
                Text(gb(feed.reclaimable)).font(.headline).foregroundStyle(.green).monospacedDigit()
            } else {
                Text(low ? "只剩 \(pct)%" : "还有 \(pct)%").font(.caption).foregroundStyle(low ? .red : .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(gb(entry.free)).font(.title2.bold()).monospacedDigit().foregroundStyle(low ? .red : .primary)
            Text(low ? "可用 · 只剩 \(pct)%" : "可用 · 共 \(String(format: "%.0f GB", entry.total))").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let feed = entry.feed, feed.reclaimable > 0.05 {
                Text("能腾出 \(gb(feed.reclaimable))").font(.caption.weight(.semibold)).foregroundStyle(.green)
            }
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                    Rectangle().fill(s.0).frame(width: max(2, (geo.size.width - CGFloat(segments.count * 2)) * s.1))
                }
            }
        }
        .frame(height: 10)
        .clipShape(.rect(cornerRadius: 4))
    }

    private func legend(_ count: Int) -> some View {
        let cats = (entry.feed?.categories ?? []).sorted { $0.size > $1.size }.prefix(count)
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], alignment: .leading, spacing: 4) {
            ForEach(Array(cats.enumerated()), id: \.offset) { _, c in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(red: c.rgb[0], green: c.rgb[1], blue: c.rgb[2])).frame(width: 8, height: 8)
                    Text(c.label).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(gb(c.size)).foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.caption2)
            }
        }
    }

    private var footnote: some View {
        let parts: [String] = [
            entry.feed?.weekChange.flatMap { abs($0) > 0.05 ? ($0 > 0 ? String(localized: "这周多用了 \(gb($0))") : String(localized: "这周空出了 \(gb(-$0))")) : nil },
            entry.feed.map { String(localized: "统计于 \($0.date.formatted(date: .omitted, time: .shortened))") }
        ].compactMap { $0 }
        return Text(parts.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
    }

    @ViewBuilder private var medium: some View {
        if entry.feed == nil {
            noFeed
        } else {
            VStack(alignment: .leading, spacing: 8) {
                header
                bar
                legend(4)
                Spacer(minLength: 0)
                footnote
            }
        }
    }

    @ViewBuilder private var large: some View {
        if let feed = entry.feed {
            VStack(alignment: .leading, spacing: 10) {
                header
                bar
                legend(6)
                Divider()
                Text("可以清理").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if feed.items.isEmpty {
                    Text("暂时没有要处理的。").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(feed.items.prefix(4).enumerated()), id: \.offset) { _, item in
                    HStack {
                        Text(item.title).font(.callout).lineLimit(1)
                        Spacer(minLength: 6)
                        if let size = item.size { Text(gb(size)).font(.callout.weight(.semibold)).foregroundStyle(.green).monospacedDigit() }
                    }
                }
                Spacer(minLength: 0)
                footnote
            }
        } else {
            noFeed
        }
    }

    /// 主程序还没扫过：只有剩余空间
    private var noFeed: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ProgressView(value: entry.usedRatio).tint(tint)
            Spacer(minLength: 0)
            Text("打开 Adieu 扫描一次，这里会显示空间都用在哪了。").font(.caption).foregroundStyle(.secondary)
        }
    }
}

@main
struct AdieuWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AdieuDisk", provider: DiskProvider()) { entry in
            DiskWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("磁盘空间")
        .description("还剩多少、空间用在哪、能腾出多少。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
