import SwiftUI

/// 侧边栏的入口。按“要处理的东西”分组：应用、文件、开发工具。
/// 处理方式（逐个看、自动规则）放在各页面里，不单独占入口。
enum AppSection: String, Hashable, CaseIterable, Identifiable, Sendable {
    case home
    case apps, leftovers, launch
    case installers, captures, bigFiles, stale
    case devTools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "概览"
        case .apps: "已安装"
        case .leftovers: "残留文件"
        case .launch: "开机与后台"
        case .installers: "安装包与压缩包"
        case .captures: "截图与录屏"
        case .bigFiles: "大文件"
        case .stale: "久未打开"
        case .devTools: "开发工具"
        }
    }

    var symbol: String {
        switch self {
        case .home: "chart.bar.xaxis"
        case .apps: "square.grid.2x2"
        case .leftovers: "shippingbox"
        case .launch: "power"
        case .installers: "arrow.down.circle"
        case .captures: "camera.viewfinder"
        case .bigFiles: "doc.badge.ellipsis"
        case .stale: "clock"
        case .devTools: "terminal"
        }
    }

    /// 侧边栏和页头图标块的颜色
    var tint: Color {
        switch self {
        case .home: Theme.brand
        case .apps: .blue
        case .leftovers: .orange
        case .launch: .pink
        case .installers: .purple
        case .captures: .teal
        case .bigFiles: .orange
        case .stale: .gray
        case .devTools: .green
        }
    }

    /// 侧边栏右侧的小字（示例数据）
    var badge: String? {
        switch self {
        case .apps: "9"
        case .leftovers: "7.1 GB"
        case .launch: "1 个失效"
        case .installers: "3.9 GB"
        case .captures: "4.2 GB"
        case .bigFiles: "17 个"
        case .stale: "5.0 GB"
        case .devTools: "33.8 GB"
        default: nil
        }
    }
}

/// 不占侧边栏入口、在任何页面都能打开的面板
enum AppSheet: String, Identifiable, Sendable {
    case goal, history, diary
    /// 只用于截图，界面上没有入口：`-AdieuSheet menuBar` / `onboarding` 把菜单栏面板、欢迎页直接放在窗口右边显示。
    /// 后台开的实例里，弹出面板经常截不到图，放在窗口里就稳定
    case menuBar, onboarding
    var id: String { rawValue }
    var isPreview: Bool { self == .menuBar || self == .onboarding }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar(selection: $model.section)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 290)
        } detail: {
            Group {
                if let preview = model.sheet, preview.isPreview {
                    sheetContent(preview).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    detail(for: model.section)
                }
            }
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                .background { PageBackground() }
        }
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView()
        }
        .sheet(item: Binding(get: { model.sheet?.isPreview == true ? nil : model.sheet }, set: { model.sheet = $0 })) { sheet in
            SheetContainer { sheetContent(sheet) }
                .background { PageBackground() }
                .environment(model)
                .trashConfirmation()
        }
        .trashConfirmation(active: model.sheet == nil)
    }

    @ViewBuilder
    private func detail(for section: AppSection) -> some View {
        switch section {
        case .home: HomeView()
        case .apps: AppsView()
        case .leftovers: LeftoversView()
        case .launch: LaunchItemsView()
        case .devTools: DevSpaceView()
        case .installers, .captures, .bigFiles, .stale:
            if let category = model.category(section) {
                FileCategoryView(category: category).id(section)
            } else {
                ScanWaitHint(text: "正在扫描桌面、文稿、下载等文件夹…")
            }
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: AppSheet) -> some View {
        switch sheet {
        case .goal: GoalView().frame(width: 960, height: 640)
        case .history: HistoryView().frame(width: 900, height: 620)
        case .diary: DiaryView().frame(width: 1000, height: 660)
        case .menuBar: MenuBarView()
        case .onboarding: OnboardingView()
        }
    }
}

/// 面板外框：顶部一条放“完成”，Esc 也能关
private struct SheetContainer<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            content
        }
    }
}

private struct Sidebar: View {
    @Binding var selection: AppSection
    @Environment(AppModel.self) private var model

    private let groups: [(String?, [AppSection])] = [
        (nil, [.home]),
        ("应用", [.apps, .leftovers, .launch]),
        ("文件", [.installers, .captures, .bigFiles, .stale]),
        ("开发", [.devTools])
    ]

    /// 已安装应用数取真实扫描结果，其余仍是示例数据
    private func badge(for s: AppSection) -> String? {
        model.badge(for: s)
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(groups.indices, id: \.self) { i in
                let (title, items) = groups[i]
                Section {
                    ForEach(items) { s in
                        Label(s.title, systemImage: s.symbol)
                            .badge(badge(for: s).map { Text($0).monospacedDigit().foregroundStyle(s == .launch ? .red : .secondary) })
                            .tag(s)
                    }
                } header: {
                    if let title { Text(title) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                DiskSummary()
                HStack(spacing: 6) {
                    SettingsLink {
                        Label("设置与规则", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button { model.sheet = .history } label: {
                        Label("最近", systemImage: "clock.arrow.circlepath")
                    }
                    .help("最近操作：每次删了什么")
                    // 系统标准的“?”帮助按钮，侧边栏窄，放不下文字
                    HelpLink(destination: .adieuManual)
                        .controlSize(.small)
                        .help("使用手册（在官网打开）")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 6)
            }
            .padding(12)
        }
    }
}

/// 侧边栏底部的磁盘余量
struct DiskSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let disk = model.disk
        let used = disk.used / disk.total
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(disk.name).fontWeight(.semibold)
                Spacer()
                Text("可用 \(disk.free.gbText)").foregroundStyle(.secondary)
            }
            .font(.caption)
            ProgressView(value: used)
                .tint(used > 0.9 ? .red : Theme.brand)
        }
        .padding(12)
        .background(.background.opacity(0.7), in: .rect(cornerRadius: 12, style: .continuous))
    }
}
