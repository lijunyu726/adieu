import SwiftUI
import ServiceManagement

/// 设置窗口（⌘,）
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("安全", systemImage: "lock.shield") { SafetySettings() }
            Tab("自动规则", systemImage: "wand.and.stars") { RulesView() }
            Tab("通用", systemImage: "switch.2") { GeneralSettings() }
            Tab("权限", systemImage: "hand.raised") { PermissionSettings() }
            Tab("关于", systemImage: "info.circle") { AboutView() }
        }
        .frame(width: 760, height: 560)
    }
}

private struct SafetySettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("confirmAlways") private var confirmAlways = true

    var body: some View {
        Form {
            Section {
                LabeledContent("删除方式") { Text("直接删除，不进废纸篓，立刻腾出空间").foregroundStyle(.secondary) }
                Toggle("删除前总是再确认一次", isOn: $confirmAlways)
            } footer: {
                Text("卸载应用、清理文件都是直接删掉，不用再去清空废纸篓，删了不能放回。所以默认删除前确认一次；侧边栏底部的“最近”里有每次删了什么。")
            }
            Section {
                ForEach(model.protectedPaths, id: \.self) { p in
                    HStack {
                        Image(systemName: "lock.fill").foregroundStyle(.secondary)
                        Text(p).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("移除", role: .destructive) { model.protectedPaths.removeAll { $0 == p } }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button("添加文件夹或应用…", action: add)
                    Spacer()
                    Button("恢复默认") { model.protectedPaths = TrashService.defaultProtected }
                        .buttonStyle(.borderless)
                }
            } header: {
                Text("保护名单")
            } footer: {
                Text("放进来的文件夹，Adieu 不会碰它和它里面的东西。")
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "加入保护名单"
        guard panel.runModal() == .OK else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for url in panel.urls {
            let p = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
            if !model.protectedPaths.contains(p) { model.protectedPaths.append(p) }
        }
    }
}

private struct GeneralSettings: View {
    @AppStorage("showMenuBar") private var showMenuBar = true
    @State private var sound = DeleteSound.current
    @State private var loginItem = SMAppService.mainApp.status == .enabled

    private func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {}
        loginItem = SMAppService.mainApp.status == .enabled
    }

    var body: some View {
        Form {
            Section {
                Toggle("在菜单栏显示 Adieu", isOn: $showMenuBar)
                Toggle("登录时打开 Adieu", isOn: Binding(get: { loginItem }, set: setLoginItem))
            } header: {
                Text("菜单栏与启动")
            } footer: {
                Text("自动规则只在 Adieu 开着的时候工作。打开“登录时打开 Adieu”后，开机就会悄悄启动，关掉窗口它也会待在菜单栏里。")
            }
            Section("声音") {
                Picker("删除完成时", selection: $sound) {
                    ForEach(DeleteSound.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: sound) { _, new in
                    UserDefaults.standard.set(new.rawValue, forKey: DeleteSound.key)
                    new.preview()
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionSettings: View {
    @State private var fullDisk = Permissions.hasFullDiskAccess
    @State private var automation = Permissions.automation
    @State private var notifications: Permissions.State?
    @State private var asking = false

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    symbol: "internaldrive.fill", tint: .blue,
                    title: "查看所有文件夹",
                    detail: "系统里叫“完全磁盘访问权限”。没有它，微信、邮件这类应用藏在自己文件夹里的数据看不到：首页的大小会算不准，卸载时残留也会漏掉。Adieu 只在本机读取和统计，不上传。",
                    state: fullDisk ? .granted : .denied,
                    howTo: "点“打开系统设置”，在列表里找到 Adieu 把开关打开；列表里没有的话，点下面的“+”，选“应用程序 › Adieu”。打开后回到 Adieu 按 ⌘R 重新扫描。",
                    action: fullDisk ? nil : .init(title: "打开系统设置", run: openFullDisk))
                PermissionRow(
                    symbol: "power", tint: .pink,
                    title: "管理“登录时打开”的应用",
                    detail: "系统里叫“自动化 › 系统事件”。“开机与后台”页面要通过 macOS 自带的“系统事件”列出开机时自动打开的应用，你关掉哪个它才能帮你关。不会控制别的东西。",
                    state: automation,
                    howTo: automation == .denied
                        ? "之前点过“不允许”。点“打开系统设置”，在“自动化”里找到 Adieu，把下面的“System Events”打开。"
                        : "系统规定这项权限不能在系统设置里手动添加：要 Adieu 先问一次，系统才会弹窗，也才会在设置的“自动化”列表里出现。点“允许”，弹窗里选“好”。",
                    action: automationAction)
                PermissionRow(
                    symbol: "bell.badge.fill", tint: .red,
                    title: "通知",
                    detail: "只在自动规则帮你做了事、或者需要你看一眼时提醒，比如“下载里有 3 个安装包对应的应用已经装好了”。不开也能正常用，只是不会提醒。",
                    state: notifications ?? .notAsked,
                    howTo: notifications == .denied
                        ? "之前关掉了。点“打开系统设置”，在“通知”里找到 Adieu，打开“允许通知”。"
                        : "Adieu 还没向系统申请过，所以系统设置的通知列表里暂时找不到它。点“允许”，系统会弹窗问你。",
                    action: notificationAction)
                PermissionRow(
                    symbol: "key.fill", tint: .gray,
                    title: "管理员密码",
                    detail: "不需要。系统目录里的后台服务，Adieu 只帮你在访达里找到，由你自己决定要不要动。",
                    state: .granted, howTo: nil, action: nil, okText: "不需要")
            } footer: {
                Text(asking ? "等你在系统弹窗里选择…" : "授权完回到这里，状态会自动刷新。")
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await refresh() } }
    }

    private func openFullDisk() { NSWorkspace.shared.open(Permissions.fullDiskAccessSettings) }

    private var automationAction: PermissionRow.Action? {
        switch automation {
        case .granted: nil
        case .denied: .init(title: "打开系统设置") { NSWorkspace.shared.open(Permissions.automationSettings) }
        case .notAsked: .init(title: "允许", run: askAutomation)
        }
    }

    private var notificationAction: PermissionRow.Action? {
        switch notifications ?? .notAsked {
        case .granted: nil
        case .denied: .init(title: "打开系统设置") { NSWorkspace.shared.open(Permissions.notificationSettings) }
        case .notAsked: .init(title: "允许", run: askNotifications)
        }
    }

    private func askAutomation() {
        Task {
            asking = true
            automation = await Permissions.requestAutomation()
            asking = false
        }
    }

    private func askNotifications() {
        Task {
            _ = await Notifier.requestAuthorization()
            await refresh()
        }
    }

    private func refresh() async {
        fullDisk = Permissions.hasFullDiskAccess
        automation = Permissions.automation
        notifications = await Notifier.state()
    }
}

/// 一项权限：做什么用、现在什么状态、下一步怎么做
private struct PermissionRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let state: Permissions.State
    let howTo: String?
    struct Action {
        let title: String
        let run: () -> Void
    }
    let action: Action?
    var okText = "已允许"

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SymbolTile(symbol: symbol, tint: tint, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).fontWeight(.semibold)
                    Spacer()
                    switch state {
                    case .granted: Chip(text: okText, tint: .green)
                    case .denied: Chip(text: "没有开", tint: .orange)
                    case .notAsked: Chip(text: "还没开", tint: .orange)
                    }
                    if let action { Button(action.title, action: action.run).buttonStyle(.borderedProminent) }
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if state != .granted, let howTo {
                    Label(howTo, systemImage: "lightbulb").font(.callout).foregroundStyle(.secondary)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.brand.opacity(0.07), in: .rect(cornerRadius: 8))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 10) {
            AdieuLogo(size: 96)
            Text("Adieu").font(.title.bold())
            Text("好好告别，不留遗憾也不留残渣。").foregroundStyle(.secondary)
            Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") · 只在本机运行，不需要账号")
                .font(.caption).foregroundStyle(.tertiary)
            Link("使用手册 ↗", destination: .adieuManual).padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
