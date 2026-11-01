import SwiftUI

/// 菜单栏面板：剩多少、这周多用了多少、最值得做的一件事、另外几件小事、刚才删的结果。
/// 建议和概览“今日建议”是同一套（`Suggestion.make`）。能当场处理的（开发缓存、已装好的安装包、启动副本）
/// 点按钮就做，菜单栏里点的就是确认；要人看一眼的（大文件、残留）打开主窗口过去
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    /// 正在当场处理的建议
    @State private var working: Set<String> = []

    private var suggestions: [Suggestion] { Suggestion.make(model) }

    /// 一小时内删过、核对过的最近一条
    private var recent: HistoryEntry? {
        model.history.first { $0.actualFreed != nil && $0.date > .now.addingTimeInterval(-3600) }
    }

    var body: some View {
        let used = model.disk.total > 0 ? model.disk.used / model.disk.total : 0
        let low = used > 0.9
        let list = suggestions
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("可用 \(model.disk.free.gbText)").font(.title2.bold()).monospacedDigit()
                    Spacer()
                    Text("共 \(model.disk.total.gbText)").font(.caption).foregroundStyle(.secondary)
                }
                ProgressView(value: used).tint(low ? .red : .accentColor)
                Text(headline(used: used)).font(.caption).foregroundStyle(low ? .red : .secondary)
            }

            if let top = list.first {
                VStack(alignment: .leading, spacing: 6) {
                    Text("现在最值得做").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline) {
                        Text(Copy.text(top.title)).fontWeight(.semibold)
                        Spacer()
                        if let size = top.size { Text(size.gbText).fontWeight(.bold).foregroundStyle(.green).monospacedDigit() }
                    }
                    Text(Copy.text(top.detail)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    actionButton(top, prominent: true).padding(.top, 2)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.opacity(0.8), in: .rect(cornerRadius: 12))
            } else {
                Text(model.scanning ? "正在扫描，稍等一下…" : "暂时没有要处理的。")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if list.count > 1 {
                VStack(spacing: 0) {
                    ForEach(Array(list.dropFirst().enumerated()), id: \.element.id) { i, s in
                        if i > 0 { Divider() }
                        HStack(spacing: 8) {
                            Text(Copy.text(s.title)).font(.callout).lineLimit(1)
                            Spacer(minLength: 6)
                            if let size = s.size { Text(size.gbText).font(.callout).foregroundStyle(.secondary).monospacedDigit() }
                            actionButton(s, prominent: false)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                }
                .background(.background.opacity(0.8), in: .rect(cornerRadius: 12))
            }

            if let recent, let actual = recent.actualFreed {
                Label("刚才\(Copy.text(recent.title))，实际腾出 \(actual.gbText)", systemImage: "checkmark")
                    .font(.caption).foregroundStyle(.green).lineLimit(2)
            }

            HStack(spacing: 8) {
                Button("腾出空间…") { model.sheet = .goal; activateMainWindow() }.frame(maxWidth: .infinity)
                Button("最近") { model.sheet = .history; activateMainWindow() }.frame(maxWidth: .infinity)
                Button("打开 Adieu") { activateMainWindow() }.frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func headline(used: Double) -> String {
        let pct = Int(((1 - used) * 100).rounded())
        var line = pct < 10 ? String(localized: "只剩 \(pct)%，系统更新可能装不上") : String(localized: "还有 \(pct)%")
        if let week = DiaryStore.week(model), abs(week.change) > 0.05 {
            line += " · " + (week.change > 0 ? String(localized: "这周多用了 \(week.change.gbText)") : String(localized: "这周空出了 \((-week.change).gbText)"))
        }
        return line
    }

    @ViewBuilder
    private func actionButton(_ s: Suggestion, prominent: Bool) -> some View {
        let busy = working.contains(s.id)
        let title: String = switch s.kind {
        case .dev: String(localized: "清理")
        case .clones: String(localized: "删掉")
        case .files where s.target == .installers: String(localized: "删除")
        default: String(localized: "去看看")
        }
        if prominent {
            Button(busy ? String(localized: "正在处理…") : title) { act(s) }
                .buttonStyle(.borderedProminent).disabled(busy)
        } else {
            Button(busy ? String(localized: "处理中…") : title) { act(s) }
                .controlSize(.small).disabled(busy)
        }
    }

    private func act(_ s: Suggestion) {
        if model.useSample { return }
        switch s.kind {
        case .dev(let id):
            guard let tool = model.devTools.first(where: { $0.id == id }) else { return }
            working.insert(s.id)
            Task { await model.runDev(tool); working.remove(s.id) }
        case .clones:
            guard let c = model.space?.clones, !c.removable.isEmpty else { return }
            working.insert(s.id)
            model.perform(.init(title: String(localized: "删掉 \(c.removable.count) 份启动副本"), source: "菜单栏",
                                urls: c.removable.map { URL(filePath: $0) }, sizes: c.removableSizes,
                                onDone: { _ in
                                    Task { @MainActor in
                                        model.space?.clones = await blocking { CodeSignClones.scan() }
                                        working.remove(s.id)
                                    }
                                }))
        case .files where s.target == .installers && !s.sizes.isEmpty:
            working.insert(s.id)
            model.perform(.init(title: Copy.text(s.title), source: "菜单栏",
                                urls: s.sizes.keys.map { URL(filePath: $0) }, sizes: s.sizes, keys: Array(s.sizes.keys),
                                onDone: { _ in working.remove(s.id) }))
        default:
            if s.picks { model.pickOnOpen = s.target }
            model.section = s.target
            activateMainWindow()
        }
    }

    private func activateMainWindow() {
        NSApp.activate()
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            openWindow(id: "main")
        }
    }
}
