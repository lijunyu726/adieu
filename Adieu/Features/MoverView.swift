import AppKit
import SwiftUI

/// 搬家：左右两栏，在这台 Mac 和外接硬盘之间移动、复制文件，也能改名、新建文件夹
struct MoverView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let mover = model.mover
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(.mover, subtitle: "在这台 Mac、iCloud Drive 和外接硬盘之间搬文件。跨盘移动先复制、核对无误再删原件。") {
                RecentMoves()
                Button("刷新") { mover.refreshPlaces(); mover.left.reload(); mover.right.reload() }
                    .disabled(mover.busy)
            }
            if !mover.leftovers.isEmpty {
                HStack {
                    Label("上次搬家中断，留下了 \(mover.leftovers.count) 个没复制完的临时项目（原件都还在）。",
                          systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("清理") { Task { await mover.clearLeftovers() } }
                }
                .padding(10)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(alignment: .top, spacing: 10) {
                PaneView(pane: mover.left)
                VStack(spacing: 10) {
                    Spacer().frame(height: 120)
                    transfer("移动", symbol: "arrow.right", from: mover.left, mode: .move)
                    transfer("复制", symbol: "arrow.right", from: mover.left, mode: .copy)
                    Divider().frame(width: 40)
                    transfer("移动", symbol: "arrow.left", from: mover.right, mode: .move)
                    transfer("复制", symbol: "arrow.left", from: mover.right, mode: .copy)
                }
                .frame(width: 92)
                PaneView(pane: mover.right)
            }
            if let p = mover.progress { ProgressRow(progress: p) }
        }
        .padding(24)
        .task { mover.start() }
        .sheet(isPresented: Binding(get: { mover.pending != nil }, set: { if !$0 { mover.pending = nil } })) {
            if let plan = mover.pending { MoveConfirm(plan: plan) }
        }
        .alert("没办成", isPresented: Binding(get: { mover.notice != nil }, set: { if !$0 { mover.notice = nil } })) {
            Button("好") { mover.notice = nil }
        } message: {
            Text(mover.notice ?? "")
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            mover.refreshPlaces()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            mover.refreshPlaces()
        }
    }

    private func transfer(_ title: LocalizedStringKey, symbol: String, from pane: MoverPane, mode: FileMover.Mode) -> some View {
        let mover = model.mover
        let target = mover.other(than: pane)
        let disabled = mover.busy || pane.chosen.isEmpty || target.folder == nil || target.place?.readOnly == true
        return Button { mover.prepare(mode, from: pane) } label: {
            HStack(spacing: 4) {
                if symbol == "arrow.left" { Image(systemName: symbol) }
                Text(title)
                if symbol == "arrow.right" { Image(systemName: symbol) }
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.bordered)
        .tint(mode == .move ? .accentColor : .secondary)
        .disabled(disabled)
    }
}

/// 一栏：选盘、面包屑、搜索、文件列表、新建文件夹和改名
private struct PaneView: View {
    @Environment(AppModel.self) private var model
    @Bindable var pane: MoverPane
    @State private var naming: Naming?
    @State private var name = ""
    @State private var batch: [FolderItem] = []
    @State private var deleting: [FolderItem] = []
    @State private var dropping = false

    private enum Naming: Equatable { case folder, rename(FolderItem) }

