import SwiftUI
import QuickLook

/// “文件”分组下的通用页面：安装包与压缩包、截图与录屏、大文件、久未打开。
/// 上面筛选（位置、类型、时间、搜索），中间勾选，底部一条操作栏一次处理所有勾选的文件。
/// 截图与录屏默认按天排成缩略图；能逐个看的类别可以切到卡片模式。
/// 每个文件都能用快速查看预览（眼睛按钮、右键菜单，或点选后按空格），预览里用方向键翻看筛选结果里的其他文件。
struct FileCategoryView: View {
    let category: FileCategory
    @Environment(AppModel.self) private var model

    private enum Mode: String, CaseIterable { case grid = "缩略图", list = "列表", cards = "逐个看" }
    @State private var mode: Mode
    @State private var filter = FileFilter()
    /// 勾选的文件（路径）
    @State private var selected: Set<String> = []
    /// 按住 Shift 点选时，从这一个连到点的那一个
    @State private var anchor: String?
    /// 正在快速查看的文件
    @State private var preview: URL?
    @FocusState private var listFocused: Bool

    init(category: FileCategory) {
        self.category = category
        _mode = State(initialValue: category.id == .captures ? .grid : .list)
    }

    private var modes: [Mode] {
        category.id == .captures ? [.grid, .list, .cards] : (category.reviewable ? [.list, .cards] : [])
    }

    // MARK: 数据

    private func key(_ f: FileItem) -> String { f.path ?? "\(category.id.rawValue).\(f.id)" }

    /// 还在原处的文件（删掉的不再显示）
    private var files: [FileItem] { category.items.filter { !$0.isSummary && !model.removedKeys.contains(key($0)) } }
    private var summaries: [FileItem] { category.items.filter(\.isSummary) }
    private var shown: [FileItem] { filter.apply(files) }
    private var chosen: [FileItem] { files.filter { selected.contains(key($0)) } }

    private var tint: Color { category.id.tint }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(category.id, subtitle: category.subtitle) {
                    if !modes.isEmpty {
                        Picker("查看方式", selection: $mode) {
                            ForEach(modes, id: \.self) { Text($0.rawValue) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: modes.count == 3 ? 220 : 150)
                    }
                }
                stats
                if mode != .cards && !files.isEmpty { filterBar }
            }
            .padding([.horizontal, .top], 28)
            .padding(.bottom, 12)

