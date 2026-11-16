import AppKit
import Foundation
import Observation

/// MCP 工具在 Adieu 里的实现。三档：只读直接做；改动类先预览发确认编号，带编号再做；
/// 删除类带编号后还要在 Adieu 窗口里弹清单，用户亲手点“删除”才执行（agent 点不了）
@Observable
@MainActor
final class AgentTools {
    /// 等用户在窗口里点的删除请求
    struct Request: Identifiable {
        struct Line: Hashable {
            let label: String
            let detail: String
            let size: Double?
        }
        let id = UUID()
        let tool: String
        let title: String
        let lines: [Line]
        let note: String
        fileprivate let answer: CheckedContinuation<Bool, Never>
    }

    var request: Request?
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var server: AgentServer?
    @ObservationIgnored private var tokens: [String: Pending] = [:]

    private struct Pending {
        let fingerprint: String
        /// 预览的内容（去掉大小这类会自己变的数）。执行前重新算一遍，对不上说明东西变了
        let preview: String
        let expires: Date
    }

    struct Reply {
        var text: String
        var isError = false
    }

    struct Failure: Error { let message: String }

    static let settingKey = "agentAccess"
    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.settingKey) }

    // MARK: 开关

    /// 按设置开或关通道；启动时和设置里切换时调用
    func apply() {
        if enabled && !(model?.useSample ?? true) {
            if server == nil {
                server = AgentServer { [weak self] data in
                    await self?.handle(data) ?? Self.encode(Reply(text: "Adieu is shutting down.", isError: true))
                }
            }
            do { try server?.start() } catch { model?.notice = String(localized: "没能打开 agent 通道：\(error.localizedDescription)") }
        } else {
            server?.stop()
            if let request { request.answer.resume(returning: false); self.request = nil }
        }
    }

    func stop() { server?.stop() }

    func answer(_ approve: Bool) {
        guard let request else { return }
        self.request = nil
        request.answer.resume(returning: approve)
    }

    // MARK: 分发

    nonisolated private static func encode(_ reply: Reply) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["text": reply.text, "isError": reply.isError])) ?? Data()
    }

    func handle(_ data: Data) async -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String else {
            return Self.encode(Reply(text: "Bad request.", isError: true))
        }
        let args = object["arguments"] as? [String: Any] ?? [:]
        guard enabled else { return Self.encode(Reply(text: "Agent access is turned off in Adieu settings.", isError: true)) }
        let reply: Reply
        do {
            reply = try await run(name, args)
        } catch let failure as Failure {
            reply = Reply(text: failure.message, isError: true)
        } catch {
            reply = Reply(text: error.localizedDescription, isError: true)
        }
        return Self.encode(reply)
    }

    private func run(_ name: String, _ a: [String: Any]) async throws -> Reply {
        guard let model else { throw Failure(message: "Adieu is not ready.") }
        switch name {
        case "disk_overview": return try await diskOverview(model)
        case "list_apps": return try await listApps(model, query: a["query"] as? String)
        case "app_detail": return try await appDetail(model, try app(model, a))
        case "scan_leftovers": return try await leftovers(model)
        case "scan_files": return try await files(model, a)
        case "dev_spaces": return try await devSpaces(model)
        case "launch_items": return try await launchItems(model)
        case "list_volumes": return json(["volumes": Places.list().map(placeJSON)])
        case "list_dir": return try await listDir(a)
        case "search_files": return try await search(a)
        case "agent_skills": return await skills(model)
        case "cloud_drive": return await cloudDrive(model)
        case "recent_moves": return recentMoves(model)
        case "move", "copy": return try await transfer(model, name, a)
        case "rename": return try await rename(model, a)
        case "create_folder": return try await createFolder(model, a)
        case "set_login_item": return try await loginItem(a)
        case "set_skill": return try await setSkill(model, a)
        case "undo": return try await undo(model, a)
        case "uninstall_app": return try await uninstall(model, a)
        case "clean_app_data": return try await cleanAppData(model, a)
        case "delete_items": return try await deleteItems(model, a)
        case "empty_trash": return try await emptyTrash(model, a)
        case "remove_cloud_download": return try await removeCloudDownload(model, a)
        case "remove_worktree": return try await removeWorktree(model, a)
        case "uninstall_skill": return try await uninstallSkill(model, a)
        default: throw Failure(message: "Unknown tool \(name).")
        }
    }

    // MARK: 确认编号

    /// 两步走：没带编号就登记一个、回预览；带了编号，要参数一致、没过期、预览内容没变才执行
    private func twoStep(_ tool: String, _ a: [String: Any], preview: [String: Any],
                         execute: @escaping @MainActor () async -> Reply) async -> Reply {
        var rest = a
        let given = rest.removeValue(forKey: "confirm_token") as? String
        let fingerprint = tool + ":" + canonical(rest)
        let content = canonical(stable(preview))
        let now = Date.now
        tokens = tokens.filter { $0.value.expires > now }
        if let given {
            guard let pending = tokens.removeValue(forKey: given), pending.fingerprint == fingerprint else {
                return Reply(text: "The confirm_token is unknown, expired, or the arguments changed. Call again without confirm_token to get a new preview.", isError: true)
            }
            if pending.preview == content { return await execute() }
        }
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        tokens[token] = Pending(fingerprint: fingerprint, preview: content, expires: now.addingTimeInterval(600))
        var body = preview
        body["confirm_token"] = token
        if given != nil { body["changed"] = "The files changed since the preview, so nothing was done. This is the new preview." }
        body["next_step"] = AgentCatalog.tools.first { $0.name == tool }?.tier == .delete
            ? "Show this to the user. If they agree, call \(tool) again with the same arguments and this confirm_token. Adieu will then show the list in its window and only the user's click there deletes anything."
            : "Show this to the user. If they agree, call \(tool) again with the same arguments and this confirm_token."
        return json(body)
    }

    /// 去掉大小、字节数、是否在运行这些会自己变的字段
    private func stable(_ value: Any) -> Any {
        if let d = value as? [String: Any] {
            return d.filter { k, _ in !(k.hasSuffix("_gb") || k.hasSuffix("bytes") || k.hasPrefix("size") || k == "app_running") }
                .mapValues(stable)
        }
        if let list = value as? [Any] { return list.map(stable) }
        return value
    }

    private func canonical(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(["v": value]),
              let data = try? JSONSerialization.data(withJSONObject: ["v": value], options: [.sortedKeys]) else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 删除类第二步：把清单放到 Adieu 窗口里，等用户点。最多等 10 分钟
    private func askUser(_ tool: String, title: String, lines: [Request.Line], note: String) async -> Bool {
        if let old = request { old.answer.resume(returning: false) }
        NSApp.activate()
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        let approved = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            request = Request(tool: tool, title: title, lines: lines, note: note, answer: c)
            let current = request?.id
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(600))
                if let self, let r = self.request, r.id == current { self.answer(false) }
            }
        }
        return approved
    }

    private let declined = Reply(text: "The user did not approve in Adieu (clicked Cancel or did not answer within 10 minutes). Nothing was deleted.")

    // MARK: 等扫描

    private func waitFor(_ ready: @MainActor () -> Bool) async {
        for _ in 0..<360 where !ready() { try? await Task.sleep(for: .milliseconds(500)) }
    }

    private func ensureScanned(_ model: AppModel) async {
        if model.apps.isEmpty && !model.appsLoading && model.space == nil && !model.spaceLoading {
            Task { await model.scanAll() }
        }
        await waitFor { !model.appsLoading && !model.filesLoading && !model.leftoversLoading && !model.devLoading && !model.spaceLoading }
    }

    // MARK: 只读

    private func diskOverview(_ model: AppModel) async throws -> Reply {
        await ensureScanned(model)
        let d = model.disk
        var body: [String: Any] = [
            "disk": ["total_gb": r(d.total), "used_gb": r(d.used), "free_gb": r(d.free)],
            "categories": model.spaceCategories.map { c in
                ["label": c.label, "size_gb": r(c.size), "hint": c.hint,
                 "parts": c.parts.map { p in
                     var x: [String: Any] = ["label": p.label, "note": p.note]
                     if let s = p.size { x["size_gb"] = r(s) }
                     if let g = p.grade { x["grade"] = g.rawValue }
                     return x
                 }] as [String: Any]
            },
        ]
        if let space = model.space {
            body["pending_os_update"] = space.pendingUpdate
            body["local_snapshots"] = space.snapshots
            body["handle_elsewhere"] = space.hotspots.map { h in
                var x: [String: Any] = ["label": h.label, "path": h.path, "size_gb": r(h.size), "grade": h.grade.rawValue, "how_to_handle": h.note]
                if let l = h.logical { x["apparent_size_gb"] = r(l) }
                return x
            }
        }
        body["note"] = "Sizes are allocated space on disk. \"macOS 系统与其他\" is what remains after the known categories."
        return json(body)
    }

    private func listApps(_ model: AppModel, query: String?) async throws -> Reply {
        await waitFor { !model.appsLoading }
        let q = query?.trimmingCharacters(in: .whitespaces) ?? ""
        let apps = model.apps.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || $0.bundleID.localizedCaseInsensitiveContains(q) }
        return json(["apps": apps.sorted { $0.total > $1.total }.map { a in
            ["name": a.name, "bundle_id": a.bundleID, "path": a.path ?? "", "app_gb": r(a.appSize), "data_gb": r(a.dataSize),
             "measured": a.isMeasured, "running": a.isRunning] as [String: Any]
        }])
    }

    private func app(_ model: AppModel, _ a: [String: Any]) throws -> AppItem {
        guard let key = (a["app"] as? String)?.trimmingCharacters(in: .whitespaces), !key.isEmpty else { throw Failure(message: "Missing app.") }
        let matches = model.apps.filter {
            $0.name.caseInsensitiveCompare(key) == .orderedSame || $0.bundleID.caseInsensitiveCompare(key) == .orderedSame || $0.path == key
        }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 {
            throw Failure(message: "Several apps match \"\(key)\": " + matches.map { "\($0.name) (\($0.path ?? ""))" }.joined(separator: ", ") + ". Use the path.")
        }
        throw Failure(message: "No installed app matches \"\(key)\". Use list_apps.")
    }

    private func partJSON(_ p: AppPart) -> [String: Any] {
        var x: [String: Any] = ["label": p.label, "path": p.path, "kind": "\(p.kind)", "evidence": p.evidence.rawValue,
                                "selected_by_default": p.defaultOn, "personal_data": p.isPersonalData]
        if let s = p.size { x["size_gb"] = r(s) }
        if let h = p.hint { x["hint"] = h }
        return x
    }

    private func appDetail(_ model: AppModel, _ app: AppItem) async throws -> Reply {
        await waitFor { model.apps.first { $0.id == app.id }?.isMeasured ?? true }
        let app = model.apps.first { $0.id == app.id } ?? app
        return json(["name": app.name, "bundle_id": app.bundleID, "path": app.path ?? "", "running": app.isRunning,
                     "total_gb": r(app.total), "parts": app.parts.map(partJSON)])
    }

    private func leftovers(_ model: AppModel) async throws -> Reply {
        await waitFor { !model.leftoversLoading }
        return json(["groups": model.leftovers.map { g in
            ["title": g.title, "subtitle": g.subtitle, "items": g.items.map { i in
                var x: [String: Any] = ["name": i.name, "path": i.path, "evidence": i.evidence, "selected_by_default": i.defaultOn,
                                        "grade": i.defaultOn ? Safety.safe.rawValue : Safety.review.rawValue]
                if let s = i.size { x["size_gb"] = r(s) }
                if !i.paths.isEmpty { x["paths"] = i.paths }
                return x
            }] as [String: Any]
        }])
    }

    private func files(_ model: AppModel, _ a: [String: Any]) async throws -> Reply {
        guard let raw = a["category"] as? String, let section = AppSection(rawValue: raw),
              [.installers, .captures, .bigFiles, .stale].contains(section) else { throw Failure(message: "category must be installers, captures, bigFiles or stale.") }
        await waitFor { !model.filesLoading }
        let limit = max(1, min(500, (a["limit"] as? Int) ?? 50))
        let items = (model.category(section)?.items ?? []).filter { !$0.isSummary && $0.path != nil }
        return json(["category": raw, "count": items.count, "total_gb": r(items.map(\.size).reduce(0, +)),
                     "items": items.sorted { $0.size > $1.size }.prefix(limit).map { f in
                         ["name": f.name, "path": f.path ?? "", "size_gb": r(f.size), "modified": f.modified, "reason": f.reason,
                          "grade": section == .installers ? Safety.safe.rawValue : Safety.review.rawValue] as [String: Any]
                     }])
    }

    private func devSpaces(_ model: AppModel) async throws -> Reply {
        await waitFor { !model.devLoading }
        let tools = model.devTools.map { t in
            var x: [String: Any] = ["id": t.id, "name": t.name, "location": t.location, "note": t.note,
                                    "total_gb": r(t.total), "reclaimable_gb": r(t.reclaimable), "commands": t.commands,
                                    "grade": Safety.safe.rawValue]
            if let n = t.never { x["never_run"] = n }
            if let b = t.blocked { x["blocked"] = b }
            return x
        }
        let worktrees = model.worktrees.projects.flatMap { p in
            p.items.map { w in
                var x: [String: Any] = ["project": p.path, "path": w.path, "branch": w.branch ?? "", "command": w.command,
                                        "can_remove": w.removalMode != nil, "needs_force": w.removalMode == .force]
                if let s = w.size { x["size_gb"] = r(s) }
                if let b = w.blocked { x["blocked"] = b }
                return x
            }
        }
        return json(["tools": tools, "worktrees": worktrees,
                     "note": "Adieu runs the listed official commands when the user cleans a tool on the 开发工具 page; this server does not run them."])
    }

    private func launchItems(_ model: AppModel) async throws -> Reply {
        let login = await blocking { LoginItems.list() }
        return json([
            "login_items": login.items.map { ["name": $0.name, "path": $0.path] },
            "login_items_error": login.error ?? "",
            "background": model.launchGroups.map { g in
                ["title": g.title, "note": g.note, "items": g.items.map { i in
                    ["owner": i.owner, "label": i.label, "plist": i.plist ?? "", "user": i.isUser, "loaded": i.loaded] as [String: Any]
                }] as [String: Any]
            },
        ])
    }

    private func placeJSON(_ p: Place) -> [String: Any] {
        var x: [String: Any] = ["name": p.name, "path": p.root.path, "kind": "\(p.kind)", "format": p.format, "read_only": p.readOnly]
        if let f = p.free { x["free_gb"] = r(Double(f) / 1e9) }
        if let t = p.total { x["total_gb"] = r(Double(t) / 1e9) }
        if let n = p.limitNote { x["limit"] = n }
        return x
    }

    private func path(_ a: [String: Any], _ key: String) throws -> URL {
        guard let p = (a[key] as? String)?.trimmingCharacters(in: .whitespaces), !p.isEmpty else { throw Failure(message: "Missing \(key).") }
        return URL(filePath: (p as NSString).expandingTildeInPath).standardizedFileURL
    }

    private func itemJSON(_ i: FolderItem) -> [String: Any] {
        var x: [String: Any] = ["name": i.url.lastPathComponent, "path": i.url.path, "folder": i.isFolder]
        if let s = i.size { x["size_bytes"] = s }
        if i.isLink { x["symlink"] = true }
        if i.isDataless { x["online_only"] = true }
        if let m = i.modified { x["modified"] = ISO8601DateFormatter().string(from: m) }
        return x
    }

    private func listDir(_ a: [String: Any]) async throws -> Reply {
        let folder = try path(a, "path")
        let items = try await blocking { Result { try FolderListing.list(folder) } }.get()
        return json(["path": folder.path, "items": items.map(itemJSON)])
    }

    private func search(_ a: [String: Any]) async throws -> Reply {
        let folder = try path(a, "path")
        guard let q = a["query"] as? String, !q.isEmpty else { throw Failure(message: "Missing query.") }
        let items = await blocking { FolderListing.search(folder, query: q) }
        return json(["path": folder.path, "query": q, "items": items.map(itemJSON)])
    }

    private static let agentNames: [SkillAgent: String] = [.codex: "codex", .claudeCode: "claude_code", .deepSeekHarness: "deepseek_harness"]

    private func skills(_ model: AppModel) async -> Reply {
        if model.agentSkills.skills.isEmpty { await model.agentSkills.load() }
        return json(["skills": model.agentSkills.skills.map { s in
            var modes: [String: String] = [:]
            for agent in s.activeAgents {
                switch s.mode(for: agent) {
                case .automatic: modes[Self.agentNames[agent]!] = "automatic"
                case .explicit: modes[Self.agentNames[agent]!] = "explicit"
                case .unavailable: modes[Self.agentNames[agent]!] = "unknown"
                }
            }
            return ["skill": s.id, "enabled_for": s.activeAgents.compactMap { Self.agentNames[$0] }.sorted(),
                    "installed_for": s.installedAgents.compactMap { Self.agentNames[$0] }.sorted(),
                    "invocation": modes, "paths": s.installations.map(\.entry.path)] as [String: Any]
        }])
    }

    private func cloudDrive(_ model: AppModel) async -> Reply {
        if model.cloudDrive == nil { await model.loadCloudDrive() }
        if let e = model.cloudDriveError { return Reply(text: e, isError: true) }
        let files = model.cloudDrive?.files ?? []
        return json(["root": CloudDriveScanner.root.path, "files": files.prefix(500).map { f in
            ["path": f.url.path, "relative_path": f.relativePath, "state": f.state.title,
             "local_bytes": f.allocatedBytes, "can_remove_download": f.canEvict] as [String: Any]
        }])
    }

    private func recentMoves(_ model: AppModel) -> Reply {
        json(["moves": model.mover.records.prefix(30).map { m in
            ["id": m.id.uuidString, "date": ISO8601DateFormatter().string(from: m.date), "kind": m.kind.rawValue, "undone": m.undone,
             "undo_deletes": m.undoDeletes, "items": m.pairs.map { ["from": $0.from, "to": $0.to] }] as [String: Any]
        }])
    }

    // MARK: 改动类

    private func transfer(_ model: AppModel, _ tool: String, _ a: [String: Any]) async throws -> Reply {
        guard let raw = a["paths"] as? [String], !raw.isEmpty else { throw Failure(message: "Missing paths.") }
        let items = raw.map { URL(filePath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
        let destination = try path(a, "destination")
        let mode: FileMover.Mode = tool == "copy" ? .copy : .move
        let places = Places.list()
        let protected = model.protectedPaths
        var plan = try await blocking { Result { try FileMover.plan(items, to: destination, mode: mode, places: places, protected: protected) } }.get()
        switch a["on_conflict"] as? String {
        case "skip": plan.conflict = .skip
        case "replace": plan.conflict = .replace
        default: plan.conflict = .keepBoth
        }
        plan.verifyContents = a["verify_contents"] as? Bool ?? false
        let replacing = plan.conflict == .replace && !plan.conflicts.isEmpty
        var preview: [String: Any] = [
            "action": tool, "items": plan.items.map(\.path), "destination": plan.destination.path,
            "crosses_disks": plan.crossVolume, "bytes_to_copy": plan.bytes, "files_to_copy": plan.files,
            "name_conflicts": plan.conflicts, "on_conflict": a["on_conflict"] as? String ?? "keep_both",
            "skipped": plan.skipped.map { ["name": $0.name, "reason": $0.reason] }, "touches_icloud": plan.touchesCloud,
        ]
        if replacing { preview["warning"] = "Replacing permanently deletes the existing items with the same names; the user must approve in Adieu." }
        let final = plan
        return await twoStep(tool, a, preview: preview) { [weak self] in
            guard let self else { return Reply(text: "", isError: true) }
            if replacing {
                let ok = await self.askUser(tool, title: String(localized: "agent 要替换 \(final.conflicts.count) 个同名项目"),
                                            lines: final.conflicts.map { .init(label: $0, detail: final.destination.appending(path: $0).path, size: nil) },
                                            note: String(localized: "原有的会被直接删除，不进废纸篓，撤销也找不回来。"))
                guard ok else { return self.declined }
            }
            let out = await model.mover.run(final)
            return self.json(["done": out.done.map { ["from": $0.from, "to": $0.to] },
                              "failed": out.failed.map { ["path": $0.path, "reason": $0.reason] },
                              "skipped_same_name": out.skipped, "cancelled": out.cancelled,
                              "undo": model.mover.records.first.map { "undo with id \($0.id.uuidString)" } ?? ""])
        }
    }

    private func rename(_ model: AppModel, _ a: [String: Any]) async throws -> Reply {
        let url = try path(a, "path")
        guard let name = a["new_name"] as? String, !name.isEmpty else { throw Failure(message: "Missing new_name.") }
        try FileMover.checkSource(url, protected: model.protectedPaths)
        guard FileMover.validName(name, fsType: Places.containing(url, in: Places.list())?.fsType ?? "apfs") else {
            throw Failure(message: FileMover.Refusal.name.localizedDescription)
        }
        let target = url.deletingLastPathComponent().appending(path: name)
        return await twoStep("rename", a, preview: ["action": "rename", "from": url.path, "to": target.path]) { [weak self] in
            guard let self else { return Reply(text: "", isError: true) }
            do {
                let pair = try model.mover.rename(url, to: name)
                return self.json(["done": ["from": pair.from, "to": pair.to]])
            } catch {
                return Reply(text: error.localizedDescription, isError: true)
            }
        }
    }

    private func createFolder(_ model: AppModel, _ a: [String: Any]) async throws -> Reply {
        let parent = try path(a, "parent")
        guard let name = a["name"] as? String, !name.isEmpty else { throw Failure(message: "Missing name.") }
        try FileMover.checkDestination(parent, protected: model.protectedPaths)
        return await twoStep("create_folder", a, preview: ["action": "create_folder", "path": parent.appending(path: name).path]) { [weak self] in
            guard let self else { return Reply(text: "", isError: true) }
            do {
                let pair = try model.mover.createFolder(named: name, at: parent)
                return self.json(["done": pair.to])
            } catch {
                return Reply(text: error.localizedDescription, isError: true)
            }
        }
    }

    private func loginItem(_ a: [String: Any]) async throws -> Reply {
        let app = try path(a, "app_path")
        guard let on = a["enabled"] as? Bool else { throw Failure(message: "Missing enabled.") }
        guard app.pathExtension == "app", FileManager.default.fileExists(atPath: app.path) else { throw Failure(message: "app_path must be an existing .app.") }
        let list = await blocking { LoginItems.list() }
        let current = list.items.first { $0.path == app.path || URL(filePath: $0.path).standardizedFileURL.path == app.path }
        if (current != nil) == on { return json(["unchanged": true, "enabled": on]) }
        let name = current?.name ?? app.deletingPathExtension().lastPathComponent
        return await twoStep("set_login_item", a, preview: ["action": on ? "add login item" : "remove login item", "app": app.path]) { [weak self] in
            guard let self else { return Reply(text: "", isError: true) }
            let path = app.path
            if let error = await blocking({ on ? LoginItems.add(path: path) : LoginItems.remove(name) }) {
                return Reply(text: error, isError: true)
            }
            return self.json(["done": true, "enabled": on, "undo": "call set_login_item with enabled=\(!on)"])
        }
    }

    private func skill(_ model: AppModel, _ a: [String: Any]) async throws -> AgentSkill {
        guard let id = a["skill"] as? String else { throw Failure(message: "Missing skill.") }
        if model.agentSkills.skills.isEmpty { await model.agentSkills.load() }
        guard let s = model.agentSkills.skills.first(where: { $0.id == id }) else { throw Failure(message: "No skill named \(id). Use agent_skills.") }
        return s
    }

    private func setSkill(_ model: AppModel, _ a: [String: Any]) async throws -> Reply {
        let s = try await skill(model, a)
        guard let agent = Self.agentNames.first(where: { $0.value == a["agent"] as? String })?.key else { throw Failure(message: "Missing or unknown agent.") }
        let enabled = a["enabled"] as? Bool
        let invocation: SkillInvocation? = switch a["invocation"] as? String {
        case "automatic": .automatic
        case "explicit": .explicit
        default: nil
        }
        guard enabled != nil || invocation != nil else { throw Failure(message: "Give enabled and/or invocation.") }
        var preview: [String: Any] = ["skill": s.id, "agent": a["agent"] as? String ?? ""]
        if let enabled { preview["enabled"] = enabled }
        if let invocation { preview["invocation"] = a["invocation"] as? String ?? "\(invocation)" }
        return await twoStep("set_skill", a, preview: preview) { [weak self] in
            guard let self else { return Reply(text: "", isError: true) }
            if let enabled { await model.agentSkills.setEnabled(enabled, for: agent, skill: s) }
            if let invocation {
                await model.agentSkills.load()
                guard let fresh = model.agentSkills.skills.first(where: { $0.id == s.id }),
                      await model.agentSkills.change(.invocation(agent, invocation), for: fresh) else {
                    return Reply(text: "Adieu could not change the invocation (see Adieu for details).", isError: true)
                }
            }
            await model.agentSkills.load()
            return self.json(["done": true])
        }
    }

    private func undo(_ model: AppModel, _ a: [String: Any]) async throws -> Reply {
        guard let id = (a["id"] as? String).flatMap(UUID.init(uuidString:)),
              let record = model.mover.records.first(where: { $0.id == id }) else { throw Failure(message: "No such entry. Use recent_moves.") }
        guard !record.undone else { throw Failure(message: "Already undone.") }
        let preview: [String: Any] = ["undo": record.kind.rawValue, "items": record.pairs.map { ["now_at": $0.to, "goes_back_to": $0.from] },
                                      "deletes_new_items": record.undoDeletes]
        return await twoStep("undo", a, preview: preview) { [weak self] in
            guard let self else { return Reply(text: "", isError: true) }
            if record.undoDeletes {
                let ok = await self.askUser("undo", title: String(localized: "agent 要撤销一次复制或新建，删掉新的那份"),
                                            lines: record.pairs.map { .init(label: URL(filePath: $0.to).lastPathComponent, detail: $0.to, size: nil) },
                                            note: String(localized: "复制出来的文件或新建的文件夹会被直接删除，不进废纸篓。原件不受影响。"))
                guard ok else { return self.declined }
            }
            await model.mover.undo(record)
            let notice = model.mover.notice
            model.mover.notice = nil
            return notice.map { Reply(text: $0, isError: true) } ?? self.json(["done": true])
        }
    }

    // MARK: 删除类

    private func lines(_ urls: [URL], sizes: [String: Double]) -> [Request.Line] {
        urls.map { .init(label: $0.lastPathComponent, detail: $0.path, size: sizes[$0.path]) }
    }

    /// 交给 Adieu 的删除流程（记“最近”、权限不够弹系统密码），等它删完
    private func performAndWait(_ model: AppModel, _ request: AppModel.TrashRequest) async -> HistoryEntry? {
        await withCheckedContinuation { c in
            var req = request
            let old = req.onDone
            req.onDone = { entry in
                old?(entry)
                c.resume(returning: entry)
            }
            model.perform(req)
        }
    }

    private func deletedJSON(_ model: AppModel, _ entry: HistoryEntry?, requested: Int) -> Reply {
        let notice = model.notice
        model.notice = nil
        guard let entry else {
            return Reply(text: "Nothing was deleted." + (notice.map { " " + $0 } ?? ""), isError: true)
        }
        var body: [String: Any] = ["deleted": entry.files.map(\.originalPath), "requested": requested,
                                   "freed_gb_estimate": r(entry.total)]
        if let notice { body["problems"] = notice }
        return json(body)
    }

    private func uninstall(_ model: AppModel, _ a: [String: Any]) async throws -> Reply {
        await waitFor { !model.appsLoading }
        let found = try app(model, a)
        await waitFor { model.apps.first { $0.id == found.id }?.isMeasured ?? true }
        let app = model.apps.first { $0.id == found.id } ?? found
        if let p = app.path, InputMethods.isInputMethod(URL(filePath: p), info: Bundle(url: URL(filePath: p))?.infoDictionary) {
            throw Failure(message: "\(app.name) is an input method. Uninstall it in the Adieu window so it can be turned off first.")
        }
        let keep = a["keep_personal_data"] as? Bool ?? false
        let parts = app.parts.filter { $0.defaultOn && !(keep && $0.isPersonalData) }
        guard !parts.isEmpty else { throw Failure(message: "Nothing to remove.") }
        let urls = parts.map { URL(filePath: ($0.path as NSString).expandingTildeInPath) }
        var sizes: [String: Double] = [:]
        for (u, p) in zip(urls, parts) { if let s = p.size { sizes[u.path] = s } }
        let preview: [String: Any] = ["uninstall": app.name, "parts": parts.map(partJSON), "total_gb": r(parts.compactMap(\.size).reduce(0, +)),
                                      "app_running": AppQuit.isRunning(app), "kept_personal_data": keep]
        return await twoStep("uninstall_app", a, preview: preview) { [weak self] in
            guard let self else { return Reply(text: "", isError: true) }
            if AppQuit.isRunning(app) { return Reply(text: "\(app.name) is running. Ask the user to quit it first.", isError: true) }
            let ok = await self.askUser("uninstall_app", title: String(localized: "agent 要卸载 \(app.name)"),
                                        lines: zip(parts, urls).map { .init(label: $0.label, detail: $1.path, size: $0.size) },
                                        note: keep ? String(localized: "个人数据保留。其余直接删除，不进废纸篓。")
                                                   : String(localized: "包括个人数据（聊天记录、文档、账号等可能在里面），直接删除，不进废纸篓，删了找不回来。"))
            guard ok else { return self.declined }
            if AppQuit.isRunning(app) { return Reply(text: "\(app.name) was opened again. Nothing was deleted.", isError: true) }
            let agents = parts.filter { $0.kind == .background && $0.id.hasPrefix("agent.") }
                .map { LaunchItem(owner: app.name, label: String($0.id.dropFirst(6)), isUser: true) }
            await blocking { for x in agents { LaunchScanner.unload(x) } }
            let appPath = app.path
            let logins = await blocking { appPath.map(LoginItems.names(pointingInto:)) ?? [] }
            let entry = await model.deleteForUninstall(.init(title: String(localized: "卸载 \(app.name)"), source: "Agent", urls: urls, sizes: sizes))
            if let entry, entry.files.contains(where: { $0.originalPath == app.path }) {
                model.apps.removeAll { $0.id == app.id }
                await blocking { for name in logins { _ = LoginItems.remove(name) } }
            }
            return self.deletedJSON(model, entry, requested: urls.count)
        }
    }

    private func cleanAppData(_ model: AppModel, _ a: [String: Any]) async throws -> Reply {
        await waitFor { !model.appsLoading }
        let found = try app(model, a)
        await waitFor { model.apps.first { $0.id == found.id }?.isMeasured ?? true }
        let app = model.apps.first { $0.id == found.id } ?? found
        let personal = a["include_personal_data"] as? Bool ?? false
        let parts = app.parts.filter { $0.kind == .data && $0.evidence != .shared && (personal || !$0.isPersonalData) }
        guard !parts.isEmpty else { throw Failure(message: "No data to clean for \(app.name).") }
        let urls = parts.map { URL(filePath: ($0.path as NSString).expandingTildeInPath) }
        var sizes: [String: Double] = [:]
        for (u, p) in zip(urls, parts) { if let s = p.size { sizes[u.path] = s } }
        let preview: [String: Any] = ["clean": app.name, "parts": parts.map(partJSON), "total_gb": r(parts.compactMap(\.size).reduce(0, +)),
                                      "app_running": AppQuit.isRunning(app)]
        return await twoStep("clean_app_data", a, preview: preview) { [weak self] in
            guard let self else { return Reply(text: "", isError: true) }
            if AppQuit.isRunning(app) { return Reply(text: "\(app.name) is running. Ask the user to quit it first.", isError: true) }
            let ok = await self.askUser("clean_app_data", title: String(localized: "agent 要清理 \(app.name) 的数据"),
                                        lines: zip(parts, urls).map { .init(label: $0.label, detail: $1.path, size: $0.size) },
                                        note: String(localized: "应用本身保留，这些直接删除，不进废纸篓。"))
            guard ok else { return self.declined }
            let entry = await self.performAndWait(model, .init(title: String(localized: "清理 \(app.name) 的数据"), source: "Agent", urls: urls, sizes: sizes))
            await model.remeasure(app.id)
            return self.deletedJSON(model, entry, requested: urls.count)
        }
    }

    private func deleteItems(_ model: AppModel, _ a: [String: Any]) async throws -> Reply {
        guard let raw = a["paths"] as? [String], !raw.isEmpty else { throw Failure(message: "Missing paths.") }
        let urls = raw.map { URL(filePath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
        let protected = model.protectedPaths
        var refused: [[String: String]] = [], ok: [URL] = []
        for u in urls {
            do { try TrashService.check(u, protected: protected); ok.append(u) } catch {
                refused.append(["path": u.path, "reason": error.localizedDescription])
            }
        }
        guard !ok.isEmpty else { return json(["refused": refused]) }
        let targets = ok
        let sizes = await blocking { Dictionary(targets.map { ($0.path, AppScanner.allocatedSize($0) ?? 0) }, uniquingKeysWith: { a, _ in a }) }
        let preview: [String: Any] = ["delete": ok.map { ["path": $0.path, "size_gb": r(sizes[$0.path] ?? 0)] },
                                      "total_gb": r(sizes.values.reduce(0, +)), "refused": refused]
        return await twoStep("delete_items", a, preview: preview) { [weak self] in
            guard let self else { return Reply(text: "", isError: true) }
            let yes = await self.askUser("delete_items", title: String(localized: "agent 要删除 \(ok.count) 项"), lines: self.lines(ok, sizes: sizes),
                                         note: String(localized: "直接删除，不进废纸篓，删了不能放回。"))
            guard yes else { return self.declined }
            let entry = await self.performAndWait(model, .init(title: String(localized: "删除 \(ok.count) 项"), source: "Agent", urls: ok, sizes: sizes,
                                                               keys: ok.map(\.path)))
            model.removedKeys.formUnion(entry?.files.map(\.originalPath) ?? [])
            return self.deletedJSON(model, entry, requested: ok.count)
        }
    }

    private func emptyTrash(_ model: AppModel, _ a: [String: Any]) async throws -> Reply {
        let items = try await blocking { Result { try TrashService.trashContents() } }.get()
        guard !items.isEmpty else { return json(["empty": true]) }
        let size = await blocking { items.compactMap { AppScanner.allocatedSize($0.url) }.reduce(0, +) }
        return await twoStep("empty_trash", a, preview: ["items": items.count, "size_gb": r(size)]) { [weak self] in
            guard let self else { return Reply(text: "", isError: true) }
            guard !model.cleaningTrash else { return Reply(text: "Adieu is already emptying the Trash.", isError: true) }
            let yes = await self.askUser("empty_trash", title: String(localized: "agent 要清空废纸篓"),
                                         lines: items.prefix(200).map { .init(label: $0.url.lastPathComponent, detail: $0.url.path, size: nil) },
                                         note: String(localized: "废纸篓里的 \(items.count) 项会被永久删除，此操作无法撤销。"))
            guard yes else { return self.declined }
            let entry = await self.performAndWait(model, .init(title: String(localized: "清空废纸篓"), source: String(localized: "废纸篓"),
                                                               urls: items.map(\.url), trashItems: items))
            return self.deletedJSON(model, entry, requested: items.count)
        }
    }

    private func removeCloudDownload(_ model: AppModel, _ a: [String: Any]) async throws -> Reply {
        guard let raw = a["paths"] as? [String], !raw.isEmpty else { throw Failure(message: "Missing paths.") }
        if model.cloudDrive == nil { await model.loadCloudDrive() }
        let wanted = Set(raw.map { URL(filePath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path })
        let files = (model.cloudDrive?.files ?? []).filter { wanted.contains($0.url.standardizedFileURL.path) }
        let ok = files.filter(\.canEvict)
        let notReady = wanted.subtracting(ok.map { $0.url.standardizedFileURL.path })
        guard !ok.isEmpty else { throw Failure(message: "None of these are downloaded iCloud Drive files that can be removed. Use cloud_drive.") }
        let preview: [String: Any] = ["remove_download": ok.map(\.url.path), "local_bytes": ok.map(\.allocatedBytes).reduce(0, +),
                                      "not_removable": Array(notReady)]
        return await twoStep("remove_cloud_download", a, preview: preview) { [weak self] in
            guard let self else { return Reply(text: "", isError: true) }
            let yes = await self.askUser("remove_cloud_download", title: String(localized: "agent 要移除 \(ok.count) 个 iCloud 文件的本机下载"),
                                         lines: ok.map { .init(label: $0.url.lastPathComponent, detail: $0.relativePath, size: Double($0.allocatedBytes) / 1e9) },
                                         note: String(localized: "文件仍在 iCloud 里，需要时可以重新下载。"))
            guard yes else { return self.declined }
            await model.removeCloudDownloads(ok)
            let out = model.cloudDriveRemoval
            return self.json(["removed": out?.removed.count ?? 0, "failed": (out?.failed ?? []).map { ["path": $0.path, "reason": $0.reason] }])
        }
    }

    private func removeWorktree(_ model: AppModel, _ a: [String: Any]) async throws -> Reply {
        let p = try path(a, "path").path
        guard let item = model.worktrees.projects.flatMap(\.items).first(where: { $0.path == p }) else {
            throw Failure(message: "Adieu does not list this worktree. Use dev_spaces.")
        }
        let force = a["force"] as? Bool ?? false
        guard let allowed = item.removalMode else { throw Failure(message: item.blocked ?? "This worktree cannot be removed.") }
        let mode: WorktreeRemovalMode = force ? .force : .safe
        if mode == .force && allowed != .force { throw Failure(message: "Adieu does not allow forcing this one.") }
        if mode == .safe && allowed == .force { throw Failure(message: (item.blocked ?? "") + " It needs force=true.") }
        var preview: [String: Any] = ["remove_worktree": item.path, "branch": item.branch ?? "", "command": item.command, "force": force]
        if let s = item.size { preview["size_gb"] = r(s) }
        return await twoStep("remove_worktree", a, preview: preview) { [weak self] in
            guard let self else { return Reply(text: "", isError: true) }
            let yes = await self.askUser("remove_worktree", title: String(localized: "agent 要移除工作区"),
                                         lines: [.init(label: item.branch ?? item.path, detail: item.path, size: item.size)],
                                         note: force ? String(localized: "强制移除：工作区里没提交的改动会丢掉。") : String(localized: "用 git worktree remove 移除。"))
            guard yes else { return self.declined }
            let entry = await withCheckedContinuation { c in model.removeWorktree(item, mode: mode) { c.resume(returning: $0) } }
            return self.deletedJSON(model, entry, requested: 1)
        }
    }

    private func uninstallSkill(_ model: AppModel, _ a: [String: Any]) async throws -> Reply {
        let s = try await skill(model, a)
        let preview: [String: Any] = ["uninstall_skill": s.id, "paths": s.installations.map(\.entry.path),
                                      "agents": s.installedAgents.compactMap { Self.agentNames[$0] }.sorted()]
        return await twoStep("uninstall_skill", a, preview: preview) { [weak self] in
            guard let self else { return Reply(text: "", isError: true) }
            let yes = await self.askUser("uninstall_skill", title: String(localized: "agent 要卸载技能 \(s.id)"),
                                         lines: s.installations.map { .init(label: $0.entry.lastPathComponent, detail: $0.entry.path, size: nil) },
                                         note: String(localized: "直接删除，不进废纸篓。链接过来的技能只删链接，不动源文件。"))
            guard yes else { return self.declined }
            await model.uninstallSkill(s)
            await model.agentSkills.load()
            let gone = !model.agentSkills.skills.contains { $0.id == s.id }
            let notice = model.notice
            model.notice = nil
            return gone ? self.json(["done": true]) : Reply(text: notice ?? "The skill is still there.", isError: true)
        }
    }

    // MARK: 工具

    /// 两位小数；用十进制数，JSON 里不会变成 7.9299999…
    private func r(_ gb: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.2f", gb)) }

    private func json(_ object: [String: Any]) -> Reply {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return Reply(text: "\(object)")
        }
        return Reply(text: String(decoding: data, as: UTF8.self))
    }
}