    var body: some View {
        let mover = model.mover
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                ForEach(mover.places) { place in
                    Button { mover.choose(place, for: pane) } label: {
                        Label(place.name, systemImage: place.symbol)
                    }
                }
            } label: {
                Label(pane.place?.name ?? String(localized: "选择位置"), systemImage: pane.place?.symbol ?? "laptopcomputer")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.headline)
            if let place = pane.place {
                HStack(spacing: 6) {
                    if let free = place.free {
                        Text("剩余 \(FileMover.Refusal.bytes(free))").monospacedDigit()
                    }
                    Text(place.format)
                    if let note = place.limitNote {
                        Text(note).foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            trail
            if let folder = pane.folder {
                Text(folder.path)
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(folder.path)
            }
            TextField("在这个文件夹里搜索", text: $pane.query)
                .textFieldStyle(.roundedBorder)
            list
            HStack {
                Button("新建文件夹") { name = String(localized: "未命名文件夹"); naming = .folder }
                    .disabled(pane.folder == nil || pane.place?.readOnly == true || mover.busy)
                Button("重命名") {
                    if pane.chosen.count > 1 {
                        batch = pane.chosen
                    } else if let item = pane.chosen.first {
                        name = item.url.lastPathComponent
                        naming = .rename(item)
                    }
                }
                .disabled(pane.chosen.isEmpty || pane.place?.readOnly == true || mover.busy)
                Button("删除…", role: .destructive) { deleting = pane.chosen }
                    .disabled(pane.chosen.isEmpty || pane.place?.readOnly == true || mover.busy)
                    .keyboardShortcut(.delete, modifiers: .command)
                Spacer()
                if !pane.chosen.isEmpty {
                    Text("已选 \(pane.chosen.count) 项").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .card()
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        // 拖进来：从另一栏拖的，那一栏选中的一起搬；也接受访达拖来的
        .dropDestination(for: URL.self) { urls, _ in
            guard let folder = pane.folder, pane.place?.readOnly != true else { return false }
            let source = mover.other(than: pane)
            let chosen = source.chosen.map(\.url)
            let items = urls.count == 1 && chosen.contains(urls[0]) ? chosen : urls
            mover.prepare(.move, items: items, to: folder)
            return true
        } isTargeted: { dropping = $0 }
        .sheet(isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })) {
            MoverDelete(items: deleting) { deleting = [] }
        }
        .sheet(isPresented: Binding(get: { !batch.isEmpty }, set: { if !$0 { batch = [] } })) {
            BatchRename(items: batch) { prefix, suffix in
                mover.batchRename(batch, in: pane, prefix: prefix, suffix: suffix)
                batch = []
            } cancel: { batch = [] }
        }
        .alert(naming == .folder ? String(localized: "新建文件夹") : String(localized: "重命名"),
               isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("名称", text: $name)
            Button("取消", role: .cancel) { naming = nil }
            Button("好") {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                switch naming {
                case .folder: mover.createFolder(named: trimmed, in: pane)
                case .rename(let item): mover.rename(item, in: pane, to: trimmed)
                case nil: break
                }
                naming = nil
            }
        }
    }

    private var trail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                let steps = pane.trail
                ForEach(Array(steps.enumerated()), id: \.offset) { i, url in
                    if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    Button(i == 0 ? (pane.place?.name ?? url.lastPathComponent) : FileManager.default.displayName(atPath: url.path)) { pane.open(url) }
                        .buttonStyle(.plain)
                        .foregroundStyle(i == steps.count - 1 ? .primary : .secondary)
                        .lineLimit(1)
                }
            }
            .font(.callout)
        }
    }

    @ViewBuilder
    private var list: some View {
        if let error = pane.error {
            ContentUnavailableView(error, systemImage: "lock")
                .frame(maxHeight: .infinity)
        } else if pane.searching && pane.results == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if pane.shown.isEmpty {
            Group {
                if pane.query.isEmpty {
                    ContentUnavailableView("空文件夹", systemImage: "folder")
                } else {
                    ContentUnavailableView.search(text: pane.query)
                }
            }
            .frame(maxHeight: .infinity)
        } else {
            List(pane.shown, selection: $pane.selection) { item in
                HStack(spacing: 8) {
                    FileIcon(path: item.url.path, folder: item.isFolder, size: 20)
                        .opacity(item.isDataless ? 0.5 : 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        if let detail = item.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                    }
                    Spacer()
                    if item.isDataless {
                        Image(systemName: "icloud.and.arrow.down").font(.caption).foregroundStyle(.secondary)
                            .help(Text("只在云端，还没下载到这台 Mac"))
                    }
                    if item.isLink { Image(systemName: "arrow.turn.up.right").font(.caption).foregroundStyle(.secondary) }
                    if let size = item.size {
                        Text(FileMover.Refusal.bytes(size)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .tag(item.id)
                .draggable(item.url)
            }
            .contextMenu(forSelectionType: FolderItem.ID.self) { ids in
                if ids.count == 1, let item = pane.shown.first(where: { ids.contains($0.id) }) {
                    if item.isFolder { Button("打开") { pane.open(item.url) } }
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                    Button("拷贝路径") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.url.path, forType: .string)
                    }
                }
                if !ids.isEmpty, pane.place?.readOnly != true {
                    Divider()
                    Button("删除…", role: .destructive) { deleting = pane.shown.filter { ids.contains($0.id) } }
                        .disabled(model.mover.busy)
                }
            } primaryAction: { ids in
                // 双击：文件夹就进去，文件交给默认应用打开
                guard ids.count == 1, let item = pane.shown.first(where: { ids.contains($0.id) }) else { return }
                if item.isFolder { pane.open(item.url) } else { NSWorkspace.shared.open(item.url) }
            }
            .listStyle(.inset)
            .frame(minHeight: 260, maxHeight: .infinity)
        }
    }
}

/// 确认窗口：要搬什么、去哪、跨不跨盘、哪些不搬、重名怎么处理
private struct MoveConfirm: View {
    @Environment(AppModel.self) private var model
    @State private var plan: FileMover.Plan
    @State private var confirmingReplace = false

    init(plan: FileMover.Plan) { _plan = State(initialValue: plan) }

