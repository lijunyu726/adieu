import Darwin
import Foundation

/// 搬家：移动、复制、改名、新建文件夹。
/// 同一块盘里的移动只是改登记（瞬间完成）；跨盘的“移动”其实是复制再删原件，按五步走：
/// 预检 → 复制到临时名字 → 核对文件数和大小 → 改成正式名字 → 删原件（走 TrashService，保护名单照常生效）。
/// 中途出错、取消、拔盘，原件都还在；目标盘上只会留下临时名字的半成品（记在 Pending 里，下次提示清理）
enum FileMover {
    enum Mode: String, Codable, Sendable { case move, copy }

    enum Refusal: LocalizedError {
        case name
        case conflict(String)
        case changed(String)
        case sameFolder
        case intoItself(String)
        case source(String)
        case destination(String)
        case readOnly
        case noSpace(need: Int64, free: Int64)
        case problems([String])
        case cancelled
        case verify(String)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .name: String(localized: "名字不能为空，不能以“.”开头，也不能含“/”“:”。")
            case .conflict(let name): String(localized: "那里已经有“\(name)”了。")
            case .changed(let name): String(localized: "“\(name)”已经变了，请刷新后重试。")
            case .sameFolder: String(localized: "已经在这个文件夹里了。")
            case .intoItself(let name): String(localized: "不能把“\(name)”放进它自己里面。")
            case .source(let why), .destination(let why): why
            case .readOnly: String(localized: "这块盘是只读的，不能往里放东西。")
            case .noSpace(let need, let free):
                String(localized: "空间不够：要 \(Self.bytes(need))，那块盘只剩 \(Self.bytes(free))。")
            case .problems(let list): list.joined(separator: "\n")
            case .cancelled: String(localized: "已取消。")
            case .verify(let name): String(localized: "“\(name)”复制后核对不上（文件数或大小不一致），没有删原件。")
            case .unsupported(let name): String(localized: "“\(name)”是特殊文件（不是普通文件、文件夹或链接），不能复制。")
            }
        }

        static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
    }

    /// 预检的结果，确认窗口照着它显示
    struct Plan: Sendable {
        let mode: Mode
        let items: [URL]
        let destination: URL
        /// 有项目要跨盘（复制一律算）
        let crossVolume: Bool
        /// 要复制的总字节和文件数（同盘移动不算）
        let bytes: Int64
        let files: Int
        /// 目标里已经有同名的：会保留两份，新的自动加编号
        let conflicts: [String]
        /// 预检时每项的身份，执行前再核对一次，变了就不动
        let identities: [String: String]
    }

    struct Progress: Sendable {
        var done: Int64 = 0
        var total: Int64 = 0
        var current = ""
    }

    struct Outcome: Sendable {
        var done: [MoveRecord.Pair] = []
        var failed: [MoveRecord.Failure] = []
        var cancelled = false
    }

    // MARK: 能动哪里

    private static var home: [String] {
        FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
            .split(separator: "/").map(String.init)
    }

    /// 路径本身不解开（它可能是个链接，搬的就是链接），只解开上级
    private static func real(_ url: URL) -> String {
        let u = url.standardizedFileURL
        return u.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: u.lastPathComponent).path
    }

    /// 能搬、能改名的：主目录里文件夹里面的东西（资源库除外），外接硬盘上的东西。
    /// 和 TrashService.check 的范围一致，所以跨盘移动最后删原件时不会被拦
    static func checkSource(_ url: URL, protected: [String]) throws {
        let path = real(url)
        var info = stat()
        guard lstat(path, &info) == 0 else { throw Refusal.changed(url.lastPathComponent) }
        if TrashService.isProtected(path, protected: protected) {
            throw TrashService.Refusal.protected(path)
        }
        let parts = path.split(separator: "/").map(String.init)
        if parts.starts(with: home) {
            let rel = parts.dropFirst(home.count)
            if rel.count >= 2 && rel.first != "Library" { return }
            throw Refusal.source(rel.count < 2 ? String(localized: "“\(url.lastPathComponent)”是系统需要的文件夹，不能搬。")
                                               : String(localized: "资源库里的东西是应用自己用的，不能搬。"))
        }
        if parts.first == "Volumes", parts.count >= 3 { return }
        throw Refusal.source(String(localized: "只能搬主目录和外接硬盘上的东西。"))
    }

    /// 能放东西进去的文件夹：主目录里的文件夹（资源库除外），外接硬盘上任何文件夹
    static func checkDestination(_ folder: URL, protected: [String]) throws {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw Refusal.changed(folder.lastPathComponent)
        }
        if TrashService.isProtected(path, protected: protected) { throw TrashService.Refusal.protected(path) }
        let parts = path.split(separator: "/").map(String.init)
        if parts.starts(with: home) {
            let rel = parts.dropFirst(home.count)
            if rel.count >= 1 && rel.first != "Library" { return }
            throw Refusal.destination(rel.isEmpty ? String(localized: "主目录第一层只放系统文件夹，请放进某个文件夹里。")
                                                  : String(localized: "资源库是应用自己用的，不能往里放东西。"))
        }
        if parts.first == "Volumes", parts.count >= 2 { return }
        throw Refusal.destination(String(localized: "只能放到主目录和外接硬盘上。"))
    }

    /// fsType 为目标盘的文件系统：FAT32、exFAT 不认 \ * ? " < > | 这些字符，也不认结尾的空格和点
    static func validName(_ name: String, fsType: String = "apfs") -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":"),
              name.rangeOfCharacter(from: .controlCharacters) == nil, name.utf8.count <= 255 else { return false }
        if ["msdos", "exfat"].contains(fsType) {
            if name.rangeOfCharacter(from: CharacterSet(charactersIn: "\\*?\"<>|")) != nil { return false }
            if name.hasSuffix(" ") || name.hasSuffix(".") { return false }
        }
        return true
    }

    // MARK: 预检

    static func plan(_ items: [URL], to destination: URL, mode: Mode, places: [Place], protected: [String]) throws -> Plan {
        try checkDestination(destination, protected: protected)
        let target = Places.containing(destination, in: places)
        if target?.readOnly == true { throw Refusal.readOnly }
        let fsType = target?.fsType ?? "apfs"
        let destPath = destination.standardizedFileURL.path
        let destDevice = device(destination)
        var bytes: Int64 = 0, files = 0, cross = false
        var conflicts: [String] = [], problems: [String] = [], identities: [String: String] = [:]
        for item in items {
            try checkSource(item, protected: protected)
            let path = item.standardizedFileURL.path
            if destPath == path || destPath.hasPrefix(path + "/") { throw Refusal.intoItself(item.lastPathComponent) }
            if item.deletingLastPathComponent().standardizedFileURL.path == destPath { throw Refusal.sameFolder }
            identities[path] = TrashService.fileIdentity(at: item)
            if exists(destination.appending(path: item.lastPathComponent)) { conflicts.append(item.lastPathComponent) }
            guard mode == .copy || device(item) != destDevice else { continue }
            cross = true
            // 跨盘：数一遍要复制多少，顺便查目标盘放不放得下
            walk(item) { url, info in
                let kind = info.st_mode & S_IFMT
                if kind == S_IFREG {
                    files += 1
                    bytes += Int64(info.st_size)
                    if fsType == "msdos" && info.st_size > 0xFFFF_FFFF {
                        problems.append(String(localized: "“\(url.lastPathComponent)”超过 4 GB，FAT32 格式的盘放不下。"))
                    }
                }
                if !validName(url.lastPathComponent, fsType: fsType) && url.lastPathComponent.first != "." {
                    problems.append(String(localized: "“\(url.lastPathComponent)”的名字在这块盘上不能用（含 \\ * ? \" < > | 或以空格、点结尾）。"))
                }
            }
        }
        if !problems.isEmpty { throw Refusal.problems(Array(problems.prefix(20))) }
        // 留点余量免得把盘写满：大盘留 200 MB，小 U 盘按容量的 2% 留
        let margin = min(200_000_000, (target?.total ?? 0) / 50)
        if cross, let free = target?.free, free < bytes + margin { throw Refusal.noSpace(need: bytes, free: free) }
        return Plan(mode: mode, items: items, destination: destination, crossVolume: cross, bytes: bytes, files: files,
                    conflicts: conflicts, identities: identities)
    }

    // MARK: 执行

    static func run(_ plan: Plan, protected: [String],
                    progress: @escaping @Sendable (Progress) -> Void,
                    cancelled: @escaping @Sendable () -> Bool) -> Outcome {
        var out = Outcome()
        let copier = Copier(total: plan.bytes, progress: progress, cancelled: cancelled)
        let destDevice = device(plan.destination)
        for item in plan.items {
            if cancelled() { out.cancelled = true; break }
            let name = item.lastPathComponent
            guard TrashService.fileIdentity(at: item) == plan.identities[item.standardizedFileURL.path] else {
                out.failed.append(.init(path: item.path, reason: Refusal.changed(name).localizedDescription))
                continue
            }
            let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: item.path)) != nil
            do {
                if plan.mode == .move && device(item) == destDevice {
                    // 同一块盘：直接改登记，瞬间完成
                    let target = try renameIntoPlace(item, in: plan.destination, name: name)
                    out.done.append(.init(from: item.path, to: target.path, identity: TrashService.fileIdentity(at: target)))
                    continue
                }
                let target = try copyIntoPlace(item, in: plan.destination, name: name, copier: copier, protected: protected)
                let pair = MoveRecord.Pair(from: item.path, to: target.path, identity: TrashService.fileIdentity(at: target))
                if plan.mode == .move {
                    // 核对过了才删原件
                    let deletion = TrashService.delete([item], protected: protected, symbolicLinkOnly: isLink)
                    if let failure = deletion.failed.first {
                        out.failed.append(.init(path: item.path, reason: String(localized: "已复制到 \(target.path)，但原件没删掉：\(failure.reason)")))
                        out.done.append(.init(from: item.path, to: target.path, identity: pair.identity, copied: true))
                        continue
                    }
                    if !deletion.needsAdmin.isEmpty {
                        out.failed.append(.init(path: item.path, reason: String(localized: "已复制到 \(target.path)，但没有权限删原件。")))
                        out.done.append(.init(from: item.path, to: target.path, identity: pair.identity, copied: true))
                        continue
                    }
                }
                out.done.append(plan.mode == .copy ? .init(from: item.path, to: target.path, identity: pair.identity, copied: true) : pair)
            } catch Refusal.cancelled {
                out.cancelled = true
                break
            } catch {
                out.failed.append(.init(path: item.path, reason: error.localizedDescription))
            }
        }
        return out
    }

    /// 同盘移动；目标重名就自动加编号
    private static func renameIntoPlace(_ item: URL, in folder: URL, name: String) throws -> URL {
        for _ in 0..<3 {
            let target = folder.appending(path: uniqueName(name, in: folder, isFolder: isFolder(item)))
            if renamex_np(item.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
            if errno != EEXIST { throw posixError(item) }
        }
        throw Refusal.conflict(name)
    }

    /// 复制到临时名字 → 核对 → 改成正式名字。出任何问题都把临时的删掉，原件不动
    private static func copyIntoPlace(_ item: URL, in folder: URL, name: String, copier: Copier, protected: [String]) throws -> URL {
        let temp = folder.appending(path: ".adieu-moving-\(UUID().uuidString.prefix(8))-\(name)")
        Pending.add(temp)
        do {
            // 同一块 APFS 盘上复制：先试克隆，瞬间完成、不占额外空间
            if device(item) == device(folder), clonefile(item.path, temp.path, UInt32(CLONE_NOFOLLOW)) == 0 {
                copier.advance(by: summary(item).bytes, current: name)
            } else {
                try copier.copy(item, to: temp)
            }
            let (a, b) = (summary(item), summary(temp))
            guard a == b else { throw Refusal.verify(name) }
            let target = try renameIntoPlace(temp, in: folder, name: name)
            Pending.remove(temp)
            return target
        } catch {
            let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: temp.path)) != nil
            if exists(temp) {
                let cleanup = TrashService.delete([temp], protected: protected, symbolicLinkOnly: isLink)
                if cleanup.failed.isEmpty && cleanup.needsAdmin.isEmpty { Pending.remove(temp) }
            } else {
                Pending.remove(temp)
            }
            throw error
        }
    }

    // MARK: 改名、新建文件夹

    static func rename(_ item: URL, to name: String, fsType: String, protected: [String]) throws -> MoveRecord.Pair {
        try checkSource(item, protected: protected)
        guard validName(name, fsType: fsType) else { throw Refusal.name }
        let target = item.deletingLastPathComponent().appending(path: name)
        guard target.path != item.path else { throw Refusal.sameFolder }
        // 只改大小写时目标“已存在”的就是它自己
        let caseOnly = TrashService.fileIdentity(at: target) == TrashService.fileIdentity(at: item)
        guard renamex_np(item.path, target.path, caseOnly ? 0 : UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw Refusal.conflict(name) }
            throw posixError(item)
        }
        return .init(from: item.path, to: target.path, identity: TrashService.fileIdentity(at: target))
    }

    static func createFolder(named name: String, in folder: URL, fsType: String, protected: [String]) throws -> MoveRecord.Pair {
        try checkDestination(folder, protected: protected)
        guard validName(name, fsType: fsType) else { throw Refusal.name }
        let url = folder.appending(path: name, directoryHint: .isDirectory)
        guard mkdir(url.path, 0o755) == 0 else {
            if errno == EEXIST { throw Refusal.conflict(name) }
            throw posixError(url)
        }
        return .init(from: "", to: url.path, identity: TrashService.fileIdentity(at: url))
    }

    // MARK: 工具

    /// “名字 2.后缀”“名字 3.后缀”…；普通文件夹不拆后缀（“v1.2” 不变成 “v1 2.2”）
    static func uniqueName(_ name: String, in folder: URL, isFolder: Bool) -> String {
        guard exists(folder.appending(path: name)) else { return name }
        let ext = isFolder ? "" : (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        for n in 2... {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !exists(folder.appending(path: candidate)) { return candidate }
        }
        return name
    }

    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func isFolder(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
        return v?.isDirectory == true && v?.isPackage != true && v?.isSymbolicLink != true
    }

    static func device(_ url: URL) -> dev_t {
        var info = stat()
        // 链接本身所在的盘：取上级文件夹
        let path = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil ? url.deletingLastPathComponent().path : url.path
        return stat(path, &info) == 0 ? info.st_dev : 0
    }

    /// 核对用：普通文件个数、总字节、链接个数、文件夹个数
    struct Summary: Equatable { var files = 0, bytes: Int64 = 0, links = 0, folders = 0 }

    static func summary(_ url: URL) -> Summary {
        var s = Summary()
        walk(url) { _, info in
            switch info.st_mode & S_IFMT {
            case S_IFREG: s.files += 1; s.bytes += Int64(info.st_size)
            case S_IFLNK: s.links += 1
            case S_IFDIR: s.folders += 1
            default: break
            }
        }
        return s
    }

    /// 不跟随链接地走一遍，包括隐藏文件
    static func walk(_ url: URL, _ visit: (URL, stat) -> Void) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return }
        visit(url, info)
        guard info.st_mode & S_IFMT == S_IFDIR,
              let children = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return }
        for child in children { walk(url.appending(path: child), visit) }
    }

    static func posixError(_ url: URL) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }
}

