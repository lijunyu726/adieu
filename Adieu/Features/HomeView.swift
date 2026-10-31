import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var expandedID: String? = Sample.categories.first?.id

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PageHeader(.home, subtitle: subtitle) {
                        Button("腾出空间…") { model.sheet = .goal }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                    if !model.useSample && !model.hasFullDiskAccess { accessBanner }
                    overview
                    categoryRows
                }
                .padding(32)
            }
            .scrollBounceBehavior(.basedOnSize)
            suggestions
                .frame(width: 320)
                .padding([.vertical, .trailing], 32)
        }
    }

    private var accessBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.trianglebadge.exclamationmark").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("还没有“完全磁盘访问权限”").fontWeight(.semibold)
                Text("微信这类应用的数据统计不到，算进了“系统与其他”，残留也会找漏。授权后按 ⌘R 重新扫描。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("去授权") { NSWorkspace.shared.open(Permissions.fullDiskAccessSettings) }
        }
        .padding(14)
        .background(.orange.opacity(0.1), in: .rect(cornerRadius: 12))
    }

    private var subtitle: String {
        let pct = Int((model.disk.free / model.disk.total * 100).rounded())
        return pct < 10
            ? String(localized: "可用 \(model.disk.free.gbText)，只剩 \(pct)%。低于 10% 时系统会变慢，更新也可能装不上。")
            : String(localized: "可用 \(model.disk.free.gbText)，还有 \(pct)%。")
    }

    private var categories: [SpaceCategory] { model.spaceCategories }

    /// 顶部一整条：按磁盘总量分段，看“占整块盘多少”
    private var overview: some View {
        // spaceCategories 每次读都要现算，一次重画只算一遍
        let categories = categories
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("已用 \(Text(model.disk.used.gbText).fontWeight(.bold).foregroundStyle(.primary).monospacedDigit()) / \(model.disk.total.gbText)")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("点一行看里面是什么").font(.caption).foregroundStyle(.tertiary)
            }
            SegmentBar(segments: categories.map { c in
                .init(value: c.size, color: c.color, dimmed: expandedID != nil && expandedID != c.id && c.id != "free")
            }, total: max(model.disk.total, categories.map(\.size).reduce(0, +)), height: 22)
            .animation(.smooth, value: expandedID)
        }
    }

    /// 每类一行：条以最大的一类为满格，看“彼此谁大谁小”
    private var categoryRows: some View {
        let categories = categories
        let maxSize = categories.map(\.size).max() ?? 1
        return VStack(spacing: 2) {
            ForEach(categories) { c in
                CategoryRow(category: c, maxSize: maxSize, expanded: expandedID == c.id,
                            toggle: { withAnimation(.smooth) { expandedID = expandedID == c.id ? nil : c.id } },
                            open: { model.section = $0 })
            }
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("今日建议").font(.headline).foregroundStyle(.secondary)
            let list = Suggestion.make(model)
            if list.isEmpty {
                Text(model.filesLoading || model.appsLoading ? "正在扫描，稍等一下…" : "暂时没有要处理的。")
                    .foregroundStyle(.secondary).padding(.vertical, 8)
            }
            ForEach(list) { s in
                SuggestionCard(title: s.title, size: s.size, detail: s.detail,
                               action: s.picks ? String(localized: "去 \(s.target.title) 勾选") : String(localized: "去 \(s.target.title)")) {
                    if s.picks { model.pickOnOpen = s.target }
                    model.section = s.target
                }
            }
            Spacer()
            diaryCard
        }
    }

    /// 最近 7 天的日期和一句话；记录不到两天时没有
    private var diary: (range: String, line: String)? {
        if model.useSample { return ("10 月 5 日 – 10 月 11 日", String(localized: "这一周，磁盘少了 18.6 GB。将近一半是 Docker。")) }
        return DiaryStore.week(model).map { ($0.range, String(localized: "这一周，\($0.headline)")) }
    }

    /// 有两天以上的记录才占一张卡；之前只留一行字，不拿空卡片占地方
    @ViewBuilder private var diaryCard: some View {
        if let diary {
            Button { model.sheet = .diary } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("存储日记 · \(diary.range)").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    Text(diary.line)
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("看是谁用掉的 →").font(.caption).foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.08), in: .rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.orange.opacity(0.22)))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        } else {
            Label("存储日记从今天开始记，过两天就能看到空间去哪了。", systemImage: "book.closed")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// 首页右侧的建议：从扫描结果里挑最值得做的几件事。
/// 文件类的和各页顶上的建议卡是同一套规则（FileSuggestion），点过去会替人勾好
private struct Suggestion: Identifiable {
    let title: String
    let size: Double?
    let detail: String
    let target: AppSection
    /// 跳过去时顺手勾上这页的建议
    var picks = false
    /// 用来去重：同一个文件可能同时在“安装包”“大文件”“久未打开”里
    var files: Set<String> = []
    var id: String { title }

    @MainActor
    static func make(_ model: AppModel) -> [Suggestion] {
        var list: [Suggestion] = []
        if let dev = model.devTools.filter({ $0.reclaimable > 0.1 }).max(by: { $0.reclaimable < $1.reclaimable }) {
            list.append(.init(title: String(localized: "\(dev.name) 里有可以回收的缓存"), size: dev.reclaimable, detail: dev.note, target: .devTools))
        }
        // 图片与视频不给建议（见 FileSuggestion），不用把上万个文件过一遍
        for id in [AppSection.installers, .bigFiles, .stale] {
            guard let c = model.category(id) else { continue }
            // 和文件页一样：不算汇总行，也不算刚删掉的
            let files = c.items.filter { !$0.isSummary && !model.removedKeys.contains($0.path ?? "\(id.rawValue).\($0.id)") }
            guard let s = FileSuggestion.make(id, files: files) else { continue }
            list.append(.init(title: s.title, size: s.size, detail: s.detail, target: id, picks: true,
                              files: Set(s.items.map { $0.path ?? $0.name })))
        }
        let left = model.leftovers.flatMap(\.items).filter(\.defaultOn)
        if !left.isEmpty {
            list.append(.init(title: String(localized: "\(left.count) 项应用残留"), size: left.compactMap(\.size).reduce(0, +), detail: String(localized: "对应的应用已经删掉了，数据还在。"), target: .leftovers))
        }
        // 大的先上；和已经列出的有同一个文件的跳过，免得一批文件算两遍
        var picked: [Suggestion] = []
        var seen: Set<String> = []
        for s in list.sorted(by: { ($0.size ?? 0) > ($1.size ?? 0) }) where s.files.isDisjoint(with: seen) {
            picked.append(s)
            seen.formUnion(s.files)
            if picked.count == 3 { break }
        }
        return picked
    }
}

private struct SuggestionCard: View {
    let title: String
    let size: Double?
    let detail: String
    let action: String
    let perform: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(Copy.text(title)).fontWeight(.semibold)
                Spacer()
                if let size { Text(size.gbText).fontWeight(.bold).foregroundStyle(.green).monospacedDigit() }
            }
            Text(Copy.text(detail)).font(.callout).foregroundStyle(.secondary)
            Button(action: perform) { Text(Copy.text(action)) }
                .buttonStyle(.bordered)
        }
        .padding(16)
        .card()
    }
}

