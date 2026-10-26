import SwiftUI
import QuickLook

/// “文件”分组下的通用页面：安装包与压缩包、截图与录屏、大文件、久未打开。
/// 鼠标指着哪个，右边预览栏就显示哪个；整行（整张缩略图）都能点着勾选，按住拖动连选，按住 Shift 连选一段。
/// 列表有焦点时：空格放大预览，↑↓ 换一个，回车勾选或取消这一个，⌘A 全选（再按一次全不选），esc 全部取消，⌘⌫ 删除已勾选（照样先确认）。
/// 顶上一张建议卡一键勾选可以放心删的；列表按组排，每组可以一起勾。
struct FileCategoryView: View {
    let category: FileCategory
    @Environment(AppModel.self) private var model

    private enum Mode: String, CaseIterable { case grid = "缩略图", list = "列表", cards = "逐个看" }
    @State private var mode: Mode
    @State private var filter: FileFilter
    /// 勾选的文件（路径）
    @State private var selected: Set<String> = []
    /// 按住 Shift 点选时，从这一个连到点的那一个
    @State private var anchor: String?
    /// 鼠标指着的；停一小会儿才交给预览栏，快速划过不会一路刷新预览
    @State private var hovered: String?
    /// 预览栏显示的、空格和 ↑↓ 作用的那一个
    @State private var current: String?
    /// 正在拖动连选：这一笔是勾上（true）还是取消（false）
    @State private var painting: Bool?
    @State private var frames = RowFrames()
    /// 正在快速查看的文件
    @State private var preview: URL?
    @State private var width: CGFloat = 1200
    /// 只看已勾选的，删之前复核一遍
    @State private var onlyChosen = false
    @State private var memo = FileListing.Memo()
    @AppStorage("filePreviewPane") private var showPane = true
    @FocusState private var listFocused: Bool

    private static let space = "files"
    /// Mac 键盘上的删除键发的是 U+007F；SwiftUI 的 `.delete` 是 U+0008，onKeyPress 只认后者会接不到 ⌘⌫
    private static let backspace = KeyEquivalent("\u{7F}")
    /// 比这窄就放不下预览栏，原因改写在每一行里
    private static let paneMinWidth: CGFloat = 900

    init(category: FileCategory) {
        self.category = category
        // 启动参数 `-AdieuFileMode cards` 直接进某种查看方式（调试与截图用）
        let launched = ["grid": Mode.grid, "list": .list, "cards": .cards][UserDefaults.standard.string(forKey: "AdieuFileMode") ?? ""]
        let fallback: Mode = category.id == .captures ? .grid : .list
        _mode = State(initialValue: launched.flatMap { Self.modes(for: category).contains($0) ? $0 : nil } ?? fallback)
        _filter = State(initialValue: FileFilter(sort: category.id == .captures ? .newest : .size))
    }

    private var modes: [Mode] { Self.modes(for: category) }

    private static func modes(for category: FileCategory) -> [Mode] {
        category.id == .captures ? [.grid, .list, .cards] : (category.reviewable ? [.list, .cards] : [])
    }

    // MARK: 数据

    private func key(_ f: FileItem) -> String { FileListing.key(f, in: category.id) }

    /// 筛选、分组这些只在文件或条件变了时重算，指着换一张、勾一下都直接用上次的
    private var listing: FileListing {
        memo.get(.init(section: category.id, items: category.items, removed: model.removedKeys,
                       filter: filter, only: onlyChosen ? selected : nil))
    }
    private var files: [FileItem] { listing.files }
    private var summaries: [FileItem] { listing.summaries }
    private var shown: [FileItem] { listing.shown }
    /// 按勾选去查，不把整页过一遍：勾了东西以后，指着换一张也要重画底栏
    private var chosen: [FileItem] { selected.compactMap { listing.byKey[$0] }.sorted { $0.size > $1.size } }
    private var focused: FileItem? { current.flatMap { listing.byKey[$0] } }

