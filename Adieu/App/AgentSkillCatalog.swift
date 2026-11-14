import Foundation
import Observation

@Observable
@MainActor
final class AgentSkillCatalog {
    private(set) var skills: [AgentSkill]
    private(set) var loading = false
    private(set) var saving = false
    private(set) var loaded: Bool
    var error: String?

    private let scanner: AgentSkillScanner
    private let sample: Bool
    private let defaults: UserDefaults
    private var previouslyEnabled: [String: [String]]
    private static let preferenceKey = "agentSkillPreviouslyEnabled"

    init(sample: [AgentSkill]?, defaults: UserDefaults = .standard) {
        scanner = AgentSkillScanner()
        self.sample = sample != nil
        self.defaults = defaults
        skills = sample ?? []
        loaded = sample != nil
        previouslyEnabled = sample == nil ? defaults.dictionary(forKey: Self.preferenceKey) as? [String: [String]] ?? [:] : [:]
    }

    func load() async {
        guard !sample, !loading, !saving else { return }
        loading = true
        defer { loading = false }
        do {
            skills = try await blocking { [scanner] in Result { try scanner.scan() } }.get()
            loaded = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setEnabled(_ enabled: Bool, for agent: SkillAgent, skill: AgentSkill) async {
        var desired = skill.activeAgents
        if enabled { desired.insert(agent) } else { desired.remove(agent) }
        if await change(.availability(from: skill.activeAgents, to: desired), for: skill) {
            remember(desired.isEmpty ? skill.activeAgents : desired, for: skill.id)
        }
    }

    func setEnabled(_ enabled: Bool, skill: AgentSkill) async {
        let remembered = previouslyEnabled[skill.id]?.compactMap(SkillAgent.init(rawValue:)) ?? []
        let desired = remembered.isEmpty ? skill.installedAgents : Set(remembered)
        if await change(.availability(from: skill.activeAgents, to: enabled ? desired : []), for: skill), !enabled {
            remember(skill.activeAgents, for: skill.id)
        }
    }

    private func remember(_ agents: Set<SkillAgent>, for id: String) {
        previouslyEnabled[id] = agents.map(\.rawValue).sorted()
        if !sample { defaults.set(previouslyEnabled, forKey: Self.preferenceKey) }
    }

    @discardableResult
    func change(_ change: AgentSkillSettings.Change, for skill: AgentSkill) async -> Bool {
        guard !saving, !loading else { return false }
        if sample {
            updateSample(change, for: skill)
            return true
        }
        saving = true
        defer { saving = false }
        let (updated, failure) = await blocking { [scanner] in
            let action = Result { try AgentSkillSettings(scanner: scanner).apply(change, to: skill.id) }
            return (Result { try scanner.scan() }, action.failureDescription)
        }
        do {
            skills = try updated.get()
        } catch {
            self.error = failure ?? error.localizedDescription
            return false
        }
        error = failure
        return failure == nil
    }

    func uninstall(_ skill: AgentSkill, protected: [String]) async -> TrashService.Outcome? {
        guard !saving, !loading else { return nil }
        saving = true
        defer { saving = false }
        if sample {
            skills.removeAll { $0.id == skill.id }
            previouslyEnabled.removeValue(forKey: skill.id)
            return nil
        }

        let (removal, updated) = await blocking { [scanner] in
            let result = Result { try AgentSkillSettings(scanner: scanner).uninstall(skill, protected: protected) }
            return (result, Result { try scanner.scan() })
        }
        if case .success(let fresh) = updated {
            skills = fresh
            if !fresh.contains(where: { $0.id == skill.id }) {
                previouslyEnabled.removeValue(forKey: skill.id)
                defaults.set(previouslyEnabled, forKey: Self.preferenceKey)
            }
        }
        error = removal.failureDescription ?? updated.failureDescription
        return try? removal.get()
    }

    private func updateSample(_ change: AgentSkillSettings.Change, for skill: AgentSkill) {
        guard let index = skills.firstIndex(where: { $0.id == skill.id }) else { return }
        let agents: Set<SkillAgent>
        if case .availability(_, let desired) = change { agents = desired } else { agents = skill.activeAgents }
        let installations = SkillAgent.allCases.filter { skill.installedAgents.contains($0) || agents.contains($0) }.map { agent in
            let mode: SkillInvocation
            if case .invocation(let target, let desired) = change, agent == target { mode = desired }
            else { mode = skill.installations.first { $0.agents.contains(agent) }?.invocation[agent] ?? .automatic }
            return Sample.skillInstallation(skill.id, agent: agent, active: agents.contains(agent), mode: mode)
        }
        skills[index] = .init(id: skill.id, installations: installations)
    }
}

private extension Result where Failure == any Error {
    var failureDescription: String? {
        if case .failure(let error) = self { return error.localizedDescription }
        return nil
    }
}
