import Foundation

// 命令行验证不编译窗口；与 RootView 的导航值保持一致。
enum AppSection: String, Hashable, Sendable {
    case home, apps, leftovers, launch, installers, captures, bigFiles, stale, devTools
}

@main
@MainActor
struct AppScannerTests {
    static let fm = FileManager.default

    static func main() throws {
        let root = URL(filePath: fm.currentDirectoryPath).appending(path: "scratch/app-scanner-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        inputMethods(root: root)
        try namedData(root: root)
        let home = root.appending(path: "home")
        let main = try bundle(root.appending(path: "Main.app"), id: "com.example.Main")
        let sibling = try bundle(root.appending(path: "Sibling.app"), id: "com.example.Sibling")
        _ = try bundle(main.appending(path: "Contents/PlugIns/Share.appex"), id: "com.example.Main.Share")
        _ = try bundle(main.appending(path: "Contents/MacOS/Helper.app"), id: "com.other.Helper")
        _ = try bundle(main.appending(path: "Contents/Frameworks/Engine.framework/Versions/A/Helpers/Renderer.app"), id: "com.engine.Renderer")
        _ = try bundle(main.appending(path: "Contents/Helpers/Updater.app"), id: "org.updater.Shared")
        _ = try bundle(sibling.appending(path: "Contents/Helpers/Updater.app"), id: "org.updater.Shared")
        _ = try bundle(main.appending(path: "Contents/Resources/Example.app"), id: "com.ignore.Resource")
        let outside = try bundle(root.appending(path: "Outside.appex"), id: "com.ignore.Outside")
        try fm.createSymbolicLink(at: main.appending(path: "Contents/PlugIns/Escape.appex"), withDestinationURL: outside)

        let declared = "group.org.suite.Shared"
        let scriptsOnly = "group.org.suite.ScriptsOnly"
        let index = AppBundleIndex(urls: [main, sibling, main]) { url in
            if url == main { return [declared, scriptsOnly, "../bad", "*"] }
            return url == sibling ? [declared] : []
        }
        precondition(index.applications.count == 2, "Duplicate paths must not create another owner")
        let withRunning = AppBundleIndex(urls: [main, sibling], runningURLs: [main.appending(path: "Contents/MacOS/Helper.app")]) { _ in [] }
        precondition(withRunning.applications.count == 2 && !withRunning.otherAppsUse(bundleID: "com.other.Helper", than: withRunning.applications[0]),
                     "A running helper inside a listed app must not become a second owner")
        let app = index.applications.first { $0.id == "com.example.Main" }!
        precondition(app.bundleIDs.contains("com.other.Helper") && app.bundleIDs.contains("com.engine.Renderer"))
        precondition(!app.bundleIDs.contains("com.ignore.Resource") && !app.bundleIDs.contains("com.ignore.Outside"))
        precondition(!app.groupIDs.contains("../bad") && !app.groupIDs.contains("*"))

        let expected = [
            "Containers/com.example.Main", "Containers/com.example.Main.Share",
            "Containers/com.other.Helper", "Caches/com.engine.Renderer", "Caches/org.updater.Shared",
            "Group Containers/ABCDE12345.com.example.Main", "Group Containers/\(declared)",
            "Application Scripts/com.example.Main", "Application Scripts/com.example.Main.Share",
            "Application Scripts/ABCDE12345.com.example.Main", "Application Scripts/\(declared)",
            "Application Scripts/\(scriptsOnly)"
        ]
        for sub in expected { try fm.createDirectory(at: home.appending(path: "Library/" + sub), withIntermediateDirectories: true) }
        let nested = home.appending(path: "Library/Containers/com.example.Main/Data/Documents/database.db")
        try fm.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 8192).write(to: nested)
        try fm.createDirectory(at: home.appending(path: "Library/Containers/com.example.Main.Lookalike"), withIntermediateDirectories: true)
        let keep = home.appending(path: "Library/Application Support/com.other.Keep")
        try fm.createDirectory(at: keep, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.appending(path: "Library/Caches/com.example.Main"), withDestinationURL: keep)

        let parts = AppScanner.dataParts(for: app, index: index, home: home)
        precondition(Set(parts.map(\.path)) == Set(expected.map { "~/Library/" + $0 }), "Every real component and scripts directory must be listed exactly once")
        precondition(Set(parts.map(\.id)).count == parts.count, "Part IDs must stay unique")
        precondition(parts == AppScanner.dataParts(for: app, index: index, home: home), "Ordering and IDs must stay stable across scans")
        for part in parts {
            let shared = part.path.contains(declared) || part.path.hasSuffix("org.updater.Shared")
            precondition(part.defaultOn == !shared && part.evidence == (shared ? .shared : .exact))
            if shared {
                precondition(part.ownerIDs.isSuperset(of: ["com.example.Main", "com.example.Sibling"]), "All known owners must travel with shared data")
            }
        }
        let ownedPart = parts.first { $0.path.hasSuffix(declared) }!
        let absolutePart = AppPart(id: ownedPart.id, kind: ownedPart.kind, label: ownedPart.label,
                                   path: home.appending(path: String(ownedPart.path.dropFirst(2))).path,
                                   size: nil, evidence: ownedPart.evidence, defaultOn: ownedPart.defaultOn, ownerIDs: ownedPart.ownerIDs)
        let measuredApp = AppScanner.measured(.init(id: app.id, name: "Fixture", monogram: "F", color: .gray,
                                                   meta: "fixture", parts: [absolutePart]))
        precondition(measuredApp.parts[0].ownerIDs == ownedPart.ownerIDs, "Size measurement must preserve ownership")
        let unchanged = try Data(contentsOf: nested)
        precondition(unchanged.count == 8192, "Scanning must leave user data untouched")
        let linkedHome = root.appending(path: "linked-home")
        try fm.createDirectory(at: linkedHome, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkedHome.appending(path: "Library"), withDestinationURL: home.appending(path: "Library"))
        let linkedParts = AppScanner.dataParts(for: app, index: index, home: linkedHome)
        precondition(Set(linkedParts.map(\.path)) == Set(expected.map { home.appending(path: "Library/" + $0).path }), "A relocated Library must retain valid absolute paths")

        try leftovers(home: home, index: index)
        try signedGroups(root: root)
        let selected = parts.filter(\.defaultOn).map { home.appending(path: String($0.path.dropFirst(2))) }
        let deleted = TrashService.delete(selected, protected: [])
        precondition(deleted.failed.isEmpty && deleted.needsAdmin.isEmpty && deleted.done.count == selected.count)
        precondition(!fm.fileExists(atPath: nested.path))
        for part in parts where !part.defaultOn {
            precondition(fm.fileExists(atPath: home.appending(path: String(part.path.dropFirst(2))).path), "Shared data must remain after deleting the default selection")
        }
        precondition(fm.fileExists(atPath: keep.path), "A symlink must never pull its unrelated target into deletion")
        print("App scanner tests passed: embedded IDs, scripts, shared ownership, symlink boundaries, stable deduplication, leftovers, signed app groups and deletion of the default selection.")
    }

