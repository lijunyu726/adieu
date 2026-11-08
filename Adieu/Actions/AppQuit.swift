import AppKit

/// 删除应用或它的数据前先让它退出：开着的应用会把数据写回去，正在写的数据库也可能删坏。
/// 先“请”它退出（同 ⌘Q，能保存、也能拒绝），退不出由用户决定要不要强制退出。
@MainActor
enum AppQuit {
    /// 这个应用本身，以及它包里正在运行的扩展、助手程序（如输入法的 Finder 扩展）
    static func processes(of app: AppItem) -> [NSRunningApplication] {
        let inside = app.path.map { $0 + "/" }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter { r in
            r.processIdentifier != me && !r.isTerminated
                && (r.bundleIdentifier == app.id || inside.map { r.bundleURL?.standardizedFileURL.path.hasPrefix($0) == true } == true)
        }
    }

    static func isRunning(_ app: AppItem) -> Bool { !processes(of: app).isEmpty }

    /// 请它退出，最多等 5 秒；返回还没退出的
    static func quit(_ app: AppItem) async -> [NSRunningApplication] {
        let list = processes(of: app)
        for r in list { r.terminate() }
        return await wait(list, seconds: 5)
    }

    /// 强制退出（没保存的内容会丢），最多等 3 秒；返回还没退出的
    static func forceQuit(_ app: AppItem) async -> [NSRunningApplication] {
        let list = processes(of: app)
        for r in list { r.forceTerminate() }
        return await wait(list, seconds: 3)
    }

    /// 给用户看的名字：主程序和扩展同名时只写一次
    static func names(_ list: [NSRunningApplication], fallback: String) -> String {
        let names = Set(list.compactMap(\.localizedName))
        return names.isEmpty ? fallback : ListFormatter.localizedString(byJoining: names.sorted())
    }

    private static func wait(_ list: [NSRunningApplication], seconds: Int) async -> [NSRunningApplication] {
        for _ in 0..<(seconds * 5) where list.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return list.filter { !$0.isTerminated }
    }
}