/// 一块一块地复制，能报进度、能中途取消；复制完补上权限、时间和扩展属性
private final class Copier {
    private var progress: FileMover.Progress
    private let report: @Sendable (FileMover.Progress) -> Void
    private let cancelled: @Sendable () -> Bool
    private var lastReport = Date.distantPast

    init(total: Int64, progress: @escaping @Sendable (FileMover.Progress) -> Void, cancelled: @escaping @Sendable () -> Bool) {
        self.progress = .init(total: total)
        report = progress
        self.cancelled = cancelled
    }

    func advance(by bytes: Int64, current: String) {
        progress.done += bytes
        progress.current = current
        report(progress)
    }

    func copy(_ src: URL, to dst: URL) throws {
        if cancelled() { throw FileMover.Refusal.cancelled }
        var info = stat()
        guard lstat(src.path, &info) == 0 else { throw FileMover.posixError(src) }
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: src.path)
            guard symlink(target, dst.path) == 0 else { throw FileMover.posixError(dst) }
        case S_IFDIR:
            guard mkdir(dst.path, 0o700) == 0 else { throw FileMover.posixError(dst) }
            for child in try FileManager.default.contentsOfDirectory(atPath: src.path) {
                try copy(src.appending(path: child), to: dst.appending(path: child))
            }
            metadata(src, dst)
        case S_IFREG:
            try copyFile(src, to: dst)
            metadata(src, dst)
        default:
            throw FileMover.Refusal.unsupported(src.lastPathComponent)
        }
    }

    private func copyFile(_ src: URL, to dst: URL) throws {
        let input = open(src.path, O_RDONLY)
        guard input >= 0 else { throw FileMover.posixError(src) }
        defer { close(input) }
        let output = open(dst.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard output >= 0 else { throw FileMover.posixError(dst) }
        defer { close(output) }
        _ = fcntl(input, F_NOCACHE, 1)
        _ = fcntl(output, F_NOCACHE, 1)
        let size = 8 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16_384)
        defer { buffer.deallocate() }
        progress.current = src.lastPathComponent
        while true {
            if cancelled() { throw FileMover.Refusal.cancelled }
            let n = read(input, buffer, size)
            if n < 0 { if errno == EINTR { continue }; throw FileMover.posixError(src) }
            if n == 0 { break }
            var written = 0
            while written < n {
                let w = write(output, buffer + written, n - written)
                if w < 0 { if errno == EINTR { continue }; throw FileMover.posixError(dst) }
                written += w
            }
            progress.done += Int64(n)
            if Date.now.timeIntervalSince(lastReport) > 0.1 {
                lastReport = .now
                report(progress)
            }
        }
        report(progress)
    }

    /// 权限、修改时间、扩展属性、访问控制；目标盘不支持的（FAT、exFAT）就算了
    private func metadata(_ src: URL, _ dst: URL) {
        _ = copyfile(src.path, dst.path, nil, copyfile_flags_t(COPYFILE_STAT | COPYFILE_XATTR | COPYFILE_ACL))
    }
}

