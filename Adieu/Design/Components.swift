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
        Text(Copy.text(text))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.13), in: .capsule)
    }
}

/// 一颗键帽。快捷键记不住，就把它画在用得到的地方
struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 19, minHeight: 18)
            .background(.background.opacity(0.8), in: .rect(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.primary.opacity(0.16)))
            .shadow(color: .black.opacity(0.10), radius: 0, y: 1)
    }
}

/// 一条快捷键提示：几颗键帽，后面写它做什么
struct KeyHint: View {
    let label: String
    let keys: [String]
    init(_ label: String, keys: String...) {
        self.label = label
        self.keys = keys
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { KeyCap($0) }
            Text(label).font(.caption).foregroundStyle(.secondary).padding(.leading, 2)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// 按钮文字后面跟一个淡一点的快捷键，像菜单里那样
struct ShortcutLabel: View {
    let title: String
    let shortcut: String
    init(_ title: String, shortcut: String) {
        self.title = title
        self.shortcut = shortcut
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(Copy.text(title))
            if !shortcut.isEmpty { Text(shortcut).opacity(0.6) }
        }
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
                Text(Copy.text(title)).font(.system(size: 28, weight: .bold))
                Text(Copy.text(subtitle)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
            Text(Copy.text(value)).font(.title2.bold()).monospacedDigit().foregroundStyle(tint)
            Text(Copy.text(label)).font(.caption).foregroundStyle(.secondary)
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
    struct Segment {
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
                // 按位置认：每次重画都换新 id 的话，SwiftUI 会把每一段删掉再重新插入
                ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
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
            Image(nsImage: FileIcon.image(path, folder: false, size: size))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            MonogramIcon(monogram: app.monogram, color: app.color, size: size)
        }
    }
}

/// 和访达里一样的图标：文件还在就取它自己的图标；已经删掉的，卸载掉的应用用删之前存下的图标，
/// 文件夹用文件夹图标，其余按扩展名取系统的类型图标。没有扩展名、或扩展名系统不认识的（com.tencent.xinWeChat）当文件夹
struct FileIcon: View {
    let path: String
    /// 删除记录里存了是不是文件夹；不知道时按扩展名猜
    var folder: Bool? = nil
    var size: CGFloat = 26

    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 3000  // 画成小位图后每个十几到几十 KB
        return c
    }()

    var body: some View {
        Image(nsImage: Self.image(path, folder: folder, size: size))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    /// size：显示多大（点）。按这个大小画成一张小位图再用，见 NSImage.bitmap
    static func image(_ raw: String, folder: Bool? = nil, size: CGFloat = 32) -> NSImage {
        let path = (raw as NSString).expandingTildeInPath
        let key = "\(path)#\(Int(size))" as NSString
        // 取过一次就记住：删掉以后也还是原来那个图标
        if let hit = cache.object(forKey: key) { return hit }
        let image: NSImage
        if FileManager.default.fileExists(atPath: path) {
            image = NSWorkspace.shared.icon(forFile: path)
        } else if let saved = IconStore.load(path) {
            image = saved
        } else {
            let ext = (path as NSString).pathExtension
            let type = ext.isEmpty ? nil : UTType(filenameExtension: ext)
            let isFolder = folder ?? (type == nil || type!.isDynamic)
            // 不是文件夹又认不出类型（比如登录项指向的应用已经删了，路径是空的）就用普通文件图标
            image = NSWorkspace.shared.icon(for: isFolder ? .folder : type ?? .data)
        }
        let small = image.bitmap(pixels: CGSize(width: size * 2, height: size * 2))
        cache.setObject(small, forKey: key)
        return small
    }
}

extension NSImage {
    /// 按要显示的像素大小画成一张位图。系统图标里带着最大 1024 像素的那一层，直接交给界面时会按大的那层解码、
    /// 一直占着内存（一个应用图标好几 MB）；画小以后一个只有几十 KB。保持长宽比，放在正中
    func bitmap(pixels: CGSize) -> NSImage {
        let w = max(1, Int(pixels.width.rounded())), h = max(1, Int(pixels.height.rounded()))
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return self }
        let k = min(CGFloat(w) / size.width, CGFloat(h) / size.height)
        let fit = NSSize(width: size.width * k, height: size.height * k)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(x: (CGFloat(w) - fit.width) / 2, y: (CGFloat(h) - fit.height) / 2, width: fit.width, height: fit.height))
        NSGraphicsContext.restoreGraphicsState()
        rep.size = NSSize(width: CGFloat(w) / 2, height: CGFloat(h) / 2)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
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
    /// 生成的缩略图尺寸（点，按 2 倍像素生成），和显示的大小一致：列表里的小图要的太大，每张白占一两 MB
    var pixels = CGSize(width: 320, height: 240)
    @State private var loaded: NSImage?

    /// 按像素算总量，最多留 48 MB；超了先丢最早用过的
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 48 << 20
        return c
    }()

    /// 应用退到后台一会儿以后清掉：回来时再生成，比一直占着内存划算
    static func purge() { cache.removeAllObjects() }

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
            result = NSWorkspace.shared.icon(forFile: path).bitmap(pixels: CGSize(width: size.width * 2, height: size.height * 2))
        }
        let rep = result.representations.first
        cache.setObject(result, forKey: key, cost: max(1, (rep?.pixelsWide ?? 0) * (rep?.pixelsHigh ?? 0) * 4))
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
