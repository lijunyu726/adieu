import Foundation
import Security
import AppKit

/// 应用包里实际声明的组件与共享组。只读代码目录，不遍历 Resources 或用户数据。
struct AppBundleIndex {
    struct Application {
        let url: URL
        let id: String
        var bundleIDs: Set<String>
        var groupIDs: Set<String>
        var groupMembers: [String: Set<String>] = [:]
    }

    let applications: [Application]
    private var bundleOwners: [String: Set<String>] = [:]
    private var groupOwners: [String: Set<String>] = [:]

    init(urls: [URL], runningURLs: [URL] = [], readGroups: (URL) -> Set<String> = AppBundleIndex.groups) {
        var seen: Set<String> = []
        let listed = urls.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        // 运行中的扩展、助手程序就在已列出的应用包里，归那个应用，不另算一个
        let outside = runningURLs.filter { url in
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            return !listed.contains { path.hasPrefix($0 + "/") }
        }
        applications = (urls + outside).compactMap { url in
            let url = url.standardizedFileURL.resolvingSymlinksInPath()
            guard seen.insert(url.path).inserted else { return nil }
            return Self.application(at: url, readGroups: readGroups)
        }
        for app in applications {
            for id in app.bundleIDs { bundleOwners[id.lowercased(), default: []].insert(app.url.path) }
            for id in app.groupIDs { groupOwners[id.lowercased(), default: []].insert(app.url.path) }
        }
    }

    static func runningURLs() -> [URL] {
        NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)
    }

    static func current(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        runningURLs: [URL] = AppBundleIndex.runningURLs()) -> AppBundleIndex {
        AppBundleIndex(urls: roots(home: home).flatMap { installed(in: $0) }, runningURLs: runningURLs)
    }

    func ownerIDs(bundleID: String) -> Set<String> {
        let paths = bundleOwners[bundleID.lowercased(), default: []]
        return Set(applications.filter { paths.contains($0.url.path) }.map(\.id)).union([bundleID])
    }

    func ownerIDs(groupID: String) -> Set<String> {
        let key = groupID.lowercased()
        let paths = groupOwners[key, default: []]
        return applications.filter { paths.contains($0.url.path) }.reduce(into: Set<String>()) { ids, app in
            ids.insert(app.id)
            ids.formUnion(app.groupMembers[key, default: []])
        }
    }

    func otherAppsUse(bundleID: String, than app: Application) -> Bool {
        bundleOwners[bundleID.lowercased(), default: []].contains { $0 != app.url.path }
    }

    func otherAppsUse(groupID: String, than app: Application) -> Bool {
        groupOwners[groupID.lowercased(), default: []].contains { $0 != app.url.path }
    }

    static func roots(home: URL) -> [URL] {
        [URL(filePath: "/Applications"), home.appending(path: "Applications"), URL(filePath: "/System/Applications")]
            + InputMethods.roots(home: home)
    }

    /// Applications 中普通文件夹再看一层，不进入已经找到的应用包。
    static func installed(in dir: URL, depth: Int = 1) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                               options: [.skipsHiddenFiles])) ?? []
        return urls.sorted { $0.path < $1.path }.flatMap { url -> [URL] in
            if url.pathExtension == "app" { return [url] }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDir && depth > 0 ? installed(in: url, depth: depth - 1) : []
        }
    }

    /// 标识符只用作单个路径分量；不接受路径、通配符和上级目录。
    static func validIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id != "." && id != ".." && id.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
        }
    }

    private static func application(at root: URL, readGroups: (URL) -> Set<String>) -> Application? {
        guard let id = Bundle(url: root)?.bundleIdentifier, validIdentifier(id) else { return nil }
        var app = Application(url: root, id: id, bundleIDs: [id], groupIDs: [])
        var visited: Set<String> = []
        let fm = FileManager.default
        let codeDirs = ["MacOS", "PlugIns", "XPCServices", "Helpers", "Library", "Frameworks", "SharedFrameworks"]

        func visit(_ url: URL, depth: Int) {
            let url = url.standardizedFileURL.resolvingSymlinksInPath()
            guard depth < 24, url.path == root.path || url.path.hasPrefix(root.path + "/"),
                  visited.insert(url.path).inserted,
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return }
            if ["app", "appex", "xpc"].contains(url.pathExtension) {
                if let childID = Bundle(url: url)?.bundleIdentifier, validIdentifier(childID) {
                    app.bundleIDs.insert(childID)
                    let groups = readGroups(url).filter(validIdentifier)
                    app.groupIDs.formUnion(groups)
                    for group in groups { app.groupMembers[group.lowercased(), default: []].insert(childID) }
                }
                for name in codeDirs { visit(url.appending(path: "Contents/" + name), depth: depth + 1) }
            } else {
                // framework 的多版本目录和嵌套 Helpers 也在代码目录内；跳过资源、头文件。
                let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles])) ?? []
                for child in children where !["Resources", "Headers", "PrivateHeaders", "Modules"].contains(child.lastPathComponent) {
                    visit(child, depth: depth + 1)
                }
            }
        }
        visit(root, depth: 0)
        return app
    }

    /// 直接读签名元数据，不启动 codesign 子进程，也不校验整个应用的文件内容。
    private static func groups(_ url: URL) -> Set<String> {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return [] }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSRequirementInformation), &information) == errSecSuccess,
              let dict = information as? [String: Any],
              let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else { return [] }
        return Set(groups.filter(validIdentifier))
    }
}
