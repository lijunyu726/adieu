import WidgetKit
import SwiftUI

/// 桌面小组件：启动盘还剩多少。自己读容量，不依赖主程序
struct DiskEntry: TimelineEntry {
    let date: Date
    let free: Double
    let total: Double
    var usedRatio: Double { total > 0 ? 1 - free / total : 0 }
}

struct DiskProvider: TimelineProvider {
    func placeholder(in context: Context) -> DiskEntry { DiskEntry(date: .now, free: 81.5, total: 460.4) }

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
                         total: Double(v?.volumeTotalCapacity ?? 0) / bytesPerGB)
    }
}

struct DiskWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DiskEntry

    private var tint: Color { entry.usedRatio > 0.9 ? .red : (entry.usedRatio > 0.8 ? .orange : .accentColor) }
    private var freeText: String { entry.free >= 1 ? String(format: "%.1f GB", entry.free) : "\(Int(entry.free * 1000)) MB" }

    var body: some View {
        switch family {
        case .systemMedium:
            HStack(spacing: 16) {
                gauge.frame(width: 90, height: 90)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Macintosh HD").font(.caption).foregroundStyle(.secondary)
                    Text("可用 \(freeText)").font(.title2.bold()).monospacedDigit()
                    Text(note).font(.caption).foregroundStyle(entry.usedRatio > 0.9 ? .red : .secondary)
                }
                Spacer(minLength: 0)
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                gauge.frame(width: 58, height: 58)
                Spacer(minLength: 0)
                Text("可用").font(.caption).foregroundStyle(.secondary)
                Text(freeText).font(.title3.bold()).monospacedDigit().minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var note: String {
        let pct = Int(((1 - entry.usedRatio) * 100).rounded())
        return pct < 10 ? "只剩 \(pct)%，打开 Adieu 腾出空间" : "共 \(String(format: "%.0f GB", entry.total)) · 还有 \(pct)%"
    }

    private var gauge: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 9)
            Circle().trim(from: 0, to: entry.usedRatio).stroke(tint, style: StrokeStyle(lineWidth: 9, lineCap: .round)).rotationEffect(.degrees(-90))
            Text("\(Int((entry.usedRatio * 100).rounded()))%").font(.caption.bold()).monospacedDigit()
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
        .description("启动盘还剩多少空间。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
