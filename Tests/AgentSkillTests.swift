import Darwin
import Foundation
@testable import ReviewAdieu

@main
struct AgentSkillTests {
    static func main() throws {
        let home = URL(filePath: FileManager.default.currentDirectoryPath)
            .appending(path: "scratch/agent-skills-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fm = FileManager.default
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let scanner = AgentSkillScanner(home: home, environment: [:])
        let settings = AgentSkillSettings(scanner: scanner)

        func write(_ contents: String, to relativePath: String) throws {
            let file = home.appending(path: relativePath)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        func read(_ relativePath: String) throws -> String {
            try String(contentsOf: home.appending(path: relativePath), encoding: .utf8)
        }
        func skill(_ id: String) throws -> AgentSkill {
            try require(scanner.scan().first { $0.id == id }, "找不到 \(id)")
        }
        func select(_ agents: Set<SkillAgent>, _ id: String) throws {
            let item = try skill(id)
            try settings.apply(.availability(from: item.activeAgents, to: agents), to: id)
            try check(skill(id).activeAgents == agents, "保存后 agent 集合不匹配：\(id)")
        }

        try check(scanner.scan().isEmpty, "没有技能目录时应该显示空列表")
        let body = "---\r\nname: shared\r\ndescription: >\r\n  A shared skill.\r\nuser-invocable: false # 可调用性\r\n---\r\nBody and resources.\r\n"
        try write(body, to: ".agents/skills/shared/SKILL.md")
        let sharedFolder = home.appending(path: ".agents/skills/shared")
        try check(chflags(sharedFolder.path, UInt32(UF_HIDDEN)) == 0, "应能给测试技能设置 Finder 隐藏标记")
        try write("test script\n", to: ".agents/skills/shared/scripts/run.sh")
        try write("---\nname: bundled\ndescription: System skill\n---\n", to: ".codex/skills/.system/bundled/SKILL.md")
        try write("---\nname: synced\ndescription: Synced skill\n---\n", to: ".claude/skills/synced/SKILL.md")
        try check(scanner.scan().map(\.id) == ["shared"], "系统和同步技能不应被接管")
        try check(skill("shared").activeAgents == [.codex, .deepSeekHarness], "共享技能应同时对 Codex 和 Harness 启用")

        try settings.apply(.invocation(.deepSeekHarness, .explicit), to: "shared")
        let manual = try read(".agents/skills/shared/SKILL.md")
        try check(manual.contains("disable-model-invocation: true\r\n"), "应写入 Harness 的点名设置")
        try check(manual.contains("user-invocable: true # 可调用性\r\n"), "点名技能应允许用户调用并保留注释")
        try check(manual.hasSuffix("---\r\nBody and resources.\r\n"), "应保留技能正文和换行")
        try check(skill("shared").mode(for: .deepSeekHarness) == .explicit, "应读回 Harness 的点名设置")

        try select([.codex], "shared")
        try check(read(".agents/adieu-disabled-skills/shared/SKILL.md") == manual, "共享原件应完整保留")
        try check(read(".codex/skills/shared/scripts/run.sh") == "test script\n", "切换后仍可用的客户端应收到完整技能包")
        try select([], "shared")
        try select([.codex], "shared")
        try select([.codex, .claudeCode, .deepSeekHarness], "shared")

        try write("interface:\n  display_name: Shared\npolicy:\n  allow_implicit_invocation: true # keep this\n", to: ".codex/skills/shared/agents/openai.yaml")
        try settings.apply(.invocation(.codex, .explicit), to: "shared")
        let policy = try read(".codex/skills/shared/agents/openai.yaml")
        try check(policy.contains("  allow_implicit_invocation: false # keep this"), "Codex 应使用原生策略")
        try check(policy.contains("  display_name: Shared"), "应保留 Codex 的界面元数据")
        try check(skill("shared").mode(for: .codex) == .explicit, "应读回 Codex 的点名设置")
        try settings.apply(.invocation(.claudeCode, .automatic), to: "shared")
        try check(skill("shared").mode(for: .claudeCode) == .automatic, "应独立保存 Claude Code 的调用方式")
        try check(skill("shared").mode(for: .deepSeekHarness) == .explicit, "应保留 Harness 的调用方式")

        // 分别验证共享根目录向两个专用目录拆分时的实际可见性。
        try write("---\nname: reverse\ndescription: Reverse split\n---\n", to: ".agents/skills/reverse/SKILL.md")
        try select([.deepSeekHarness], "reverse")
        try check(read(".dsh/skills/reverse/SKILL.md").contains("name: reverse"), "Harness 应能发现拆分后的技能")

        try write("---\nname: flat\ndescription: Flat skill\n---\nFlat body\n", to: ".dsh/skills/flat.md")
        try check(skill("flat").activeAgents == [.deepSeekHarness], "Harness 支持单文件技能")
        try select([], "flat")
        try select([.deepSeekHarness, .codex], "flat")
        try settings.apply(.invocation(.codex, .explicit), to: "flat")
        try check(read(".codex/skills/flat/agents/openai.yaml").contains("allow_implicit_invocation: false"), "缺少 Codex 元数据时应创建")

        try write("---\nname: linked\ndescription: Linked skill\n---\n", to: "library/linked/SKILL.md")
        try fm.createSymbolicLink(atPath: home.appending(path: ".claude/skills/linked").path, withDestinationPath: "../../library/linked")
        try select([], "linked")
        try select([.claudeCode], "linked")
        try check(fm.destinationOfSymbolicLink(atPath: home.appending(path: ".claude/skills/linked").path) == "../../library/linked",
                  "停用后恢复应保留原始相对链接")
        try check(read("library/linked/SKILL.md").contains("name: linked"), "链接目标应保留")

        // 外部技能管理器可能在旧链接停用后重新注册同名链接。
        let oldTarget = "../../library/old"
        let newTarget = "../../library/current"
        let laterTarget = "../../library/later"
        let sharedPath = home.appending(path: ".agents/skills/reinstalled")
        let originalBackup = home.appending(path: ".agents/adieu-disabled-skills/reinstalled")
        for source in ["old", "current", "later"] {
            try write("---\nname: reinstalled\ndescription: \(source) version\n---\n", to: "library/\(source)/SKILL.md")
        }
        try fm.createSymbolicLink(atPath: sharedPath.path, withDestinationPath: oldTarget)
        try select([], "reinstalled")
        try fm.createSymbolicLink(atPath: sharedPath.path, withDestinationPath: newTarget)
        try select([], "reinstalled")
        try fm.createSymbolicLink(atPath: sharedPath.path, withDestinationPath: laterTarget)
        try select([], "reinstalled")
        try check(skill("reinstalled").installations.count == 3, "应保留全部同名的停用版本")
        try select([.codex, .deepSeekHarness], "reinstalled")
        try check(fm.destinationOfSymbolicLink(atPath: sharedPath.path) == laterTarget, "应恢复最近停用的同名链接")
        try check(fm.destinationOfSymbolicLink(atPath: originalBackup.path) == oldTarget, "旧停用链接应保持原样")
        try check(skill("reinstalled").installations.contains { !$0.isActive && $0.content.path.hasSuffix("/library/current") },
                  "其他停用版本仍应可发现")

        try write("---\nname: collision\ndescription: Conflict test\n---\n", to: ".agents/skills/collision/SKILL.md")
        try write("unrelated", to: ".codex/skills/collision")
        do {
            try settings.apply(.availability(from: [.codex, .deepSeekHarness], to: [.codex]), to: "collision")
            throw TestFailure("预期遇到同名文件时停止保存")
        } catch AgentSkillSettings.ChangeError.conflict {
            try check(read(".codex/skills/collision") == "unrelated", "不能覆盖同名文件")
            try check(skill("collision").activeAgents == [.codex, .deepSeekHarness], "冲突时应保留共享安装")
        }

        print("Agent skill checks passed")
    }

    private struct TestFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw TestFailure(message) }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw TestFailure(message) }
        return value
    }
}
