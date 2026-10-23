import SwiftUI

// MARK: - 证据与分类

/// 某个文件“为什么属于这个应用”的证据强度。界面据此决定默认是否勾选。
enum Evidence: String, Sendable {
    case bundle    // 应用包本身
    case exact     // 标识符完全匹配（如容器名就是 Bundle ID）
    case team      // 同一开发者（Team ID 前缀）
    case name      // 只是名字相似
    case shared    // 其他应用也在用

    var label: String {
        switch self {
        case .bundle: String(localized: "应用本身")
        case .exact: String(localized: "确定是它的")
        case .team: String(localized: "同一家开发商")
        case .name: String(localized: "名字像，要你确认")
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
    /// 默认是否勾选：个人数据和共享组件默认不选
    let defaultOn: Bool
}

struct AppItem: Identifiable, Hashable, Sendable {
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
        var id: String { label }
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
    var root: String { location.components(separatedBy: " › ").first ?? location }
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
