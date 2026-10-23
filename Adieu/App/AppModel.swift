import SwiftUI

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

    init() {
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
    /// 有权限不够的（如 App Store 装的应用）会接着弹系统密码窗口，完成后才调用 onDone
    @discardableResult
    func perform(_ request: TrashRequest) -> HistoryEntry? {
        let (entry, admin) = firstPass(request)
        if admin.isEmpty {
            if entry != nil { DeleteSound.play() }
            request.onDone?(entry)
        } else {
            Task {
                let merged = await adminPass(request, admin, entry)
                if merged != nil { DeleteSound.play() }
                request.onDone?(merged)
            }
        }
        return entry
    }

    /// 卸载应用：直接删除，不进废纸篓。权限不够的弹一次系统密码窗口，全部删完才返回
    func deleteForUninstall(_ request: TrashRequest) async -> HistoryEntry? {
        pendingTrash = nil
        if useSample { return nil }
        let first = TrashService.delete(request.urls, sizes: request.sizes, protected: protectedPaths)
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
        return entry
    }

    private func firstPass(_ request: TrashRequest) -> (HistoryEntry?, [URL]) {
        pendingTrash = nil
        if useSample {
            removedKeys.formUnion(request.keys)
            return (nil, [])
        }
        let result = TrashService.delete(request.urls, sizes: request.sizes, protected: protectedPaths)
        let entry = record(request, files: result.done, into: nil)
        report(result.failed)
        return (entry, result.needsAdmin)
    }

    private func adminPass(_ request: TrashRequest, _ urls: [URL], _ entry: HistoryEntry?) async -> HistoryEntry? {
        let sizes = request.sizes
        let protected = protectedPaths
        let result = await blocking { TrashService.deleteAsAdmin(urls, sizes: sizes, protected: protected) }
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
        HistoryStore.save(history)
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
        HistoryStore.save(history)
        refreshDisk()
        if !errors.isEmpty { notice = errors.joined(separator: "\n") }
    }

    // MARK: 应用

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
            for await m in group {
                if let i = apps.firstIndex(where: { $0.id == m.id }) { apps[i] = m }
                if let next = pending.popFirst() { group.addTask { await blocking { AppScanner.measured(next) } } }
            }
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
        rebuildFileCategories()
        DiaryStore.record(self)
        startRules()
        await RuleEngine.evaluate(self)
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
                let r = TrashService.delete(paths.map { URL(filePath: $0) }, protected: protectedPaths)
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
        HistoryStore.save(history)
        // 只跑了命令（npm cache clean 之类）也算删完了，和删文件响同一声
        if !trashed.isEmpty || (commandsRan && failed.isEmpty) { DeleteSound.play() }
        if !failed.isEmpty {
            notice = String(localized: "\(tool.name) 有 \(failed.count) 条命令没有成功，对应的缓存还在：") + "\n" + failed.map { "· \($0)" }.joined(separator: "\n")
        }
    }

    private func loadFiles() async {
        filesLoading = true
        fileScan = await blocking { FileScanner.scan() }
        filesLoading = false
        rebuildFileCategories()
    }

    private func loadSpace() async {
        spaceLoading = true
        space = await blocking { SpaceScanner.scan() }
        spaceLoading = false
    }

    /// 删掉的文件不算进分类：列表、汇总、侧边栏、首页建议都按剩下的算
    func rebuildFileCategories() {
        guard var scan = fileScan else { return }
        if !removedKeys.isEmpty { scan.files.removeAll { removedKeys.contains($0.path) } }
        fileCategories = FileCategorizer.categories(scan, apps: apps)
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
                            hint: "已用空间减去上面几类，剩下的就是这一块。主要是系统本身，以及 Adieu 看不到的其他用户和系统目录。",
                            parts: [.init(label: "交换文件", size: space.swap, note: "内存不够时临时写到磁盘，重启后会减少"),
                                    .init(label: String(localized: "本地快照 \(space.snapshots) 个"), size: nil, note: space.snapshots > 0 ? "系统更新或时间机器创建的，系统会自动清理" : "目前没有"),
                                    .init(label: "系统卷", size: nil, note: "只读且有签名保护，不能也不需要清理")]))
        return result.sorted { $0.size > $1.size } + [free]
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
    func startRules() {
        guard ruleTimer == nil, !useSample else { return }
        ruleTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in self.refreshDisk(); await RuleEngine.evaluate(self) }
        }
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

/// 阻塞的磁盘读取和命令放到 GCD 线程上跑。Swift 并发的协作线程池只有 CPU 核数那么多线程，
/// 被阻塞读取占满后，别的扫描即使已经开始也会一直排队
func blocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { c in
        DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: work()) }
    }
}
