import Foundation
import Observation

/// 项目选择与上次结果独立于页面生命周期。扫描逐个写回，后台刷新不清空列表。
@Observable
@MainActor
final class WorktreeCatalog {
    private(set) var projects: [WorktreeProject]
    private(set) var refreshing: Set<String> = []
    private(set) var removing: Set<String> = []
    private(set) var adding = false
    private(set) var addError: String?
    private(set) var restoring = false
    private(set) var loaded: Set<String> = []
    var selectedID: String? {
        didSet { if !isSample { defaults.set(selectedID, forKey: "worktreeSelectedProject") } }
    }
    var showsWorktrees: Bool {
        didSet { if !isSample { defaults.set(showsWorktrees, forKey: "devSpaceShowsWorktrees") } }
    }
    var selectedProject: WorktreeProject? { projects.first { $0.id == selectedID } ?? projects.first }
    var isRefreshing: Bool { restoring || !refreshing.isEmpty }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private let language: String
    @ObservationIgnored private let isSample: Bool
    @ObservationIgnored private let scan: @Sendable (String) -> WorktreeProject
    @ObservationIgnored private var paths: [String]
    @ObservationIgnored private var updatedAt: [String: Date] = [:]
    @ObservationIgnored private var attemptedAt: [String: Date] = [:]
    @ObservationIgnored private var revisions: [String: Int] = [:]
    @ObservationIgnored private var refreshTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var restoreTask: Task<WorktreeSnapshot?, Never>?
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var pendingRemovals: [String: (item: WorktreeItem, index: Int)] = [:]

    init(defaults: UserDefaults = .standard, sample: [WorktreeProject]? = nil,
         cacheURL: URL = WorktreeCacheStore.file,
         scan: @escaping @Sendable (String) -> WorktreeProject = { WorktreeScanner.scan($0) }) {
        self.defaults = defaults
        self.cacheURL = cacheURL
        self.scan = scan
        isSample = sample != nil
        language = (defaults.stringArray(forKey: "AppleLanguages") ?? Locale.preferredLanguages).joined(separator: "|")
        paths = sample?.map(\.path) ?? defaults.stringArray(forKey: "worktreeProjects") ?? []
        projects = sample ?? paths.map { WorktreeProject(path: $0, items: []) }
        if let sample { loaded = Set(sample.map(\.path)) }
        let saved = defaults.string(forKey: "worktreeSelectedProject")
        let initialPaths = paths
        selectedID = saved.flatMap { initialPaths.contains($0) ? $0 : nil } ?? initialPaths.first
        showsWorktrees = defaults.object(forKey: "AdieuWorktrees") != nil
            ? defaults.bool(forKey: "AdieuWorktrees") : defaults.bool(forKey: "devSpaceShowsWorktrees")
    }

    /// 五分钟内切回页面直接使用结果；过期时保留旧内容，后台更新。
    func load(force: Bool = false) async {
        guard !isSample else { return }
        await restore()
        let ordered = paths.sorted { $0 == selectedID && $1 != selectedID }
        for path in ordered { await refresh(path, force: force) }
    }

    private func restore() async {
        guard !restored else { return }
        restoring = true
        let task: Task<WorktreeSnapshot?, Never>
        if let existing = restoreTask { task = existing }
        else {
            let file = cacheURL
            task = Task { await blocking { WorktreeCacheStore.load(from: file) } }
            restoreTask = task
        }
        let snapshot = await task.value
        guard !restored else { return }
        restored = true
        restoring = false
        restoreTask = nil
        guard let snapshot, snapshot.language == language else { return }
        for cached in snapshot.projects where paths.contains(cached.path) && !loaded.contains(cached.path) {
            if let i = projects.firstIndex(where: { $0.path == cached.path }) {
                projects[i] = cached
                loaded.insert(cached.path)
                updatedAt[cached.path] = snapshot.updatedAt[cached.path]
            }
        }
    }

