import Darwin
import Foundation

enum CloudDriveOrganization {
    enum Change: Sendable {
        case createFolder(name: String, in: CloudDriveFolder)
        case rename(CloudDriveFile, name: String)
        case move([CloudDriveFile], to: CloudDriveFolder)
    }

    struct Outcome: Sendable {
        var completed = 0
        var failed: [(path: String, reason: String)] = []
    }

    enum Refusal: LocalizedError {
        case name, changed, conflict, alreadyThere

        var errorDescription: String? {
            switch self {
            case .name: String(localized: "请输入有效的名称。")
            case .changed: String(localized: "文件或文件夹已变化，请刷新后重试。")
            case .conflict: String(localized: "目标位置已有同名项目。")
            case .alreadyThere: String(localized: "文件已在此位置。")
            }
        }
    }

    static func apply(_ change: Change, protected: [String], root: URL = CloudDriveScanner.root) -> Outcome {
        var outcome = Outcome()
        func perform(_ path: String, _ work: () throws -> Void) {
            do {
                try work()
                outcome.completed += 1
            } catch {
                outcome.failed.append((path, error.localizedDescription))
            }
        }
        switch change {
        case .createFolder(let name, let folder):
            perform(name) { try createFolder(name, in: folder, root: root, protected: protected) }
        case .rename(let file, let name):
            perform(file.relativePath) {
                try move(file, to: file.url.deletingLastPathComponent(), name: name,
                         folder: nil, root: root, protected: protected)
            }
        case .move(let files, let folder):
            for file in files {
                perform(file.relativePath) {
                    try move(file, to: folder.url, name: file.url.lastPathComponent,
                             folder: folder, root: root, protected: protected)
                }
            }
        }
        return outcome
    }

    static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !name.hasPrefix(".") && !name.contains("/") && !name.contains(":") &&
            name.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func createFolder(_ name: String, in folder: CloudDriveFolder,
                                     root: URL, protected: [String]) throws {
        let url = try destination(name, in: folder.url)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationError: (any Error)?
        coordinator.coordinate(writingItemAt: folder.url, options: .contentIndependentMetadataOnly,
                               error: &coordinationError) { coordinatedFolder in
            do {
                try validateFolder(coordinatedFolder, expected: folder, root: root)
                try validateDestination(url, in: coordinatedFolder, protected: protected)
                guard mkdir(url.path, 0o777) == 0 else { throw fileError() }
            } catch {
                operationError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
    }

    private static func move(_ file: CloudDriveFile, to parent: URL, name: String, folder: CloudDriveFolder?,
                             root: URL, protected: [String]) throws {
        let url = try destination(name, in: parent)
        guard file.url.path != url.path else { throw Refusal.alreadyThere }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationError: (any Error)?
        coordinator.coordinate(writingItemAt: file.url, options: .forMoving,
                               writingItemAt: url, options: [], error: &coordinationError) { source, target in
            do {
                // 协调期间外部改名或替换路径时，保留原确认范围。
                guard source.path == file.url.path, target.path == url.path,
                      source.resolvingSymlinksInPath().path == source.path,
                      let current = try CloudDriveScanner.inspect(source, under: root),
                      current.canOrganize, current.identity == file.identity else { throw Refusal.changed }
                try validateFolder(parent, expected: folder, root: root)
                try TrashService.check(source, protected: protected)
                try validateDestination(target, in: parent, protected: protected)
                coordinator.item(at: source, willMoveTo: target)
                // 同卷改名可移动占位文件，RENAME_EXCL 原子地拒绝覆盖。
                guard renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 else { throw fileError() }
                coordinator.item(at: source, didMoveTo: target)
            } catch {
                operationError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
    }

    private static func destination(_ name: String, in parent: URL) throws -> URL {
        guard validName(name) else { throw Refusal.name }
        return parent.appending(path: name, directoryHint: .notDirectory)
    }

    private static func validateFolder(_ url: URL, expected: CloudDriveFolder?, root: URL) throws {
        guard (url.path == root.path || CloudDriveScanner.relativePath(of: url, under: root) != nil),
              url.resolvingSymlinksInPath().path == url.path else { throw Refusal.changed }
        let values = try URL(filePath: url.path).resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        guard values.isDirectory == true, values.isPackage == false,
              expected.map({ $0.url.path == url.path && TrashService.fileIdentity(at: url) == $0.identity }) ?? true
        else { throw Refusal.changed }
    }

    private static func validateDestination(_ url: URL, in parent: URL, protected: [String]) throws {
        guard url.deletingLastPathComponent().path == parent.path else { throw Refusal.changed }
        // check 无法检查尚不存在的路径，所以核对目标的保护名单和父目录边界。
        if TrashService.isProtected(url.path, protected: protected) {
            throw TrashService.Refusal.protected(url.path)
        }
        if TrashService.fileIdentity(at: url) != nil { throw Refusal.conflict }
        try TrashService.check(parent, protected: [])
    }

    private static func fileError() -> any Error {
        let code = errno
        return code == EEXIST ? Refusal.conflict : NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
