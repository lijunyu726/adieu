import SwiftUI
import UniformTypeIdentifiers

/// 开机与后台：登录项放主位，能关、能加；其他软件的后台程序只帮你清掉已经失效的
struct LaunchItemsView: View {
    @Environment(AppModel.self) private var model
    @State private var loginItems: [LoginItems.Item] = []
    @State private var loginError: String?
    @State private var loginLoaded = false
    /// 读不到登录项时，是不是之前在系统弹窗里点了“不允许”
    @State private var automationDenied = false
    /// 这次关掉的登录项，用来重新打开
    @State private var removedLogin: [String: String] = [:]
    /// 指向的应用已经不在了的登录项（应用被删了，系统不会自己去掉）
    @State private var missingLogin: Set<String> = []
    @State private var showOthers = false
    /// 软件在自己的设置里打开的开机启动（系统后台任务账本里读出来的）
    @State private var registered: [RegisteredItems.Item] = []

    private var broken: [LaunchItem] { model.launchGroups.first { $0.id == "broken" }?.items ?? [] }
    private var others: [(LaunchItem, LaunchGroup)] {
        model.launchGroups.filter { $0.id != "broken" }.flatMap { g in g.items.map { ($0, g) } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(.launch, subtitle: "开机后自己打开的应用。关掉不会卸载应用，随时可以再打开。")
                login
                background
            }
            .padding(32)
        }
        .task { if !loginLoaded { await loadLogin() } }
    }

    // MARK: 登录项

    @ViewBuilder private var login: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("登录时打开").font(.headline)
                    Text(loginLoaded && loginError == nil ? "开着 \(rows.filter(\.on).count) 个，打开的越多，开机越慢。" : "打开的越多，开机越慢。").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("添加应用…", systemImage: "plus", action: addApps)
                    .disabled(loginError != nil)
            }
            .padding(16)
            Divider()
            if let loginError {
                permissionHint(loginError)
            } else if !loginLoaded {
                ProgressView().padding(20).frame(maxWidth: .infinity)
            } else {
                let rows = rows
                if rows.isEmpty {
                    Text("还没有登录时打开的应用。").foregroundStyle(.secondary).padding(16)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 3), spacing: 0) {
                    ForEach(rows) { row in
                        HStack(spacing: 12) {
                            Image(nsImage: FileIcon.image(row.path.isEmpty ? "/Applications/\(row.name).app" : row.path, folder: false, size: 30)).resizable().frame(width: 30, height: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name).lineLimit(1).foregroundStyle(row.on ? .primary : .secondary)
                                if let note = row.note {
                                    Text(note).font(.caption).foregroundStyle(row.kind == .missing || row.kind == .gone ? .orange : .secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            switch row.kind {
                            case .missing:
                                Button("移除") { toggle(row.name, row.path, false, keep: false) }
                            case .gone:
                                EmptyView()
                            default:
                                Toggle(row.name, isOn: Binding(get: { row.on }, set: { flip(row, $0) }))
                                    .toggleStyle(.switch).labelsHidden()
                            }
                        }
                        .padding(12)
                        .overlay(alignment: .bottom) { Divider() }
                    }
                }
                HStack {
                    Text("写着“软件自己设置的”是在那个软件的设置里开的，要在那个软件里或系统设置里关。")
                    Button("打开系统设置") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                    .buttonStyle(.link)
                }
                .font(.caption).foregroundStyle(.secondary).padding(14)
            }
        }
        .card()
    }

    private func permissionHint(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let denied = automationDenied
            Text("还看不到登录时打开的应用").fontWeight(.semibold)
            Text(denied ? "之前在系统弹窗里点了“不允许”。到“系统设置 › 隐私与安全性 › 自动化”里找到 Adieu，把“System Events”打开，再回来点“再试一次”。"
                        : "Adieu 要通过 macOS 自带的“系统事件”才能列出这些应用。点“允许”，系统会弹窗问你，选“好”就行。")
                .font(.callout).foregroundStyle(.secondary)
            Text("系统的原话：\(error)").font(.caption).foregroundStyle(.tertiary)
            HStack {
                if denied {
                    Button("打开系统设置") { NSWorkspace.shared.open(Permissions.automationSettings) }.buttonStyle(.borderedProminent)
                } else {
                    Button("允许") { Task { _ = await Permissions.requestAutomation(); await loadLogin() } }.buttonStyle(.borderedProminent)
                }
                Button("再试一次") { Task { await loadLogin() } }
            }
        }
        .padding(16)
    }

    /// 要等“系统事件”回话，在后台读
    private func loadLogin() async {
        if model.useSample {
            loginItems = Sample.loginApps.map { .init(name: $0.name, path: "/Applications") }
            loginLoaded = true
            return
        }
        async let found = blocking { RegisteredItems.scan() }
        let r = await blocking { () -> (items: [LoginItems.Item], error: String?, missing: Set<String>) in
            let r = LoginItems.list()
            let missing = r.items.filter { $0.path.isEmpty || !FileManager.default.fileExists(atPath: $0.path) }.map(\.name)
            return (r.items, r.error, Set(missing))
        }
        loginItems = r.items
        missingLogin = r.missing
        registered = await found
        loginError = r.error
        if r.error != nil { automationDenied = await blocking { Permissions.automation == .denied } }
        loginLoaded = true
    }

    // MARK: 合并：已装的软件 + 登录项 + 软件自己登记的

    private struct Row: Identifiable {
        enum Kind { case login, byApp, off, missing, gone }
        let name: String
        let path: String
        let kind: Kind
        let on: Bool
        var note: String?
        var id: String { path.isEmpty ? "#" + name : path }
    }

    /// 每个软件一行：登录项（能直接开关）> 软件自己登记的（只显示，拨了去系统设置）> 没开的（打开就加进登录项）。
    /// 开着的排前面
    private var rows: [Row] {
        var byPath: [String: Row] = [:]
        for app in model.apps { if let p = app.path { byPath[p] = Row(name: app.name, path: p, kind: .off, on: false) } }
        for (path, items) in Dictionary(grouping: registered, by: \.appPath) {
            let name = items[0].appName
            if !items[0].appExists {
                byPath[path] = Row(name: name, path: path, kind: .gone, on: false, note: String(localized: "应用已经不在了"))
            } else if items.contains(where: \.running) {
                byPath[path] = Row(name: byPath[path]?.name ?? name, path: path, kind: .byApp, on: true, note: String(localized: "软件自己设置的"))
            } else if items.contains(where: \.enabled) {
                byPath[path] = Row(name: byPath[path]?.name ?? name, path: path, kind: .byApp, on: false, note: String(localized: "系统设置里关掉了"))
            }
        }
        var extra: [Row] = []
        for item in loginItems {
            if missingLogin.contains(item.name) {
                extra.append(Row(name: item.name, path: item.path, kind: .missing, on: false, note: String(localized: "应用已经不在了")))
            } else {
                byPath[item.path] = Row(name: item.name, path: item.path, kind: .login, on: true)
            }
        }
        for (name, path) in removedLogin where byPath[path] == nil {
            byPath[path] = Row(name: name, path: path, kind: .login, on: false)
        }
        func rank(_ r: Row) -> Int { r.on ? 0 : r.kind == .byApp ? 1 : r.kind == .off || r.kind == .login ? 3 : 2 }
        return (Array(byPath.values) + extra).sorted {
            rank($0) != rank($1) ? rank($0) < rank($1) : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func flip(_ row: Row, _ on: Bool) {
        switch row.kind {
        case .byApp:
            // 苹果不让别的软件改这一类，带人去系统设置
            model.notice = String(localized: "\(row.name) 是在自己的设置里开的开机启动，到 \(row.name) 的设置里，或系统设置“登录项与扩展”里改。")
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
        case .login, .off:
            toggle(row.name, row.path, on)
        case .missing, .gone:
            break
        }
    }

    /// keep：关掉后留在列表里（灰着，可以再打开）；应用已经不在了的直接拿掉
    private func toggle(_ name: String, _ path: String, _ on: Bool, keep: Bool = true) {
        guard !model.useSample else { return }
        Task {
            if let error = await blocking({ on ? LoginItems.add(path: path) : LoginItems.remove(name) }) {
                model.notice = error
                return
            }
            if on || !keep { removedLogin[name] = nil } else { removedLogin[name] = path }
            await loadLogin()
        }
    }

    /// 从“应用程序”里挑，可以多选；已经在列表里的跳过
    private func addApps() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = "登录时打开"
        guard panel.runModal() == .OK, !model.useSample else { return }
        let existing = Set(loginItems.map(\.path))
        let urls = panel.urls.filter { !existing.contains($0.path) }
        Task {
            for url in urls {
                let path = url.path
                if let error = await blocking({ LoginItems.add(path: path) }) { model.notice = error; break }
                removedLogin[url.deletingPathExtension().lastPathComponent] = nil
            }
            await loadLogin()
        }
    }

    // MARK: 其他软件的后台程序

    @ViewBuilder private var background: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("其他软件的后台程序").font(.headline)
                Text("软件自带的小程序，没有窗口，负责同步、检查更新这些事。还在用的软件不用管它们。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            if model.launchGroups.isEmpty && model.launchLoading {
                ProgressView().padding(20).frame(maxWidth: .infinity)
            } else if broken.isEmpty {
                Label("没有失效的后台程序", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).padding(16)
            } else {
                brokenSection
            }
            if !others.isEmpty {
                Divider()
                DisclosureGroup(isExpanded: $showOthers) {
                    VStack(spacing: 0) {
                        ForEach(others, id: \.0.id) { item, group in
                            HStack {
                                NameAndPath(name: item.owner, path: item.label)
                                if let tag = tag(group) { Chip(text: tag, tint: group.color) }
                                Spacer()
                                if let plist = item.plist {
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: plist)]) } label: { Image(systemName: "magnifyingglass") }
                                        .buttonStyle(.borderless).help("在访达中显示")
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("还在用的软件的后台程序 \(others.count) 个").foregroundStyle(.secondary)
                }
                .padding(16)
            }
        }
        .card()
    }

    private var brokenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(broken.count) 个已经失效").fontWeight(.semibold)
                    Text("对应的软件已经删了，它们每次开机还会白白启动一次。清掉没有副作用。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("清掉", action: removeBroken).buttonStyle(.borderedProminent)
            }
            ForEach(broken) { item in
                NameAndPath(name: item.owner, path: item.plist ?? item.label)
            }
            if broken.contains(where: { !$0.isUser }) {
                Text("其中有系统级的，系统会要一次开机密码。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private func tag(_ group: LaunchGroup) -> String? {
        switch group.id {
        case "root": "系统级"
        case "updater": "自动更新"
        case "mine": "你自己配置的"
        default: nil
        }
    }

    /// 先停用用户级的，再删除 plist；系统级的由 perform 接着弹一次密码
    private func removeBroken() {
        let items = broken
        Task {
            // 停用要等对应的进程退出，在后台做
            await blocking { for item in items where item.isUser { LaunchScanner.unload(item) } }
            model.perform(.init(title: String(localized: "清掉失效的后台程序 \(items.count) 个"), source: "开机与后台",
                                urls: items.compactMap(\.plist).map { URL(filePath: $0) },
                                onDone: { _ in Task { await model.loadLaunch() } }))
        }
    }
}
