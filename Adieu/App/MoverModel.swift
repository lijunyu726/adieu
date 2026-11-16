import Foundation
import Observation

/// 搬家页的一栏：在哪块盘、哪个文件夹、选中了什么
@Observable
@MainActor
final class MoverPane {
    var place: Place?
    private(set) var folder: URL?
    private(set) var items: [FolderItem] = []
    private(set) var error: String?
    var selection: Set<FolderItem.ID> = []
    var query = "" { didSet { if query != oldValue { searchLater() } } }
    private(set) var results: [FolderItem]?
    private(set) var searching = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    var shown: [FolderItem] { results ?? items }
    var chosen: [FolderItem] { shown.filter { selection.contains($0.id) } }

    /// 当前文件夹往上一直到盘的根，面包屑用
    var trail: [URL] {
        guard let folder, let root = place?.root else { return [] }
        var list = [folder]
        var url = folder
        while url.path != root.path, url.path.count > root.path.count {
            url = url.deletingLastPathComponent()
            list.insert(url, at: 0)
        }
        return list
    }

    func open(_ url: URL) {
        folder = url.standardizedFileURL
        selection = []
        query = ""
        results = nil
        reload()
    }

    func reload() {
        guard let folder else { return }
        do {
            items = try FolderListing.list(folder)
            error = nil
        } catch let e as CocoaError where e.code == .fileReadNoPermission {
            items = []
            error = String(localized: "macOS 没有允许 Adieu 打开这里。到「系统设置 → 隐私与安全性 → 文件与文件夹」里打开 Adieu 的“可移除宗卷”或对应文件夹，或者给 Adieu 完全磁盘访问权限。")
        } catch {
            items = []
            self.error = String(localized: "打不开这个文件夹：\(error.localizedDescription)")
        }
        let ids = Set(shown.map(\.id))
        selection = selection.intersection(ids)
        if !query.isEmpty { searchLater(delay: false) }
    }

    private func searchLater(delay: Bool = true) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let folder, !q.isEmpty else {
            results = nil
            searching = false
            return
        }
        searching = true
        searchTask = Task {
            if delay { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            let found = await blocking { FolderListing.search(folder, query: q) }
            guard !Task.isCancelled else { return }
            results = found
            searching = false
            selection = selection.intersection(Set(found.map(\.id)))
        }
    }
}

/// 搬家页的状态。放在 AppModel 里，切到别的页面再回来，进行中的复制和两栏位置都还在
@Observable
@MainActor
final class MoverModel {
    let left = MoverPane()
    let right = MoverPane()
    private(set) var places: [Place] = []
    /// 等用户确认的一次搬动
    var pending: FileMover.Plan?
    private(set) var progress: FileMover.Progress?
    private(set) var records: [MoveRecord]
    /// 上次中断留下的临时半成品
    private(set) var leftovers: [URL] = []
    var notice: String?
    /// 常用位置（绝对路径），按加入顺序
    private(set) var favorites: [String] = UserDefaults.standard.stringArray(forKey: MoverModel.favoritesKey) ?? []
    @ObservationIgnored private let cancelFlag = CancelFlag()
    static let favoritesKey = "moverFavorites"

    var busy: Bool { progress != nil }

    init() {
        records = MoveLog.load()
    }

    func start() {
        refreshPlaces()
        if left.folder == nil, let mac = places.first {
            left.place = mac
            left.open(mac.root)
        }
        // 右边优先放外接硬盘，没有就放 iCloud Drive
        if right.folder == nil,
           let other = places.first(where: { $0.kind == .volume }) ?? places.first(where: { $0.kind == .cloud }) ?? places.first {
            right.place = other
            right.open(other.kind == .home ? other.root.appending(path: "Documents") : other.root)
        }
        leftovers = Pending.leftovers()
    }

    func refreshPlaces() {
        places = Places.list()
        for pane in [left, right] {
            guard let current = pane.place else { continue }
            if let fresh = places.first(where: { $0.id == current.id }) {
                pane.place = fresh
            } else if let mac = places.first {
                // 盘被拔掉了，回到这台 Mac
                pane.place = mac
                pane.open(mac.root)
            }
        }
    }

    /// 从别的页面跳过来：左栏打开这个文件夹，右栏照常
    func show(_ folder: URL) {
        refreshPlaces()
        guard let place = Places.containing(folder, in: places) else { return }
        if right.folder == nil { start() }
        left.place = place
        left.open(folder)
        // 没插外接硬盘时右栏也是 iCloud Drive，换成主目录的“文稿”，两边才有得搬
        if right.place?.id == place.id, let mac = places.first(where: { $0.kind == .home }) {
            right.place = mac
            right.open(mac.root.appending(path: "Documents"))
        }
    }

