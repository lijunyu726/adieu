import Foundation

enum CloudDriveScanner {
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
    }

    private static let keys: Set<URLResourceKey> = [
        .isRegularFileKey, .isSymbolicLinkKey, .isUbiquitousItemKey, .totalFileAllocatedSizeKey,
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
        for case let url as URL in entries {
            do {
                if let file = try inspect(url, under: root, refresh: false) { files.append(file) }
            } catch {
                unreadable += 1
            }
        }
        if let rootError { throw rootError }
        files.sort {
            if $0.allocatedBytes != $1.allocatedBytes { return $0.allocatedBytes > $1.allocatedBytes }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        return .init(files: files, unreadable: unreadable)
    }

    static func inspect(_ url: URL, under root: URL, refresh: Bool = true) throws -> CloudDriveFile? {
        var canonical = url.standardizedFileURL
        let prefix = root.standardizedFileURL.path + "/"
        guard canonical.path.hasPrefix(prefix) else { return nil }
        if refresh { canonical.removeAllCachedResourceValues() }
        let values = try canonical.resourceValues(forKeys: keys)
        guard values.isRegularFile == true, values.isSymbolicLink == false else { return nil }
        let state = state(values)
        let bytes = state == .onlineOnly ? 0 : max(0, values.totalFileAllocatedSize ?? 0)
        return .init(url: canonical, relativePath: String(canonical.path.dropFirst(prefix.count)),
                     state: state, allocatedBytes: bytes,
                     identity: bytes > 0 && state == .downloadableCopy ? TrashService.fileIdentity(at: canonical) : nil)
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
