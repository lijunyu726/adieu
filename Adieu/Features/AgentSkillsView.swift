import SwiftUI

struct AgentSkillsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var selection: String?

    private var catalog: AgentSkillCatalog { model.agentSkills }

    var body: some View {
        @Bindable var catalog = model.agentSkills
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = catalog.skills.filter { skill in
            query.isEmpty || skill.id.localizedCaseInsensitiveContains(query)
                || skill.installations.contains { $0.declaredName?.localizedCaseInsensitiveContains(query) == true }
        }
        let selected = visible.first { $0.id == selection } ?? visible.first
        VStack(alignment: .leading, spacing: 16) {
            PageHeader("Agent 技能", subtitle: "管理此 Mac 上的用户级技能，选择可用的 agent 和调用方式。") {
                Button {
                    Task { await catalog.load() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(catalog.loading || catalog.saving || model.useSample)
            }

            if catalog.loading && !catalog.loaded {
                ProgressView("正在查找技能…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if catalog.skills.isEmpty {
                ContentUnavailableView("没有找到用户级技能", systemImage: "puzzlepiece.extension",
                    description: Text("这里会显示 Codex、Claude Code 和 DeepSeek Harness 的本地用户技能。"))
            } else {
                HStack(alignment: .top, spacing: 16) {
                    list(visible, selected: selected?.id)
                        .frame(width: 230)
                        .card()
                    if let selected { detail(selected).card() }
                    else { ContentUnavailableView.search(text: search) }
                }
            }
        }
        .padding(28)
        .task { await catalog.load() }
        .alert("技能设置未保存", isPresented: Binding(get: { catalog.error != nil }, set: {
            if !$0 { catalog.error = nil }
        })) {
            Button("好", role: .cancel) { catalog.error = nil }
        } message: {
            Text(catalog.error ?? "")
        }
    }

    private func list(_ skills: [AgentSkill], selected: String?) -> some View {
        VStack(spacing: 8) {
            TextField("搜索技能", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding([.top, .horizontal], 10)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(skills) { skill in
                        Button { selection = skill.id } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(skill.id).font(.headline).lineLimit(1)
                                let count = skill.activeAgents.count
                                if count == 0 {
                                    Text("已停用").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("\(count) 个 agent 可用").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(selected == skill.id ? Theme.brand.opacity(0.12) : .clear, in: .rect(cornerRadius: 9))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected == skill.id ? .isSelected : [])
                    }
                }
                .padding([.horizontal, .bottom], 6)
            }
        }
    }

    private func detail(_ skill: AgentSkill) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(skill.id).font(.title2.bold()).textSelection(.enabled)
                    Spacer()
                    if catalog.saving { ProgressView().controlSize(.small) }
                    if skill.activeAgents.isEmpty {
                        Button("恢复启用") { Task { await catalog.setEnabled(true, skill: skill) } }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("全部停用") { Task { await catalog.setEnabled(false, skill: skill) } }
                    }
                }
                .disabled(catalog.saving || catalog.loading)

                ForEach(SkillAgent.allCases) { agent in
                    agentRow(agent, skill: skill)
                }

                if skill.installations.contains(where: { $0.isActive && $0.agents.count > 1 }) {
                    Label("调整共享技能的可用范围也会影响读取同一目录的客户端。", systemImage: "folder.badge.gearshape")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("为新 agent 启用技能时，Adieu 会复制技能文件。停用的技能保存在本机，可以重新启用。更改后可新开 agent 会话。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func agentRow(_ agent: SkillAgent, skill: AgentSkill) -> some View {
        let entries = skill.activeInstallations(for: agent)
        let enabled = !entries.isEmpty
        let mode = skill.mode(for: agent)
        let commands = Set(entries.map { agent.invocation($0.commandName(for: agent, folderName: skill.id)) }).sorted()
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(agent.title).font(.headline).accessibilityHidden(true)
                Spacer()
                Toggle(isOn: Binding(get: { enabled }, set: { enabled in
                    Task { await catalog.setEnabled(enabled, for: agent, skill: skill) }
                })) {
                    Text(agent.title)
                }
                .toggleStyle(.switch)
                .labelsHidden()
            }

            if enabled {
                HStack(alignment: .firstTextBaseline) {
                    Text(commands.joined(separator: " · "))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .help(entries.map { $0.entry.path }.joined(separator: "\n"))
                    Spacer(minLength: 10)
                    Picker("调用方式", selection: Binding(get: { mode }, set: { mode in
                        Task { await catalog.change(.invocation(agent, mode), for: skill) }
                    })) {
                        if mode == .unavailable { Text(mode.title).tag(mode).disabled(true) }
                        Text(SkillInvocation.automatic.title).tag(SkillInvocation.automatic)
                        Text(SkillInvocation.explicit.title).tag(SkillInvocation.explicit)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 9))
        .disabled(catalog.saving || catalog.loading)
    }
}
