import SwiftUI
import QuickLook

/// 应用数据的逐层查看和精细清理；所有扫描、选中和删除状态由 AppModel 持有。
struct AppDataView: View {
    let target: AppDataTarget
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @FocusState private var listFocused: Bool
    @State private var preview: URL?

    private var browser: AppDataBrowser { model.appData }

    var body: some View {
        let chosen = browser.chosen
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                fileList.frame(minWidth: 480, maxWidth: .infinity)
                previewPane.frame(width: 270)
            }
            Divider()
            footer(chosen)
        }
        .frame(width: 940, height: 640)
        .background { PageBackground() }
        .task(id: target.id) {
            let subpath = UserDefaults.standard.string(forKey: "AdieuDataPath")
            await browser.refresh(at: subpath.map { URL(filePath: target.root).appending(path: $0).path })
            listFocused = true
        }
        .interactiveDismissDisabled(browser.deleting)
        .quickLookPreview($preview, in: preview.map { [$0] } ?? [])
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(target.appName) 的数据").font(.title2.bold())
                    HStack(spacing: 8) {
                        Text(Copy.text(target.part.label)).font(.callout).lineLimit(1)
                        EvidenceChip(evidence: target.part.evidence)
                    }
                }
                Spacer()
                Button("关闭") { dismiss() }.disabled(browser.deleting)
            }
            Text("这些是应用数据，可能包含聊天记录、账号和配置。请确认用途后再删。")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button { Task { await browser.goBack() } } label: {
                    Label("上一级", systemImage: "arrow.up")
                }
                .disabled(!browser.canGoBack || browser.deleting)
                Text((browser.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 0)
                if browser.measuring { ProgressView().controlSize(.small).help("正在统计大小…") }
                Button { Task { await browser.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("重新统计").disabled(browser.loading || browser.deleting)
            }
        }
        .padding(20)
    }

    private var fileList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if browser.loading {
                        ProgressView("正在读取文件夹…").frame(maxWidth: .infinity, minHeight: 280)
                    } else if let error = browser.error {
                        ContentUnavailableView("无法读取这个位置", systemImage: "folder.badge.questionmark", description: Text(error))
                            .frame(minHeight: 280)
                    } else if browser.entries.isEmpty {
                        ContentUnavailableView("文件夹为空", systemImage: "folder")
                            .frame(minHeight: 280)
                    } else {
                        ForEach(browser.entries) { item in
                            row(item).id(item.path)
                            Divider()
                        }
                    }
                }
                .padding(12)
            }
            .focusable().focused($listFocused).focusEffectDisabled()
            .onKeyPress(keys: [.space, .upArrow, .downArrow, .return, .escape, .delete, KeyEquivalent("\u{7f}"), "a"]) { press in
                handleKey(press, proxy: proxy)
            }
        }
    }

    private func row(_ item: AppDataEntry) -> some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { browser.selected.contains(item.path) }, set: { _ in
                browser.toggle(item)
                browser.focused = item.path
                listFocused = true
            })) { EmptyView() }
                .toggleStyle(.checkbox).labelsHidden().accessibilityLabel(item.name)
                .disabled(!item.canSelect || browser.deleting)
            Button {
                listFocused = true
                if item.canEnter { Task { await browser.enter(item) } }
                else { browser.focused = item.path }
            } label: {
                HStack(spacing: 10) {
                    FileIcon(path: item.path, folder: item.isDirectory, size: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle)
                        if let reason = item.restriction {
                            Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        } else if let date = item.modified {
                            Text(date, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if !item.isMeasured {
                        ProgressView().controlSize(.small)
                    } else if item.sizeIsPartial, let size = item.size {
                        Text("至少 \(size.gbText)").font(.caption).monospacedDigit()
                            .help("部分内容无法读取，大小可能偏小。")
                    } else {
                        Text(item.size.gbText).font(.callout).monospacedDigit()
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundStyle(.tertiary).opacity(item.canEnter ? 1 : 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain).disabled(browser.deleting)
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .background(browser.focused == item.path ? Theme.brand.opacity(0.09) : .clear, in: .rect(cornerRadius: 8))
        .contextMenu {
            if item.canEnter { Button("打开文件夹") { Task { await browser.enter(item) } } }
            if item.restriction == nil {
                Button("快速查看") { quickLook(item) }.disabled(model.useSample)
            }
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: item.path)]) }
                .disabled(model.useSample)
        }
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let item = browser.current {
                Group {
                    if !model.useSample, !item.isDirectory, item.restriction == nil {
                        QuickLookView(url: URL(filePath: item.path))
                    } else {
                        FileIcon(path: item.path, folder: item.isDirectory, size: 96)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: 180)
                Text(item.name).font(.headline).lineLimit(3).textSelection(.enabled)
                Text(item.size.gbText).font(.title3).monospacedDigit()
                Text((item.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(5).textSelection(.enabled)
                if let restriction = item.restriction {
                    Text(restriction).font(.callout).foregroundStyle(.secondary)
                } else if item.canEnter {
                    Button("打开文件夹") { Task { await browser.enter(item) } }
                }
                if item.sizeIsPartial {
                    Text("部分内容无法读取，大小可能偏小。").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("选择文件查看预览，或打开文件夹继续查看。")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                KeyHint(Copy.text("快速查看"), keys: Copy.text("空格"))
                KeyHint(Copy.text("换一个"), keys: "↑", "↓")
                KeyHint(Copy.text("勾选 / 取消"), keys: "↩")
            }
        }
        .padding(18).frame(maxHeight: .infinity, alignment: .top)
        .background(.white.opacity(0.4))
    }

    private func footer(_ chosen: [AppDataEntry]) -> some View {
        let knownSize = chosen.allSatisfy { $0.isMeasured && $0.size != nil }
        let amount = chosen.compactMap(\.size).reduce(0, +).gbText
        let shownAmount = chosen.contains(where: \.sizeIsPartial) ? String(localized: "至少 \(amount)") : amount
        let summary = knownSize ? String(localized: "已选 \(chosen.count) 项 · \(shownAmount)") : String(localized: "已选 \(chosen.count) 项")
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(chosen.isEmpty ? String(localized: "点击文件夹继续查看；勾选具体项目后清理。")
                     : summary)
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button { browser.toggleAll(); listFocused = true } label: { ShortcutLabel("全选", shortcut: "⌘A") }
                    .disabled(browser.loading || browser.deleting || browser.entries.isEmpty)
                if !chosen.isEmpty {
                    Button { browser.clearSelection(); listFocused = true } label: { ShortcutLabel("清除", shortcut: "esc") }
                        .disabled(browser.deleting)
                }
                Button { model.cleanAppDataSelection() } label: { ShortcutLabel("删除已勾选", shortcut: "⌘⌫") }
                    .buttonStyle(.borderedProminent).disabled(chosen.isEmpty || browser.deleting)
            }
            if browser.deleting { ProgressView("正在删除…").controlSize(.small) }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func quickLook(_ item: AppDataEntry) {
        guard !model.useSample, item.restriction == nil else { return }
        preview = preview == nil ? URL(filePath: item.path) : nil
    }

    private func handleKey(_ press: KeyPress, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !browser.deleting, !browser.loading else { return .ignored }
        switch press.key {
        case .upArrow, .downArrow:
            let step = press.key == .upArrow ? -1 : 1
            guard let path = browser.moveFocus(by: step) else { return .ignored }
            proxy.scrollTo(path)
        case .return:
            if let current = browser.current { browser.toggle(current) }
        case .space:
            if let current = browser.current { quickLook(current) }
        case "a" where press.modifiers.contains(.command): browser.toggleAll()
        case .delete, KeyEquivalent("\u{7f}"):
            guard press.modifiers.contains(.command) else { return .ignored }
            model.cleanAppDataSelection()
        case .escape:
            if browser.selected.isEmpty { dismiss() } else { browser.clearSelection() }
        default: return .ignored
        }
        return .handled
    }
}
