import Foundation
import CoreServices

/// 扫描主目录里的个人文件夹，找出安装包、压缩包、截图录屏、大文件和久未打开的文件。只读。
enum FileScanner {
    struct File: Sendable, Hashable {
        let path: String
        /// GB，实际占用
        let size: Double
        /// 字节，文件声明的大小
        let bytes: Int
        let modified: Date
        /// 聚焦记录的“上次打开时间”；没记录时为 nil
        let lastUsed: Date?
        let isScreenCapture: Bool
        let isPackage: Bool

        var url: URL { URL(filePath: path) }
        var name: String { url.lastPathComponent }
        var ext: String { url.pathExtension.lowercased() }
        var lastTouched: Date { max(lastUsed ?? modified, modified) }
    }

    struct Result: Sendable {
        var files: [File] = []
        /// 桌面、文稿等每个根目录的总占用（GB）
        var rootSizes: [(name: String, size: Double)] = []
        var date = Date.now
    }

    /// 扫描的根目录和显示名
    static let roots: [(dir: String, name: String)] = [
        ("Desktop", "桌面"), ("Documents", "文稿"), ("Downloads", "下载"),
        ("Movies", "影片"), ("Music", "音乐"), ("Pictures", "图片")
    ]

    /// 由应用自己管理的文件夹（剪辑草稿、素材缓存、媒体库）：算进总量，但里面的文件不单独列出，
    /// 直接删会弄坏应用里的工程。相对主目录
    static let appManaged: Set<String> = ["Movies/CapCut", "Movies/JianyingPro", "Movies/TV", "Movies/iMovie Library.imovielibrary",
                                          "Movies/Final Cut Backups", "Music/Music", "Music/iTunes", "Music/GarageBand",
                                          "Pictures/Photo Booth Library"]
    /// 安装包和压缩包只在这些地方找；其他地方的多半是工程或应用的一部分
    static let downloadRoots: Set<String> = ["Desktop", "Documents", "Downloads"]

    static let installerExts: Set<String> = ["dmg", "pkg", "mpkg", "xip"]
    static let archiveExts: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"]
    /// 截图、录屏只看后缀
    static let screenshotExts: Set<String> = ["png", "jpg", "jpeg", "heic", "gif"]
    static let recordingExts: Set<String> = ["mov", "mp4"]
    static let captureExts: Set<String> = screenshotExts.union(recordingExts)

    static func scan() -> Result {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey]
        var result = Result()
        for root in roots {
            let rootURL = home.appending(path: root.dir)
            var rootBytes = 0
            guard let e = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { continue }
            while let url = e.nextObject() as? URL {
                guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if v.isDirectory == true, appManaged.contains(String(url.path.dropFirst(home.path.count + 1))) {
                    e.skipDescendants()
                    rootBytes += Int((AppScanner.allocatedSize(url) ?? 0) * bytesPerGB)
                    continue
                }
                if v.isPackage == true {
                    e.skipDescendants()
                    // 照片图库由“照片”应用自己管，不进去统计：一读里面就会弹照片权限
                    if url.pathExtension == "photoslibrary" { continue }
                    // 应用、剪辑工程这类“包”当成一个整体
                    let size = AppScanner.allocatedSize(url) ?? 0
                    rootBytes += Int(size * bytesPerGB)
                    if size >= 50.0 / 1000 {
                        result.files.append(file(url, size: size, bytes: Int(size * bytesPerGB), modified: v.contentModificationDate, package: true))
                    }
                    continue
                }
                guard v.isRegularFile == true else { continue }
                let allocated = v.totalFileAllocatedSize ?? 0
                rootBytes += allocated
                let ext = url.pathExtension.lowercased()
                // 只留下后面会用到的：1 MB 以上的（大文件、久未打开），以及按后缀认的安装包、压缩包、截图、录屏
                let downloadable = downloadRoots.contains(root.dir) && (installerExts.contains(ext) || archiveExts.contains(ext))
                let interesting = allocated >= 1 << 20 || downloadable || captureExts.contains(ext)
                if interesting {
                    result.files.append(file(url, size: Double(allocated) / bytesPerGB, bytes: v.fileSize ?? allocated, modified: v.contentModificationDate, package: false))
                }
            }
            result.rootSizes.append((root.name, Double(rootBytes) / bytesPerGB))
        }
        return result
    }

    private static func file(_ url: URL, size: Double, bytes: Int, modified: Date?, package: Bool) -> File {
        var lastUsed: Date?
        if let item = MDItemCreateWithURL(nil, url as CFURL) {
            lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        }
        let ext = url.pathExtension.lowercased()
        let capture = screenshotExts.contains(ext) || recordingExts.contains(ext)
        return File(path: url.path, size: size, bytes: bytes, modified: modified ?? .distantPast,
                    lastUsed: lastUsed, isScreenCapture: capture, isPackage: package)
    }
}
