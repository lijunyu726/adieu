import Foundation

struct AgentSkillScanner: Sendable {
    struct Location: Sendable {
        let root: URL
        let bundleAgents: Set<SkillAgent>
        var flatAgents: Set<SkillAgent> = []

        var parked: URL {
            root.deletingLastPathComponent().appending(path: "adieu-disabled-skills", directoryHint: .isDirectory)
        }

        var parkedVersions: URL {
            parked.appending(path: ".adieu-versions", directoryHint: .isDirectory)
        }
    }

    private let configuredLocations: [Location]

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        func root(_ variable: String, _ fallback: String) -> URL {
            let value = environment[variable]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let expanded = (value as NSString).expandingTildeInPath
            let base = expanded.hasPrefix("/") ? URL(filePath: expanded, directoryHint: .isDirectory) : home.appending(path: fallback)
            return base.appending(path: "skills", directoryHint: .isDirectory).standardizedFileURL
        }

        let dshShared = root("DSH_AGENTS_HOME", ".agents")
        let shared = home.appending(path: ".agents/skills", directoryHint: .isDirectory).standardizedFileURL
        var roots: [Location] = [
            .init(root: root("CODEX_HOME", ".codex"), bundleAgents: [.codex]),
            .init(root: root("CLAUDE_CONFIG_DIR", ".claude"), bundleAgents: [.claudeCode]),
            .init(root: root("DSH_HOME", ".dsh"), bundleAgents: [.deepSeekHarness], flatAgents: [.deepSeekHarness]),
            .init(root: shared, bundleAgents: dshShared == shared ? [.codex, .deepSeekHarness] : [.codex],
                  flatAgents: dshShared == shared ? [.deepSeekHarness] : [])
        ]
        if dshShared != shared {
            roots.append(.init(root: dshShared, bundleAgents: [.deepSeekHarness], flatAgents: [.deepSeekHarness]))
        }
        configuredLocations = roots
    }

    var locations: [Location] {
        var merged: [Location] = []
        for location in configuredLocations {
            if let index = merged.firstIndex(where: { $0.root.resolvingSymlinksInPath() == location.root.resolvingSymlinksInPath() }) {
                let prior = merged[index]
                merged[index] = .init(root: prior.root, bundleAgents: prior.bundleAgents.union(location.bundleAgents),
                                      flatAgents: prior.flatAgents.union(location.flatAgents))
            } else {
                merged.append(location)
            }
        }
        return merged
    }

    func scan() throws -> [AgentSkill] {
        var skills: [String: [AgentSkill.Installation]] = [:]
        for location in locations {
            let active = try contents(location.root)
            let parked = try parkedEntries(location)
            for (entries, isActive) in [(active, true), (parked, false)] {
                for entry in entries {
                    let folder = entry.lastPathComponent
                    let activePath = location.root.appending(path: folder, directoryHint: .notDirectory)
                    let resolved = resolvedEntry(entry, activePath: activePath)
                    let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                    let isBundle = values?.isDirectory == true
                    let agents: Set<SkillAgent>
                    let instruction: URL
                    let id: String
                    if isBundle {
                        agents = location.bundleAgents
                        instruction = resolved.appending(path: "SKILL.md", directoryHint: .notDirectory).resolvingSymlinksInPath()
                        id = folder
                    } else if entry.pathExtension == "md", values?.isRegularFile == true {
                        agents = location.flatAgents
                        instruction = resolved
                        id = entry.deletingPathExtension().lastPathComponent
                    } else {
                        continue
                    }
                    guard !agents.isEmpty, instruction.isRegularSkillFile else { continue }
                    if agents.contains(.claudeCode), folder.lowercased() == "synced" { continue }
                    let metadata = try? Self.metadata(at: instruction, frontmatter: true)
                    let modes = Dictionary(uniqueKeysWithValues: agents.map { agent in
                        (agent, (try? Self.invocation(agent, bundle: resolved, metadata: metadata)) ?? .unavailable)
                    })
                    skills[id, default: []].append(.init(entry: entry, activePath: activePath, content: resolved, instruction: instruction,
                                                         agents: agents, isActive: isActive, isBundle: isBundle,
                                                         declaredName: metadata?.name, invocation: modes))
                }
            }
        }
        return skills.map { AgentSkill(id: $0.key, installations: $0.value) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private func parkedEntries(_ location: Location) throws -> [URL] {
        // 按停用时间从新到旧读取。同名旧安装仍保留在原位置。
        let versions = try contents(location.parkedVersions).reversed()
        let entries = try versions.flatMap { try contents($0) }
        return entries + (try contents(location.parked))
    }

    private func contents(_ directory: URL) throws -> [URL] {
        do {
            // Finder 的隐藏标记不影响 agent 发现技能。这里只跳过点号目录（例如 .system）。
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { !$0.lastPathComponent.hasPrefix(".") }
                .sorted { $0.path < $1.path }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return []
        }
    }

    private func resolvedEntry(_ entry: URL, activePath: URL) -> URL {
        // 停用时连同链接本身移走。相对链接仍按原安装位置查找目标。
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: entry.path) {
            let original = activePath.deletingLastPathComponent().resolvingSymlinksInPath()
            let target = destination.hasPrefix("/") ? URL(filePath: destination) : original.appending(path: destination)
            return target.resolvingSymlinksInPath()
        }
        return entry.resolvingSymlinksInPath()
    }

    static func metadata(at url: URL, frontmatter: Bool) throws -> SkillMetadata {
        SkillMetadata(try String(contentsOf: url, encoding: .utf8), at: url, frontmatter: frontmatter)
    }

    static func policyFile(_ bundle: URL) -> URL {
        bundle.appending(path: "agents/openai.yaml", directoryHint: .notDirectory)
    }

    private static func invocation(_ agent: SkillAgent, bundle: URL, metadata: SkillMetadata?) throws -> SkillInvocation {
        if agent == .codex {
            let path = policyFile(bundle)
            guard FileManager.default.fileExists(atPath: path.path) else { return .automatic }
            guard path.resolvingSymlinksInPath().isRegularSkillFile else { return .unavailable }
            return try Self.metadata(at: path, frontmatter: false).mode(for: agent)
        }
        return try metadata?.mode(for: agent) ?? .unavailable
    }
}

extension URL {
    var isRegularSkillFile: Bool {
        (try? resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}
