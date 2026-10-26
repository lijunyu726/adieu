import Foundation

/// 文件页上显示的东西：还在原处的文件、筛选排序后的结果、分组、各维的个数、顶上的建议。
/// 一页上万个文件时算一遍要几百毫秒，而鼠标每指到一张新的缩略图页面就会重画一次，
/// 所以只在文件或条件变了时重算，平时重画直接用上次的（`Memo`）。
/// 上万条中文路径光算一遍哈希就要几十毫秒，按路径查的表、给快速查看的 URL 都等用到时再建
@MainActor final class FileListing {
    struct Section: Identifiable {
        let id: String
        var title = ""
        var note = ""
        var unit = "这一组"
        let items: [FileItem]
        var size: Double = 0
    }

    /// 决定结果的全部条件。文件列表没换时数组共用同一块存储，比较只看是不是同一块，不逐个比
    struct Input: Equatable {
        let section: AppSection
        let items: [FileItem]
        let removed: Set<String>
        let filter: FileFilter
        /// “只看已选”时的勾选；没开时为 nil，勾选变了不用重算
        let only: Set<String>?
    }

    let filter: FileFilter
    /// 还在原处的文件（删掉的不再显示），不含汇总行
    let files: [FileItem]
    let summaries: [FileItem]
    let shown: [FileItem]
    let sections: [Section]
    /// 显示顺序：连选、↑↓、全选都按它
    let order: [String]
    private(set) lazy var urls: [URL] = sections.flatMap(\.items).compactMap(\.path).map { URL(filePath: $0) }
    private(set) lazy var byKey: [String: FileItem] = Dictionary(files.map { (Self.key($0, in: section), $0) }, uniquingKeysWith: { a, _ in a })
    let section: AppSection
    let largest: Double
    let roots: [(String, Int)]
    let kinds: [(String, Int)]
    let ages: [(String, Int)]
    let suggestion: FileSuggestion?

    static func key(_ f: FileItem, in section: AppSection) -> String { f.path ?? "\(section.rawValue).\(f.id)" }

    init(_ input: Input) {
        let section = input.section
        let key = { Self.key($0, in: section) }
        self.section = section
        filter = input.filter
        files = input.removed.isEmpty ? input.items.filter { !$0.isSummary }
            : input.items.filter { !$0.isSummary && !input.removed.contains(key($0)) }
        summaries = input.items.filter(\.isSummary)
        shown = input.filter.apply(files).filter { input.only?.contains(key($0)) ?? true }
        sections = Self.sections(shown, section: section).map { s in
            var s = s
            s.size = s.items.map(\.size).reduce(0, +)
            return s
        }
        order = sections.flatMap { $0.items.map(key) }
        largest = files.map(\.size).max() ?? 1
        // 算个数不用排序
        roots = Self.facet(\.root, files: files, base: files.filter(input.filter.cleared(\.roots).matches()))
        kinds = Self.facet(\.kind, files: files, base: files.filter(input.filter.cleared(\.kinds).matches()))
        let base = files.filter(input.filter.cleared(\.ages).matches())
        var perAge: [FileFilter.Age: Int] = [:]
        for f in base { perAge[FileFilter.Age.of(f.date), default: 0] += 1 }
        ages = FileFilter.Age.allCases.map { ($0.rawValue, perAge[$0] ?? 0) }
            .filter { $0.1 > 0 || input.filter.ages.contains(FileFilter.Age(rawValue: $0.0)!) }
        suggestion = FileSuggestion.make(section, files: files)
    }

