import Foundation

/// 删掉的文件的记录；以前移到废纸篓的带着废纸篓里的位置，够放回原处用
struct TrashedFile: Codable, Hashable, Sendable {
    let name: String
    let originalPath: String
    /// 废纸篓里的位置；系统没告诉我们时为 nil，此时不能自动放回
    let trashedPath: String?
    /// GB
    let size: Double?

    var isInTrash: Bool { trashedPath.map { FileManager.default.fileExists(atPath: $0) } ?? false }
}

/// 所有删除都走这里，先过安全检查。按用户要求一律直接删除，不经过废纸篓；
/// 以前的版本移到废纸篓的记录仍可以 restore 放回。
enum TrashService {
    enum Refusal: LocalizedError {
        case protected(String)
        case notAllowed(String)
        case missing

        var errorDescription: String? {
            switch self {
            case .protected(let p): "在保护名单里（\(p)），已跳过"
            case .notAllowed(let why): why
            case .missing: "文件已经不在了"
            }
        }
    }

    /// 默认保护：丢了很难找回的东西
    static let defaultProtected = ["~/.ssh", "~/.gnupg", "~/Library/Keychains", "~/Library/Mobile Documents",
                                   "~/Pictures/Photos Library.photoslibrary"]

    /// 在保护名单里（本身、里面、或包含名单里的东西）。只比路径，不碰磁盘
    static func isProtected(_ path: String, protected: [String]) -> Bool {
        protected.contains { raw in
            let p = (raw as NSString).expandingTildeInPath
            return path == p || path.hasPrefix(p + "/") || p.hasPrefix(path + "/")
        }
    }

    /// 检查一个路径能不能动。只允许：主目录里两层以下、/Applications 里、外置卷里两层以下，
    /// 以及 /Library/LaunchAgents、/Library/LaunchDaemons 里的单个 plist（清理已失效的后台程序）
    static func check(_ url: URL, protected: [String]) throws {
        let fm = FileManager.default
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard fm.fileExists(atPath: path) else { throw Refusal.missing }
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path

        for raw in protected {
            let p = URL(filePath: (raw as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
            if path == p || path.hasPrefix(p + "/") || p.hasPrefix(path + "/") { throw Refusal.protected(raw) }
        }

        let parts = path.split(separator: "/").map(String.init)
        let homeParts = home.split(separator: "/").map(String.init)
        if parts.starts(with: homeParts) {
            let rel = parts.dropFirst(homeParts.count)
            // 主目录本身和第一层（文稿、下载、资源库…）不动；资源库里再多一层（Caches、Containers 本身）也不动
            if rel.count < 2 || (rel.first == "Library" && rel.count < 3) {
                throw Refusal.notAllowed("这是系统需要的文件夹，不能删除")
            }
            return
        }
        if parts.first == "Applications", parts.count >= 2 { return }
        if parts.first == "Volumes", parts.count >= 3 { return }
        if parts.count == 3, parts[0] == "Library", ["LaunchAgents", "LaunchDaemons"].contains(parts[1]), path.hasSuffix(".plist") { return }
        throw Refusal.notAllowed("不在 Adieu 允许清理的范围内（只处理主目录、应用程序和外置硬盘）")
    }

    struct Outcome {
        var done: [TrashedFile] = []
        var failed: [(name: String, reason: String)] = []
        /// 通过了安全检查、只是权限不够的（如 App Store 装的应用归 root 所有），可以输管理员密码再移
        var needsAdmin: [URL] = []
    }

    /// 直接删除，不经过废纸篓。已经不在的直接跳过，权限不够的交给 deleteAsAdmin
    static func delete(_ urls: [URL], sizes: [String: Double] = [:], protected: [String]) -> Outcome {
        var out = Outcome()
        for url in urls {
            let name = url.lastPathComponent
            do {
                try check(url, protected: protected)
                let size = sizes[url.path] ?? AppScanner.allocatedSize(url)
                try FileManager.default.removeItem(at: url)
                out.done.append(TrashedFile(name: name, originalPath: url.path, trashedPath: nil, size: size))
            } catch Refusal.missing {
                continue
            } catch let r as Refusal {
                out.failed.append((name, r.localizedDescription))
            } catch {
                let ns = error as NSError
                if ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError
                    || (ns.underlyingErrors.first as NSError?)?.code == Int(EACCES) || (ns.underlyingErrors.first as NSError?)?.code == Int(EPERM) {
                    out.needsAdmin.append(url)
                } else {
                    out.failed.append((name, ns.localizedDescription))
                }
            }
        }
        return out
    }

    /// 用管理员身份删除（系统弹出密码窗口，只问一次）。路径照样先过安全检查
    static func deleteAsAdmin(_ urls: [URL], sizes: [String: Double] = [:], protected: [String]) -> Outcome {
        let targets = urls.filter { (try? check($0, protected: protected)) != nil }
        let jobs = targets.map { (src: $0, size: sizes[$0.path] ?? AppScanner.allocatedSize($0)) }
        guard !jobs.isEmpty else { return Outcome() }
        let shell = jobs.map { "/bin/rm -rf \(quote($0.src.path))" }.joined(separator: "; ")
        let cancelled = runAsAdmin(shell, prompt: "Adieu 要删除 \(displayNames(targets))。它们归系统管理员所有，需要输入你的开机密码。")
        var out = Outcome()
        for j in jobs {
            if !FileManager.default.fileExists(atPath: j.src.path) {
                out.done.append(TrashedFile(name: j.src.lastPathComponent, originalPath: j.src.path, trashedPath: nil, size: j.size))
            } else {
                out.failed.append((j.src.lastPathComponent, cancelled ? "没有输入管理员密码，留在原处" : "用管理员身份也没能删除"))
            }
        }
        return out
    }

    private static func quote(_ s: String) -> String { "'" + s.replacing("'", with: "'\\''") + "'" }

    private static func displayNames(_ urls: [URL]) -> String {
        urls.map { "“\($0.deletingPathExtension().lastPathComponent)”" }.joined(separator: "、")
    }

    /// 通过 osascript 的 “with administrator privileges” 运行，系统自己弹密码窗口，Adieu 碰不到密码。返回用户是否点了取消
    private static func runAsAdmin(_ shell: String, prompt: String) -> Bool {
        func esc(_ s: String) -> String { s.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") }
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script \"\(esc(shell))\" with prompt \"\(esc(prompt))\" with administrator privileges"]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return message.contains("-128")
    }

    /// 从废纸篓放回原处；原位置已经有同名文件时不覆盖
    static func restore(_ f: TrashedFile) throws {
        guard let from = f.trashedPath, FileManager.default.fileExists(atPath: from) else {
            throw Refusal.notAllowed("“\(f.name)”已经不在废纸篓里了")
        }
        if FileManager.default.fileExists(atPath: f.originalPath) {
            // 归档时留下的替身：先把替身移到废纸篓，再放回原件
            let existing = URL(filePath: f.originalPath)
            if (try? existing.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true {
                try FileManager.default.trashItem(at: existing, resultingItemURL: nil)
            } else {
                throw Refusal.notAllowed("原位置已经有一个“\(f.name)”，没有覆盖")
            }
        }
        let parent = URL(filePath: f.originalPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: from, toPath: f.originalPath)
    }
}