    /// 按应用包里写的名字找数据：整名相等、不分大小写；短名字、通用词、和别的应用同名的都不用
    static func namedData(root: URL) throws {
        let base = root.appending(path: "named")
        let home = base.appending(path: "home")
        let support = home.appending(path: "Library/Application Support"), caches = home.appending(path: "Library/Caches")
        for dir in [support.appending(path: "WeType"), caches.appending(path: "wetype"), support.appending(path: "WeType Pro"),
                    support.appending(path: "Twins"), support.appending(path: "Helper"), support.appending(path: "Duo"),
                    support.appending(path: "com.named.WeType")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        func app(_ file: String, id: String, name: String) throws -> URL {
            let url = try bundle(base.appending(path: file), id: id)
            let info = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL", "CFBundleExecutable": name]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appending(path: "Contents/Info.plist"))
            return url
        }
        let wetype = try app("微信输入法.app", id: "com.named.WeType", name: "WeType")
        let twinA = try app("TwinA.app", id: "com.named.TwinA", name: "Twins")
        let twinB = try app("TwinB.app", id: "com.named.TwinB", name: "Twins")
        let helper = try app("Helper.app", id: "com.named.Helper", name: "Helper")
        let duo = try app("Duo.app", id: "com.named.Duo", name: "Duo")
        let index = AppBundleIndex(urls: [wetype, twinA, twinB, helper, duo]) { _ in [] }
        func paths(_ url: URL) -> [String: Evidence] {
            let app = index.applications.first { $0.url == url.standardizedFileURL.resolvingSymlinksInPath() }!
            return Dictionary(uniqueKeysWithValues: AppScanner.dataParts(for: app, index: index, home: home).map { ($0.path, $0.evidence) })
        }
        let found = paths(wetype)
        let library = "~/Library"
        precondition(found[library + "/Application Support/WeType"] == .name && found[library + "/Caches/wetype"] == .name,
                     "Folders named exactly like the bundle name must be found, ignoring case")
        precondition(found[library + "/Application Support/com.named.WeType"] == .exact, "An identifier match keeps its stronger evidence")
        precondition(found[library + "/Application Support/WeType Pro"] == nil, "Only whole-name matches count")
        precondition(found.count == 3)
        precondition(paths(twinA).isEmpty && paths(twinB).isEmpty, "A name shared by two installed apps belongs to neither")
        precondition(paths(helper).isEmpty, "Common words are never used as names")
        precondition(paths(duo).isEmpty, "Names shorter than five characters are never used")
        precondition(AppBundleIndex.matchNames(wetype) == ["wetype"], "Localized file names (non-ASCII) are not used")
    }

    static func inputMethods(root: URL) {
        let inFolder = URL(filePath: "/Library/Input Methods/Some.app")
        precondition(InputMethods.isInputMethod(inFolder, info: nil), "Bundles in an Input Methods folder are input methods")
        precondition(InputMethods.isInputMethod(root.appending(path: "Any.app"), info: ["tsInputModeListKey": [:]]))
        precondition(!InputMethods.isInputMethod(URL(filePath: "/Applications/Plain.app"), info: ["LSUIElement": true]))
        precondition(InputMethods.roots(home: URL(filePath: "/Users/x")).map(\.path) == ["/Library/Input Methods", "/Users/x/Library/Input Methods"])
        precondition(AppBundleIndex.roots(home: URL(filePath: "/Users/x")).contains(URL(filePath: "/Library/Input Methods")),
                     "Data of installed input methods must not be reported as leftovers")
        // 只放行输入法文件夹里的单个应用包，文件夹本身不行
        for path in try! fm.contentsOfDirectory(atPath: "/Library/Input Methods") where path.hasSuffix(".app") {
            precondition((try? TrashService.check(URL(filePath: "/Library/Input Methods/" + path), protected: [])) != nil)
        }
        precondition((try? TrashService.check(URL(filePath: "/Library/Input Methods"), protected: [])) == nil)
    }

    static func leftovers(home: URL, index: AppBundleIndex) throws {
        let old = Date(timeIntervalSinceNow: -90 * 86400)
        let orphanPaths = ["Application Scripts/com.gone.Orphan", "Group Containers/ABCDE12345.com.gone.Orphan"]
        let freshPath = "Application Scripts/com.fresh.Orphan"
        let runningPath = "Group Containers/group.com.running.App"
        let installedPath = "Application Scripts/com.elsewhere.App"
        let protectedPaths = ["Application Scripts/group.org.suite.Shared", "Containers/com.other.Helper"]
        for sub in orphanPaths + [freshPath, runningPath, installedPath] + protectedPaths {
            let dir = home.appending(path: "Library/" + sub)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 0x42, count: 1_100_000).write(to: dir.appending(path: "fixture"))
            if sub != freshPath { try fm.setAttributes([.modificationDate: old], ofItemAtPath: dir.path) }
        }
        let owners = LeftoverScanner.owners(index: index)
        precondition(owners.ids.contains("com.other.Helper") && owners.groups.contains("group.org.suite.shared"))
        let items = LeftoverScanner.dataItems(home: home, owners: owners, running: ["com.running.App"],
                                             applicationExists: { $0 == "com.elsewhere.App" })
        let orphan = items.first { $0.id == "com.gone.Orphan" }!
        precondition(orphan.paths.count == 2 && orphan.defaultOn)
        precondition(items.first { $0.id == "com.fresh.Orphan" }?.defaultOn == false)
        let reported = Set(items.flatMap(\.paths))
        for sub in [runningPath, installedPath] + protectedPaths {
            precondition(!reported.contains(home.appending(path: "Library/" + sub).path))
        }
    }

