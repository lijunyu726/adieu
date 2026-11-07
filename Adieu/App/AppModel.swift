import SwiftUI
import WidgetKit

/// 全局状态：导航、扫描结果、删除与操作记录
@Observable
@MainActor
final class AppModel {
    /// 启动参数 `-AdieuSection apps` 可直接打开某页（调试与截图用）
    var section: AppSection = AppSection(rawValue: UserDefaults.standard.string(forKey: "AdieuSection") ?? "") ?? .home
    /// 首页“今日建议”点了“去勾选”：跳到的那一页打开时替人勾上它的建议
    var pickOnOpen: AppSection?
    /// 当前弹出的面板；启动参数 `-AdieuSheet goal` 可直接打开（截图用）
    var sheet: AppSheet? = AppSheet(rawValue: UserDefaults.standard.string(forKey: "AdieuSheet") ?? "")
    /// 已开启的自动规则（Sample.rules 的 id）。设置里和各页面底部共用这一份
    var enabledRules: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "enabledRules") ?? ["pkg", "low"]) {
        didSet { UserDefaults.standard.set(Array(enabledRules), forKey: "enabledRules") }
    }
    var showOnboarding = !UserDefaults.standard.bool(forKey: "didOnboard")

    /// 启动参数 `-AdieuSample YES` 全部改用示例数据（演示与截图用，数字稳定，不会动任何文件）
    let useSample = UserDefaults.standard.bool(forKey: "AdieuSample")
    var disk: DiskInfo
    var apps: [AppItem] = []
    var appsLoading = false
    let appData = AppDataBrowser()
    @ObservationIgnored private let runningAppNames: () -> [String: String]

    // MARK: 删除与记录

    /// 一次待执行的删除
    struct TrashRequest: Identifiable {
        let id = UUID()
        let title: String
        let source: String
        let urls: [URL]
        /// 已知大小（GB），按路径；没有的现算
        var sizes: [String: Double] = [:]
        /// 界面上对应的行：删掉后不再显示
        var keys: [String] = []
        /// 应用内部的精细清理：确认后、管理员删除前仍要重新核对目录边界。
        var dataRoot: String? = nil
        var dataTarget: AppDataTarget? = nil
        var worktree: WorktreeItem? = nil
        var worktreeMode: WorktreeRemovalMode = .safe
        var onDone: (@MainActor (HistoryEntry?) -> Void)? = nil
    }

    var history: [HistoryEntry]
    var protectedPaths: [String] = UserDefaults.standard.stringArray(forKey: "protectedPaths") ?? TrashService.defaultProtected {
        didSet { UserDefaults.standard.set(protectedPaths, forKey: "protectedPaths") }
    }
    /// 等待用户确认的删除
    var pendingTrash: TrashRequest?
    /// 需要告诉用户的结果（部分失败、恢复失败等）
    var notice: String?
    /// 已经删掉的行（界面 key，文件就是路径）。变了就重算文件分类，汇总数字和侧边栏跟着变
    var removedKeys: Set<String> = [] { didSet { rebuildFileCategories() } }

    let worktrees: WorktreeCatalog

    init(runningAppNames: (() -> [String: String])? = nil) {
        self.runningAppNames = runningAppNames ?? (useSample ? { [:] } : {
            NSWorkspace.shared.runningApplications.reduce(into: [:]) { names, app in
                if let id = app.bundleIdentifier { names[id] = app.localizedName ?? id }
            }
        })
        worktrees = WorktreeCatalog(sample: useSample ? Sample.worktreeProjects : nil)
        disk = useSample ? .sample : (DiskInfo.current() ?? .sample)
        history = useSample ? Sample.history : HistoryStore.load()
    }

    func refreshDisk() {
        if !useSample, let d = DiskInfo.current() { disk = d }
    }

    /// 不管设置怎样都先确认：键盘快捷键和“逐个看”里攒下来的一批，都不能一按就删掉
    func confirmTrash(_ request: TrashRequest) {
        pendingTrash = request
    }

    /// 设置里开了“删除前总是再确认一次”就先弹确认，否则直接执行
    func requestTrash(_ request: TrashRequest) {
        if UserDefaults.standard.object(forKey: "confirmAlways") as? Bool ?? true {
            pendingTrash = request
        } else {
            perform(request)
        }
    }

    /// 直接删除（不进废纸篓）并记一笔。示例模式只做界面演示，不碰文件。
    /// 删除在后台线程做（删大文件夹前要先走一遍算大小，要好几秒），删完才调用 onDone；
    /// 有权限不够的（如 App Store 装的应用）会接着弹系统密码窗口
    func perform(_ request: TrashRequest) {
        pendingTrash = nil
        if let target = request.dataTarget, !canCleanAppData(target) { return }
        if request.dataRoot != nil { appData.deleting = true }
        Task {
            let before = freeNow()
            let (entry, admin) = await firstPass(request)
            var result = entry
            if !admin.isEmpty { result = await adminPass(request, admin, entry) }
            if result != nil { DeleteSound.play() }
            if request.dataRoot != nil { appData.deleting = false }
            request.onDone?(result)
            await verify(result, freeBefore: before)
        }
    }

    // MARK: 删后核对

    /// 删完告诉用户实际腾出多少：删除前后各读一次磁盘可用空间
    struct FreedReport: Identifiable {
        let id: UUID
        let title: String
        let expected: Double
        let actual: Double
        let reasons: [String]
        var short: Bool { !reasons.isEmpty }
    }
    var freedReport: FreedReport?

    private func freeNow() -> Double {
        refreshDisk()
        return disk.free
    }

    /// APFS 释放空间有一点延迟，等两秒再读。同时在删别的东西时数字会混在一起，所以只说“约”
    private func verify(_ entry: HistoryEntry?, freeBefore: Double) async {
        guard let entry, !useSample else { return }
        try? await Task.sleep(for: .seconds(2))
        let actual = max(0, freeNow() - freeBefore)
        let expected = entry.total
        // 差得不多不算：可用空间本来就会随系统活动上下浮动几十 MB
        let reasons = expected - actual > 0.1 && actual < expected * 0.8 ? await blocking { Self.shortfallReasons() } : []
        if let i = history.firstIndex(where: { $0.id == entry.id }) {
            history[i].actualFreed = actual
            history[i].shortfall = reasons.isEmpty ? nil : reasons
            HistoryStore.saveLater(history)
        }
        freedReport = FreedReport(id: entry.id, title: entry.title, expected: expected, actual: actual, reasons: reasons)
        feedWidget()
    }

    /// 把空间分布和建议写给桌面组件，再让组件重画
    func feedWidget() {
        guard !useSample, space != nil else { return }
        let categories = spaceCategories.filter { !["free", "pending"].contains($0.id) }.map { c in
            let ns = NSColor(c.color).usingColorSpace(.sRGB)
            return WidgetFeed.Category(label: Copy.text(c.label), size: c.size,
                                       rgb: [ns?.redComponent ?? 0.5, ns?.greenComponent ?? 0.5, ns?.blueComponent ?? 0.5].map(Double.init))
        }
        let list = Suggestion.make(self)
        WidgetFeed(date: .now, categories: categories, reclaimable: list.compactMap(\.size).reduce(0, +),
                   items: list.map { .init(title: Copy.text($0.title), size: $0.size) },
                   weekChange: DiaryStore.week(self)?.change).save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// 腾出比预计少的常见原因，能查到的先说
    nonisolated static func shortfallReasons() -> [String] {
        var reasons: [String] = []
        let snapshots = (SpaceScanner.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]) ?? "")
            .split(separator: "\n").filter { $0.contains("com.apple") }.count
        if snapshots > 0 {
            reasons.append(String(localized: "有 \(snapshots) 个本地快照还保留着这些文件，要等快照到期（一般一天内）或空间紧张时系统删掉快照，空间才回来。"))
        }
        reasons.append(String(localized: "有些文件和别的文件共用存储（APFS 克隆，比如复制出来的副本），删掉其中一份腾不出空间。"))
        reasons.append(String(localized: "还开着的程序正在用的文件，要等程序退出后空间才会回来。"))
        return reasons
    }

    /// 正在删的路径：一大批要删好几秒，这期间再点一次删除，同一个文件不会再删一遍
    @ObservationIgnored private var deleting: Set<String> = []

    /// 在后台线程删，正在删的跳过
    private func delete(_ urls: [URL], sizes: [String: Double] = [:], dataRoot: String? = nil,
                        worktree: WorktreeItem? = nil, worktreeMode: WorktreeRemovalMode = .safe) async -> TrashService.Outcome {
        let urls = urls.filter { !deleting.contains($0.path) }
        let paths = urls.map(\.path)
        deleting.formUnion(paths)
        defer { deleting.subtract(paths) }
        let protected = protectedPaths
        return await blocking {
            TrashService.delete(urls, sizes: sizes, protected: protected, dataRoot: dataRoot,
                                worktree: worktree, worktreeMode: worktreeMode)
        }
    }

    /// 卸载应用：直接删除，不进废纸篓。权限不够的弹一次系统密码窗口，全部删完才返回
    func deleteForUninstall(_ request: TrashRequest) async -> HistoryEntry? {
        pendingTrash = nil
        if useSample { return nil }
        let before = freeNow()
        let first = await delete(request.urls, sizes: request.sizes)
        var entry = record(request, files: first.done, into: nil)
        report(first.failed)
        if !first.needsAdmin.isEmpty {
            let urls = first.needsAdmin, sizes = request.sizes, protected = protectedPaths
            let second = await blocking { TrashService.deleteAsAdmin(urls, sizes: sizes, protected: protected) }
            entry = record(request, files: second.done, into: entry?.id) ?? entry
            report(second.failed)
        }
        if entry != nil { DeleteSound.play() }
        request.onDone?(entry)
        Task { await verify(entry, freeBefore: before) }
        return entry
    }

    private func firstPass(_ request: TrashRequest) async -> (HistoryEntry?, [URL]) {
        if useSample {
            removedKeys.formUnion(request.keys)
            return (nil, [])
        }
        let result = await delete(request.urls, sizes: request.sizes, dataRoot: request.dataRoot,
                                  worktree: request.worktree, worktreeMode: request.worktreeMode)
        let entry = record(request, files: result.done, into: nil)
        report(result.failed)
        return (entry, result.needsAdmin)
    }

    private func adminPass(_ request: TrashRequest, _ urls: [URL], _ entry: HistoryEntry?) async -> HistoryEntry? {
        if let target = request.dataTarget, !canCleanAppData(target) { return entry }
        let sizes = request.sizes
        let protected = protectedPaths
        let root = request.dataRoot
        let result = await blocking { TrashService.deleteAsAdmin(urls, sizes: sizes, protected: protected, dataRoot: root) }
        let merged = record(request, files: result.done, into: entry?.id)
        report(result.failed)
        return merged ?? entry
    }

    /// 把删掉的文件记进“最近”：into 不为空时并进同一条记录
    private func record(_ request: TrashRequest, files: [TrashedFile], into id: UUID?) -> HistoryEntry? {
        guard !files.isEmpty else { return nil }
        let e: HistoryEntry
        if let id, let i = history.firstIndex(where: { $0.id == id }) {
            history[i].files += files
            e = history[i]
        } else {
            var new = HistoryEntry(date: .now, title: request.title, source: request.source, files: files)
            new.deleted = true
            e = new
            history.insert(e, at: 0)
        }
        HistoryStore.saveLater(history)
        removedKeys.formUnion(files.map(\.originalPath))
        refreshDisk()
        return e
    }

    private func report(_ failed: [(name: String, reason: String)]) {
        guard !failed.isEmpty else { return }
        notice = (notice.map { $0 + "\n" } ?? "") + String(localized: "有 \(failed.count) 项没有移走：") + "\n" + failed.prefix(6).map { "· \($0.name)：\($0.reason)" }.joined(separator: "\n")
    }

    /// 以前的版本清理时先进废纸篓：这些记录里还在废纸篓的文件可以放回原处
    func restore(_ entryID: UUID) {
        if useSample {
            if let i = history.firstIndex(where: { $0.id == entryID }) { history[i].restored = true }
            return
        }
        guard let i = history.firstIndex(where: { $0.id == entryID }) else { return }
        var errors: [String] = []
        for f in history[i].files where f.isInTrash {
            do { try TrashService.restore(f) } catch { errors.append(error.localizedDescription) }
        }
        history[i].restored = errors.isEmpty
        HistoryStore.saveLater(history)
        refreshDisk()
        if !errors.isEmpty { notice = errors.joined(separator: "\n") }
    }

    // MARK: 应用

    func openAppData(_ app: AppItem, part: AppPart) {
        guard [.data, .shared].contains(part.kind), app.parts.contains(part) else { return }
        appData.open(.init(appID: app.id, appName: app.name, part: part), sample: useSample)
    }

    func cleanAppDataSelection() {
        guard let target = appData.target, !appData.deleting, !appData.loading else { return }
        let items = appData.chosen
        guard !items.isEmpty else { return }
        guard canCleanAppData(target) else { return }
        var sizes: [String: Double] = [:]
        for item in items { if let size = item.size { sizes[item.path] = size } }
        confirmTrash(.init(title: String(localized: "清理 \(target.appName) 的数据"), source: "已安装",
                           urls: items.map { URL(filePath: $0.path) }, sizes: sizes,
                           dataRoot: target.root, dataTarget: target, onDone: { [weak self] entry in
            guard let self else { return }
            let removed = self.useSample ? items.map(\.path) : entry?.files.map(\.originalPath) ?? []
            if self.appData.target?.id == target.id {
                if removed.contains(target.root) { self.appData.close() }
                else if self.useSample { self.appData.removeSample(removed) }
            }
            Task {
                if self.appData.target?.id == target.id { await self.appData.refresh() }
                await self.remeasure(target.appID)
                self.feedWidget()
            }
        }))
    }

    private func canCleanAppData(_ target: AppDataTarget) -> Bool {
        let owners = Set(target.ownerIDs.map { $0.lowercased() })
        let active = runningAppNames().filter { owners.contains($0.key.lowercased()) }
        if !active.isEmpty {
            let names = ListFormatter.localizedString(byJoining: Set(active.values).sorted())
            notice = String(localized: "请先退出 \(names)，再清理它的数据。")
            return false
        }
        return true
    }

    /// 先列出应用，再并行统计大小，每算完一个就更新一个
    func loadApps(force: Bool = false) async {
        guard force || apps.isEmpty, !appsLoading else { return }
        if useSample { apps = Sample.apps; return }
        appsLoading = true
        defer { appsLoading = false }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let listed = await blocking { AppScanner.list(running: running) }
        apps = listed
        // 同时最多统计 6 个：全部一起跑会让磁盘来回寻道，也会拖慢其他扫描
        await withTaskGroup(of: AppItem.self) { group in
            var pending = listed[...]
            for app in pending.prefix(6) { group.addTask { await blocking { AppScanner.measured(app) } } }
            pending = pending.dropFirst(6)
            // 攒一会儿再一起写回：每测完一个就改一次 apps，几百个应用就是几百次整窗重画
            var done: [AppItem] = []
            var flushed = ContinuousClock.now
            @MainActor func flush() {
                guard !done.isEmpty else { return }
                var list = apps
                for m in done { if let i = list.firstIndex(where: { $0.id == m.id }) { list[i] = m } }
                apps = list
                done = []
                flushed = .now
            }
            for await m in group {
                done.append(m)
                if flushed.duration(to: .now) > .milliseconds(300) { flush() }
                if let next = pending.popFirst() { group.addTask { await blocking { AppScanner.measured(next) } } }
            }
            flush()
        }
    }

    // MARK: 文件与空间

    var fileScan: FileScanner.Result?
    var space: SpaceScanner.Result?
    var fileCategories: [FileCategory] = []
    var filesLoading = false
    var spaceLoading = false
    var leftovers: [LeftoverGroup] = []
    var launchGroups: [LaunchGroup] = []
    var devTools: [DevTool] = []
    var leftoversLoading = false
    var launchLoading = false
    var devLoading = false
    /// 还有扫描没结束：这时“没有找到”“0 MB”都不可信
    var scanning: Bool { appsLoading || filesLoading || leftoversLoading || devLoading }
    /// 正在运行清理命令的工具；不同工具可以同时清，同一个工具不会重复开始
    var devRunning: Set<String> = []
    /// 每次扫描前检查一次
    var hasFullDiskAccess = true
    var devLog: [String: String] = [:]
    /// 桌面上放了 30 天、可以归档的截图张数（自动规则卡片上显示）；规则检查时在后台数
    var oldShotCount: Int?

    @ObservationIgnored private var scanInFlight = false

    /// 启动时跑一遍：应用、个人文件、空间分布等互不依赖，一起开始。
    /// 开机后台启动时正在扫，这时打开窗口不会再开一遍（要重扫用 force）
    func scanAll(force: Bool = false) async {
        if scanInFlight && !force { return }
        scanInFlight = true
        defer { scanInFlight = false }
        if useSample {
            apps = Sample.apps
            fileCategories = Sample.fileCategories
            leftovers = Sample.leftoverGroups
            launchGroups = Sample.launchGroups
            devTools = Sample.devTools
            return
        }
        if force { removedKeys = [] }
        hasFullDiskAccess = Permissions.hasFullDiskAccess
        refreshDisk()
        async let spaceDone: Void = loadSpace()
        async let leftDone: Void = loadLeftovers()
        async let launchDone: Void = loadLaunch()
        async let devDone: Void = loadDev()
        async let appsDone: Void = loadApps(force: force)
        async let filesDone: Void = loadFiles()
        _ = await (filesDone, appsDone, spaceDone, leftDone, launchDone, devDone)
        HangLog.mark("各项扫描结束")
        // 应用大小测完了再分一次：安装包对不对得上已装的应用要用到
        await categorize()
        DiaryStore.record(self)
        startRules()
        await RuleEngine.evaluate(self)
        feedWidget()
        lastFullScan = .now
        releaseFreedMemory()
        HangLog.mark("扫描全部完成")
    }

    func loadLeftovers() async {
        leftoversLoading = true
        leftovers = await blocking { LeftoverScanner.scan() }
        leftoversLoading = false
    }

    func loadLaunch() async {
        launchLoading = true
        launchGroups = await blocking { LaunchScanner.scan() }
        launchLoading = false
    }

    func loadDev() async {
        devLoading = true
        devTools = await blocking { DevScanner.scan() }
        devLoading = false
    }

    func removeWorktree(_ item: WorktreeItem, mode: WorktreeRemovalMode) {
        guard worktrees.beginRemoval(item, mode: mode) else {
            notice = String(localized: "工作区状态已经变化，请重新统计后再试。")
            return
        }
        perform(.init(title: mode.title, source: "开发工具",
                      urls: [URL(filePath: item.path)], sizes: item.size.map { [item.path: $0] } ?? [:],
                      worktree: item, worktreeMode: mode, onDone: { [weak self] entry in
            guard let self else { return }
            self.worktrees.finishRemoval(item, succeeded: self.useSample || entry != nil)
            Task { await self.worktrees.refresh(item.projectPath, force: true) }
            if !self.useSample, entry != nil {
                Task {
                    await self.loadFiles()
                    self.feedWidget()
                }
            }
        }))
    }

    /// 依次执行一个工具的清理步骤：命令直接跑，目录直接删除；前后对比记一笔。
    /// 几个工具可以同时清，所以腾出的空间按这个工具自己清理前后的占用算，不看磁盘剩余（会混进别的工具腾出的）
    func runDev(_ tool: DevTool) async {
        guard !devRunning.contains(tool.id), !tool.actions.isEmpty else { return }
        devRunning.insert(tool.id)
        defer { devRunning.remove(tool.id) }
        let before = tool.total
        var log: [String] = []
        var trashed: [TrashedFile] = []
        var failed: [String] = []
        for action in tool.actions {
            log.append("$ " + action.display)
            switch action {
            case .command(let exe, let args):
                let out = await blocking { Shell.run(exe, args) }
                if let out, out.busy {
                    log.append(String(localized: "缓存正在被别的程序使用（比如正在运行的 Python 程序或编辑器插件），没有清。关掉它们后再试。"))
                    failed.append(action.display)
                } else if let out {
                    let text = (out.out + out.err).split(separator: "\n").suffix(4).joined(separator: "\n")
                    if !text.isEmpty { log.append(text) }
                    if out.status != 0 { log.append(String(localized: "（退出码 \(out.status)）")); failed.append(action.display) }
                } else {
                    log.append(String(localized: "（没能运行或超时）"))
                    failed.append(action.display)
                }
            case .trash(let paths):
                let r = await delete(paths.map { URL(filePath: $0) })
                trashed += r.done
                log.append(r.failed.isEmpty ? String(localized: "已删除 \(r.done.count) 项") : r.failed.map { "\($0.name)：\($0.reason)" }.joined(separator: "\n"))
            }
            devLog[tool.id] = log.joined(separator: "\n")
        }
        refreshDisk()
        await loadDev()
        let after = devTools.first { $0.id == tool.id }?.total ?? 0
        let commandsRan = tool.actions.contains { if case .command = $0 { return true } else { return false } }
        var entry = HistoryEntry(date: .now, title: String(localized: "清理 \(tool.name)"), source: "开发工具", files: trashed)
        if commandsRan {
            entry.commandNote = String(localized: "运行了 \(tool.actions.compactMap { if case .command = $0 { return $0.display } else { return nil } }.joined(separator: "、"))")
            entry.commandFreed = max(0, before - after)
        }
        history.insert(entry, at: 0)
        HistoryStore.saveLater(history)
        feedWidget()
        // 只跑了命令（npm cache clean 之类）也算删完了，和删文件响同一声
        if !trashed.isEmpty || (commandsRan && failed.isEmpty) { DeleteSound.play() }
        if !failed.isEmpty {
            notice = String(localized: "\(tool.name) 有 \(failed.count) 条命令没有成功，对应的缓存还在：") + "\n" + failed.map { "· \($0)" }.joined(separator: "\n")
        }
    }

    @ObservationIgnored private var fileScanRun = 0

    func loadFiles(using scanner: @escaping @Sendable () -> FileScanner.Result = { FileScanner.scan() }) async {
        fileScanRun += 1
        let run = fileScanRun
        filesLoading = true
        let result = await blocking { scanner() }
        guard run == fileScanRun else { return }
        fileScan = result
        // 分好类再算扫完：不然页面会先闪一下“这里是空的”
        await categorize()
        if run == fileScanRun { filesLoading = false }
    }

    private func loadSpace() async {
        spaceLoading = true
        space = await blocking { SpaceScanner.scan() }
        spaceLoading = false
    }

    /// 删掉的文件不算进分类：列表、汇总、侧边栏、首页建议都按剩下的算
    func rebuildFileCategories() {
        Task { await categorize() }
    }

    /// 上一次分类的编号：删得快时几次分类会同时在算，只用最后开始的那次
    @ObservationIgnored private var categorizeRun = 0

    /// 一万多个文件分一次类要几百毫秒，在主线程上算界面会停住，所以放到后台
    private func categorize() async {
        guard let scan = fileScan else { return }
        categorizeRun += 1
        let run = categorizeRun
        let removed = removedKeys, apps = apps
        let result = await blocking {
            var scan = scan
            if !removed.isEmpty { scan.files.removeAll { removed.contains($0.path) } }
            return FileCategorizer.categories(scan, apps: apps)
        }
        if run == categorizeRun { fileCategories = result }
    }

    func category(_ id: AppSection) -> FileCategory? {
        fileCategories.first { $0.id == id }
    }

    /// 首页的空间分布。真实数据没算完时，未知部分先归到“统计中”
    var spaceCategories: [SpaceCategory] {
        if useSample { return Sample.categories }
        let t = Dictionary(uniqueKeysWithValues: Sample.categories.map { ($0.id, $0) })
        var result: [SpaceCategory] = []
        let free = SpaceCategory(id: "free", label: "可用", size: disk.free, color: t["free"]!.color,
                                 hint: String(localized: "建议至少保留 \((disk.total * 0.1).gbText)（10%）。"))
        guard let space else {
            let mine = fileScan?.rootSizes.map(\.size).reduce(0, +)
            if let mine {
                result.append(.init(id: "mine", label: "你的文件", size: mine, color: t["mine"]!.color, hint: t["mine"]!.hint,
                                    parts: fileScan!.rootSizes.sorted { $0.size > $1.size }.map { .init(label: $0.name, size: $0.size) }, link: .bigFiles))
            }
            result.append(.init(id: "pending", label: "统计中…", size: max(0, disk.used - (mine ?? 0)), color: Color.secondary.opacity(0.35),
                                hint: "正在统计资源库和隐藏文件夹，大约需要半分钟。"))
            return result + [free]
        }
        let appData = space.containers + space.groupContainers + space.appSupport
        let topData = apps.filter(\.isMeasured).sorted { $0.dataSize > $1.dataSize }.prefix(2)
        result.append(.init(id: "appdata", label: "应用数据", size: appData, color: t["appdata"]!.color,
                            hint: "应用自己存的东西：聊天记录、虚拟磁盘、离线内容。系统设置会把它们算进“系统数据”。",
                            parts: topData.map { .init(label: $0.name, size: $0.dataSize) }
                                + [.init(label: "其他应用", size: max(0, appData - topData.map(\.dataSize).reduce(0, +)))],
                            link: .apps))
        let hidden = max(0, space.library - appData) + space.dotDirs
        result.append(.init(id: "other", label: "隐藏文件与开发缓存", size: hidden, color: t["other"]!.color,
                            hint: "资源库里的缓存，以及主目录里以点开头的隐藏文件夹（各种工具的配置和缓存）。",
                            parts: [.init(label: "应用缓存", size: space.caches)]
                                + space.biggestDotDirs.map { .init(label: "~/\($0.name)", size: $0.size) }
                                + [.init(label: "其他", size: max(0, hidden - space.caches - space.biggestDotDirs.map(\.size).reduce(0, +)))],
                            link: .devTools))
        if let fileScan {
            result.append(.init(id: "mine", label: "你的文件", size: fileScan.rootSizes.map(\.size).reduce(0, +), color: t["mine"]!.color, hint: t["mine"]!.hint,
                                parts: fileScan.rootSizes.sorted { $0.size > $1.size }.map { .init(label: $0.name, size: $0.size) }, link: .bigFiles))
        }
        let appBundles = apps.filter(\.isMeasured).map(\.appSize).reduce(0, +)
        result.append(.init(id: "apps", label: "应用程序", size: appBundles, color: t["apps"]!.color, hint: t["apps"]!.hint, link: .apps))
        if let brew = space.homebrew {
            result.append(.init(id: "brew", label: "Homebrew", size: brew, color: t["brew"]!.color, hint: t["brew"]!.hint, link: .devTools))
        }
        let known = result.map(\.size).reduce(0, +)
        let system = max(0, disk.used - known)
        result.append(.init(id: "system", label: "macOS 系统与其他", size: system, color: t["system"]!.color,
                            hint: "已用空间减去上面几类，剩下的就是这一块，系统设置里叫“系统数据”。能看清的部分列在下面，每项都写了会不会自己变小、能不能删。",
                            parts: systemParts(space, total: system)))
        return result.sorted { $0.size > $1.size } + [free]
    }

    /// “macOS 系统与其他”的细分。大小来自 APFS 各卷和几个固定目录；加起来以外的部分记作“其他”
    private func systemParts(_ space: SpaceScanner.Result, total: Double) -> [SpaceCategory.Part] {
        var parts: [SpaceCategory.Part] = []
        func add(_ label: String, _ size: Double?, _ note: String, _ action: SpaceCategory.PartAction? = nil) {
            guard let size, size >= 0.05 else { return }
            parts.append(.init(label: label, size: size, note: note, action: action))
        }
        add("macOS 本身", space.systemVolume, "系统卷，只读且有签名保护，不会自己变，也不能删。")
        add("启动与恢复", (space.preboot ?? 0) + (space.recovery ?? 0), "开机和恢复要用的文件，系统更新时会临时变大，装完自己收回，不要手动删。")
        add("交换文件", space.vmVolume ?? space.swap, "内存不够时把内存写到磁盘，重启后会变小，不能手动删。")
        add("睡眠镜像", space.sleepImage, "合盖休眠时保存内存内容，系统自己维护，不能删。")
        add("系统素材", space.assets, "字体、语音、Apple 智能模型等按需下载的资源，系统自己管理，不要手动删。")
        add("系统日志", space.logs, "系统运行记录，按时间和大小自动轮换，不用管。")
        add("临时文件", space.temp, "应用运行时放的临时文件和缓存，重启后大多会清掉，不建议手动删。")
        let c = space.clones
        if c.count > 0 {
            let name = c.apps.count == 1 ? c.apps[0].replacing("Google ", with: "") : String(localized: "应用")
            let note = String(localized: "共 \(c.count) 份。") + String(localized: "\(name) 启动时复制的自己，被强制退出就会留下。和本体共用存储，看着有 \(c.logical.gbText)，实际约 \(c.real.gbText)。")
                + (c.removable.isEmpty ? String(localized: "现在的都在用，不要删。") : String(localized: "没在用的可以删。"))
            parts.append(.init(label: String(localized: "\(name) 签名副本"), size: c.real, note: note,
                               action: c.removable.isEmpty ? nil : .cleanClones(count: c.removable.count)))
        }
        parts.sort { ($0.size ?? 0) > ($1.size ?? 0) }
        parts.append(.init(label: String(localized: "本地快照 \(space.snapshots) 个"), size: nil,
                           note: space.snapshots > 0 ? "系统更新或时间机器做的，删掉的文件要等快照到期才腾出空间；空间紧张时系统会自动删。" : "目前没有。"))
        let known = parts.compactMap(\.size).reduce(0, +)
        parts.append(.init(label: "其他", size: max(0, total - known), note: "其他用户的文件、系统目录和数据库等 Adieu 看不到的部分。"))
        return parts
    }

    /// 删掉没在用的签名副本，删完重新数一遍
    func cleanClones() {
        guard let c = space?.clones, !c.removable.isEmpty else { return }
        confirmTrash(.init(title: String(localized: "删掉 \(c.removable.count) 份签名副本？"), source: "空间分布",
                           urls: c.removable.map { URL(filePath: $0) }, sizes: c.removableSizes,
                           onDone: { [weak self] _ in
                               Task { @MainActor in
                                   let fresh = await blocking { CodeSignClones.scan() }
                                   self?.space?.clones = fresh
                               }
                           }))
    }

    // MARK: 规则

    /// 打开规则时顺便请求通知权限
    func setRule(_ id: String, on: Bool) {
        if on {
            enabledRules.insert(id)
            Task { _ = await Notifier.requestAuthorization(); await RuleEngine.evaluate(self) }
        } else {
            enabledRules.remove(id)
        }
    }

    private var ruleTimer: Timer?

    /// 启动后每小时检查一次规则
    /// 每小时一次：规则照常检查；上次全量扫描超过 6 小时就在后台重扫（只在菜单栏时也算）；
    /// 上次检查更新超过 24 小时就再看一次
    func startRules() {
        guard ruleTimer == nil, !useSample else { return }
        ruleTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in
                self.refreshDisk()
                if self.scanIsStale(6 * 3600) { await self.scanAll(force: true) } else { await RuleEngine.evaluate(self) }
                await UpdatePrompt.automaticIfDue()
            }
        }
    }

    /// 上次全量扫描完成的时间。扫描要半分钟、磁盘读得多，所以按时间判断要不要重扫，不定时硬扫
    private(set) var lastFullScan: Date?

    func scanIsStale(_ age: TimeInterval) -> Bool {
        guard let lastFullScan else { return false }  // 还没扫完第一次，不叠加
        return Date.now.timeIntervalSince(lastFullScan) > age
    }

    /// 窗口回到前台：剩余空间马上刷新；上次扫描超过 1 小时就在后台重扫
    func didBecomeActive() {
        refreshDisk()
        guard !useSample, !scanInFlight, scanIsStale(3600) else { return }
        Task { await scanAll(force: true) }
    }

    /// “腾出空间”的候选：从各页面的扫描结果里汇总
    var goalCandidates: [CleanupItem] {
        if useSample { return Sample.goalCandidates }
        var list: [CleanupItem] = []
        for t in devTools where t.reclaimable > 0.01 && t.blocked == nil && !t.actions.isEmpty {
            list.append(.init(id: "dev.\(t.id)", title: String(localized: "\(t.name) 的缓存"), detail: t.note, size: t.reclaimable, safety: .safe, action: .dev(toolID: t.id)))
        }
        if let c = category(.installers) {
            let done = c.items.filter { $0.modified.hasSuffix("已安装") || $0.modified.hasPrefix("旁边已经有") }
            if !done.isEmpty {
                list.append(.init(id: "installers", title: String(localized: "用过的安装包和压缩包 \(done.count) 个"), detail: String(localized: "对应的应用已经装好，或者旁边已经有解压后的文件夹。"),
                                  size: done.map(\.size).reduce(0, +), safety: .safe, action: .trash(paths: done.compactMap(\.path))))
            }
        }
        let gone = leftovers.first { $0.id == "gone" }?.items ?? []
        if !gone.isEmpty {
            list.append(.init(id: "leftovers", title: String(localized: "已删应用的残留 \(gone.count) 项"), detail: String(localized: "标识符找不到任何已装应用。"),
                              size: gone.compactMap(\.size).reduce(0, +), safety: .safe, action: .trash(paths: gone.flatMap(\.paths))))
        }
        // 要你确认的：1 GB 以上的大文件，逐个列出
        for f in (category(.bigFiles)?.items ?? []).filter({ $0.size >= 1 }).prefix(6) {
            list.append(.init(id: "file.\(f.id)", title: f.name, detail: f.reason, size: f.size, safety: .review, action: .trash(paths: f.path.map { [$0] } ?? [])))
        }
        return list
    }

    /// 按计划执行：要删的文件合成一次操作，开发工具逐个跑命令
    func execute(_ plan: GoalPlanner.Plan) async {
        let paths = plan.items.flatMap { if case .trash(let p) = $0.action { return p } else { return [] } }
        if !paths.isEmpty {
            perform(.init(title: String(localized: "腾出空间：移走 \(paths.count) 项"), source: "腾出空间", urls: paths.map { URL(filePath: $0) }))
        }
        for item in plan.items {
            if case .dev(let id) = item.action, let tool = devTools.first(where: { $0.id == id }) { await runDev(tool) }
        }
        await scanAll(force: true)
    }

    /// 侧边栏右侧的小字
    func badge(for s: AppSection) -> String? {
        if useSample { return s.badge }
        func size(_ id: AppSection) -> String? {
            guard let c = category(id), !c.items.isEmpty else { return nil }
            return c.items.map(\.size).reduce(0, +).gbText
        }
        switch s {
        case .apps: return apps.isEmpty ? nil : "\(apps.count)"
        case .installers, .captures, .stale: return size(s)
        case .bigFiles: return category(.bigFiles).map { String(localized: "\($0.items.count) 个") }
        case .leftovers:
            let on = leftovers.flatMap(\.items).filter(\.defaultOn).compactMap(\.size).reduce(0, +)
            return on > 0 ? on.gbText : nil
        case .launch:
            let broken = launchGroups.first { $0.id == "broken" }?.items.count ?? 0
            return broken > 0 ? String(localized: "\(broken) 个失效") : nil
        case .devTools:
            let r = devTools.map(\.reclaimable).reduce(0, +)
            return r > 0.01 ? r.gbText : nil
        default: return nil
        }
    }

    func remeasure(_ id: String) async {
        guard let app = apps.first(where: { $0.id == id }) else { return }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let fresh = await blocking { AppScanner.rescan(app, running: running) }
        if let fresh, let i = apps.firstIndex(where: { $0.id == id }) { apps[i] = fresh } else if fresh == nil { apps.removeAll { $0.id == id } }
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "didOnboard")
        showOnboarding = false
    }
}
