import Darwin
import Foundation

struct AgentSkillSettings: Sendable {
    enum Change: Sendable {
        case availability(from: Set<SkillAgent>, to: Set<SkillAgent>)
        case invocation(SkillAgent, SkillInvocation)
    }

    enum ChangeError: LocalizedError {
        case missing
        case changed(URL)
        case conflict(URL)
        case linked(URL)
        case invalidName(String)
        case recovery(String, [String])

        var errorDescription: String? {
            switch self {
            case .missing: String(localized: "技能已移动，请刷新列表后重试。")
            case .changed(let url): String(localized: "文件在保存前发生了变化：\(url.path)")
            case .conflict(let url): String(localized: "已有同名文件：\(url.path)")
            case .linked(let url): String(localized: "此目录被其他技能链接引用：\(url.path)")
            case .invalidName(let name): String(localized: "目标 agent 无法使用此技能名称：\(name)")
            case .recovery(let reason, let paths):
                String(localized: "\(reason)\n部分改动需要手动恢复：\(paths.joined(separator: ", "))")
            }
        }
    }

    let scanner: AgentSkillScanner
    private static let lock = NSLock()

    func apply(_ change: Change, to id: String) throws {
        try Self.lock.withLock {
            let skills = try scanner.scan()
            guard let skill = skills.first(where: { $0.id == id }) else { throw ChangeError.missing }
            switch change {
            case .availability(let expected, let agents):
                guard skill.activeAgents == expected, let first = skill.installations.first else {
                    throw ChangeError.missing
                }
                if !exists(first.entry) { throw ChangeError.changed(first.entry) }
                try setAvailability(agents, for: skill, allSkills: skills)
            case .invocation(let agent, let mode): try setInvocation(mode, for: agent, skill: skill)
            }
        }
    }

    private struct Move {
        let from: URL
        let to: URL
    }

    private func setAvailability(_ desired: Set<SkillAgent>, for skill: AgentSkill, allSkills: [AgentSkill]) throws {
        let fm = FileManager.default
        var moves: [Move] = []
        var staged: [URL] = []
        var keepStaging = false
        defer {
            if !keepStaging {
                for folder in staged { try? fm.removeItem(at: folder) }
            }
        }

        var covered: Set<SkillAgent> = []
        for entry in skill.installations where entry.isActive {
            if entry.agents.isSubset(of: desired) {
                covered.formUnion(entry.agents)
            } else {
                guard let location = scanner.locations.first(where: { $0.root.path == entry.activePath.deletingLastPathComponent().path }) else {
                    throw ChangeError.missing
                }
                try verifyCanPark(entry, allSkills: allSkills)
                let destination = parkingDestination(for: entry, in: location, skill: skill)
                moves.append(.init(from: entry.entry, to: destination))
            }
        }

        let parked = skill.installations.filter { !$0.isActive }.sorted { $0.agents.count < $1.agents.count }
        for entry in parked where entry.agents.isSubset(of: desired) && entry.agents.isDisjoint(with: covered) {
            moves.append(.init(from: entry.entry, to: entry.activePath))
            covered.formUnion(entry.agents)
        }

        for agent in SkillAgent.allCases where desired.contains(agent) && !covered.contains(agent) {
            guard let location = scanner.locations.first(where: { $0.bundleAgents == [agent] }),
                  let source = skill.installations.first(where: { $0.agents.contains(agent) })
                    ?? skill.installations.first(where: \.isActive) ?? skill.installations.first else {
                throw ChangeError.missing
            }
            let isFlat = agent == .deepSeekHarness && !source.isBundle
            try validateName(of: skill, source: source, for: agent)
            let stage = location.root.deletingLastPathComponent()
                .appending(path: ".adieu-skill-\(UUID().uuidString)", directoryHint: .isDirectory)
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
            staged.append(stage)
            let temp = stage.appending(path: "skill")
            if source.isBundle {
                try fm.copyItem(at: source.content, to: temp)
            } else if isFlat {
                try fm.copyItem(at: source.instruction, to: temp)
            } else {
                try fm.createDirectory(at: temp, withIntermediateDirectories: false)
                try fm.copyItem(at: source.instruction, to: temp.appending(path: "SKILL.md"))
            }
            let filename = isFlat ? skill.id + ".md" : skill.id
            moves.append(.init(from: temp, to: location.root.appending(path: filename)))
        }

        do {
            try perform(moves)
        } catch let error as ChangeError {
            if case .recovery = error { keepStaging = true }
            throw error
        }
    }