            switch mode {
            case .cards:
                FileReviewDeck(deck: shown, onDelete: { model.perform(request([$0])) })
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
            case .list, .grid:
                content
            }
        }
        .safeAreaInset(edge: .bottom) { if mode != .cards { actionBar } }
        .quickLookPreview($preview, in: shown.compactMap { $0.path.map { URL(filePath: $0) } })
        .onChange(of: filter) { anchor = nil }
    }

    // MARK: 顶部

    private var stats: some View {
        HStack(spacing: 10) {
            ForEach(category.stats, id: \.self) { s in
                StatTile(value: s.value, label: s.label, tint: s.highlight ? .green : .primary)
            }
        }
    }

    private var filterBar: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索文件名", text: $filter.query).textFieldStyle(.plain)
                    if !filter.query.isEmpty {
                        Button { filter.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.background.opacity(0.8), in: .capsule)
                .overlay(Capsule().strokeBorder(.primary.opacity(0.1)))
                .frame(maxWidth: 300)
                Picker("排序", selection: $filter.sort) {
                    ForEach(FileFilter.Sort.allCases, id: \.self) { Text($0.rawValue) }
                }
                .fixedSize()
                Spacer()
                Text(filter.isActive ? "筛出 \(shown.count) / \(files.count) 个" : "共 \(files.count) 个")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                if filter.isActive {
                    Button("清除筛选") { filter.clear() }.buttonStyle(.link)
                }
            }
            facet("位置", values: facetValues(\.root), on: filter.roots) { filter.roots.formSymmetricDifference([$0]) }
            facet("类型", values: facetValues(\.kind), on: filter.kinds) { filter.kinds.formSymmetricDifference([$0]) }
            facet("时间", values: FileFilter.Age.allCases.map { age in
                (age.rawValue, filter.cleared(\.ages).apply(files).filter { FileFilter.Age.of($0.date) == age }.count)
            }.filter { $0.1 > 0 || filter.ages.contains(FileFilter.Age(rawValue: $0.0)!) },
                  on: Set(filter.ages.map(\.rawValue))) { filter.ages.formSymmetricDifference([FileFilter.Age(rawValue: $0)!]) }
        }
    }

    /// 某一维的取值和个数。个数按“其他条件都不变、只换这一维”来算，点之前就知道会筛出几个
    private func facetValues(_ path: KeyPath<FileItem, String>) -> [(String, Int)] {
        let base = filter.cleared(path == \FileItem.root ? \.roots : \.kinds).apply(files)
        var counts: [String: Int] = [:]
        for f in files { counts[f[keyPath: path], default: 0] += 0 }
        for f in base { counts[f[keyPath: path], default: 0] += 1 }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
    }

    @ViewBuilder
    private func facet(_ title: String, values: [(String, Int)], on: Set<String>, toggle: @escaping (String) -> Void) -> some View {
        if values.count > 1 || !on.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(.callout).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                FlowLayout(spacing: 6) {
                    ForEach(values, id: \.0) { v, n in
                        FilterChip(text: v, count: n, on: on.contains(v)) { toggle(v) }
                    }
                }
            }
        }
    }

    // MARK: 列表与缩略图

    @ViewBuilder private var content: some View {
        if files.isEmpty && summaries.isEmpty {
            ContentUnavailableView(model.filesLoading ? "还在扫描" : "这里是空的", systemImage: model.filesLoading ? "hourglass" : "checkmark.circle",
                                   description: Text(category.items.contains { model.removedKeys.contains(key($0)) } ? "都处理完了。" : "桌面、文稿、下载、影片、音乐、图片里没有找到这类文件。"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if shown.isEmpty && !files.isEmpty {
            ContentUnavailableView {
                Label("没有符合条件的文件", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("换个条件试试。")
            } actions: {
                Button("清除筛选") { filter.clear() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if mode == .grid { grid } else { list }
                    if let rule = Sample.rules.first(where: { $0.id == category.ruleID }) { ruleBar(rule) }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.space) {
                guard let f = shown.first(where: { key($0) == anchor }) else { return .ignored }
                quickLook(f)
                return .handled
            }
        }
    }

    /// 再按一次空格关掉；快速查看放不了的视频改用默认播放器打开
    private func quickLook(_ f: FileItem) {
        guard let p = f.path else { return }
        let url = URL(filePath: p)
        if preview != nil { preview = nil; return }
        Task { if await quickLookCanOpen(url) { preview = url } else { NSWorkspace.shared.open(url) } }
    }

    private var list: some View {
        let items = shown
        return LazyVStack(spacing: 0) {
            ForEach(items) { f in
                row(f, in: items)
                Divider().padding(.leading, 64)
            }
            if !filter.isActive {
                ForEach(summaries) { f in summaryRow(f) }
            }
        }
        .card()
    }

    private func row(_ f: FileItem, in items: [FileItem]) -> some View {
        let k = key(f)
        let on = selected.contains(k)
        return HStack(spacing: 12) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.title3).foregroundStyle(on ? Theme.brand : Color.secondary.opacity(0.5))
                .accessibilityLabel(on ? "已勾选" : "未勾选")
            Thumbnail(path: f.path, ext: f.ext, tint: tint).frame(width: 46, height: 34).clipShape(.rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(f.name).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                Text(meta(f)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !f.reason.isEmpty { Text(f.reason).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            Text(f.size.gbText).fontWeight(.semibold).monospacedDigit()
            if let p = f.path {
                Button { quickLook(f) } label: { Image(systemName: "eye") }
                    .buttonStyle(.borderless).help("预览（空格键）")
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: p)]) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless).help("在访达中显示")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(on ? Theme.brand.opacity(0.08) : .clear)
        .contentShape(.rect)
        .onTapGesture { tap(k, in: items.map(key)) }
        .contextMenu { menu(f) }
    }

    /// 修改时间精确到秒；modified 是状态说明（“微信已安装”）时也带上
    private func meta(_ f: FileItem) -> String {
        var parts = [f.kind, f.location, f.timeText]
        if f.date != nil, f.modified != FileCategorizer.dateText(f.date!) { parts.append(f.modified) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func summaryRow(_ f: FileItem) -> some View {
        HStack(spacing: 12) {
            ExtensionTile(ext: f.ext, color: tint.opacity(0.5), size: 34).padding(.leading, 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.name).fontWeight(.semibold)
                Text("\(f.location) · \(f.modified)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(f.size.gbText).fontWeight(.semibold).monospacedDigit()
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    @ViewBuilder private func menu(_ f: FileItem) -> some View {
        if let p = f.path {
            Button("预览") { quickLook(f) }
            Button("打开") { NSWorkspace.shared.open(URL(filePath: p)) }
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: p)]) }
            Divider()
        }
        Button("只勾选这一个") { selected = [key(f)]; anchor = key(f) }
        Button("删除…") { model.requestTrash(request([f])) }
    }

    /// 截图与录屏：按天分组的缩略图，每天可以一键全选或只留最后一张
    private var grid: some View {
        let days = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.date ?? .distantPast) }
            .sorted { $0.key > $1.key }
            .map { ($0.key, $0.value.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }) }
        let order = days.flatMap { $0.1.map(key) }
        return LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(days, id: \.0) { day, items in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(dayTitle(day)).font(.headline)
                        Text("\(items.count) 个 · \(items.map(\.size).reduce(0, +).gbText)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        let keys = Set(items.map(key))
                        Button(keys.isSubset(of: selected) ? "取消这一天" : "选这一天") {
                            if keys.isSubset(of: selected) { selected.subtract(keys) } else { selected.formUnion(keys) }
                        }
                        .buttonStyle(.link)
                        if items.count > 1 {
                            Button("只留最后一张") { selected.formUnion(items.dropFirst().map(key)); selected.remove(key(items[0])) }
                                .buttonStyle(.link)
                                .help("勾选这一天除最晚那一个以外的全部")
                        }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)], spacing: 12) {
                        ForEach(items) { f in tile(f, order: order) }
                    }
                }
            }
        }
    }

    private func dayTitle(_ d: Date) -> String {
        if d == .distantPast { return "日期未知" }
        if Calendar.current.isDateInToday(d) { return "今天" }
        if Calendar.current.isDateInYesterday(d) { return "昨天" }
        return Calendar.current.isDate(d, equalTo: .now, toGranularity: .year)
            ? d.formatted(.dateTime.month().day().weekday(.wide)) : d.formatted(.dateTime.year().month().day().weekday(.wide))
    }

    private func tile(_ f: FileItem, order: [String]) -> some View {
        let k = key(f)
        let on = selected.contains(k)
        let video = f.kind == "屏幕录制" || f.kind == "视频"
        return VStack(alignment: .leading, spacing: 6) {
            Thumbnail(path: f.path, ext: f.ext, tint: tint)
                .aspectRatio(4 / 3, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(.rect(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(on ? Theme.brand : Color.primary.opacity(0.08), lineWidth: on ? 3 : 1))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.title2).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, on ? Theme.brand : .black.opacity(0.25))
                        .padding(6)
                }
                .overlay(alignment: .bottomTrailing) {
                    if f.path != nil {
                        Button { quickLook(f) } label: {
                            Image(systemName: "eye").font(.caption.bold()).foregroundStyle(.white)
                                .padding(6).background(.black.opacity(0.5), in: .circle)
                        }
                        .buttonStyle(.plain).help("预览（空格键）").padding(6)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if video {
                        Label("录屏", systemImage: "video.fill").font(.caption2.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(.black.opacity(0.5), in: .capsule).padding(6)
                    }
                }
            HStack {
                Text(f.date.map { $0.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)) } ?? f.modified)
                    .monospacedDigit()
                Spacer()
                Text(f.size.gbText).monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .onTapGesture { tap(k, in: order) }
        .contextMenu { menu(f) }
        .help(f.name)
    }

    // MARK: 勾选

    /// 点一下勾选或取消；按住 Shift 把上次点的到这次点的之间全部勾上
    private func tap(_ k: String, in order: [String]) {
        if NSEvent.modifierFlags.contains(.shift), let a = anchor, let i = order.firstIndex(of: a), let j = order.firstIndex(of: k) {
            selected.formUnion(order[min(i, j)...max(i, j)])
        } else if selected.contains(k) {
            selected.remove(k)
        } else {
            selected.insert(k)
        }
        anchor = k
        listFocused = true
    }

    // MARK: 底部操作栏

    private var actionBar: some View {
        let chosen = chosen
        let size = chosen.map(\.size).reduce(0, +)
        let shownKeys = Set(shown.map(key))
        return HStack(spacing: 10) {
            if chosen.isEmpty {
                Text(category.id == .captures && mode == .grid ? "点缩略图勾选，按住 Shift 连选，空格预览" : "点一行勾选，按住 Shift 连选，空格预览")
                    .foregroundStyle(.secondary)
                Button("全选筛选结果（\(shown.count)）") { selected = shownKeys }
                    .disabled(shown.isEmpty)
                if category.id == .captures, shown.count > 1 {
                    Button("每天只留最后一张", action: keepLastPerDay)
                        .help("勾选每一天除最晚那一个以外的全部，勾完可以再调整")
                }
            } else {
                Text("已选 \(chosen.count) 个 · \(size.gbText)").fontWeight(.semibold).monospacedDigit()
                if !shownKeys.isSubset(of: selected) {
                    Button("全选筛选结果（\(shown.count)）") { selected.formUnion(shownKeys) }
                }
                Button("清除") { selected = []; anchor = nil }
                Divider().frame(height: 18)
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting(chosen.compactMap(\.path).map { URL(filePath: $0) }) }
                Button("删除") { model.requestTrash(request(chosen)) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .padding(.bottom, 16)
        .animation(.smooth, value: chosen.count)
    }

    private func keepLastPerDay() {
        let days = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.date ?? .distantPast) }
        for items in days.values {
            let sorted = items.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            selected.formUnion(sorted.dropFirst().map(key))
        }
    }

    private func request(_ list: [FileItem]) -> AppModel.TrashRequest {
        let keys = list.map(key)
        let title = list.count == 1 ? "删除“\(list[0].name)”" : "删除 \(list.count) 个\(category.id.title)里的文件"
        return .init(title: title, source: category.id.title,
                     urls: list.compactMap(\.path).map { URL(filePath: $0) },
                     sizes: Dictionary(list.compactMap { f in f.path.map { ($0, f.size) } }, uniquingKeysWith: { a, _ in a }),
                     keys: keys, onDone: { _ in selected.subtract(model.removedKeys) })
    }

    private func ruleBar(_ rule: RuleItem) -> some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: rule.symbol, tint: rule.color, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("自动规则 · \(rule.name)").fontWeight(.semibold)
                Text(RuleEngine.status(rule.id, model)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            SettingsLink { Text("全部规则") }.buttonStyle(.link).font(.caption)
            Toggle("自动规则 · \(rule.name)", isOn: Binding(
                get: { model.enabledRules.contains(rule.id) },
                set: { model.setRule(rule.id, on: $0) }
            ))
            .toggleStyle(.switch).labelsHidden()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .card()
    }
}

