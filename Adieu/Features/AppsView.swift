import SwiftUI

struct AppsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: AppItem.ID?
    /// 用户改过勾选状态的部件，key 为 "应用ID:部件ID"
    @State private var overrides: [String: Bool] = [:]
    @State private var uninstalling: AppItem?
    @State private var search = ""
    /// “只清理数据”时应用还开着，问用户要不要强制退出
    @State private var quitPrompt: QuitPrompt?

    struct QuitPrompt: Identifiable {
        let app: AppItem
        let names: String
        var id: String { app.id }
    }

    private var filtered: [AppItem] {
        let list = model.apps.sorted { $0.total > $1.total }
        return search.isEmpty ? list : list.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        HSplitView {
            appList.frame(minWidth: 300, idealWidth: 330, maxWidth: 380)
            Group {
                if model.apps.isEmpty && model.appsLoading {
                    ProgressView("正在查找已安装的应用…")
                } else if let app = model.apps.first(where: { $0.id == selection }) {
                    AppInspector(app: app, overrides: $overrides, onUninstall: { uninstalling = app }, onCleanData: { cleanData(app) })
                } else {
                    ContentUnavailableView("选择一个应用", systemImage: "square.grid.2x2", description: Text("查看它在 Mac 上留下的所有东西"))
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "搜索应用")
        .onChange(of: model.apps.isEmpty, initial: true) {
            if selection == nil { selection = filtered.first?.id }
            // 启动参数 `-AdieuUninstall YES` 直接打开第一个应用的卸载确认（调试与截图用）
            if UserDefaults.standard.bool(forKey: "AdieuUninstall"), uninstalling == nil, let first = filtered.first { uninstalling = first }
        }
        .sheet(item: $uninstalling) { app in
            UninstallSheet(app: app, parts: app.parts.filter { isOn(app, $0) })
                .environment(model)
        }
        .alert(quitPrompt.map { String(localized: "\($0.names) 没有退出") } ?? "",
               isPresented: Binding(get: { quitPrompt != nil }, set: { if !$0 { quitPrompt = nil } }), presenting: quitPrompt) { prompt in
            Button("强制退出并清理", role: .destructive) { Task { await forceQuitThenClean(prompt.app) } }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("清理前要先关掉它，不然它会把数据写回去，正在用的数据也可能删坏。强制退出的话，没保存的内容会丢掉；想先保存，就取消，自己退出它之后再来清理。")
        }
    }

    private var appList: some View {
        List(filtered, selection: $selection) { app in
            HStack(spacing: 11) {
                AppIcon(app: app, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(app.name).fontWeight(.semibold).lineLimit(1)
                        if app.isRunning {
                            Circle().fill(.green).frame(width: 6, height: 6).help("正在运行")
                        }
                    }
                    Text(app.dataSize > 0
                         ? String(localized: "应用 \(app.appSize.gbText) · 数据 \(app.dataSize.gbText)")
                         : String(localized: "应用 \(app.appSize.gbText)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if app.isMeasured {
                    Text(app.total.gbText).fontWeight(.semibold).monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.vertical, 4)
            .tag(app.id)
        }
        .listStyle(.inset)
    }

    private func isOn(_ app: AppItem, _ p: AppPart) -> Bool {
        overrides["\(app.id):\(p.id)"] ?? p.defaultOn
    }

    /// 只清理数据：应用开着就先请它退出，再删勾选的数据
    private func cleanData(_ app: AppItem) {
        if !model.useSample, AppQuit.isRunning(app) {
            quitPrompt = .init(app: app, names: AppQuit.names(AppQuit.processes(of: app), fallback: app.name))
        } else {
            requestClean(app)
        }
    }

    private func forceQuitThenClean(_ app: AppItem) async {
        quitPrompt = nil
        let left = await AppQuit.forceQuit(app)
        if left.isEmpty {
            requestClean(app)
        } else {
            model.notice = String(localized: "\(AppQuit.names(left, fallback: app.name)) 强制退出也没有退出，什么都没删。")
        }
    }

    /// 应用已经不在运行：勾选的数据直接删除，完成后重新统计这个应用
    private func requestClean(_ app: AppItem) {
        let parts = app.parts.filter { $0.kind != .app && isOn(app, $0) }
        var sizes: [String: Double] = [:]
        for p in parts { if let s = p.size { sizes[(p.path as NSString).expandingTildeInPath] = s } }
        model.requestTrash(.init(
            title: String(localized: "清理 \(app.name) 的数据"), source: "已安装",
            urls: parts.map { URL(filePath: ($0.path as NSString).expandingTildeInPath) },
            sizes: sizes,
            onDone: { _ in Task { await model.remeasure(app.id) } }))
    }
}

private struct AppInspector: View {
    let app: AppItem
    @Binding var overrides: [String: Bool]
    let onUninstall: () -> Void
    let onCleanData: () -> Void

    private func key(_ p: AppPart) -> String { "\(app.id):\(p.id)" }
    private func isOn(_ p: AppPart) -> Bool { overrides[key(p)] ?? p.defaultOn }
    private var chosen: [AppPart] { app.parts.filter(isOn) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    composition
                    if let notice = app.notice {
                        Label(notice, systemImage: "info.circle")
                            .font(.callout)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.12), in: .rect(cornerRadius: 10))
                    }
                    partsList
                }
                .padding(28)
            }
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            AppIcon(app: app, size: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.title.bold())
                Text(app.meta).font(.callout.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(chosen.compactMap(\.size).reduce(0, +).gbText)
                    .font(.system(size: 28, weight: .bold)).monospacedDigit()
                    .contentTransition(.numericText())
                Text("将移除 \(chosen.count) 项").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var composition: some View {
        VStack(alignment: .leading, spacing: 8) {
            SegmentBar(segments: app.parts.compactMap { p in
                p.size.map { .init(value: $0, color: p.kind.color, dimmed: !isOn(p)) }
            }, height: 10)
            HStack(spacing: 16) {
                ForEach(PartKind.allCases, id: \.self) { kind in
                    let size = app.parts.filter { $0.kind == kind }.compactMap(\.size).reduce(0, +)
                    if size > 0 {
                        HStack(spacing: 5) {
                            Circle().fill(kind.color).frame(width: 8, height: 8)
                            Text(kind.label).foregroundStyle(.secondary)
                            Text(size.gbText).fontWeight(.semibold).monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    private var partsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("相关文件").fontWeight(.semibold)
                Spacer()
                Text("每一项都标明它为什么属于这个应用").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            ForEach(app.parts) { p in
                HStack(spacing: 12) {
                    Toggle(isOn: Binding(get: { isOn(p) }, set: { overrides[key(p)] = $0 })) { EmptyView() }
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .accessibilityLabel(p.label)
                    FileIcon(path: p.path, size: 28)
                    NameAndPath(name: p.label, path: p.path, hint: p.hint, important: p.isPersonalData).opacity(isOn(p) ? 1 : 0.55)
                    Spacer()
                    EvidenceChip(evidence: p.evidence)
                    Text(p.size.gbText).fontWeight(.semibold).monospacedDigit().frame(width: 70, alignment: .trailing)
                        .opacity(isOn(p) ? 1 : 0.55)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                Divider()
            }
        }
        .card()
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label("卸载和清理数据都是直接删干净，不进废纸篓", systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("只清理数据", action: onCleanData)
                .disabled(!chosen.contains { $0.kind != .app })
            Button("卸载 \(app.name)…", action: onUninstall)
                .buttonStyle(.borderedProminent)
                .disabled(!chosen.contains { $0.kind == .app })
        }
        .controlSize(.large)
        .padding(.horizontal, 28).padding(.vertical, 14)
        .background(.bar)
    }
}

/// 卸载流程：确认 → 进行中 → 完成
struct UninstallSheet: View {
    let app: AppItem
    let parts: [AppPart]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .confirm
    @State private var entry: HistoryEntry?
    @State private var failures: String?

    /// stuck：请应用退出 5 秒后还没退，等用户决定强制退出还是取消
    enum Step: Equatable { case confirm, working, stuck(String), done }
    /// 卸载前在系统里停用了输入法；取消时要恢复
    @State private var disabledInputMethod = false

    private var total: Double { parts.compactMap(\.size).reduce(0, +) }

    var body: some View {
        VStack(spacing: 16) {
            switch step {
            case .confirm: confirm
            case .working: working
            case .stuck(let names): stuck(names)
            case .done: done
            }
        }
        .padding(28)
        .frame(width: 440)
        .animation(.smooth, value: step)
    }

    private var confirm: some View {
        VStack(spacing: 14) {
            AppIcon(app: app, size: 64)
            Text("卸载 \(app.name)？").font(.headline)
            Text(String(localized: "将删除 \(parts.count) 项、共 \(total.gbText)，不进废纸篓，删完立刻腾出空间。") + (app.isRunning ? String(localized: "\(app.name) 还开着，卸载前要先关掉它。") : ""))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if needsPassword {
                Label(String(localized: "\(app.name) 归系统管理员所有（App Store 装的应用常这样），点“卸载”后系统会请你输入一次开机密码。"), systemImage: "lock")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.brand.opacity(0.08), in: .rect(cornerRadius: 8))
            }
            let personal = parts.filter(\.isPersonalData)
            if !personal.isEmpty {
                Label(String(localized: "其中 \(personal.count) 项是个人数据（共 \(personal.compactMap(\.size).reduce(0, +).gbText)），可能有聊天记录、文档和账号，删了找不回来。想保留就取消，回到详情里不勾它们。"),
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.1), in: .rect(cornerRadius: 8))
            }
            VStack(spacing: 0) {
                ForEach(parts) { p in
                    HStack(spacing: 8) {
                        FileIcon(path: p.path, size: 18)
                        Text(Copy.text(p.label))
                        Spacer()
                        Text(p.size.gbText).foregroundStyle(.secondary).monospacedDigit()
                    }
                        .font(.callout).padding(.vertical, 6)
                    Divider()
                }
            }
            .padding(.horizontal, 12)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).frame(maxWidth: .infinity)
                Button("卸载") { Task { await uninstall() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
    }

    /// 应用包本身不归当前用户所有时，移动它要管理员密码
    private var needsPassword: Bool {
        guard let path = app.path, parts.contains(where: { $0.kind == .app }) else { return false }
        // 删除要能改它所在的文件夹（/Library/Input Methods 归 root）
        let fm = FileManager.default
        return !fm.isWritableFile(atPath: path) || !fm.isWritableFile(atPath: (path as NSString).deletingLastPathComponent)
    }

    /// 应用开着就先停下来问用户要不要强制退出；没开着直接删除勾选的部分
    private func uninstall() async {
        if !model.useSample, AppQuit.isRunning(app) {
            step = .stuck(AppQuit.names(AppQuit.processes(of: app), fallback: app.name))
            return
        }
        step = .working
        if model.useSample {
            try? await Task.sleep(for: .seconds(1.2))
            step = .done
            return
        }
        disableInputMethod()
        await remove()
    }

    private func forceQuitAndUninstall() async {
        step = .working
        // 输入法要先在系统里停用，不然退出后系统会马上再把它拉起来
        disableInputMethod()
        let left = await AppQuit.forceQuit(app)
        if !left.isEmpty {
            failures = String(localized: "\(AppQuit.names(left, fallback: app.name)) 强制退出也没有退出，什么都没删。")
            cancelStuck(keepOpen: true)
            step = .done
            return
        }
        await remove()
    }

    private func disableInputMethod() {
        guard let path = app.path, InputMethods.isInputMethod(URL(filePath: path), info: Bundle(url: URL(filePath: path))?.infoDictionary) else { return }
        InputMethods.disable(bundleID: app.id)
        disabledInputMethod = true
    }

    /// 取消卸载：把停用的输入法恢复回来
    private func cancelStuck(keepOpen: Bool = false) {
        if disabledInputMethod { InputMethods.enable(bundleID: app.id); disabledInputMethod = false }
        if !keepOpen { dismiss() }
    }

    /// 应用已经退出，停掉启动项、删除勾选的部分
    private func remove() async {
        let agents = parts.filter { $0.kind == .background && $0.id.hasPrefix("agent.") }
            .map { LaunchItem(owner: app.name, label: String($0.id.dropFirst(6)), isUser: true) }
        await blocking { for a in agents { LaunchScanner.unload(a) } }
        let appPath = app.path
        let logins = await blocking { appPath.map(LoginItems.names(pointingInto:)) ?? [] }
        let urls = parts.map { URL(filePath: ($0.path as NSString).expandingTildeInPath) }
        var sizes: [String: Double] = [:]
        for (u, p) in zip(urls, parts) { if let s = p.size { sizes[u.path] = s } }
        model.notice = nil
        entry = await model.deleteForUninstall(.init(title: String(localized: "卸载 \(app.name)"), source: "已安装", urls: urls, sizes: sizes))
        // 失败原因在这里直接显示，不再弹第二个提示
        failures = model.notice
        model.notice = nil
        if let entry, entry.files.contains(where: { $0.originalPath == app.path }) {
            model.apps.removeAll { $0.id == app.id }
            await blocking { for name in logins { _ = LoginItems.remove(name) } }
        }
        step = .done
    }

    private func stuck(_ names: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(.orange)
            Text("\(names) 没有退出").font(.headline)
            Text("卸载前要先关掉它。强制退出的话，没保存的内容会丢掉；想先保存，就取消，自己退出它之后再来卸载。")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("取消") { cancelStuck() }.keyboardShortcut(.cancelAction).frame(maxWidth: .infinity)
                Button("强制退出并卸载") { Task { await forceQuitAndUninstall() } }
                    .buttonStyle(.borderedProminent).tint(.red)
            }
            .controlSize(.large)
        }
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AppIcon(app: app, size: 40)
                VStack(alignment: .leading) {
                    Text("正在卸载 \(app.name)").fontWeight(.semibold)
                    Text(needsPassword ? "要输入开机密码的话，系统会弹窗…" : "正在删除…").font(.caption).foregroundStyle(.secondary)
                }
            }
            ProgressView().progressViewStyle(.linear)
        }
    }

    private var done: some View {
        let moved = entry?.total ?? (model.useSample ? total : 0)
        return VStack(spacing: 12) {
            Image(systemName: failures == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 52)).foregroundStyle(failures == nil ? .green : .orange)
                .symbolEffect(.bounce, value: step)
            Text(failures == nil ? "\(app.name) 已经删干净了" : "\(app.name) 没有完全卸载").font(.headline)
            Text(moved.gbText).font(.system(size: 40, weight: .bold)).monospacedDigit()
            // 删后核对两秒后才有结果，到了就补上
            if let actual = model.history.first(where: { $0.id == entry?.id })?.actualFreed {
                Text("磁盘实际多出 \(actual.gbText)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            if let failures {
                Text(failures).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).background(.orange.opacity(0.1), in: .rect(cornerRadius: 8))
            }
            Text(failures == nil ? "空间已经腾出来了。以后还想用，重新下载安装就行。" : "上面没删掉的还留在原处。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("完成") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
    }
}
