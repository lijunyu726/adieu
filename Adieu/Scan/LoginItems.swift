import Foundation

/// “登录时打开”的应用，通过“系统事件”读写（第一次会请求自动化权限）。
/// 用 SMAppService 注册的新式登录项不在这里，系统设置里能看到全部。
/// 每次都要等“系统事件”回话（没在运行时要先启动它，半秒多），所以用系统自带的 osascript 在后台跑，
/// 调用方放进 `blocking {}`；NSAppleScript 只能在主线程用，会让界面停住
enum LoginItems {
    struct Item: Identifiable, Hashable, Sendable {
        let name: String
        let path: String
        var id: String { name }
    }

    /// 读不到时 error 是原因
    static func list() -> (items: [Item], error: String?) {
        let script = """
        tell application "System Events"
            set out to ""
            repeat with i in (every login item)
                set out to out & (name of i) & tab & (path of i) & linefeed
            end repeat
        end tell
        return out
        """
        guard let r = Shell.run("/usr/bin/osascript", ["-e", script], timeout: 120) else { return ([], "没有读取登录项的权限") }
        guard r.status == 0 else { return ([], message(r.err) ?? "没有读取登录项的权限") }
        let items = r.out.split(separator: "\n").compactMap { line -> Item? in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first, !name.isEmpty else { return nil }
            // 应用被删掉后，路径读出来是 missing value
            let path = parts.count > 1 && parts[1] != "missing value" ? String(parts[1]) : ""
            return Item(name: String(name), path: path)
        }
        return (items, nil)
    }

    /// 指向这个应用的登录项名字。卸载前先查：应用一删，“系统事件”给出的路径就成了 missing value，对不上了。
    /// 应用删了系统不会自己去掉这一项，系统设置和“开机与后台”里会一直留着一个打不开的名字。
    /// 只在已经允许控制“系统事件”时查，卸载过程中不为这个弹权限窗口
    static func names(pointingInto appPath: String) -> [String] {
        guard Permissions.automation == .granted else { return [] }
        let root = appPath.hasSuffix("/") ? String(appPath.dropLast()) : appPath
        return list().items.filter { $0.path == root || $0.path.hasPrefix(root + "/") }.map(\.name)
    }

    static func remove(_ name: String) -> String? {
        run("tell application \"System Events\" to delete login item (item 1 of argv)", name)
    }

    static func add(path: String) -> String? {
        run("tell application \"System Events\" to make login item at end with properties {path:(item 1 of argv), hidden:false}", path)
    }

    /// 参数从 argv 传进脚本，名字里有引号也不用转义
    private static func run(_ line: String, _ arg: String) -> String? {
        guard let r = Shell.run("/usr/bin/osascript", ["-e", "on run argv", "-e", line, "-e", "end run", arg], timeout: 120) else { return "操作失败" }
        return r.status == 0 ? nil : message(r.err) ?? "操作失败"
    }

    /// osascript 的报错形如“0:63: execution error: 没有权限…… (-1743)”，只留中间那句
    private static func message(_ err: String) -> String? {
        var s = err.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "execution error: ") { s = String(s[r.upperBound...]) }
        if let r = s.range(of: #" \(-?\d+\)$"#, options: .regularExpression) { s.removeSubrange(r) }
        return s.isEmpty ? nil : s
    }
}