    private var tint: Color { category.id.tint }
    private var roomForPane: Bool { width >= Self.paneMinWidth }
    private var paneVisible: Bool { showPane && roomForPane && mode != .cards }

    private func total(_ list: [FileItem]) -> Double { list.map(\.size).reduce(0, +) }
    private var allChosen: Bool { listing.order.count <= selected.count && listing.order.allSatisfy(selected.contains) }
    private func isVideo(_ f: FileItem) -> Bool { FileSuggestion.isVideo(f) }

    var body: some View {
        let listing = listing
        let sections = listing.sections
        let order = listing.order
        HStack(spacing: 0) {
            main(sections, order: order)
            if paneVisible {
                Divider()
                FilePreviewPane(item: focused, selected: current.map(selected.contains) ?? false) {
                    if let current { toggle(current) }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onAppear(perform: pickFromHome)
        .quickLookPreview($preview, in: preview == nil ? [] : listing.urls)
        .onChange(of: filter) { anchor = nil }
        .onChange(of: selected.isEmpty) { if selected.isEmpty { onlyChosen = false } }
        .task(id: hovered) {
            guard let hovered else { return }
            try? await Task.sleep(for: .milliseconds(150))
            if !Task.isCancelled { current = hovered }
        }
        .animation(.smooth(duration: 0.25), value: paneVisible)
    }

    private func main(_ sections: [FileListing.Section], order: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                PageHeader(category.id, subtitle: category.subtitle) { headerControls }
                statsLine
                if mode != .cards, let s = suggestion { suggestionCard(s) }
                if mode != .cards && !files.isEmpty { toolbar }
            }
            .padding([.horizontal, .top], 28)
            .padding(.bottom, 12)

            switch mode {
            case .cards:
                FileReviewDeck(deck: shown, marked: $selected, key: key,
                               onDelete: { model.confirmTrash(request(chosen)) },
                               onList: { onlyChosen = true; mode = modes.first { $0 != .cards } ?? .list })
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 28)
            case .list, .grid:
                content(sections, order: order)
            }
        }
        .frame(maxWidth: .infinity)
        .safeAreaInset(edge: .bottom) {
            // 逐个看自己有一排键帽提示和待删统计，没勾东西时不用再垫一条
            if mode != .cards || !selected.isEmpty { actionBar(order: order) }
        }
    }

    // MARK: 顶部

