import SwiftUI

/// 开发工具：左边工具列表，右边看占用、将要执行的命令和永不执行的命令。
/// 命令原样展示，点“清理”前再确认一次。
struct DevSpaceView: View {
    @Environment(AppModel.self) private var model
    private enum Tab: String { case caches, worktrees, skills }
    @State private var tab: Tab? = UserDefaults.standard.bool(forKey: "AdieuAgentSkills") ? .skills : nil
    @State private var selection: DevTool.ID?
    /// 示例模式下演示“已完成”
    @State private var ran: Set<String> = []
    @State private var confirming: DevTool?

    @State private var confirmingWorktree: WorktreeItem?
    @State private var hoveredProject: WorktreeProject.ID?
    @State private var confirmingProject: WorktreeProject?
    @State private var hoveredWorktree: WorktreeItem.ID?

    var body: some View {
        let worktrees = model.worktrees
        let selected = tab ?? (worktrees.showsWorktrees ? .worktrees : .caches)
        return VStack(alignment: .leading, spacing: 0) {
            Picker("开发工具", selection: Binding(get: { selected }, set: { next in
                tab = next
                if next != .skills { worktrees.showsWorktrees = next == .worktrees }
            })) {
                Text("开发缓存").tag(Tab.caches)
                Text("Git worktree").tag(Tab.worktrees)
                Text("Agent 技能").tag(Tab.skills)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 390).padding(.horizontal, 28).padding(.top, 20)
            switch selected {
            case .caches: cacheContent
            case .worktrees: worktreeContent
            case .skills: AgentSkillsView()
            }
        }
        .task(id: selected) { if selected == .worktrees { await worktrees.load() } }
        .alert(confirmingWorktree?.removalMode?.title ?? "", isPresented: Binding(get: { confirmingWorktree != nil }, set: {
            if !$0 { confirmingWorktree = nil }
        }), presenting: confirmingWorktree) { item in
            if let mode = item.removalMode {
                Button(mode.title, role: mode == .force ? .destructive : nil) { model.removeWorktree(item, mode: mode) }
            }
            Button("取消", role: .cancel) {}
        } message: { item in
            Text(worktreeConfirmationMessage(item))
        }
        .alert("移出列表", isPresented: Binding(get: { confirmingProject != nil }, set: {
            if !$0 { confirmingProject = nil }
        }), presenting: confirmingProject) { project in
            Button("移出列表", role: .destructive) {
                confirmingProject = nil
                model.worktrees.forget(project.path)
            }
            .disabled(!model.worktrees.removing.isEmpty)
            Button("取消", role: .cancel) {}
        } message: { project in
            Text(project.path + "\n\n" + String(localized: "只移出列表，保留磁盘上的项目和 worktree。"))
        }
    }

    private func worktreeConfirmationMessage(_ item: WorktreeItem) -> String {
        let warning: String
        if item.removalMode == .force {
            warning = String(localized: "将永久删除整个工作区，包括未提交、未跟踪和忽略的文件。游离 HEAD 的独有提交可能丢失。已有分支保留。此操作无法撤销。")
        } else {
            warning = String(localized: "将直接删除整个工作区，包括 Git 忽略的文件（例如依赖、构建产物和 .env）。不进废纸篓，删了不能放回。Git 分支会保留。")
        }
        return [item.path, item.blocked, item.command, warning].compactMap { $0 }.joined(separator: "\n\n")
    }

