import SwiftUI
import UniformTypeIdentifiers

/// 开机与后台：登录项放主位，能关、能加；其他软件的后台程序只帮你清掉已经失效的
struct LaunchItemsView: View {
    @Environment(AppModel.self) private var model
    @State private var loginItems: [LoginItems.Item] = []
    @State private var loginError: String?
    @State private var loginLoaded = false
    /// 这次关掉的登录项，用来重新打开
    @State private var removedLogin: [String: String] = [:]
    @State private var showOthers = false

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
        .onAppear { if !loginLoaded { loadLogin() } }
    }

    // MARK: 登录项

    @ViewBuilder private var login: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("登录时打开").font(.headline)
                    Text("打开的越多，开机越慢。").font(.callout).foregroundStyle(.secondary)
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
                let rows = loginItems.map { ($0.name, $0.path, true) } + removedLogin.sorted { $0.key < $1.key }.map { ($0.key, $0.value, false) }
                if rows.isEmpty {
                    Text("还没有登录时打开的应用。").foregroundStyle(.secondary).padding(16)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 3), spacing: 0) {
                    ForEach(rows, id: \.0) { name, path, on in
                        HStack(spacing: 12) {
                            Image(nsImage: FileIcon.image(path, folder: false, size: 30)).resizable().frame(width: 30, height: 30)
                            Text(name).lineLimit(1).foregroundStyle(on ? .primary : .secondary)
                            Spacer()
                            Toggle(name, isOn: Binding(get: { on }, set: { toggle(name, path, $0) }))
                                .toggleStyle(.switch).labelsHidden()
                        }
                        .padding(12)
                        .overlay(alignment: .bottom) { Divider() }
                    }
                }
                HStack {
                    Text("有些应用是在自己的设置里开的“开机启动”，不在这里，系统设置里能看到全部。")
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
            let denied = Permissions.automation == .denied
            Text("还看不到登录时打开的应用").fontWeight(.semibold)
            Text(denied ? "之前在系统弹窗里点了“不允许”。到“系统设置 › 隐私与安全性 › 自动化”里找到 Adieu，把“System Events”打开，再回来点“再试一次”。"
                        : "Adieu 要通过 macOS 自带的“系统事件”才能列出这些应用。点“允许”，系统会弹窗问你，选“好”就行。")
                .font(.callout).foregroundStyle(.secondary)
            Text("系统的原话：\(error)").font(.caption).foregroundStyle(.tertiary)
            HStack {
                if denied {
                    Button("打开系统设置") { NSWorkspace.shared.open(Permissions.automationSettings) }.buttonStyle(.borderedProminent)
                } else {
                    Button("允许") { Task { _ = await Permissions.requestAutomation(); loadLogin() } }.buttonStyle(.borderedProminent)
                }
                Button("再试一次", action: loadLogin)
            }
        }
        .padding(16)
    }

    private func loadLogin() {
        if model.useSample {
            loginItems = Sample.loginApps.map { .init(name: $0.name, path: "/Applications") }
            loginLoaded = true
            return
        }
        let r = LoginItems.list()
        loginItems = r.items
        loginError = r.error
        loginLoaded = true
    }

    private func toggle(_ name: String, _ path: String, _ on: Bool) {
        guard !model.useSample else { return }
        if let error = on ? LoginItems.add(path: path) : LoginItems.remove(name) {
            model.notice = error
            return
        }
        if on { removedLogin[name] = nil } else { removedLogin[name] = path }
        loadLogin()
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
        for url in panel.urls where !existing.contains(url.path) {
            if let error = LoginItems.add(path: url.path) { model.notice = error; break }
            removedLogin[url.deletingPathExtension().lastPathComponent] = nil
        }
        loadLogin()
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
        for item in items where item.isUser { LaunchScanner.unload(item) }
        model.perform(.init(title: String(localized: "清掉失效的后台程序 \(items.count) 个"), source: "开机与后台",
                            urls: items.compactMap(\.plist).map { URL(filePath: $0) },
                            onDone: { _ in Task { await model.loadLaunch() } }))
    }
}