/// 正在复制的临时项目。正常结束会去掉；还留着的就是上次中断留下的半成品
enum Pending {
    private static let key = "AdieuPendingMoves"
    private static let lock = NSLock()

    static func add(_ url: URL) { lock.withLock { UserDefaults.standard.set(paths() + [url.path], forKey: key) } }
    static func remove(_ url: URL) { lock.withLock { UserDefaults.standard.set(paths().filter { $0 != url.path }, forKey: key) } }
    static func forget(_ paths: [String]) {
        lock.withLock { UserDefaults.standard.set(self.paths().filter { !paths.contains($0) }, forKey: key) }
    }

    /// 还在磁盘上的半成品（盘没插着的先不管）
    static func leftovers() -> [URL] {
        lock.withLock { paths() }.map { URL(filePath: $0) }.filter(FileMover.exists)
    }

    private static func paths() -> [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
}

/// 一次搬家操作，存起来用于撤销
struct MoveRecord: Identifiable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case move, copy, rename, folder }

    struct Pair: Codable, Hashable, Sendable {
        let from: String
        let to: String
        /// 搬完后目标的身份；撤销前核对，变了就不动
        let identity: String?
        /// 这一项是复制出来的（复制，或跨盘移动但原件没删掉）
        var copied = false
    }

    struct Failure: Codable, Hashable, Sendable {
        let path: String
        let reason: String
    }

    var id = UUID()
    let date: Date
    let kind: Kind
    let pairs: [Pair]
    var undone = false

    /// 撤销要删东西（复制出来的、新建的文件夹）就得先问用户
    var undoDeletes: Bool { kind == .copy || kind == .folder || pairs.contains(where: \.copied) }
}

enum MoveLog {
    private static var file: URL { HistoryStore.folder.appending(path: "moves.json") }

    static func load() -> [MoveRecord] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([MoveRecord].self, from: data)) ?? []
    }

    /// 只留最近 50 次
    static func save(_ records: [MoveRecord]) {
        try? FileManager.default.createDirectory(at: HistoryStore.folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Array(records.prefix(50))) { try? data.write(to: file, options: .atomic) }
    }
}