    var body: some View {
        let mover = model.mover
        VStack(alignment: .leading, spacing: 14) {
            Text(plan.mode == .move ? "移动 \(plan.items.count) 项" : "复制 \(plan.items.count) 项")
                .font(.title3.bold())
            VStack(alignment: .leading, spacing: 6) {
                Text("从").font(.caption).foregroundStyle(.secondary)
                PathList(paths: plan.items.map(\.path))
                Text("到").font(.caption).foregroundStyle(.secondary)
                PathList(paths: [plan.destination.path])
            }
            if plan.crossVolume {
                Label(plan.mode == .move
                      ? String(localized: "要跨盘，共 \(plan.files) 个文件、\(FileMover.Refusal.bytes(plan.bytes))。先复制过去，核对文件数和大小一致后才删原件；中途取消或拔盘，原件都还在。")
                      : String(localized: "共 \(plan.files) 个文件、\(FileMover.Refusal.bytes(plan.bytes))。复制完会核对文件数和大小。"),
                      systemImage: "externaldrive")
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("再逐字节核对内容（更慢，适合重要文件）", isOn: $plan.verifyContents)
            } else {
                Label("在同一块盘里移动，只改位置，瞬间完成。", systemImage: "bolt")
            }
            if plan.touchesCloud {
                Label(plan.mode == .move
                      ? String(localized: "涉及 iCloud Drive：移进移出会同步到你的其他设备，从 iCloud Drive 移走的，其他设备上也就没有了。")
                      : String(localized: "涉及 iCloud Drive：复制进去的会上传并同步到你的其他设备。"),
                      systemImage: "icloud")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !plan.skipped.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("这 \(plan.skipped.count) 项不搬：", systemImage: "minus.circle")
                    ForEach(plan.skipped.prefix(5), id: \.self) { skip in
                        Text("\(skip.name)：\(skip.reason)").font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if plan.skipped.count > 5 {
                        Text("还有 \(plan.skipped.count - 5) 项。").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.orange)
            }
            if !plan.conflicts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("那里已经有 \(plan.conflicts.joined(separator: "、"))。", systemImage: "doc.on.doc")
                        .fixedSize(horizontal: false, vertical: true)
                    Picker("同名的", selection: $plan.conflict) {
                        Text("两份都留，新的加编号").tag(FileMover.Conflict.keepBoth)
                        Text("跳过").tag(FileMover.Conflict.skip)
                        Text("替换").tag(FileMover.Conflict.replace)
                    }
                    .pickerStyle(.radioGroup)
                }
            }
            HStack {
                Spacer()
                Button("取消") { mover.pending = nil }.keyboardShortcut(.cancelAction)
                Button(plan.mode == .move ? "移动" : "复制") {
                    if plan.conflict == .replace && !plan.conflicts.isEmpty {
                        confirmingReplace = true
                    } else {
                        let p = plan
                        Task { await mover.run(p) }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .alert("替换那里原有的 \(plan.conflicts.count) 项？", isPresented: $confirmingReplace) {
            Button("取消", role: .cancel) {}
            Button("替换", role: .destructive) {
                let p = plan
                Task { await mover.run(p) }
            }
        } message: {
            Text("原有的会被直接删除，不进废纸篓，撤销也找不回来。")
        }
    }
}

/// 多选后改名：统一加前缀、后缀（后缀放在扩展名前面）
private struct BatchRename: View {
    let items: [FolderItem]
    let apply: (String, String) -> Void
    let cancel: () -> Void
    @State private var prefix = ""
    @State private var suffix = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("给 \(items.count) 项改名").font(.title3.bold())
            TextField("前缀，比如 2026-11-", text: $prefix).textFieldStyle(.roundedBorder)
            TextField("后缀（放在扩展名前面）", text: $suffix).textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items.prefix(5)) { item in
                    Text(FileMover.batchName(item.url.lastPathComponent, prefix: prefix, suffix: suffix, isFolder: item.isFolder))
                        .lineLimit(1).truncationMode(.middle)
                }
                if items.count > 5 { Text("…").foregroundStyle(.secondary) }
            }
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button("改名") { apply(prefix, suffix) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(prefix.isEmpty && suffix.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

private struct ProgressRow: View {
    @Environment(AppModel.self) private var model
    let progress: FileMover.Progress

    var body: some View {
        HStack(spacing: 12) {
            if progress.total > 0 {
                ProgressView(value: Double(min(progress.done, progress.total)), total: Double(progress.total))
            } else {
                ProgressView().controlSize(.small)
            }
            Text(progress.total > 0
                 ? "\(FileMover.Refusal.bytes(progress.done)) / \(FileMover.Refusal.bytes(progress.total))"
                 : String(localized: "正在搬…"))
                .monospacedDigit()
                .font(.callout)
            Text(progress.current).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .leading)
            Button("取消") { model.mover.cancel() }
        }
        .padding(10)
        .card()
    }
}

/// 最近搬过的，可以撤销
private struct RecentMoves: View {
    @Environment(AppModel.self) private var model
    @State private var open = false
    @State private var confirming: MoveRecord?

    var body: some View {
        let mover = model.mover
        Button("最近") { open = true }
            .disabled(mover.records.isEmpty)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                List(mover.records.prefix(20)) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(record)).lineLimit(1).truncationMode(.middle)
                            ForEach(record.pairs.prefix(3), id: \.to) { pair in
                                Group {
                                    if record.kind == .folder {
                                        Text(pair.to)
                                    } else {
                                        Text("\(pair.from) → \(pair.to)")
                                    }
                                }
                                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                                .lineLimit(2).truncationMode(.middle)
                                .textSelection(.enabled)
                                .help(record.kind == .folder ? pair.to : "\(pair.from) → \(pair.to)")
                            }
                            if record.pairs.count > 3 {
                                Text("还有 \(record.pairs.count - 3) 项。").font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(record.date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if record.undone {
                            Text("已撤销").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("撤销") {
                                if record.undoDeletes { confirming = record } else { Task { await mover.undo(record) } }
                            }
                            .disabled(mover.busy)
                        }
                    }
                }
                .frame(width: 620, height: 380)
                .alert("撤销会删掉新的那份", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
                    Button("取消", role: .cancel) { confirming = nil }
                    Button("删除并撤销", role: .destructive) {
                        if let r = confirming { Task { await mover.undo(r) } }
                        confirming = nil
                    }
                } message: {
                    Text("复制出来的文件或新建的文件夹会被直接删除，不进废纸篓。原件不受影响。")
                }
            }
    }

    private func title(_ r: MoveRecord) -> String {
        let first = r.pairs.first.map { URL(filePath: $0.to).lastPathComponent } ?? ""
        let more = r.pairs.count > 1 ? String(localized: " 等 \(r.pairs.count) 项") : ""
        switch r.kind {
        case .move: return String(localized: "移动 \(first)\(more)")
        case .copy: return String(localized: "复制 \(first)\(more)")
        case .rename:
            let old = r.pairs.first.map { URL(filePath: $0.from).lastPathComponent } ?? ""
            return String(localized: "\(old) 改名为 \(first)")
        case .folder: return String(localized: "新建文件夹 \(first)")
        }
    }
}

/// 一组绝对路径：等宽字体、可选中复制，多了在框里滚动
private struct PathList: View {
    let paths: [String]
    var sizes: [String: Double] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(paths, id: \.self) { path in
                    HStack(alignment: .firstTextBaseline) {
                        Text(path).font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if let size = sizes[path] { Text(size.gbText).font(.callout).monospacedDigit().foregroundStyle(.secondary) }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 160)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
    }
}

/// 搬家页的删除确认：列出每项的绝对路径和大小，不管设置怎样都先确认
private struct MoverDelete: View {
    @Environment(AppModel.self) private var model
    let items: [FolderItem]
    let close: () -> Void
    @State private var sizes: [String: Double] = [:]
    @State private var measuring = true