    func isFavorite(_ url: URL) -> Bool { favorites.contains(url.standardizedFileURL.path) }

    func toggleFavorite(_ url: URL) {
        let path = url.standardizedFileURL.path
        if let i = favorites.firstIndex(of: path) { favorites.remove(at: i) } else { favorites.append(path) }
        UserDefaults.standard.set(favorites, forKey: Self.favoritesKey)
    }

    /// 常用位置现在能不能打开（外接盘拔了、文件夹被删了就不能）
    func reachable(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            && Places.containing(URL(filePath: path), in: places) != nil
    }

    /// 在这一栏打开常用位置
    func open(favorite path: String, in pane: MoverPane) {
        refreshPlaces()
        let url = URL(filePath: path)
        guard reachable(path), let place = Places.containing(url, in: places) else { return }
        pane.place = place
        pane.open(url)
    }

    func choose(_ place: Place, for pane: MoverPane) {
        pane.place = place
        pane.open(place.root)
    }

    func other(than pane: MoverPane) -> MoverPane { pane === left ? right : left }

    /// 预检：通过了就弹确认，没通过就把原因告诉用户
    func prepare(_ mode: FileMover.Mode, from pane: MoverPane) {
        guard let destination = other(than: pane).folder else { return }
        prepare(mode, items: pane.chosen.map(\.url), to: destination)
    }

    /// 拖到某一栏（从另一栏或访达拖进来）
    func prepare(_ mode: FileMover.Mode, items: [URL], to destination: URL) {
        guard !items.isEmpty, !busy else { return }
        let places = places
        let protected = protectedPaths()
        Task {
            let result = await blocking {
                Result { try FileMover.plan(items, to: destination, mode: mode, places: places, protected: protected) }
            }
            switch result {
            case .success(let plan): pending = plan
            case .failure(let error): notice = error.localizedDescription
            }
        }
    }

    @discardableResult
    func run(_ plan: FileMover.Plan) async -> FileMover.Outcome {
        pending = nil
        cancelFlag.set(false)
        progress = .init(total: plan.bytes)
        let protected = protectedPaths()
        let flag = cancelFlag
        let report: @Sendable (FileMover.Progress) -> Void = { [weak self] p in
            Task { @MainActor in if self?.progress != nil { self?.progress = p } }
        }
        let outcome = await blocking {
            FileMover.run(plan, protected: protected, progress: report, cancelled: { flag.get() })
        }
        progress = nil
        if !outcome.done.isEmpty {
            remember(.init(date: .now, kind: plan.mode == .copy ? .copy : .move, pairs: outcome.done))
        }
        var lines: [String] = plan.skipped.prefix(8).map { "\($0.name)：\($0.reason)" }
        if !outcome.skipped.isEmpty {
            lines.append(String(localized: "那里已有同名的，跳过了：\(outcome.skipped.joined(separator: "、"))"))
        }
        if outcome.cancelled { lines.append(String(localized: "已取消，没搬完的原件都还在原处。")) }
        lines += outcome.failed.prefix(8).map { "\(URL(filePath: $0.path).lastPathComponent)：\($0.reason)" }
        if outcome.failed.count > 8 { lines.append(String(localized: "还有 \(outcome.failed.count - 8) 项没搬成。")) }
        notice = lines.isEmpty ? nil : lines.joined(separator: "\n")
        afterChange()
        return outcome
    }

    /// 批量改名：都加同一个前缀或后缀，记成一步，撤销时一起改回去
    func batchRename(_ items: [FolderItem], in pane: MoverPane, prefix: String, suffix: String) {
        let fsType = pane.place?.fsType ?? "apfs"
        let protected = protectedPaths()
        var pairs: [MoveRecord.Pair] = [], failures: [String] = []
        for item in items {
            let name = FileMover.batchName(item.url.lastPathComponent, prefix: prefix, suffix: suffix, isFolder: item.isFolder)
            do {
                pairs.append(try FileMover.rename(item.url, to: name, fsType: fsType, protected: protected))
            } catch {
                failures.append("\(item.name)：\(error.localizedDescription)")
            }
        }
        if !pairs.isEmpty { remember(.init(date: .now, kind: .rename, pairs: pairs)) }
        notice = failures.isEmpty ? nil : failures.joined(separator: "\n")
        afterChange()
    }

    func cancel() { cancelFlag.set(true) }

    func rename(_ item: FolderItem, in pane: MoverPane, to name: String) {
        do {
            _ = try rename(item.url, to: name)
        } catch {
            notice = error.localizedDescription
        }
    }