    /// 同一个项目只扫描一次；删除或移出列表会使已经在途的扫描结果失效。
    func refresh(_ path: String, force: Bool = false) async {
        guard !isSample, paths.contains(path), !pendingRemovals.values.contains(where: { $0.item.projectPath == path }) else { return }
        if let existing = refreshTasks[path] {
            await existing.value
            if force && updatedAt[path] == nil { await refresh(path, force: true) }
            return
        }
        if !force {
            if let date = updatedAt[path], Date().timeIntervalSince(date) < 300 { return }
            if let date = attemptedAt[path], Date().timeIntervalSince(date) < 30 { return }
        }
        let revision = revisions[path, default: 0]
        refreshing.insert(path)
        let scan = scan
        let task = Task { [weak self] in
            let result = await blocking { scan(path) }
            guard let self else { return }
            defer {
                self.refreshing.remove(path)
                self.refreshTasks[path] = nil
            }
            guard self.paths.contains(path), self.revisions[path, default: 0] == revision,
                  let i = self.projects.firstIndex(where: { $0.path == path }) else { return }
            self.attemptedAt[path] = .now
            if result.error == nil {
                self.projects[i] = result
                self.updatedAt[path] = .now
            } else {
                // 磁盘暂时断开、权限或 Git 出错时保留上次结果，并显示实际错误。
                self.projects[i].error = result.error
                self.updatedAt[path] = nil
            }
            self.loaded.insert(path)
            self.persistCache()
        }
        refreshTasks[path] = task
        await task.value
    }

    func add(_ path: String) async -> String? {
        guard !isSample, !adding else { return nil }
        adding = true
        addError = nil
        defer { adding = false }
        await restore()
        let scan = scan
        let result = await blocking { scan(path) }
        guard result.error == nil else { addError = result.error; return nil }
        revisions[result.path, default: 0] += 1
        if let i = projects.firstIndex(where: { $0.path == result.path }) { projects[i] = result }
        else { paths.append(result.path); projects.append(result) }
        loaded.insert(result.path)
        updatedAt[result.path] = .now
        attemptedAt[result.path] = .now
        selectedID = result.id
        defaults.set(paths, forKey: "worktreeProjects")
        persistCache()
        return result.id
    }

    func forget(_ path: String) {
        guard removing.isEmpty else { return }
        revisions[path, default: 0] += 1
        paths.removeAll { $0 == path }
        projects.removeAll { $0.path == path }
        loaded.remove(path)
        updatedAt[path] = nil
        attemptedAt[path] = nil
        if selectedID == path { selectedID = paths.first }
        if !isSample { defaults.set(paths, forKey: "worktreeProjects") }
        persistCache()
    }

    /// 确认后立即隐藏这一行；失败时按原位置放回。不会乐观地修改 Git 状态。
    func beginRemoval(_ item: WorktreeItem, mode: WorktreeRemovalMode = .safe) -> Bool {
        guard removing.isEmpty, item.removalMode == mode,
              let p = projects.firstIndex(where: { $0.path == item.projectPath }),
              let i = projects[p].items.firstIndex(where: { $0.id == item.id }) else { return false }
        let current = projects[p].items[i]
        guard current.removalMode == mode, current.head == item.head, current.branch == item.branch,
              current.isLocked == item.isLocked, current.blocked == item.blocked else { return false }
        revisions[item.projectPath, default: 0] += 1
        pendingRemovals[item.id] = (projects[p].items[i], i)
        removing.insert(item.id)
        projects[p].items.remove(at: i)
        return true
    }

    func finishRemoval(_ item: WorktreeItem, succeeded: Bool) {
        guard let pending = pendingRemovals.removeValue(forKey: item.id) else { return }
        if !succeeded, let p = projects.firstIndex(where: { $0.path == item.projectPath }),
           !projects[p].items.contains(where: { $0.id == item.id }) {
            projects[p].items.insert(pending.item, at: min(pending.index, projects[p].items.count))
        }
        removing.remove(item.id)
        updatedAt[item.projectPath] = nil
        attemptedAt[item.projectPath] = nil
        persistCache()
    }

    private func persistCache() {
        guard !isSample, removing.isEmpty else { return }
        WorktreeCacheStore.saveLater(.init(language: language, projects: projects.filter { loaded.contains($0.path) }, updatedAt: updatedAt), to: cacheURL)
    }
}