    /// 某一维的取值和个数。个数按“其他条件都不变、只换这一维”来算，点之前就知道会筛出几个
    private static func facet(_ path: KeyPath<FileItem, String>, files: [FileItem], base: [FileItem]) -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for f in files { counts[f[keyPath: path], default: 0] += 0 }
        for f in base { counts[f[keyPath: path], default: 0] += 1 }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
    }

    /// 安装包按“装好了 / 解压过 / 其他”，图片与视频按天，久未打开按多久没打开；大文件不分组，从大到小一列
    private static func sections(_ items: [FileItem], section: AppSection) -> [Section] {
        switch section {
        case .installers:
            let notes = [FileCategorizer.installedGroup: "以后要用可以重新下载",
                         FileCategorizer.unzippedGroup: "旁边有解压好的文件夹",
                         FileCategorizer.otherGroup: "没找到对应的应用，确认不要了再删"]
            return [FileCategorizer.installedGroup, FileCategorizer.unzippedGroup, FileCategorizer.otherGroup].compactMap { g in
                let list = items.filter { ($0.group ?? FileCategorizer.otherGroup) == g }
                return list.isEmpty ? nil : Section(id: g, title: g, note: notes[g] ?? "", items: list)
            }
        case .captures:
            // 同一天的日期先换成当天零点；一天里的文件挨在一起，只在换天时才问一次日历
            let calendar = Calendar.current
            var days: [Date?: [FileItem]] = [:]
            var start: Date?, end: Date?
            for f in items {
                guard let d = f.date else { days[nil, default: []].append(f); continue }
                if let s = start, let e = end, d >= s, d < e {
                    days[s]!.append(f)
                } else {
                    let s = calendar.startOfDay(for: d)
                    start = s
                    end = calendar.date(byAdding: .day, value: 1, to: s)
                    days[s, default: []].append(f)
                }
            }
            // 全都没有日期（示例数据）就不分天
            if days.count == 1, days.keys.first! == nil { return [Section(id: "all", items: items)] }
            return days.keys.sorted { ($0 ?? .distantPast) > ($1 ?? .distantPast) }.map { d in
                Section(id: d.map { "\($0.timeIntervalSince1970)" } ?? "unknown", title: dayTitle(d), unit: "这一天", items: days[d]!)
            }
        case .stale:
            let bands = ["两年多没打开", "一年多没打开", "半年多没打开", "其他"]
            func band(_ f: FileItem) -> String {
                guard let d = f.idleDays else { return "其他" }
                return d >= 730 ? bands[0] : d >= 365 ? bands[1] : bands[2]
            }
            let grouped = Dictionary(grouping: items, by: band)
            if grouped.count == 1 { return [Section(id: "all", items: items)] }
            return bands.compactMap { b in grouped[b].map { Section(id: b, title: b, items: $0) } }
        default:
            return items.isEmpty ? [] : [Section(id: "all", items: items)]
        }
    }

    private static func dayTitle(_ d: Date?) -> String {
        guard let d else { return "日期未知" }
        if Calendar.current.isDateInToday(d) { return "今天" }
        if Calendar.current.isDateInYesterday(d) { return "昨天" }
        return Calendar.current.isDate(d, equalTo: .now, toGranularity: .year)
            ? d.formatted(.dateTime.month().day().weekday(.wide)) : d.formatted(.dateTime.year().month().day().weekday(.wide))
    }

    /// 汇总行（“其余 21 个”）放进同组；没有组的放在最后一组
    func summaries(for s: Section) -> [FileItem] {
        guard !filter.isActive else { return [] }
        let ids = Set(sections.map(\.id))
        let last = s.id == sections.last?.id
        return summaries.filter { $0.group == s.id || (last && !ids.contains($0.group ?? "")) }
    }

    /// 上一次的结果；条件没变就直接拿来用。改它不需要刷新界面，所以是个引用类型
    @MainActor final class Memo {
        private var input: Input?
        private var value: FileListing?

        func get(_ input: Input) -> FileListing {
            if let value, input == self.input { return value }
            let v = FileListing(input)
            self.input = input
            value = v
            return v
        }
    }
}

/// 文件页面的筛选条件。同一维里多选是“或”，不同维之间是“且”
struct FileFilter: Equatable {
    var roots: Set<String> = []
    var kinds: Set<String> = []
    var ages: Set<Age> = []
    var query = ""
    var sort: Sort = .size

    enum Sort: String, CaseIterable { case size = "最大的在前", newest = "最新的在前", oldest = "最旧的在前", name = "按名称" }

    /// 按修改时间分段，互不重叠
    enum Age: String, CaseIterable {
        case today = "今天", week = "一周内", month = "一个月内", halfYear = "半年内", older = "半年以前", unknown = "不清楚"

        static func of(_ d: Date?) -> Age {
            guard let d else { return .unknown }
            if d.isToday { return .today }
            let days = FileCategorizer.days(since: d)
            return days <= 7 ? .week : days <= 31 ? .month : days <= 183 ? .halfYear : .older
        }
    }

    var isActive: Bool { !roots.isEmpty || !kinds.isEmpty || !ages.isEmpty || !query.isEmpty }

    mutating func clear() { roots = []; kinds = []; ages = []; query = "" }

    /// 去掉某一维的条件（算那一维的个数用）
    func cleared<T>(_ path: WritableKeyPath<FileFilter, Set<T>>) -> FileFilter {
        var f = self
        f[keyPath: path] = []
        return f
    }

    /// 只筛不排序
    func matches() -> (FileItem) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return { [roots, kinds, ages] f in
            (roots.isEmpty || roots.contains(f.root))
                && (kinds.isEmpty || kinds.contains(f.kind))
                && (ages.isEmpty || ages.contains(Age.of(f.date)))
                && (q.isEmpty || f.name.localizedStandardContains(q))
        }
    }

    func apply(_ items: [FileItem]) -> [FileItem] {
        let hit = items.filter(matches())
        switch sort {
        case .size: return hit.sorted { $0.size > $1.size }
        case .newest: return hit.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        case .oldest: return hit.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        case .name: return hit.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
}
