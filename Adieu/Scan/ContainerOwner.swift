import Foundation

/// 名字是一串 UUID 的沙盒容器（在 Mac 上跑的 iPhone/iPad 应用常这样）属于哪个应用。
/// 容器里的 .com.apple.containermanagerd.metadata.plist 记着它的标识符
enum ContainerOwner {
    static func isUUID(_ name: String) -> Bool { UUID(uuidString: name) != nil }

    /// 容器的标识符；读不到时为 nil
    static func bundleID(of container: URL) -> String? {
        let url = container.appending(path: ".com.apple.containermanagerd.metadata.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["MCMMetadataIdentifier"] as? String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: (library: String, date: Date, map: [String: String])?

    /// ~/Library/Containers 里 UUID 命名的容器：标识符 → 文件夹名。一分钟内重复用
    static func uuidContainers(library: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library")) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let cache, cache.library == library.path, Date.now.timeIntervalSince(cache.date) < 60 { return cache.map }
        var map: [String: String] = [:]
        let folder = library.appending(path: "Containers")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where isUUID(name) {
            if let id = bundleID(of: folder.appending(path: name)) { map[id] = name }
        }
        cache = (library.path, .now, map)
        return map
    }
}
