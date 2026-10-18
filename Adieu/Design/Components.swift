import SwiftUI
import QuickLookThumbnailing
import UniformTypeIdentifiers
import AVFoundation

/// 从应用图标里取的颜色：玻璃蓝、天空蓝、边缘的暖光
enum Theme {
    static let brand = Color(red: 0.31, green: 0.51, blue: 0.92)
    static let sky = Color(red: 0.62, green: 0.76, blue: 0.98)
    static let glow = Color(red: 0.99, green: 0.83, blue: 0.56)
}

/// 页面底色：浅蓝渐变，和图标同一个调子；卡片是浮在上面的白色
struct PageBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let colors: [Color] = scheme == .dark
            ? [Color(red: 0.10, green: 0.13, blue: 0.20), Color(red: 0.07, green: 0.09, blue: 0.15)]
            : [Color(red: 0.93, green: 0.96, blue: 1.0), Color(red: 0.87, green: 0.91, blue: 0.98), Color(red: 0.83, green: 0.88, blue: 0.97)]
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }
}

/// 彩色圆角图标块，像系统设置里那样：侧边栏、页头、设置里都用它
struct SymbolTile: View {
    let symbol: String
    var tint: Color = Theme.brand
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [tint.mix(with: .white, by: 0.25), tint], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: tint.opacity(0.25), radius: size * 0.1, y: size * 0.04)
            .accessibilityHidden(true)
    }
}

/// 真实的应用图标（关于、欢迎页用）
struct AdieuLogo: View {
    var size: CGFloat = 80
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// 应用图标的占位：彩色圆角方块加首字。接入真实扫描后换成 NSWorkspace 取到的图标。
struct MonogramIcon: View {
    let monogram: String
    let color: Color
    var size: CGFloat = 36

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(monogram)
                    .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.12), radius: size * 0.08, y: size * 0.04)
            .accessibilityHidden(true)
    }
}

/// 文件类型标签块（ISO、MOV…）
struct ExtensionTile: View {
    let ext: String
    let color: Color
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                Text(ext)
                    .font(.system(size: size * 0.27, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// 小号胶囊标签
struct Chip: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.13), in: .capsule)
    }
}

struct EvidenceChip: View {
    let evidence: Evidence
    var body: some View { Chip(text: evidence.label, tint: evidence.tint) }
}

/// 页面顶部的标题和一句说明
struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    var symbol: String?
    var tint: Color
    @ViewBuilder var trailing: Trailing

    init(_ title: String, subtitle: String, symbol: String? = nil, tint: Color = Theme.brand,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
        self.trailing = trailing()
    }

    /// 侧边栏页面直接用入口的图标和颜色
    init(_ section: AppSection, subtitle: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.init(section.title, subtitle: subtitle, symbol: section.symbol, tint: section.tint, trailing: trailing)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 28, weight: .bold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

/// 数字统计块
struct StatTile: View {
    let value: String
    let label: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.bold()).monospacedDigit().foregroundStyle(tint)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// 分组卡片背景
struct CardStyle: ViewModifier {
    var padding: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.background, in: .rect(cornerRadius: 14, style: .continuous))
            .shadow(color: Theme.brand.opacity(0.10), radius: 14, y: 5)
    }
}

extension View {
    func card(padding: CGFloat = 0) -> some View { modifier(CardStyle(padding: padding)) }
}

/// 一段按比例着色的横条
struct SegmentBar: View {
    struct Segment: Identifiable {
        let id = UUID()
        let value: Double
        let color: Color
        var dimmed = false
    }
    let segments: [Segment]
    var total: Double? = nil
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let sum = total ?? segments.map(\.value).reduce(0, +)
            HStack(spacing: 2) {
                ForEach(segments) { s in
                    Rectangle()
                        .fill(s.color.opacity(s.dimmed ? 0.22 : 1))
                        .frame(width: sum > 0 ? max(2, geo.size.width * s.value / sum - 2) : 0)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(.quaternary.opacity(0.6))
        .clipShape(.capsule)
        .accessibilityHidden(true)
    }
}

/// 列表里的一行文件信息：名称 + 路径
struct NameAndPath: View {
    let name: String
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).fontWeight(.medium).lineLimit(1)
            Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }
}

/// 底部操作栏：有选中项时显示，带 Liquid Glass 材质
struct ActionBar<Actions: View>: View {
    let summary: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            Text(summary).monospacedDigit()
            actions
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .padding(.bottom, 18)
    }
}

/// 应用图标：真实扫描到的用系统图标，示例数据用字母图标
struct AppIcon: View {
    let app: AppItem
    var size: CGFloat = 36

