import Foundation

/// 首页右侧的建议：从扫描结果里挑最值得做的几件事。
/// 文件类的和各页顶上的建议卡是同一套规则（FileSuggestion），点过去会替人勾好
struct Suggestion: Identifiable {
    let title: String
    let size: Double?
    let detail: String
    let target: AppSection
    /// 跳过去时顺手勾上这页的建议
    var picks = false
    /// 用来去重：同一个文件可能同时在“安装包”“大文件”“久未打开”里
    var files: Set<String> = []
    /// 菜单栏面板按它决定能不能当场处理
    enum Kind: Equatable { case dev(String), files, leftovers, clones }
    var kind: Kind = .files
    /// 当场删除时要删的文件和大小（安装包这类）
    var sizes: [String: Double] = [:]
    var id: String { title }

    @MainActor
    static func make(_ model: AppModel) -> [Suggestion] {
        var list: [Suggestion] = []
        if let dev = model.devTools.filter({ $0.reclaimable > 0.1 }).max(by: { $0.reclaimable < $1.reclaimable }) {
            list.append(.init(title: String(localized: "\(dev.name) 里有可以回收的缓存"), size: dev.reclaimable, detail: dev.note, target: .devTools, kind: .dev(dev.id)))
        }
        // 图片与视频不给建议（见 FileSuggestion），不用把上万个文件过一遍
        for id in [AppSection.installers, .bigFiles, .stale] {
            guard let c = model.category(id) else { continue }
            // 和文件页一样：不算汇总行，也不算刚删掉的
            let files = c.items.filter { !$0.isSummary && !model.removedKeys.contains($0.path ?? "\(id.rawValue).\($0.id)") }
            guard let s = FileSuggestion.make(id, files: files) else { continue }
            list.append(.init(title: s.title, size: s.size, detail: s.detail, target: id, picks: true,
                              files: Set(s.items.map { $0.path ?? $0.name }),
                              sizes: Dictionary(s.items.compactMap { f in f.path.map { ($0, f.size) } }, uniquingKeysWith: { a, _ in a })))
        }
        let left = model.leftovers.flatMap(\.items).filter(\.defaultOn)
        if !left.isEmpty {
            list.append(.init(title: String(localized: "\(left.count) 项应用残留"), size: left.compactMap(\.size).reduce(0, +), detail: String(localized: "对应的应用已经删掉了，数据还在。"), target: .leftovers, kind: .leftovers))
        }
        // 大的先上；和已经列出的有同一个文件的跳过，免得一批文件算两遍
        var picked: [Suggestion] = []
        var seen: Set<String> = []
        for s in list.sorted(by: { ($0.size ?? 0) > ($1.size ?? 0) }) where s.files.isDisjoint(with: seen) {
            picked.append(s)
            seen.formUnion(s.files)
            if picked.count == 3 { break }
        }
        // 签名副本藏在“macOS 系统与其他”的细分里没人会点开，有能删的就单独出一张，不占上面三张的名额
        if let c = model.space?.clones, c.removable.count >= 10 {
            let name = c.apps.count == 1 ? c.apps[0].replacing("Google ", with: "") : String(localized: "应用")
            let real = c.removableSizes.values.reduce(0, +)
            picked.append(.init(title: String(localized: "\(name) 留下了 \(c.removable.count) 份启动副本"), size: real >= 0.1 ? real : nil,
                                detail: String(localized: "\(name) 被强制退出时没来得及删的副本，现在没在用，删掉不影响 \(name)。"),
                                target: .home, kind: .clones))
        }
        return picked
    }
}