    /// 用真实的临时签名确认 Security API 能读到 App Groups，而非仅验证注入的测试数据。
    static func signedGroups(root: URL) throws {
        let app = try bundle(root.appending(path: "Signed.app"), id: "com.signed.Fixture")
        let executable = app.appending(path: "Contents/MacOS/fixture")
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(filePath: "/usr/bin/true"), to: executable)
        let entitlements = root.appending(path: "groups.plist")
        let groupID = "group.org.separate.RunningGroup"
        let data = try PropertyListSerialization.data(fromPropertyList: ["com.apple.security.application-groups": [groupID]],
                                                       format: .xml, options: 0)
        try data.write(to: entitlements)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", "--entitlements", entitlements.path, app.path]
        try process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        let index = AppBundleIndex(urls: [], runningURLs: [app])
        precondition(index.applications.first?.groupIDs.contains(groupID) == true)
        let home = root.appending(path: "running-owner-home")
        for place in ["Group Containers", "Application Scripts"] {
            let dir = home.appending(path: "Library/\(place)/\(groupID)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 0x45, count: 1_100_000).write(to: dir.appending(path: "data"))
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -90 * 86400)], ofItemAtPath: dir.path)
        }
        let unindexed = LeftoverScanner.dataItems(home: home, owners: .init(), running: ["com.signed.Fixture"], applicationExists: { _ in false })
        precondition(unindexed.count == 1 && unindexed[0].defaultOn, "Fixture must reproduce the old group-ID/bundle-ID ownership gap")
        let owners = LeftoverScanner.owners(index: index)
        precondition(LeftoverScanner.dataItems(home: home, owners: owners, running: ["com.signed.Fixture"], applicationExists: { _ in false }).isEmpty,
                     "A running app outside Applications must protect its unrelated group ID, even with old data")
    }

    @discardableResult static func bundle(_ url: URL, id: String) throws -> URL {
        try fm.createDirectory(at: url.appending(path: "Contents"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": id, "CFBundleName": url.deletingPathExtension().lastPathComponent,
                    "CFBundlePackageType": "APPL", "CFBundleExecutable": "fixture"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: url.appending(path: "Contents/Info.plist"))
        return url
    }
}