    /// 改名并记进“最近”（agent 也用这个）
    func rename(_ url: URL, to name: String) throws -> MoveRecord.Pair {
        defer { afterChange() }
        let fsType = Places.containing(url, in: places)?.fsType ?? "apfs"
        let pair = try FileMover.rename(url, to: name, fsType: fsType, protected: protectedPaths())
        remember(.init(date: .now, kind: .rename, pairs: [pair]))
        return pair
    }

    /// 新建文件夹并记进“最近”（agent 也用这个）
    func createFolder(named name: String, at folder: URL) throws -> MoveRecord.Pair {
        defer { afterChange() }
        let fsType = Places.containing(folder, in: places)?.fsType ?? "apfs"
        let pair = try FileMover.createFolder(named: name, in: folder, fsType: fsType, protected: protectedPaths())
        remember(.init(date: .now, kind: .folder, pairs: [pair]))
        return pair
    }

    func createFolder(named name: String, in pane: MoverPane) {
        guard let folder = pane.folder else { return }
        do {
            let pair = try createFolder(named: name, at: folder)
            pane.selection = [pair.to]
        } catch {
            notice = error.localizedDescription
        }
    }

    /// 撤销：改名、同盘移动直接改回去；跨盘移动再搬回原文件夹；复制和新建文件夹删掉新的那份（界面上先确认）
    func undo(_ record: MoveRecord) async {
        guard let i = records.firstIndex(where: { $0.id == record.id }), !records[i].undone else { return }
        let protected = protectedPaths()
        var failures: [String] = []
        var back: [URL: [URL]] = [:]
        for pair in record.pairs.reversed() {
            let target = URL(filePath: pair.to)
            guard TrashService.fileIdentity(at: target) == pair.identity else {
                failures.append(String(localized: "“\(target.lastPathComponent)”搬完后又被动过，没有撤销它。"))
                continue
            }
            if record.kind == .folder || pair.copied {
                if record.kind == .folder, (try? FileManager.default.contentsOfDirectory(atPath: pair.to))?.isEmpty == false {
                    failures.append(String(localized: "“\(target.lastPathComponent)”里已经放了东西，没有删除。"))
                    continue
                }
                let result = await blocking { Result { try FileMover.remove(target, protected: protected) } }
                if case .failure(let error) = result { failures.append("\(target.lastPathComponent)：\(error.localizedDescription)") }
                continue
            }
            let source = URL(filePath: pair.from)
            if FileMover.device(target) == FileMover.device(source.deletingLastPathComponent()) {
                if FileMover.exists(source) {
                    failures.append(String(localized: "原来的位置又有了“\(source.lastPathComponent)”，没有改回去。"))
                } else {
                    do {
                        try FileMover.coordinatedRename(target, to: source, flags: UInt32(RENAME_EXCL))
                    } catch {
                        failures.append("\(target.lastPathComponent)：\(error.localizedDescription)")
                    }
                }
            } else {
                back[source.deletingLastPathComponent(), default: []].append(target)
            }
        }
        // 跨盘的那些按原文件夹分组，再走一遍完整的搬家流程（核对后才删）
        for (folder, items) in back {
            let places = places
            let result = await blocking {
                Result { try FileMover.plan(items, to: folder, mode: .move, places: places, protected: protected) }
            }
            switch result {
            case .success(let plan): await run(plan)
            case .failure(let error): failures.append(error.localizedDescription)
            }
        }
        if let j = records.firstIndex(where: { $0.id == record.id }) { records[j].undone = true }
        MoveLog.save(records)
        if !failures.isEmpty { notice = failures.joined(separator: "\n") }
        afterChange()
    }

    /// 清掉上次中断留下的临时半成品
    func clearLeftovers() async {
        let urls = leftovers
        let protected = protectedPaths()
        let result = await blocking {
            urls.map { url in (try? FileMover.remove(url, protected: protected)) != nil }
        }
        Pending.forget(zip(urls, result).filter(\.1).map(\.0.path))
        leftovers = Pending.leftovers()
        afterChange()
    }

    private func remember(_ record: MoveRecord) {
        records.insert(record, at: 0)
        MoveLog.save(records)
    }

    /// 删除（在界面层交给 AppModel.perform）完成后刷新两栏
    func refresh() { afterChange() }

    private func afterChange() {
        refreshPlaces()
        left.reload()
        right.reload()
    }

    private func protectedPaths() -> [String] {
        UserDefaults.standard.stringArray(forKey: "protectedPaths") ?? TrashService.defaultProtected
    }
}

/// 跨线程的取消标记
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ v: Bool) { lock.withLock { value = v } }
    func get() -> Bool { lock.withLock { value } }
}
