import AppKit
import CoreServices

/// Adieu 用到的系统权限：检查状态，以及让系统弹出询问
enum Permissions {
    /// 完全磁盘访问权限：没有它就读不到 TCC 数据库，也统计不到其他应用的沙盒数据。
    /// 三个文件不是每台机器都有（macOS 27 上没有用户级 TCC 库），能读到任一个就算有权限
    static var hasFullDiskAccess: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let probes = [home.appending(path: "Library/Application Support/com.apple.TCC/TCC.db").path,
                      "/Library/Application Support/com.apple.TCC/TCC.db",
                      home.appending(path: "Library/Safari/CloudTabs.db").path]
        return probes.contains { FileHandle(forReadingAtPath: $0) != nil }
    }

    enum State { case granted, denied, notAsked }

    /// 能否控制“系统事件”（读写登录项用）。只检查，不弹窗
    static var automation: State { automationState(ask: false) }

    /// 让系统弹出“允许 Adieu 控制系统事件吗”。自动化权限没法在系统设置里手动添加，
    /// 只有应用先问过一次，系统设置的“自动化”里才会出现 Adieu
    static func requestAutomation() async -> State {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        // 询问前“系统事件”要在运行，否则系统直接返回“找不到程序”
        _ = try? await NSWorkspace.shared.openApplication(at: URL(filePath: "/System/Library/CoreServices/System Events.app"), configuration: cfg)
        return await blocking { automationState(ask: true) }
    }

    private static func automationState(ask: Bool) -> State {
        var target = AEAddressDesc()
        let id = "com.apple.systemevents"
        let status = id.withCString { ptr in
            AECreateDesc(typeApplicationBundleID, ptr, id.utf8.count, &target)
        }
        guard status == noErr else { return .notAsked }
        defer { AEDisposeDesc(&target) }
        switch AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask) {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .notAsked
        }
    }

    static let fullDiskAccessSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    static let automationSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
    static let notificationSettings = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
}