    private var cacheContent: some View {
        let tools = model.devTools
        return VStack(alignment: .leading, spacing: 18) {
            PageHeader(.devTools, subtitle: "Docker、Xcode、npm 这类工具留下的缓存。用它们自己的清理命令回收，以后需要时会重新下载。") {
                Button(model.devLoading ? "统计中…" : "重新统计") { Task { await model.loadDev() } }
                    .disabled(model.devLoading || !model.devRunning.isEmpty)
            }
            HStack(spacing: 10) {
                StatTile(value: tools.map(\.total).reduce(0, +).gbText, label: "开发工具一共占用")
                StatTile(value: tools.map(\.reclaimable).reduce(0, +).gbText, label: "可以放心回收", tint: .green)
                StatTile(value: String(localized: "\(tools.count) 个"), label: "检测到的工具")
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
                Text(t.blocked.map(Copy.text) ?? (t.reclaimable > 0.01 ? String(localized: "可回收 \(t.reclaimable.gbText)") : String(localized: "没有可回收的")))
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
                    Text(Copy.text(t.note)).foregroundStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    GridRow { Text("里面有什么"); Text("占用"); Text("可以回收") }.font(.caption).foregroundStyle(.secondary)
                    ForEach(t.parts, id: \.label) { p in
                        GridRow {
                            Text(Copy.text(p.label))
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
                        Label("不会执行：\(Copy.text(never))", systemImage: "hand.raised.fill").font(.callout).foregroundStyle(.red)
                    }
                }

                HStack {
                    if model.useSample {
                        Button(steps.isEmpty ? String(localized: "不用清理") : (done ? String(localized: "已完成 · 撤销演示") : String(localized: "清理（回收 \(t.reclaimable.gbText)）"))) {
                            if done { ran.remove(t.id) } else { ran.insert(t.id) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(steps.isEmpty)
                    } else {
                        Button(running ? String(localized: "正在清理…") : (t.blocked.map(Copy.text) ?? String(localized: "清理（约回收 \(t.reclaimable.gbText)）"))) { confirming = t }
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

    private var worktreeContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader("Git worktree", subtitle: "") {
                Button("添加项目") { chooseProject() }
                    .disabled(model.useSample || model.worktrees.adding)
                if model.worktrees.isRefreshing || model.worktrees.adding { ProgressView().controlSize(.small) }
                Button("重新统计") { Task { await model.worktrees.load(force: true) } }
                    .disabled(model.worktrees.isRefreshing || !model.worktrees.removing.isEmpty)
            }
            if model.worktrees.projects.isEmpty {
                if model.worktrees.adding { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else {
                    ContentUnavailableView("添加一个 Git 项目", systemImage: "point.3.connected.trianglepath.dotted")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                HStack(alignment: .top, spacing: 18) {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(model.worktrees.projects) { project in projectRow(project) }
                        }.padding(6)
                    }
                    .frame(width: 220)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .card()
                    if let project = selectedWorktreeProject {
                        worktreeDetail(project)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .card()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }.padding(28)
    }

    private var selectedWorktreeProject: WorktreeProject? {
        model.worktrees.selectedProject
    }

    private func projectRow(_ project: WorktreeProject) -> some View {
        let active = project.id == selectedWorktreeProject?.id
        return Button { model.worktrees.selectedID = project.id } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(URL(filePath: project.path).lastPathComponent)
                    .fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                    .padding(.trailing, 22)
                Text(project.path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                HStack {
                    Text("Git worktree")
                    Spacer()
                    if model.worktrees.loaded.contains(project.path) {
                        Text(project.items.count, format: .number).monospacedDigit()
                    } else { Text("—") }
                }.font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(active ? Theme.brand.opacity(0.12) : .clear, in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(project.path)
        .overlay(alignment: .topTrailing) {
            Button {
                hoveredProject = nil
                confirmingProject = project
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.red)
                    .frame(width: 20, height: 20)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("移出列表")
            .help("只移出列表，保留磁盘上的项目和 worktree。")
            .disabled(hoveredProject != project.id || !model.worktrees.removing.isEmpty)
            .opacity(hoveredProject == project.id ? 1 : 0)
            .accessibilityHidden(hoveredProject != project.id)
            .padding(6)
        }
        .onHover { hovering in
            if hovering { hoveredProject = project.id }
            else if hoveredProject == project.id { hoveredProject = nil }
        }
    }

    private func worktreeDetail(_ project: WorktreeProject) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(URL(filePath: project.path).lastPathComponent).font(.title3.bold())
                    Text(project.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let error = project.error { Text(error).foregroundStyle(.orange) }
                if !model.worktrees.loaded.contains(project.path) {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 32)
                }
                ForEach(project.items) { item in worktreeRow(item) }
            }.padding(20)
        }
    }

    private func worktreeRow(_ item: WorktreeItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(alignment: .top, spacing: 12) {
                FileIcon(path: item.path, size: 32)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(item.branch ?? String(localized: "游离 HEAD")).fontWeight(.semibold)
                        if item.branch == nil { Text(String(item.head.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary) }
                        Spacer()
                        Text(item.size?.gbText ?? "—").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Text(item.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(item.blocked ?? String(localized: "已合并"))
                        .font(.callout).foregroundStyle(item.blocked == nil ? .green : .secondary)
                    if item.hasIgnoredFiles {
                        Text("含忽略文件").font(.caption).foregroundStyle(.orange)
                    }
                    if let mode = item.removalMode {
                        let visible = mode == .safe || hoveredWorktree == item.id
                        Text(item.command).font(.caption.monospaced()).textSelection(.enabled)
                        HStack {
                            Spacer()
                            Button(mode.title, role: mode == .force ? .destructive : nil) { confirmingWorktree = item }
                                .buttonStyle(.borderedProminent)
                                .tint(mode == .force ? .red : Theme.brand)
                                .disabled(!visible || !model.worktrees.removing.isEmpty)
                                .opacity(visible ? 1 : 0)
                                .allowsHitTesting(visible)
                                .accessibilityHidden(!visible)
                        }
                    }
                }
                if model.worktrees.removing.contains(item.id) { ProgressView().controlSize(.small) }
            }
        }
        .contentShape(.rect)
        .onHover { hovering in
            if hovering { hoveredWorktree = item.id }
            else if hoveredWorktree == item.id { hoveredWorktree = nil }
        }
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "添加项目")
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                if await model.worktrees.add(url.path) == nil { model.notice = model.worktrees.addError }
            }
        }
    }

}