    private func parkingDestination(for entry: AgentSkill.Installation, in location: AgentSkillScanner.Location,
                                    skill: AgentSkill) -> URL {
        let name = entry.entry.lastPathComponent
        let original = location.parked.appending(path: name)
        let hasOlderInstallation = skill.installations.contains { !$0.isActive && $0.activePath == entry.activePath }
        guard hasOlderInstallation || exists(original) else { return original }

        // 外部工具可能重新安装同名技能，停用时为它保留自己的位置。
        let timestamp = Int64(Date.now.timeIntervalSince1970 * 1_000_000)
        return location.parkedVersions
            .appending(path: "\(timestamp)-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: name)
    }

    private func validateName(of skill: AgentSkill, source: AgentSkill.Installation, for agent: SkillAgent) throws {
        let name = source.commandName(for: agent, folderName: skill.id)
        switch agent {
        case .claudeCode:
            if name.lowercased() == "synced" || name.lowercased().hasPrefix("anthropic-skills:") || name.lowercased() == "anthropic-skills" {
                throw ChangeError.invalidName(name)
            }
        case .deepSeekHarness:
            if source.declaredName == nil || name.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) == nil {
                throw ChangeError.invalidName(name)
            }
        case .codex:
            if source.declaredName == nil { throw ChangeError.invalidName(name) }
        }
    }

    private func verifyCanPark(_ entry: AgentSkill.Installation, allSkills: [AgentSkill]) throws {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: entry.entry.path)) != nil { return }
        let prefix = entry.entry.resolvingSymlinksInPath().path
        let linked = allSkills.lazy.flatMap(\.installations).first { other in
            guard other.entry != entry.entry else { return false }
            return other.content.path == prefix || other.content.path.hasPrefix(prefix + "/")
                || other.instruction.path == prefix || other.instruction.path.hasPrefix(prefix + "/")
        }
        if let linked { throw ChangeError.linked(linked.entry) }
    }

    private func perform(_ moves: [Move]) throws {
        var destinations: Set<String> = []
        for move in moves {
            let path = move.to.path
            guard destinations.insert(path).inserted, !exists(move.to) else { throw ChangeError.conflict(move.to) }
            try FileManager.default.createDirectory(at: move.to.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var finished: [Move] = []
        do {
            for move in moves {
                try rename(move.from, to: move.to)
                finished.append(move)
            }
        } catch {
            var failed: [String] = []
            for move in finished.reversed() {
                do { try rename(move.to, to: move.from) }
                catch { failed.append(move.to.path) }
            }
            if !failed.isEmpty { throw ChangeError.recovery(error.localizedDescription, failed) }
            throw error
        }
    }

    private func rename(_ source: URL, to destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EEXIST { throw ChangeError.conflict(destination) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: source.path])
        }
    }

    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private struct Edit {
        let path: URL
        let before: Data?
        let after: Data
    }

    private func setInvocation(_ mode: SkillInvocation, for agent: SkillAgent, skill: AgentSkill) throws {
        let entries = skill.activeInstallations(for: agent)
        guard !entries.isEmpty, mode != .unavailable else { throw ChangeError.missing }
        var seen: Set<URL> = []
        var edits: [Edit] = []
        for entry in entries {
            let path = agent == .codex ? AgentSkillScanner.policyFile(entry.content) : entry.instruction
            let file = path.resolvingSymlinksInPath()
            guard seen.insert(file).inserted else { continue }
            let before: Data?
            if exists(path) {
                guard file.isRegularSkillFile else { throw SkillMetadata.EditError.unsupported(file) }
                before = try Data(contentsOf: file)
            } else {
                before = nil
            }
            let old = before.flatMap { String(data: $0, encoding: .utf8) }
            if before != nil && old == nil { throw SkillMetadata.EditError.unsupported(file) }
            var yaml = SkillMetadata(old ?? "", at: file, frontmatter: agent != .codex)
            if try yaml.mode(for: agent) == mode { continue }
            let after = try yaml.setMode(mode, for: agent)
            edits.append(.init(path: file, before: before, after: Data(after.utf8)))
        }

        var finished: [Edit] = []
        do {
            for edit in edits {
                try save(edit, from: edit.before, to: edit.after)
                finished.append(edit)
            }
        } catch {
            var failed: [String] = []
            for edit in finished.reversed() {
                do { try save(edit, from: edit.after, to: edit.before) }
                catch { failed.append(edit.path.path) }
            }
            if !failed.isEmpty { throw ChangeError.recovery(error.localizedDescription, failed) }
            throw error
        }
    }

    private func save(_ edit: Edit, from before: Data?, to after: Data?) throws {
        let fm = FileManager.default
        let current = exists(edit.path) ? try Data(contentsOf: edit.path) : nil
        guard current == before else { throw ChangeError.changed(edit.path) }
        if let after {
            try fm.createDirectory(at: edit.path.deletingLastPathComponent(), withIntermediateDirectories: true)
            if before == nil {
                let temporary = edit.path.deletingLastPathComponent().appending(path: ".adieu-policy-\(UUID().uuidString)")
                try after.write(to: temporary, options: .withoutOverwriting)
                do { try rename(temporary, to: edit.path) }
                catch {
                    try? fm.removeItem(at: temporary)
                    throw error
                }
            } else {
                try after.write(to: edit.path, options: .atomic)
            }
        } else {
            // 只回退本次操作新建的元数据文件，原有文件始终按原内容写回。
            try fm.removeItem(at: edit.path)
        }
    }
}
