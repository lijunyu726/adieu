import Foundation

enum CloudDriveScanner {
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
    }

    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isPackageKey, .isRegularFileKey, .isSymbolicLinkKey, .isUbiquitousItemKey, .totalFileAllocatedSizeKey,
        .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemIsDownloadingKey,
        .ubiquitousItemDownloadingStatusKey, .ubiquitousItemHasUnresolvedConflictsKey,
        .ubiquitousItemUploadingErrorKey, .ubiquitousItemDownloadingErrorKey, .isPurgeableKey
    ]

    static func scan(root: URL = root) throws -> CloudDriveScan {
        let fm = FileManager.default
        do {
            guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                return .init(files: [], unreadable: 0)
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .init(files: [], unreadable: 0)
        }

        var unreadable = 0
        var rootError: (any Error)?
        guard let entries = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in
            if url.path == root.path { rootError = error }
            unreadable += 1
            return url.path != root.path
        }) else { throw CocoaError(.fileReadUnknown) }

        var files: [CloudDriveFile] = []
        var folders: [CloudDriveFolder] = []
        if let identity = TrashService.fileIdentity(at: root) {
            folders.append(.init(url: root, relativePath: "", identity: identity))
        }
        for case let url as URL in entries {
            do {
                let values = try url.resourceValues(forKeys: keys)
                if values.isDirectory == true, values.isPackage == false, values.isSymbolicLink == false,
                   let path = relativePath(of: url, under: root), let identity = TrashService.fileIdentity(at: url) {
                    folders.append(.init(url: url, relativePath: path, identity: identity))
                } else if let file = file(at: url, under: root, values: values) {
                    files.append(file)
                }
            } catch {
                unreadable += 1
            }
        }
        if let rootError { throw rootError }
        files.sort {
            if $0.allocatedBytes != $1.allocatedBytes { return $0.allocatedBytes > $1.allocatedBytes }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        folders.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return .init(files: files, unreadable: unreadable, folders: folders)
    }

    static func inspect(_ url: URL, under root: URL) throws -> CloudDriveFile? {
        var fresh = URL(filePath: url.path)
        fresh.removeAllCachedResourceValues()
        return file(at: fresh, under: root, values: try fresh.resourceValues(forKeys: keys))
    }

    static func relativePath(of url: URL, under root: URL) -> String? {
        let prefix = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }

    private static func file(at url: URL, under root: URL, values: URLResourceValues) -> CloudDriveFile? {
        guard values.isRegularFile == true, values.isSymbolicLink == false,
              let path = relativePath(of: url, under: root) else { return nil }
        let state = state(values)
        let bytes = state == .onlineOnly ? 0 : max(0, values.totalFileAllocatedSize ?? 0)
        return .init(url: url, relativePath: path, state: state, allocatedBytes: bytes,
                     identity: values.isUbiquitousItem == true ? TrashService.fileIdentity(at: url) : nil)
    }

    static func state(_ values: URLResourceValues) -> CloudDriveFile.State {
        classify(ubiquitous: values.isUbiquitousItem, download: values.ubiquitousItemDownloadingStatus,
                 uploaded: values.ubiquitousItemIsUploaded, uploading: values.ubiquitousItemIsUploading,
                 downloading: values.ubiquitousItemIsDownloading,
                 conflicts: values.ubiquitousItemHasUnresolvedConflicts,
                 hasError: values.ubiquitousItemUploadingError != nil || values.ubiquitousItemDownloadingError != nil,
                 purgeable: values.isPurgeable)
    }

    static func classify(ubiquitous: Bool?, download: URLUbiquitousItemDownloadingStatus?,
                         uploaded: Bool?, uploading: Bool?, downloading: Bool?, conflicts: Bool?,
                         hasError: Bool, purgeable: Bool?) -> CloudDriveFile.State {
        guard ubiquitous == true else { return .unknown }
        if uploaded == false || uploading == true || downloading == true || conflicts == true || hasError { return .syncing }
        if download == .downloaded { return .syncing }
        if download == .notDownloaded { return .onlineOnly }
        guard download == .current, uploaded == true, uploading == false,
              downloading == false, conflicts == false, let purgeable else { return .unknown }
        return purgeable ? .downloadableCopy : .retainedCopy
    }
}
