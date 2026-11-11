import SwiftUI

// MARK: - 证据与分类

/// 某个文件“为什么属于这个应用”的证据强度。界面据此决定默认是否勾选。
enum Evidence: String, Sendable {
    case bundle    // 应用包本身
    case exact     // 标识符完全匹配（如容器名就是 Bundle ID）
    case team      // 同一开发者（Team ID 前缀）
    case name      // 文件夹名和应用包里写的名字相同
    case shared    // 其他应用也在用

    var label: String {
        switch self {
        case .bundle: String(localized: "应用本身")
        case .exact: String(localized: "确定是它的")
        case .team: String(localized: "同一家开发商")
        case .name: String(localized: "按名字找到")
        case .shared: String(localized: "别的应用也在用")
        }
    }

    var tint: Color {
        switch self {
        case .exact: .green
        case .team: .blue
        case .name: .orange
        case .bundle, .shared: .secondary
        }
    }
}

enum PartKind: String, Sendable, CaseIterable {
    case app, data, background, shared

    var label: String {
        switch self {
        case .app: String(localized: "应用本体")
        case .data: String(localized: "应用数据")
        case .background: String(localized: "后台项目")
        case .shared: String(localized: "共享组件")
        }
    }

    var color: Color {
        switch self {
        case .app: .accentColor
        case .data: .purple
        case .background: .orange
        case .shared: .gray
        }
    }
}

// MARK: - 应用

struct AppPart: Identifiable, Hashable, Sendable {
    let id: String
    let kind: PartKind
    let label: String
    let path: String
    /// 单位 GB；nil 表示未统计（如很小的 plist）
    let size: Double?
    let evidence: Evidence
    /// 独占的应用数据默认全选；其他应用也在用的默认不选
    let defaultOn: Bool
    /// 扫描得到的主程序及声明共享组的组件标识符。
    var ownerIDs: Set<String> = []
}

extension AppPart {
    /// 种类取自扫描时的 id 前缀（container、support、group…），按名字找到的也一样
    private var locationKind: String { String(id.split(separator: ".").first ?? "") }

    /// 可能装着聊天记录、文档、账号的那几类，删了找不回来
    var isPersonalData: Bool { kind != .app && ["container", "support", "group"].contains(locationKind) }

    /// 列表里名字下面的一句说明，告诉用户这一项是什么
    var hint: String? {
        guard kind != .app else { return nil }
        switch locationKind {
        case "container", "support", "group": return String(localized: "个人数据，可能有聊天记录、文档和账号")
        case "caches", "http", "webkit": return String(localized: "缓存，删了会自动重新生成")
        case "prefs": return String(localized: "应用的设置项")
        case "logs": return String(localized: "运行日志")
        case "state": return String(localized: "窗口位置等，删了不影响使用")
        case "scripts": return String(localized: "扩展用的脚本目录，一般是空的")
        default: return nil
        }
    }
}

struct AppItem: Identifiable, Hashable, Sendable {
    /// 列表里的唯一键：真实扫描的是应用包路径（同一个应用装两份时 Bundle ID 相同，如 QQ 和 QQ 2）；示例数据就是标识符
    let id: String
    let name: String
    let monogram: String
    let color: Color
    let meta: String
    var isRunning = false
    var notice: String?
    var parts: [AppPart]
    /// 真实扫描到的应用包路径；示例数据为 nil，用字母图标代替应用图标
    var path: String? = nil
    /// 各部分大小是否已经统计完
    var isMeasured = true
    /// Bundle ID；示例数据为 nil，用 id 代替
    var bundle: String? = nil

    var bundleID: String { bundle ?? id }

    var total: Double { parts.compactMap(\.size).reduce(0, +) }
    var appSize: Double { parts.filter { $0.kind == .app }.compactMap(\.size).reduce(0, +) }
    var dataSize: Double { total - appSize }
}

// MARK: - 空间分布

struct SpaceCategory: Identifiable, Hashable, Sendable {
    struct Part: Identifiable, Hashable, Sendable {
        let label: String
        let size: Double?
        var note: String = ""
        /// 这一项旁边的小按钮，如“清掉 262 份”
        var action: PartAction? = nil
        var id: String { label }
    }
    enum PartAction: Hashable, Sendable {
        case cleanClones(count: Int)