private struct CategoryRow: View {
    let category: SpaceCategory
    let maxSize: Double
    let expanded: Bool
    let toggle: () -> Void
    let open: (AppSection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 3).fill(category.color).frame(width: 10, height: 10)
                    Text(Copy.text(category.label)).fontWeight(.medium).frame(width: 140, alignment: .leading)
                    ProportionBar(fraction: category.size / maxSize, color: category.color, height: 8)
                    Text(category.size.gbText).fontWeight(.semibold).monospacedDigit()
                        .frame(width: 76, alignment: .trailing)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "收起细分" : "展开细分")

            if expanded {
                VStack(alignment: .leading, spacing: 7) {
                    Text(Copy.text(category.hint)).foregroundStyle(.secondary)
                    ForEach(category.parts) { p in
                        HStack(spacing: 12) {
                            Text(Copy.text(p.label)).frame(width: 118, alignment: .leading)
                            if p.note.isEmpty, let size = p.size {
                                ProportionBar(fraction: size / category.size, color: category.color.opacity(0.7), height: 5)
                            } else {
                                Text(Copy.text(p.note)).foregroundStyle(.tertiary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Text(p.size.gbText).monospacedDigit().frame(width: 76, alignment: .trailing)
                        }
                        .foregroundStyle(.secondary)
                    }
                    if let link = category.link {
                        Button("去 \(link.title) →") { open(link) }
                            .buttonStyle(.link)
                    }
                }
                .font(.callout)
                .padding(.leading, 22)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(expanded ? Color.primary.opacity(0.05) : .clear, in: .rect(cornerRadius: 10))
    }
}

/// 单条比例条，fraction 为 0–1
private struct ProportionBar: View {
    let fraction: Double
    let color: Color
    let height: CGFloat

    var body: some View {
        GeometryReader { geo in
            Capsule().fill(color).frame(width: max(height, geo.size.width * min(1, fraction)))
        }
        .frame(height: height)
        .background(.quaternary.opacity(0.5), in: .capsule)
        .accessibilityHidden(true)
    }
}
