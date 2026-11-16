import AppKit
import SwiftUI

/// 搬家：左右两栏，在这台 Mac 和外接硬盘之间移动、复制文件，也能改名、新建文件夹
struct MoverView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let mover = model.mover
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(.mover, subtitle: "在这台 Mac 和外接硬盘之间搬文件。跨盘移动先复制、核对无误再删原件。") {
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

    private enum Naming: Equatable { case folder, rename(FolderItem) }

    var body: some View {
        let mover = model.mover
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                ForEach(mover.places) { place in
                    Button { mover.choose(place, for: pane) } label: {
                        Label(place.name, systemImage: place.kind == .home ? "laptopcomputer" : "externaldrive")
                    }
                }
            } label: {
                Label(pane.place?.name ?? String(localized: "选择位置"),
                      systemImage: pane.place?.kind == .volume ? "externaldrive" : "laptopcomputer")
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
            TextField("在这个文件夹里搜索", text: $pane.query)
                .textFieldStyle(.roundedBorder)
            list
            HStack {
                Button("新建文件夹") { name = String(localized: "未命名文件夹"); naming = .folder }
                    .disabled(pane.folder == nil || pane.place?.readOnly == true || mover.busy)
                Button("重命名") {
                    if let item = pane.chosen.first { name = item.name; naming = .rename(item) }
                }
                .disabled(pane.chosen.count != 1 || pane.place?.readOnly == true || mover.busy)
                Spacer()
                if !pane.chosen.isEmpty {
                    Text("已选 \(pane.chosen.count) 项").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .card()
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
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        if let detail = item.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                    }
                    Spacer()
                    if item.isLink { Image(systemName: "arrow.turn.up.right").font(.caption).foregroundStyle(.secondary) }
                    if let size = item.size {
                        Text(FileMover.Refusal.bytes(size)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .tag(item.id)
            }
            .contextMenu(forSelectionType: FolderItem.ID.self) { ids in
                if ids.count == 1, let item = pane.shown.first(where: { ids.contains($0.id) }) {
                    if item.isFolder { Button("打开") { pane.open(item.url) } }
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
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

/// 确认窗口：要搬什么、去哪、跨不跨盘、重名怎么处理
private struct MoveConfirm: View {
    @Environment(AppModel.self) private var model
    let plan: FileMover.Plan

    var body: some View {
        let mover = model.mover
        let names = plan.items.map(\.lastPathComponent)
        VStack(alignment: .leading, spacing: 14) {
            Text(plan.mode == .move ? "移动 \(plan.items.count) 项" : "复制 \(plan.items.count) 项")
                .font(.title3.bold())
            VStack(alignment: .leading, spacing: 4) {
                Text(names.prefix(6).joined(separator: "、") + (names.count > 6 ? String(localized: " 等") : ""))
                    .lineLimit(3)
                Text("到 \(plan.destination.path)").foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
            if plan.crossVolume {
                Label(plan.mode == .move
                      ? String(localized: "要跨盘，共 \(plan.files) 个文件、\(FileMover.Refusal.bytes(plan.bytes))。先复制过去，核对文件数和大小一致后才删原件；中途取消或拔盘，原件都还在。")
                      : String(localized: "共 \(plan.files) 个文件、\(FileMover.Refusal.bytes(plan.bytes))。复制完会核对文件数和大小。"),
                      systemImage: "externaldrive")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("在同一块盘里移动，只改位置，瞬间完成。", systemImage: "bolt")
            }
            if !plan.conflicts.isEmpty {
                Label("那里已经有 \(plan.conflicts.joined(separator: "、"))。两份都保留，新来的名字后面加编号。",
                      systemImage: "doc.on.doc")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消") { mover.pending = nil }.keyboardShortcut(.cancelAction)
                Button(plan.mode == .move ? "移动" : "复制") { Task { await mover.run(plan) } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
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
                .frame(width: 380, height: 300)
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