    var body: some View {
        let cloud = items.contains { FileMover.inCloud($0.url) }
        let total = sizes.values.reduce(0, +)
        VStack(alignment: .leading, spacing: 14) {
            Text("删除 \(items.count) 项").font(.title3.bold())
            PathList(paths: items.map(\.url.path), sizes: sizes)
            Label(measuring ? String(localized: "正在计算大小…")
                            : String(localized: "共 \(total.gbText)，直接删除，不进废纸篓，删了不能放回，“撤销”也找不回来。"),
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if cloud {
                Label("其中有 iCloud Drive 里的文件：删了你的其他设备上也会一起没有。", systemImage: "icloud")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消", action: close).keyboardShortcut(.cancelAction)
                Button("删除", role: .destructive) {
                    // 走全应用统一的删除流程：记进“最近”，权限不够弹系统密码
                    let mover = model.mover
                    model.perform(.init(title: String(localized: "在搬家页删除 \(items.count) 项"), source: String(localized: "搬家"),
                                        urls: items.map(\.url), sizes: sizes, fromMover: true) { _ in mover.refresh() })
                    close()
                }
                .buttonStyle(.borderedProminent).tint(.red)
            }
        }
        .padding(24)
        .frame(width: 560)
        .task {
            let urls = items.map(\.url)
            sizes = await blocking { Dictionary(urls.map { ($0.path, AppScanner.allocatedSize($0) ?? 0) }, uniquingKeysWith: { a, _ in a }) }
            measuring = false
        }
    }
}