    @ViewBuilder private var headerControls: some View {
        if !modes.isEmpty {
            Picker("查看方式", selection: $mode) {
                ForEach(modes, id: \.self) { Text(Copy.text($0.rawValue)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: modes.count == 3 ? 220 : 150)
        }
        if mode != .cards {
            Button { showPane.toggle() } label: { Image(systemName: "sidebar.right") }
                .help(roomForPane ? (showPane ? "隐藏预览栏" : "显示预览栏") : "窗口再宽一些才放得下预览栏")
                .disabled(!roomForPane)
        }
    }

    private var statsLine: some View {
        HStack(spacing: 18) {
            ForEach(category.stats, id: \.self) { s in
                HStack(spacing: 6) {
                    Text(Copy.text(s.label)).foregroundStyle(.secondary)
                    Text(s.value).fontWeight(.semibold).foregroundStyle(s.highlight ? Color.green : .primary)
                }
            }
        }
        .font(.callout).monospacedDigit()
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索文件名", text: $filter.query).textFieldStyle(.plain)
                if !filter.query.isEmpty {
                    Button { filter.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.background.opacity(0.8), in: .capsule)
            .overlay(Capsule().strokeBorder(.primary.opacity(0.1)))
            .frame(maxWidth: 220)
            facetMenu("位置", values: listing.roots, on: filter.roots,
                      toggle: { filter.roots.formSymmetricDifference([$0]) }, clear: { filter.roots = [] })
            facetMenu("类型", values: listing.kinds, on: filter.kinds,
                      toggle: { filter.kinds.formSymmetricDifference([$0]) }, clear: { filter.kinds = [] })
            facetMenu("时间", values: listing.ages, on: Set(filter.ages.map(\.rawValue)),
                      toggle: { filter.ages.formSymmetricDifference([FileFilter.Age(rawValue: $0)!]) }, clear: { filter.ages = [] })
            Picker("排序", selection: $filter.sort) {
                ForEach(FileFilter.Sort.allCases, id: \.self) { Text(Copy.text($0.rawValue)) }
            }
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 0)
            Text(filter.isActive ? "筛出 \(shown.count) / \(files.count) 个" : "共 \(files.count) 个")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            if filter.isActive {
                Button("清除筛选") { filter.clear() }.buttonStyle(.link)
            }
        }
    }

    /// 一维条件收成一个下拉菜单，选了几个就在按钮上写出来
    @ViewBuilder
    private func facetMenu(_ title: String, values: [(String, Int)], on: Set<String>,
                           toggle: @escaping (String) -> Void, clear: @escaping () -> Void) -> some View {
        if values.count > 1 || !on.isEmpty {
            Menu {
                ForEach(values, id: \.0) { v, n in
                    Toggle(isOn: Binding(get: { on.contains(v) }, set: { _ in toggle(v) })) {
                        Text(Copy.labeledCount(Copy.facet(title, v), n))
                    }
                }
                if !on.isEmpty {
                    Divider()
                    Button("不限\(title)", action: clear)
                }
            } label: {
                Text(on.isEmpty ? Copy.text(title) : on.count == 1 ? "\(Copy.text(title))：\(Copy.facet(title, on.first!))" : "\(Copy.text(title)) · \(on.count)")
            }
            .fixedSize()
        }
    }

    // MARK: 建议

    /// 每页一句话：哪些可以放心删。点按钮只是勾上，勾完还能改。规则和首页“今日建议”共用
    private var suggestion: FileSuggestion? { listing.suggestion }

    /// 从首页“今日建议”点“去勾选”过来的：替人按一下这页的建议按钮，删不删还是自己定
    private func pickFromHome() {
        guard model.pickOnOpen == category.id else { return }
        model.pickOnOpen = nil
        guard let s = suggestion else { return }
        if mode == .cards { mode = modes.first { $0 != .cards } ?? .list }
        selected.formUnion(s.items.map(key))
    }

    private func suggestionCard(_ s: FileSuggestion) -> some View {
        let keys = s.items.map(key)
        let done = Set(keys).isSubset(of: selected)
        return HStack(spacing: 12) {
            Image(systemName: "sparkles").font(.body.weight(.semibold)).foregroundStyle(.orange)
                .frame(width: 30, height: 30).background(.orange.opacity(0.14), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).fontWeight(.semibold)
                Text(s.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(done ? "已勾选" : s.button) { selected.formUnion(keys) }
                .buttonStyle(.borderedProminent)
                .disabled(done)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.orange.opacity(0.07), in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.18)))
    }

    // MARK: 列表与缩略图