    var body: some View {
        if let path = app.path {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            MonogramIcon(monogram: app.monogram, color: app.color, size: size)
        }
    }
}

/// 筛选用的小胶囊：点一下选上，再点取消，右边是个数
struct FilterChip: View {
    let text: String
    let count: Int
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if on { Image(systemName: "checkmark").font(.caption2.bold()) }
                Text(text)
                Text("\(count)").foregroundStyle(on ? .white.opacity(0.8) : .secondary).monospacedDigit()
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .foregroundStyle(on ? .white : .primary)
            .background(on ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.background.opacity(0.75)), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .opacity(count == 0 && !on ? 0.45 : 1)
    }
}

/// 从左到右排，排满换行
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // 量最小尺寸时宽度会是 0：按一行算，不然每个都单独一行，会把整个窗口撑高
        let w = proposal.width ?? .infinity
        let rows = arrange(width: w > 0 ? w : .infinity, subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, v) in subviews.enumerated() {
            let size = v.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width { rows.append(Row()) }
            let gap = rows[rows.count - 1].items.isEmpty ? 0 : spacing
            rows[rows.count - 1].items.append(i)
            rows[rows.count - 1].width += gap + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

/// 快速查看能不能打开：系统解不了的视频（如 utvideo 编码的 AVI）放不了，要交给默认播放器
func quickLookCanOpen(_ url: URL) async -> Bool {
    guard let t = UTType(filenameExtension: url.pathExtension.lowercased()), t.conforms(to: .movie) else { return true }
    return (try? await AVURLAsset(url: url).load(.isPlayable)) == true
}

/// 文件图标：和访达一样，能预览的用 Quick Look 预览图，预览不了的用文件自己的图标；
/// 不论哪种都完整显示、不裁切、不垫底色，保持文件原来的样子。没有路径（示例数据）时显示扩展名
struct Thumbnail: View {
    let path: String?
    let ext: String
    var tint: Color = .teal
    /// 生成的缩略图尺寸（点）；大卡片用大一点的
    var pixels = CGSize(width: 320, height: 240)
    @State private var loaded: NSImage?

    nonisolated(unsafe) private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        // 底下垫一层不占尺寸的颜色，图片只作为覆盖层，不会把外框撑大
        tint.opacity(loaded == nil ? 0.12 : 0)
            .overlay {
                if let loaded {
                    Image(nsImage: loaded).resizable().scaledToFit()
                } else {
                    Text(ext).font(.system(.title3, design: .monospaced).bold()).foregroundStyle(tint)
                }
            }
            .clipped()
        .task(id: path) { loaded = await Self.load(path, size: pixels) }
    }

    private static func load(_ path: String?, size: CGSize) async -> NSImage? {
        guard let path else { return nil }
        let key = "\(path)#\(Int(size.width))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: URL(filePath: path), size: size,
                                                   scale: 2, representationTypes: .thumbnail)
        let result: NSImage
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            result = rep.nsImage
        } else if let frame = await blocking({ videoFrame(path, width: Int(size.width * 2)) }) {
            result = frame
        } else {
            result = NSWorkspace.shared.icon(forFile: path)
        }
        cache.setObject(result, forKey: key)
        return result
    }

    /// 系统解不了的视频（如 utvideo 编码的 AVI）：装了 ffmpeg 就抽第 1 秒的一帧
    nonisolated private static func videoFrame(_ path: String, width: Int) -> NSImage? {
        guard let t = UTType(filenameExtension: (path as NSString).pathExtension.lowercased()), t.conforms(to: .movie),
              let ffmpeg = Shell.which("ffmpeg") else { return nil }
        let out = FileManager.default.temporaryDirectory.appending(path: "adieu-frame-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: out) }
        guard Shell.run(ffmpeg, ["-v", "error", "-y", "-ss", "1", "-i", path, "-frames:v", "1", "-vf", "scale=\(width):-2", out.path], timeout: 20)?.status == 0
        else { return nil }
        return NSImage(contentsOf: out)
    }
}

/// 扫描超过一分钟还没完：多半是系统权限弹窗在等你点，提示一句
struct ScanWaitHint: View {
    let text: String
    @State private var slow = false

    var body: some View {
        VStack(spacing: 10) {
            ProgressView(text)
            if slow {
                Text("比平时慢。如果屏幕上有 Adieu 想访问某个文件夹的弹窗，点“允许”后会接着扫描。")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            }
        }
        .task { try? await Task.sleep(for: .seconds(60)); slow = true }
    }
}
