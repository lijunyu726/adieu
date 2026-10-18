import SwiftUI

/// 开发工具：左边工具列表，右边看占用、将要执行的命令和永不执行的命令。
/// 命令原样展示，点“清理”前再确认一次。
struct DevSpaceView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: DevTool.ID?
    /// 示例模式下演示“已完成”
    @State private var ran: Set<String> = []
    @State private var confirming: DevTool?

    var body: some View {
        let tools = model.devTools
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(.devTools, subtitle: "Docker、Xcode、npm 这类工具留下的缓存。用它们自己的清理命令回收，以后需要时会重新下载。") {
                Button(model.devLoading ? "统计中…" : "重新统计") { Task { await model.loadDev() } }
                    .disabled(model.devLoading || !model.devRunning.isEmpty)
            }
            HStack(spacing: 10) {
                StatTile(value: tools.map(\.total).reduce(0, +).gbText, label: "开发工具一共占用")
                StatTile(value: tools.map(\.reclaimable).reduce(0, +).gbText, label: "可以放心回收", tint: .green)
                StatTile(value: "\(tools.count) 个", label: "检测到的工具")
            }
            if tools.isEmpty {
                Group {
                    if model.devLoading { ProgressView("正在检测开发工具…") }
                    else { ContentUnavailableView("没有检测到开发工具", systemImage: "hammer", description: Text("没有找到 Docker、Xcode、Homebrew、npm 等工具的缓存。")) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 18) {
                    ScrollView {
                        VStack(spacing: 6) { ForEach(tools) { toolRow($0) } }.padding(6)
                    }
                    .frame(width: 290)
                    .card()
                    if let tool = tools.first(where: { $0.id == (selection ?? tools.first?.id) }) {
                        detail(tool).card()
                    }
                }
            }
        }
        .padding(28)
        .alert("清理 \(confirming?.name ?? "")？", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { t in
            Button("清理") { Task { await model.runDev(t) } }
            Button("取消", role: .cancel) {}
        } message: { t in
            Text("会依次执行：\n" + steps(t).joined(separator: "\n") + "\n\n直接删除，不经过废纸篓。清掉的是缓存，以后用到时工具会重新下载。")
        }
    }

    private func toolRow(_ t: DevTool) -> some View {
        let active = t.id == (selection ?? model.devTools.first?.id)
        return Button { selection = t.id } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(t.name).fontWeight(.semibold)
                    Spacer()
                    if model.devRunning.contains(t.id) { ProgressView().controlSize(.mini) }
                    Text(t.total.gbText).monospacedDigit().foregroundStyle(.secondary)
                }
                SegmentBar(segments: [.init(value: t.reclaimable, color: .green), .init(value: t.total - t.reclaimable, color: .secondary.opacity(0.3))],
                           total: max(t.total, 0.001), height: 5)
                Text(t.blocked ?? (t.reclaimable > 0.01 ? "可回收 \(t.reclaimable.gbText)" : "没有可回收的"))
                    .font(.caption).foregroundStyle(t.blocked != nil ? .orange : .secondary)
            }
            .padding(10)
            .background(active ? Theme.brand.opacity(0.12) : .clear, in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// 要展示的步骤：真实工具用 actions，示例数据用 commands
    private func steps(_ t: DevTool) -> [String] { t.actions.isEmpty ? t.commands : t.actions.map(\.display) }

    private func detail(_ t: DevTool) -> some View {
        let done = ran.contains(t.id)
        let running = model.devRunning.contains(t.id)
        let steps = steps(t)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(t.name).font(.title2.bold())
                        Text(t.location).font(.callout).foregroundStyle(.secondary)
                    }
                    Text(t.note).foregroundStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    GridRow { Text("里面有什么"); Text("占用"); Text("可以回收") }.font(.caption).foregroundStyle(.secondary)
                    ForEach(t.parts, id: \.label) { p in
                        GridRow {
                            Text(p.label)
                            Text(p.size.gbText).monospacedDigit().foregroundStyle(.secondary)
                            Text(p.reclaimable > 0 ? p.reclaimable.gbText : "留着").monospacedDigit()
                                .foregroundStyle(p.reclaimable > 0 ? .green : .secondary)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 8) {
                    Label("点“清理”会执行这些命令", systemImage: "terminal").font(.headline)
                    VStack(alignment: .leading, spacing: 6) {
                        if steps.isEmpty { Text("没有要执行的。").foregroundStyle(.secondary) }
                        ForEach(steps, id: \.self) { c in
                            Text(c).font(.callout.monospaced()).textSelection(.enabled)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
                    if let never = t.never {
                        Label("不会执行：\(never)", systemImage: "hand.raised.fill").font(.callout).foregroundStyle(.red)
                    }
                }

                HStack {
                    if model.useSample {
                        Button(steps.isEmpty ? "不用清理" : (done ? "已完成 · 撤销演示" : "清理（回收 \(t.reclaimable.gbText)）")) {
                            if done { ran.remove(t.id) } else { ran.insert(t.id) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(steps.isEmpty)
                    } else {
                        Button(running ? "正在清理…" : (t.blocked ?? "清理（约回收 \(t.reclaimable.gbText)）")) { confirming = t }
                            .buttonStyle(.borderedProminent)
                            .disabled(steps.isEmpty || t.blocked != nil || running || t.reclaimable <= 0)
                    }
                    if running { ProgressView().controlSize(.small) }
                }
                .controlSize(.large)

                if let log = model.devLog[t.id] {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("运行记录").font(.headline)
                        Text(log).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
                    }
                }
            }
            .padding(20)
        }
    }
}