    /// 显示顺序 order：连选、↑↓、全选都按它
    @ViewBuilder private func content(_ sections: [FileListing.Section], order: [String]) -> some View {
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
            let largest = listing.largest
            ScrollViewReader { proxy in
                ScrollView {
                    // 按天分组时可能有几百组，只造看得见的那几组
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(sections) { s in
                            sectionView(s, order: order, largest: largest, summaries: listing.summaries(for: s))
                        }
                        if let rule = Sample.rules.first(where: { $0.id == category.ruleID }) { ruleBar(rule) }
                    }
                    .coordinateSpace(.named(Self.space))
                    .padding(.horizontal, 28)
                    .padding(.bottom, 16)
                }
                .scrollBounceBehavior(.basedOnSize)
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .onKeyPress(keys: [.space, .upArrow, .downArrow, .leftArrow, .rightArrow, .return, .escape, .delete, Self.backspace, "a"]) { press in
                    handleKey(press, order: order, proxy: proxy)
                }
                .onAppear {
                    listFocused = true
                    // 预览栏一打开就有东西看，顺便告诉人“指着就能预览”
                    if current == nil { current = order.first }
                }
            }
        }
    }

    private func sectionView(_ s: FileListing.Section, order: [String], largest: Double, summaries: [FileItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !s.title.isEmpty { sectionHeader(s) }
            if mode == .grid {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)], spacing: 12) {
                    ForEach(s.items) { f in tile(f, order: order) }
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(s.items.enumerated()), id: \.element.id) { i, f in
                        if i > 0 { Divider().padding(.leading, 60) }
                        row(f, order: order, largest: largest)
                    }
                    ForEach(summaries) { f in
                        Divider().padding(.leading, 60)
                        summaryRow(f)
                    }
                }
                .card()
            }
        }
    }

    private func sectionHeader(_ s: FileListing.Section) -> some View {
        let all = s.items.count <= selected.count && s.items.allSatisfy { selected.contains(key($0)) }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Copy.text(s.title)).font(.headline)
            Text(([String(localized: "\(s.items.count) 个 · \(s.size.gbText)")] + (s.note.isEmpty ? [] : [Copy.text(s.note)])).joined(separator: " · "))
                .font(.callout).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            Spacer()
            Button(all ? "取消\(Copy.text(s.unit))" : "全选\(Copy.text(s.unit))") {
                let keys = s.items.map(key)
                if all { selected.subtract(keys) } else { selected.formUnion(keys) }
            }
            .buttonStyle(.link)
        }
        .padding(.horizontal, 4)
    }

    private func row(_ f: FileItem, order: [String], largest: Double) -> some View {
        let k = key(f)
        let on = selected.contains(k)
        return HStack(spacing: 12) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.title3).foregroundStyle(on ? Theme.brand : Color.secondary.opacity(0.5))
                .accessibilityLabel(on ? "已勾选" : "未勾选")
            icon(f)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.name).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                Text(meta(f)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !paneVisible && !f.reason.isEmpty { Text(f.reason).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(f.size.gbText).fontWeight(.semibold).monospacedDigit()
                Capsule().fill(tint.opacity(0.45)).frame(width: max(4, 64 * f.size / largest), height: 3)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(on ? Theme.brand.opacity(0.09) : current == k ? Color.primary.opacity(0.05) : .clear)
        .contentShape(.rect)
        .id(k)
        .modifier(pickable(k, order: order))
        .contextMenu { menu(f) }
    }

    /// 图片与视频看内容，用缩略图；其他文件和访达一样用系统图标
    @ViewBuilder private func icon(_ f: FileItem) -> some View {
        if category.id == .captures {
            Thumbnail(path: f.path, ext: f.ext, tint: tint, pixels: CGSize(width: 46, height: 34)).frame(width: 46, height: 34).clipShape(.rect(cornerRadius: 6))
        } else {
            FileIcon(path: f.path ?? f.name, folder: f.ext == "DIR" ? true : nil, size: 32)
        }
    }

    /// 修改时间精确到秒；modified 是状态说明（“微信已安装”）时也带上
    private func meta(_ f: FileItem) -> String {
        var parts = [Copy.kind(f.kind), Copy.location(f.location), f.date == nil ? Copy.status(f.timeText) : f.timeText]
        if f.date != nil, f.modified != FileCategorizer.dateText(f.date!) { parts.append(Copy.status(f.modified)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func summaryRow(_ f: FileItem) -> some View {
        HStack(spacing: 12) {
            FileIcon(path: "\(f.id).\(f.ext.lowercased())", size: 32).opacity(0.7).padding(.leading, 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.name).fontWeight(.semibold)
                Text("\(Copy.location(f.location)) · \(Copy.status(f.modified))").font(.caption).foregroundStyle(.secondary)
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

    private func tile(_ f: FileItem, order: [String]) -> some View {
        let k = key(f)
        let on = selected.contains(k)
        return VStack(alignment: .leading, spacing: 6) {
            Thumbnail(path: f.path, ext: f.ext, tint: tint)
                .aspectRatio(4 / 3, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(.rect(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(on ? Theme.brand : current == k ? Theme.brand.opacity(0.45) : Color.primary.opacity(0.08),
                                  lineWidth: on ? 3 : current == k ? 2 : 1))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.title2).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, on ? Theme.brand : .black.opacity(0.25))
                        .padding(6)
                }
                .overlay(alignment: .bottomLeading) {
                    if isVideo(f) {
                        Label("视频", systemImage: "video.fill").font(.caption2.bold()).foregroundStyle(.white)
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
        .id(k)
        .modifier(pickable(k, order: order))
        .contextMenu { menu(f) }
        .help(f.name)
    }

    // MARK: 指、点、拖

    private func pickable(_ k: String, order: [String]) -> Pickable {
        Pickable(key: k, space: Self.space,
                 hover: { inside in
                     if inside { hovered = k } else if hovered == k { hovered = nil }
                 },
                 frame: { frames.rects[k] = $0 },
                 drag: { location in paint(at: location, from: k, order: order) },
                 end: { painting = nil })
    }

    /// 按下去的那一下：按住 Shift 连选一段，否则看这一个原来的状态决定这一笔是勾还是取消；
    /// 之后拖过哪一行，就把那一行改成同样的状态
    private func paint(at location: CGPoint, from k: String, order: [String]) {
        if let on = painting {
            guard let hit = order.first(where: { frames.rects[$0]?.contains(location) == true }) else { return }
            if selected.contains(hit) != on {
                if on { selected.insert(hit) } else { selected.remove(hit) }
            }
            if current != hit { current = hit }
            return
        }
        if NSEvent.modifierFlags.contains(.shift), let a = anchor, let i = order.firstIndex(of: a), let j = order.firstIndex(of: k) {
            selected.formUnion(order[min(i, j)...max(i, j)])
            painting = true
        } else {
            let on = !selected.contains(k)
            painting = on
            if on { selected.insert(k) } else { selected.remove(k) }
        }
        anchor = k
        current = k
        listFocused = true
    }

    private func toggle(_ k: String) {
        if selected.contains(k) { selected.remove(k) } else { selected.insert(k) }
        anchor = k
    }

    private func handleKey(_ press: KeyPress, order: [String], proxy: ScrollViewProxy) -> KeyPress.Result {
        switch press.key {
        case .space:
            guard let f = focused else { return .ignored }
            quickLook(f)
            return .handled
        case .upArrow, .leftArrow, .downArrow, .rightArrow:
            guard !order.isEmpty else { return .ignored }
            let step = press.key == .upArrow || press.key == .leftArrow ? -1 : 1
            let i = current.flatMap(order.firstIndex(of:)).map { min(max($0 + step, 0), order.count - 1) } ?? 0
            current = order[i]
            hovered = nil
            withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo(order[i]) }
            return .handled
        case .return:
            guard let current, listing.byKey[current] != nil else { return .ignored }
            toggle(current)
            return .handled
        case .delete, Self.backspace:
            guard press.modifiers.contains(.command), !chosen.isEmpty else { return .ignored }
            model.confirmTrash(request(chosen))
            return .handled
        case "a" where press.modifiers.contains(.command):
            // 已经全勾上了，再按一次就全不选
            if allChosen { selected.subtract(order); anchor = nil } else { selected.formUnion(order) }
            return .handled
        case .escape:
            guard !selected.isEmpty else { return .ignored }
            selected = []
            anchor = nil
            return .handled
        default:
            return .ignored
        }
    }

    /// 再按一次空格关掉；快速查看放不了的视频改用默认播放器打开
    private func quickLook(_ f: FileItem) {
        guard let p = f.path else { return }
        let url = URL(filePath: p)
        if preview != nil { preview = nil; return }
        Task { if await quickLookCanOpen(url) { preview = url } else { NSWorkspace.shared.open(url) } }
    }

    // MARK: 底部操作栏

    private func actionBar(order: [String]) -> some View {
        let chosen = chosen
        let size = total(chosen)
        let free = model.disk.free
        return HStack(spacing: 10) {
            if chosen.isEmpty {
                // 预览栏底下已经列了空格和方向键；栏收起时写在这里。放不下就先省掉鼠标那句
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { keyHints; mouseHint }
                    HStack(spacing: 14) { keyHints }
                    mouseHint
                }
                .padding(.trailing, 4)
                Button { selected.formUnion(order) } label: { ShortcutLabel("全选（\(order.count)）", shortcut: "⌘A") }
                    .disabled(order.isEmpty)
            } else {
                Text("已选 \(chosen.count) 个 · \(size.gbText)").fontWeight(.semibold).monospacedDigit()
                if mode != .cards {
                    Toggle("只看已选", isOn: $onlyChosen).toggleStyle(.button)
                        .help("列表里只留下勾选的，删之前再看一遍")
                }
                Text("删完可用 \(free.gbText) → \(Text((free + size).gbText).fontWeight(.semibold).foregroundStyle(.green))")
                    .foregroundStyle(.secondary).monospacedDigit()
                if mode != .cards, !allChosen {
                    Button { selected.formUnion(order) } label: { ShortcutLabel("全选（\(order.count)）", shortcut: "⌘A") }
                }
                Button { selected = []; anchor = nil } label: { ShortcutLabel("清除", shortcut: mode == .cards ? "" : "esc") }
                Divider().frame(height: 18)
                if chosen.contains(where: { $0.path != nil }) {
                    Button { NSWorkspace.shared.activateFileViewerSelecting(chosen.compactMap(\.path).map { URL(filePath: $0) }) } label: {
                        Image(systemName: "folder")
                    }
                    .help("在访达中显示")
                }
                Button { mode == .cards ? model.confirmTrash(request(chosen)) : model.requestTrash(request(chosen)) } label: {
                    ShortcutLabel("删除", shortcut: mode == .cards ? "" : "⌘⌫")
                }
                .buttonStyle(.borderedProminent)
                .help(mode == .cards ? "删除标成待删的文件" : "删除已勾选的文件（⌘⌫）")
            }
        }
        .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .padding(.bottom, 16)
        .animation(.smooth, value: chosen.count)
    }

    /// 列表和缩略图里能用的键；删除和全选的快捷键写在各自的按钮上
    private var keyHints: some View {
        HStack(spacing: 12) {
            if !paneVisible {
                KeyHint("放大看", keys: "空格")
                if mode == .grid { KeyHint("换一张", keys: "←", "→") } else { KeyHint("换一个", keys: "↑", "↓") }
                KeyHint("勾选", keys: "↩")
            }
            KeyHint("点击连选一段", keys: "⇧")
        }
    }

    private var mouseHint: some View {
        Text("点一下勾选，按住拖动连选").font(.caption).foregroundStyle(.secondary).fixedSize()
    }

    private func request(_ list: [FileItem]) -> AppModel.TrashRequest {
        let keys = list.map(key)
        let title = list.count == 1 ? String(localized: "删除“\(list[0].name)”") : String(localized: "删除 \(list.count) 个\(category.id.title)里的文件")
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

/// 每一行（每张缩略图）在列表里的位置，拖动连选时用来判断鼠标划到了哪一行。
/// 只是查表用，改它不需要刷新界面，所以不放进 @State 的值里
@MainActor private final class RowFrames {
    var rects: [String: CGRect] = [:]
}

/// 让一行能被指着预览、点着勾选、拖着连选
private struct Pickable: ViewModifier {
    let key: String
    let space: String
    let hover: (Bool) -> Void
    let frame: (CGRect) -> Void
    let drag: (CGPoint) -> Void
    let end: () -> Void

    func body(content: Content) -> some View {
        content
            .onHover(perform: hover)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { frame($0) }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                .onChanged { drag($0.location) }
                .onEnded { _ in end() })
    }
}
