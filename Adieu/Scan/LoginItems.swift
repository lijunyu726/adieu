import Foundation

/// “登录时打开”的应用，通过“系统事件”读写（第一次会请求自动化权限）。
/// 用 SMAppService 注册的新式登录项不在这里，系统设置里能看到全部
@MainActor
enum LoginItems {
    struct Item: Identifiable, Hashable {
        let name: String
        let path: String
        var id: String { name }
    }

    /// 读不到时 error 是原因
    static func list() -> (items: [Item], error: String?) {
        let script = NSAppleScript(source: "tell application \"System Events\" to get {name, path} of every login item")
        var error: NSDictionary?
        guard let desc = script?.executeAndReturnError(&error) else {
            return ([], (error?[NSAppleScript.errorMessage] as? String) ?? "没有读取登录项的权限")
        }
        guard desc.numberOfItems == 2, let names = desc.atIndex(1), let paths = desc.atIndex(2) else { return ([], nil) }
        var items: [Item] = []
        if names.numberOfItems > 0 {
            for i in 1...names.numberOfItems {
                items.append(Item(name: names.atIndex(i)?.stringValue ?? "", path: paths.atIndex(i)?.stringValue ?? ""))
            }
        }
        return (items, nil)
    }

    static func remove(_ name: String) -> String? {
        run("tell application \"System Events\" to delete login item \"\(escape(name))\"")
    }

    static func add(path: String) -> String? {
        run("tell application \"System Events\" to make login item at end with properties {path:\"\(escape(path))\", hidden:false}")
    }

    private static func escape(_ s: String) -> String { s.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") }

    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error.map { ($0[NSAppleScript.errorMessage] as? String) ?? "操作失败" }
    }
}
