import Foundation

/// 同步磁盘遍历的协作取消；不依赖 Task 的协作线程执行状态。
final class AppDataScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// 所有浏览会话共用六个统计名额，等待名额时不占用 GCD 或协作线程。
actor AppDataMeasurementLimiter {
    static let shared = AppDataMeasurementLimiter()
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if active < 6 { active += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty { active -= 1 }
        else { waiting.removeFirst().resume() }
    }

    func measured(_ item: AppDataEntry, root: String, cancellation: AppDataScanCancellation,
                  work: @escaping @Sendable (AppDataEntry, String, AppDataScanCancellation) -> AppDataEntry) async -> AppDataEntry? {
        guard !cancellation.isCancelled else { return nil }
        await acquire()
        guard !cancellation.isCancelled else { release(); return nil }
        let result = await blocking { work(item, root, cancellation) }
        release()
        return cancellation.isCancelled ? nil : result
    }
}

/// 按需读取应用数据的一层目录。不会沿链接走到文稿、下载等其他位置。
enum AppDataScanner {
    static func contains(_ path: String, root: String) -> Bool {
        let base = URL(filePath: root).standardizedFileURL
        let url = URL(filePath: path).standardizedFileURL
        guard base.resolvingSymlinksInPath().path == base.path,
              url.resolvingSymlinksInPath().path == url.path else { return false }
        if url.path == base.path {
            return (try? base.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        return url.path.hasPrefix(base.path + "/")
    }

    static func list(_ target: AppDataTarget, path: String) -> AppDataListing {
        let root = URL(filePath: target.root).standardizedFileURL
        let url = URL(filePath: path).standardizedFileURL
        var listing = AppDataListing(path: url.path)
        if root.pathExtension.lowercased() == "photoslibrary" {
            listing.error = String(localized: "照片图库由“照片”管理，保留。")
            return listing
        }
        guard (url.path == root.path || contains(url.path, root: root.path)),
              root.resolvingSymlinksInPath().path == root.path,
              url.resolvingSymlinksInPath().path == url.path else {
            listing.error = String(localized: "位置已经变化，请重新查看。")
            return listing
        }
        do {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
                                            .contentModificationDateKey, .totalFileAllocatedSizeKey]
            let values = try url.resourceValues(forKeys: keys)
            let urls = values.isDirectory == true
                ? try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys)) : [url]
            listing.entries = urls.map { child in
                do {
                    let v = try child.resourceValues(forKeys: keys)
                    let folder = v.isDirectory == true
                    var restriction: String?
                    if v.isSymbolicLink == true || child.resolvingSymlinksInPath().path != child.standardizedFileURL.path {
                        restriction = String(localized: "链接不展开，也不用于清理。")
                    } else if child.lastPathComponent.hasPrefix(".com.apple.containermanagerd.") {
                        restriction = String(localized: "系统管理的容器信息，保留。")
                    } else if child.pathExtension.lowercased() == "photoslibrary" {
                        restriction = String(localized: "照片图库由“照片”管理，保留。")
                    }
                    return AppDataEntry(path: child.path, name: child.lastPathComponent, isDirectory: folder,
                                        isPackage: v.isPackage == true, modified: v.contentModificationDate,
                                        evidence: target.part.evidence,
                                        size: folder ? nil : v.totalFileAllocatedSize.map { Double($0) / bytesPerGB },
                                        isMeasured: !folder || restriction != nil, restriction: restriction)
                } catch {
                    return AppDataEntry(path: child.path, name: child.lastPathComponent, isDirectory: false,
                                        isPackage: false, modified: nil, evidence: target.part.evidence,
                                        isMeasured: true, restriction: error.localizedDescription)
                }
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            listing.error = error.localizedDescription
        }
        return listing
    }

    static func measured(_ item: AppDataEntry, root: String, cancellation: AppDataScanCancellation? = nil) -> AppDataEntry {
        var result = item
        result.isMeasured = true
        guard cancellation?.isCancelled != true, contains(item.path, root: root), item.restriction == nil else { return result }
        guard item.isDirectory else { return result }
        var partial = false
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: URL(filePath: item.path), includingPropertiesForKeys: Array(keys),
                                                              errorHandler: { _, _ in partial = true; return cancellation?.isCancelled != true }) else {
            result.sizeIsPartial = true
            return result
        }
        var bytes = 0
        while cancellation?.isCancelled != true, let url = enumerator.nextObject() as? URL {
            do {
                let values = try url.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true || url.pathExtension.lowercased() == "photoslibrary" {
                    enumerator.skipDescendants()
                    continue
                }
                bytes += values.totalFileAllocatedSize ?? 0
            } catch { partial = true }
        }
        guard cancellation?.isCancelled != true else { result.isMeasured = false; return result }
        result.size = Double(bytes) / bytesPerGB
        result.sizeIsPartial = partial
        return result
    }
}