        var title: String {
            switch self {
            case .cleanClones(let n): String(localized: "删掉没在用的 \(n) 份")
            }
        }
    }
    let id: String
    let label: String
    var size: Double
    let color: Color
    let hint: String
    var parts: [Part] = []
    /// 展开后“去处理”按钮跳到的页面
    var link: AppSection? = nil
}

// MARK: - 清理建议

enum Safety: Sendable {
    case safe      // 可再生、可重新下载
    case review    // 可能有价值，需要人看

    var label: String { self == .safe ? String(localized: "稳妥") : String(localized: "看一眼") }
    var color: Color { self == .safe ? .green : .orange }
}

/// 计划里的一项怎么执行
enum GoalAction: Hashable, Sendable {
    case trash(paths: [String])
    case dev(toolID: String)
    case none
}

struct CleanupItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let detail: String
    let size: Double
    let safety: Safety
    var action: GoalAction = .none
}

struct FileItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let ext: String
    let kind: String
    let location: String
    let modified: String
    let size: Double
    let reason: String
    /// 汇总行（如“其余 21 个”）：没有单个文件可显示，也不参与逐个看
    var isSummary = false
    /// 真实文件的完整路径；示例数据为 nil
    var path: String? = nil
    /// 修改时间；示例数据为 nil。modified 有时是状态说明（“微信已安装”），筛选和精确时间用这个
    var date: Date? = nil
    /// 安装包页的分组（应用已经装好了 / 已经解压过 / 其他）
    var group: String? = nil
    /// 多少天没打开过；示例数据为 nil
    var idleDays: Int? = nil

    /// 所在的顶层文件夹（下载、文稿…），筛选“位置”用
    var root: String { location.range(of: " › ").map { String(location[..<$0.lowerBound]) } ?? location }
    /// 精确到秒的修改时间；没有时用 modified
    var timeText: String { date.map(\.fullText) ?? modified }
}

extension Date {
    /// 2026年10月16日 14:03:27
    var fullText: String { formatted(.dateTime.year().month().day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)) }
    var isToday: Bool { Calendar.current.isDateInToday(self) }
}

/// “文件”分组下的一类：安装包与压缩包、截图与录屏、大文件、久未打开
struct FileCategory: Identifiable, Sendable {
    struct Stat: Hashable, Sendable {
        let label: String
        let value: String
        var highlight = false
    }
    let id: AppSection
    let subtitle: String
    let stats: [Stat]
    let items: [FileItem]
    /// 可以切到“逐个看”
    let reviewable: Bool
    /// 页面底部可以直接开关的自动规则（对应 Sample.rules 的 id）
    let ruleID: String?
}

// MARK: - 后台项目、残留、开发工具、规则、记录

struct LaunchItem: Identifiable, Hashable, Sendable {
    let owner: String
    let label: String
    /// plist 的位置；示例数据为 nil
    var plist: String? = nil
    /// 在 ~/Library/LaunchAgents 里，不用管理员密码就能移除
    var isUser = false
    var loaded = false
    var id: String { plist ?? label }
}

struct LaunchGroup: Identifiable, Sendable {
    let id: String
    let title: String
    let note: String
    let color: Color
    let action: String
    var items: [LaunchItem]
}

struct LeftoverItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let evidence: String
    let size: Double?
    let defaultOn: Bool
    /// 要一起移走的所有位置；示例数据为空
    var paths: [String] = []
}

struct LeftoverGroup: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    var items: [LeftoverItem]
}

/// 开发工具的一步清理：调用工具自己的命令，或直接删除缓存目录
enum DevAction: Hashable, Sendable {
    case command(executable: String, args: [String])
    case trash(paths: [String])

    var display: String {
        switch self {
        case .command(let exe, let args): ([(exe as NSString).lastPathComponent] + args).joined(separator: " ")
        case .trash(let paths):
            "删除 " + paths.map { p in
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
            }.joined(separator: " ")
        }
    }
}

struct DevTool: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let location: String
    let note: String
    let parts: [DevPart]
    let commands: [String]
    let never: String?
    /// 真实可执行的步骤；示例数据为空，只展示 commands
    var actions: [DevAction] = []
    /// 暂时不能清理的原因（如 Docker 没有运行）
    var blocked: String? = nil

    var total: Double { parts.map(\.size).reduce(0, +) }
    var reclaimable: Double { parts.map(\.reclaimable).reduce(0, +) }
}