/// 文件页面的筛选条件。同一维里多选是“或”，不同维之间是“且”
struct FileFilter: Equatable {
    var roots: Set<String> = []
    var kinds: Set<String> = []
    var ages: Set<Age> = []
    var query = ""
    var sort: Sort = .size

    enum Sort: String, CaseIterable { case size = "最大的在前", newest = "最新的在前", oldest = "最旧的在前", name = "按名称" }

    /// 按修改时间分段，互不重叠
    enum Age: String, CaseIterable {
        case today = "今天", week = "一周内", month = "一个月内", halfYear = "半年内", older = "半年以前", unknown = "不清楚"

        static func of(_ d: Date?) -> Age {
            guard let d else { return .unknown }
            if d.isToday { return .today }
            let days = FileCategorizer.days(since: d)
            return days <= 7 ? .week : days <= 31 ? .month : days <= 183 ? .halfYear : .older
        }
    }

    var isActive: Bool { !roots.isEmpty || !kinds.isEmpty || !ages.isEmpty || !query.isEmpty }

    mutating func clear() { roots = []; kinds = []; ages = []; query = "" }

    /// 去掉某一维的条件（算那一维的个数用）
    func cleared<T>(_ path: WritableKeyPath<FileFilter, Set<T>>) -> FileFilter {
        var f = self
        f[keyPath: path] = []
        return f
    }

    func apply(_ items: [FileItem]) -> [FileItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let hit = items.filter { f in
            (roots.isEmpty || roots.contains(f.root))
                && (kinds.isEmpty || kinds.contains(f.kind))
                && (ages.isEmpty || ages.contains(Age.of(f.date)))
                && (q.isEmpty || f.name.localizedStandardContains(q))
        }
        switch sort {
        case .size: return hit.sorted { $0.size > $1.size }
        case .newest: return hit.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        case .oldest: return hit.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        case .name: return hit.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
}
