import Foundation

/// MCP 工具清单、使用说明和本机通道的位置。Adieu 和 adieu-mcp 都编译这一份，
/// 所以 adieu-mcp 不用连上 Adieu 也能列出工具
enum AgentCatalog {
    /// 只读直接执行；change 先预览拿确认编号，再带编号执行；delete 还要用户在 Adieu 窗口里点“删除”
    enum Tier: String { case read, change, delete }

    struct Tool {
        let name: String
        let tier: Tier
        let description: String
        /// inputSchema 的 properties（JSON 文本）
        let properties: String
        var required: [String] = []
    }

    /// Adieu 监听的 Unix 套接字，只有当前用户能连
    static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Adieu/agent.sock").path
    }

    static let token = #""confirm_token": {"type": "string", "description": "Omit to get a preview and a token. Call again with the same arguments plus this token to execute."}"#

    static let instructions = """
    Adieu is a macOS disk cleanup, uninstaller and file-moving app running on the user's Mac. These tools talk to the running Adieu app, \
    which uses its own disk permissions and safety rules (protected paths, allowed locations).

    Rules:
    1. Scan first, then explain. Use the read-only tools, then show the user a short list with sizes, grades and the space that would be freed \
    before changing anything. Sizes are measured on disk; any total you add up yourself is an estimate, so say so.
    2. Grades: "safe" = regenerable caches and installers; "review" = may hold the user's data, the user decides; \
    "keep" = do not delete by hand, follow the note (e.g. Photos library, iOS backups, Docker disk, system data).
    3. Change tools (move, copy, rename, create_folder, set_login_item, set_skill, undo) are two-step: call without confirm_token to get a \
    preview and a token, show the preview to the user, and only call again with the token after the user agrees. Tokens expire in 10 minutes \
    and are refused if the files changed.
    4. Delete tools (uninstall_app, clean_app_data, delete_items, empty_trash, remove_cloud_download, remove_worktree, uninstall_skill) \
    are also two-step, and on the second call Adieu shows the list in its own window; nothing is deleted until the user clicks Delete there. \
    You cannot click it. Deletions are permanent (not moved to the Trash).
    5. Never try to bypass Adieu with shell commands to delete what Adieu refused.
    6. Reply to the user in the language they use.
    """

    static let tools: [Tool] = [
        Tool(name: "disk_overview", tier: .read,
             description: "Disk capacity and free space, where the used space goes (apps, app data, user files, caches, macOS system data broken down into volumes, swap, snapshots, pending OS update), and large items that must be handled elsewhere (Photos library, iOS backups, Docker disk) with the correct procedure.",
             properties: "{}"),
        Tool(name: "list_apps", tier: .read,
             description: "Installed apps with app size and data size in GB. Optional query filters by name or bundle id.",
             properties: #"{"query": {"type": "string"}}"#),
        Tool(name: "app_detail", tier: .read,
             description: "Every file Adieu found for one app: bundle, sandbox data, caches, preferences, launch agents, with size, evidence and whether it is personal data.",
             properties: #"{"app": {"type": "string", "description": "App name, bundle id or path"}}"#, required: ["app"]),
        Tool(name: "scan_leftovers", tier: .read,
             description: "Data left behind by apps that are no longer installed.",
             properties: "{}"),
        Tool(name: "scan_files", tier: .read,
             description: "User files by category: installers (installers and archives), captures (screenshots and recordings), bigFiles, stale (not opened for a long time). Each item has a grade.",
             properties: #"{"category": {"type": "string", "enum": ["installers", "captures", "bigFiles", "stale"]}, "limit": {"type": "integer", "description": "Default 50"}}"#,
             required: ["category"]),
        Tool(name: "dev_spaces", tier: .read,
             description: "Developer caches (Xcode, npm, Homebrew, Docker, models…) with reclaimable size and the official cleanup commands Adieu would run, plus Git worktrees in the projects the user added.",
             properties: "{}"),
        Tool(name: "launch_items", tier: .read,
             description: "Login items and background launch agents/daemons, including broken ones.",
             properties: "{}"),
        Tool(name: "list_volumes", tier: .read,
             description: "Places files can be moved between: this Mac (home folder), iCloud Drive and mounted external drives, with free space, format and limits (NTFS read-only, FAT32 4 GB).",
             properties: "{}"),
        Tool(name: "list_dir", tier: .read,
             description: "List a folder (non-hidden items) with sizes of files.",
             properties: #"{"path": {"type": "string"}}"#, required: ["path"]),
        Tool(name: "search_files", tier: .read,
             description: "Search by name inside a folder (recursive, up to 300 results).",
             properties: #"{"path": {"type": "string"}, "query": {"type": "string"}}"#, required: ["path", "query"]),
        Tool(name: "agent_skills", tier: .read,
             description: "Skills installed for Codex, Claude Code and DeepSeek Harness, which agents they are enabled for, and whether each agent may invoke them automatically.",
             properties: "{}"),
        Tool(name: "cloud_drive", tier: .read,
             description: "iCloud Drive files with local size and sync state (online only, downloaded and removable, syncing…).",
             properties: "{}"),
        Tool(name: "recent_moves", tier: .read,
             description: "Recent moves, copies, renames and new folders made in Adieu, with ids for undo.",
             properties: "{}"),
        Tool(name: "move", tier: .change,
             description: "Move files or folders into a folder. Within one disk it is instant; across disks Adieu copies, verifies file count and size, then deletes the originals. on_conflict=replace deletes the existing items and needs the user's click in Adieu.",
             properties: #"{"paths": {"type": "array", "items": {"type": "string"}}, "destination": {"type": "string"}, "on_conflict": {"type": "string", "enum": ["keep_both", "skip", "replace"]}, "verify_contents": {"type": "boolean"}, "#
                + token + "}",
             required: ["paths", "destination"]),
        Tool(name: "copy", tier: .change,
             description: "Copy files or folders into a folder, then verify file count and size.",
             properties: #"{"paths": {"type": "array", "items": {"type": "string"}}, "destination": {"type": "string"}, "on_conflict": {"type": "string", "enum": ["keep_both", "skip", "replace"]}, "verify_contents": {"type": "boolean"}, "#
                + token + "}",
             required: ["paths", "destination"]),
        Tool(name: "rename", tier: .change, description: "Rename one file or folder.",
             properties: #"{"path": {"type": "string"}, "new_name": {"type": "string"}, "# + token + "}", required: ["path", "new_name"]),
        Tool(name: "create_folder", tier: .change, description: "Create a folder.",
             properties: #"{"parent": {"type": "string"}, "name": {"type": "string"}, "# + token + "}", required: ["parent", "name"]),
        Tool(name: "set_login_item", tier: .change, description: "Turn an app's \"open at login\" on or off.",
             properties: #"{"app_path": {"type": "string"}, "enabled": {"type": "boolean"}, "# + token + "}", required: ["app_path", "enabled"]),
        Tool(name: "set_skill", tier: .change,
             description: "Enable or disable a skill for one agent, or set whether that agent may invoke it automatically (automatic) or only when named (explicit).",
             properties: #"{"skill": {"type": "string"}, "agent": {"type": "string", "enum": ["codex", "claude_code", "deepseek_harness"]}, "enabled": {"type": "boolean"}, "invocation": {"type": "string", "enum": ["automatic", "explicit"]}, "#
                + token + "}",
             required: ["skill", "agent"]),
        Tool(name: "undo", tier: .change,
             description: "Undo one entry from recent_moves. Undoing a copy or a new folder deletes the new item and needs the user's click in Adieu.",
             properties: #"{"id": {"type": "string"}, "# + token + "}", required: ["id"]),
        Tool(name: "uninstall_app", tier: .delete,
             description: "Uninstall an app with its data (all parts Adieu selects by default). keep_personal_data=true keeps sandbox data, Application Support and group containers. The app must not be running.",
             properties: #"{"app": {"type": "string"}, "keep_personal_data": {"type": "boolean"}, "# + token + "}", required: ["app"]),
        Tool(name: "clean_app_data", tier: .delete,
             description: "Delete an app's caches, logs and other data but keep the app. include_personal_data=true also deletes sandbox data and Application Support.",
             properties: #"{"app": {"type": "string"}, "include_personal_data": {"type": "boolean"}, "# + token + "}", required: ["app"]),
        Tool(name: "delete_items", tier: .delete,
             description: "Delete files or folders (for example items from scan_files, scan_leftovers). Adieu refuses protected and system locations.",
             properties: #"{"paths": {"type": "array", "items": {"type": "string"}}, "# + token + "}", required: ["paths"]),
        Tool(name: "empty_trash", tier: .delete, description: "Empty the current user's Trash.",
             properties: "{" + token + "}"),
        Tool(name: "remove_cloud_download", tier: .delete,
             description: "Remove the local download of iCloud Drive files. The files stay in iCloud and can be downloaded again.",
             properties: #"{"paths": {"type": "array", "items": {"type": "string"}}, "# + token + "}", required: ["paths"]),
        Tool(name: "remove_worktree", tier: .delete,
             description: "Remove a Git worktree with git worktree remove (force only when Adieu allows it).",
             properties: #"{"path": {"type": "string"}, "force": {"type": "boolean"}, "# + token + "}", required: ["path"]),
        Tool(name: "uninstall_skill", tier: .delete, description: "Delete an agent skill from every agent it is installed for.",
             properties: #"{"skill": {"type": "string"}, "# + token + "}", required: ["skill"]),
    ]

    /// MCP tools/list 的结果
    static func listJSON() -> [[String: Any]] {
        tools.map { tool in
            let props = (try? JSONSerialization.jsonObject(with: Data(tool.properties.utf8))) as? [String: Any] ?? [:]
            var schema: [String: Any] = ["type": "object", "properties": props]
            if !tool.required.isEmpty { schema["required"] = tool.required }
            let readOnly = tool.tier == .read
            return ["name": tool.name, "description": tool.description, "inputSchema": schema,
                    "annotations": ["readOnlyHint": readOnly, "destructiveHint": tool.tier == .delete]]
        }
    }
}