struct DevPart: Hashable, Sendable {
    let label: String
    let size: Double
    let reclaimable: Double
}

struct RuleItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let symbol: String
    let color: Color
    /// 规则句子：普通文字与“词块”交替
    let sentence: [RuleToken]
    let automatic: Bool
    let status: String
}

enum RuleToken: Hashable, Sendable {
    case text(String)
    case condition(String)
    case action(String)
}

// MARK: - Git worktree

struct WorktreeProject: Identifiable, Codable, Sendable {
    var id: String { path }
    let path: String
    var items: [WorktreeItem]
    var error: String? = nil
}

enum WorktreeRemovalMode: String, Codable, Sendable {
    case safe, force

    var title: String {
        switch self {
        case .safe: String(localized: "安全移除")
        case .force: String(localized: "强制移除")
        }
    }
}

struct WorktreeItem: Identifiable, Codable, Hashable, Sendable {
    var id: String { path }
    let projectPath: String
    let path: String
    let branch: String?
    let head: String
    let size: Double?
    let blocked: String?
    let hasIgnoredFiles: Bool
    var allowsForceRemoval = false
    var isLocked = false
    var removalMode: WorktreeRemovalMode? { blocked == nil ? .safe : (allowsForceRemoval ? .force : nil) }
    /// 归属由 Git 登记确认；不默认选中，始终逐项确认。
    var evidence: Evidence { .exact }
    var command: String {
        func quote(_ s: String) -> String { "'" + s.replacing("'", with: "'\\''") + "'" }
        let flags = removalArguments(mode: removalMode ?? .safe).dropLast().joined(separator: " ")
        return "git -C " + quote(projectPath) + " " + flags + " " + quote(path)
    }

    func removalArguments(mode: WorktreeRemovalMode) -> [String] {
        let force = mode == .force ? Array(repeating: "--force", count: isLocked ? 2 : 1) : []
        return ["worktree", "remove"] + force + ["--", path]
    }
}

struct WorktreeSnapshot: Codable, Sendable {
    var version = 2
    let language: String
    let projects: [WorktreeProject]
    let updatedAt: [String: Date]
}

// MARK: - Agent 技能

enum SkillAgent: String, CaseIterable, Identifiable, Sendable {
    case codex, claudeCode, deepSeekHarness

    var id: Self { self }
    var title: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .deepSeekHarness: "DeepSeek Harness"
        }
    }

    func invocation(_ name: String) -> String { (self == .codex ? "$" : "/") + name }
}

enum SkillInvocation: Hashable, Sendable {
    case automatic, explicit, unavailable

    var title: String {
        switch self {
        case .automatic: String(localized: "允许自动调用")
        case .explicit: String(localized: "仅点名调用")
        case .unavailable: String(localized: "调用方式未知")
        }
    }
}

struct AgentSkill: Identifiable, Sendable {
    struct Installation: Sendable {
        let entry: URL
        let activePath: URL
        let content: URL
        let instruction: URL
        let agents: Set<SkillAgent>
        let isActive: Bool
        let isBundle: Bool
        let declaredName: String?
        let invocation: [SkillAgent: SkillInvocation]

        func commandName(for agent: SkillAgent, folderName: String) -> String {
            agent == .claudeCode ? folderName : (declaredName ?? folderName)
        }
    }

    let id: String
    let installations: [Installation]
    var activeAgents: Set<SkillAgent> {
        installations.filter(\.isActive).reduce(into: []) { $0.formUnion($1.agents) }
    }
    var installedAgents: Set<SkillAgent> {
        installations.reduce(into: []) { $0.formUnion($1.agents) }
    }

    func activeInstallations(for agent: SkillAgent) -> [Installation] {
        installations.filter { $0.isActive && $0.agents.contains(agent) }
    }

    func mode(for agent: SkillAgent) -> SkillInvocation {
        let modes = Set(activeInstallations(for: agent).map { $0.invocation[agent] ?? .unavailable })
        return modes.count == 1 ? modes.first ?? .unavailable : .unavailable
    }
}
