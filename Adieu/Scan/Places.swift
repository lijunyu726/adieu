import AppKit
import Foundation

/// 搬家页左右两栏能选的位置：这台 Mac（主目录）、iCloud Drive 和插着的外接硬盘
struct Place: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case home, cloud, volume }

    let root: URL
    let name: String
    let kind: Kind
    /// 字节
    let total: Int64?
    let free: Int64?
    /// 文件系统类型（statfs 的 f_fstypename）：apfs、hfs、exfat、msdos、ntfs…
    let fsType: String
    /// 给人看的格式名，如“APFS”“ExFAT”
    let format: String
    let readOnly: Bool
    let ejectable: Bool

    var id: String { root.path }

    var symbol: String {
        switch kind {
        case .home: "laptopcomputer"
        case .cloud: "icloud"
        case .volume: "externaldrive"
        }
    }

    /// 格式带来的限制，界面上写在位置名下面
    var limitNote: String? {
        if readOnly {
            return fsType == "ntfs" || fsType == "ufsd_NTFS"
                ? String(localized: "NTFS 格式，macOS 只能读不能写") : String(localized: "只读，不能往里放东西")
        }
        if fsType == "msdos" { return String(localized: "FAT32 格式，单个文件不能超过 4 GB") }
        return nil
    }
}

enum Places {
    /// 主目录 + /Volumes 下的外接盘（不含系统卷和隐藏卷）
    static func list() -> [Place] {
        let fm = FileManager.default
        var result: [Place] = []
        let home = fm.homeDirectoryForCurrentUser
        if let mac = info(home, kind: .home, name: String(localized: "这台 Mac")) { result.append(mac) }
        let cloud = CloudDriveScanner.root
        if fm.fileExists(atPath: cloud.path), let drive = info(cloud, kind: .cloud, name: "iCloud Drive") { result.append(drive) }
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey]
        let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        for url in volumes where url.path.hasPrefix("/Volumes/") {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.volumeIsRootFileSystem == true { continue }
            if let place = info(url, kind: .volume, name: values?.volumeName ?? url.lastPathComponent) { result.append(place) }
        }
        return result
    }

    /// 某个路径所在的位置（用来判断跨不跨盘、目标盘的格式和剩余空间）
    static func containing(_ url: URL, in places: [Place]) -> Place? {
        let path = url.standardizedFileURL.path
        return places.filter { path == $0.root.path || path.hasPrefix($0.root.path + "/") }
            .max { $0.root.path.count < $1.root.path.count }
    }

    static func info(_ url: URL, kind: Place.Kind, name: String) -> Place? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeIsReadOnlyKey, .volumeIsEjectableKey, .volumeLocalizedFormatDescriptionKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        var fs = statfs()
        let type = statfs(url.path, &fs) == 0
            ? withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } : ""
        // 系统盘的可用空间按“重要用途”算，跟访达显示的一致（含可清除空间）
        let free = kind != .volume ? values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init)
                                 : values.volumeAvailableCapacity.map(Int64.init)
        return Place(root: url.standardizedFileURL, name: name, kind: kind,
                     total: values.volumeTotalCapacity.map(Int64.init), free: free,
                     fsType: type, format: values.volumeLocalizedFormatDescription ?? type,
                     readOnly: values.volumeIsReadOnly ?? false, ejectable: values.volumeIsEjectable ?? false)
    }
}

/// 文件夹里的一项
struct FolderItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    /// 能点进去的文件夹（应用包等“包”算文件）
    let isFolder: Bool
    let isLink: Bool
    /// 文件的大小（字节）；文件夹不算，太慢
    let size: Int64?
    let modified: Date?
    /// 只在云端、还没下载到这台 Mac
    var isDataless = false
    /// 搜索结果里显示相对路径
    var detail: String? = nil

    var id: String { url.path }
}

enum FolderListing {
    static func list(_ folder: URL) throws -> [FolderItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        return urls.compactMap(item).sorted(by: order)
    }

    /// 在文件夹里按名字往下搜，最多 limit 个
    static func search(_ folder: URL, query: String, limit: Int = 300) -> [FolderItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [FolderItem] = []
        for case let url as URL in e {
            guard url.lastPathComponent.localizedCaseInsensitiveContains(query), var it = item(url) else { continue }
            let rel = url.deletingLastPathComponent().path.dropFirst(folder.path.count).drop { $0 == "/" }
            it.detail = rel.isEmpty ? nil : String(rel)
            found.append(it)
            if found.count >= limit { break }
        }
        return found.sorted(by: order)
    }

    private static func item(_ url: URL) -> FolderItem? {
        guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        else { return nil }
        let folder = v.isDirectory == true && v.isPackage != true && v.isSymbolicLink != true
        // 文件夹用访达里的名字（“Desktop”显示成“桌面”）；文件不用，免得隐藏了扩展名
        let name = folder ? FileManager.default.displayName(atPath: url.path) : url.lastPathComponent
        var info = stat()
        let dataless = lstat(url.path, &info) == 0 && info.st_flags & FileMover.datalessFlag != 0
        return FolderItem(url: url, name: name, isFolder: folder, isLink: v.isSymbolicLink == true,
                          size: folder ? nil : v.fileSize.map(Int64.init), modified: v.contentModificationDate,
                          isDataless: dataless)
    }

    private static func order(_ a: FolderItem, _ b: FolderItem) -> Bool {
        a.isFolder != b.isFolder ? a.isFolder : a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}
