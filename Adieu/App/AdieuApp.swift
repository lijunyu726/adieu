import SwiftUI

extension URL {
    /// 官网上的使用手册。交给浏览器打开；Adieu 自己只在检查更新时访问 GitHub
    static let adieuManual = URL(string: "https://adieu.lijunyu.com.cn/manual/")!
}

@main
struct AdieuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var model: AppModel { delegate.model }
    @AppStorage("showMenuBar") private var showMenuBar = true

    var body: some Scene {
        WindowGroup("Adieu", id: "main") {
            RootView()
                .environment(model)
                .tint(Theme.brand)
                // 只做浅色：深色下渐变底和白卡片像自发光，用户不要
                .preferredColorScheme(.light)
                .frame(minWidth: 1080, minHeight: 700)
                .task { await model.scanAll() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.refreshDisk()
                }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("显示欢迎页") { model.showOnboarding = true }
            }
            CommandGroup(after: .newItem) {
                Button("重新扫描") { Task { await model.scanAll(force: true) } }
                    .keyboardShortcut("r")
            }
            // 没有本地帮助文档，系统默认的“Adieu 帮助”会提示找不到，换成官网手册
            CommandGroup(replacing: .help) {
                Link("Adieu 使用手册", destination: .adieuManual)
                    .keyboardShortcut("?")
            }
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarView()
                .environment(model)
                .preferredColorScheme(.light)
        } label: {
            Image(nsImage: MenuBarIcon.image).accessibilityLabel("Adieu")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(.light)
                .tint(Theme.brand)
        }
    }
}

/// 开机时由“登录时打开 Adieu”启动的话，不弹主窗口，只在后台扫描、跑自动规则，待在菜单栏（和 Dock）里；
/// 点菜单栏的“打开 Adieu”或 Dock 图标再打开窗口。调试参数 `-AdieuLaunchHidden YES` 走同一条路
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    override init() {
        super.init()
        AppLanguage.captureLaunch()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.bool(forKey: "AdieuUpdatePreview") {
            UpdatePrompt.preview()
        }
        Task { await UpdatePrompt.automatic() }
        guard Self.launchedAtLogin || UserDefaults.standard.bool(forKey: "AdieuLaunchHidden") else { return }
        // 窗口不在了，扫描就不能指望窗口里的 .task；自动规则的计时器在扫描结束时启动
        Task { await model.scanAll() }
        // SwiftUI 在这之后才把主窗口摆出来，下一轮主循环再关
        DispatchQueue.main.async {
            for window in NSApp.windows where window.canBecomeMain { window.close() }
        }
    }

    /// 退到后台一分钟还没回来：清掉缩略图缓存，把扫描时用过、已经空出来的内存还给系统。回来时缩略图再生成
    private var relief: Task<Void, Never>?

    func applicationDidResignActive(_ notification: Notification) {
        relief?.cancel()
        relief = Task {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            Thumbnail.purge()
            releaseFreedMemory()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) { relief?.cancel() }

    /// 登录项启动时，系统发来的“打开应用”事件里带着 keyAELaunchedAsLogInItem
    private static var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

/// 菜单栏图标：和应用图标同一个意思，一个圆角方块的右上角散成小方块。模板图，跟随菜单栏深浅色
enum MenuBarIcon {
    static let image: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            // 茎：从花心弯到左下角
            let stem = NSBezierPath()
            stem.lineWidth = 1.3
            stem.lineCapStyle = .round
            stem.move(to: NSPoint(x: 7, y: 8.5))
            stem.curve(to: NSPoint(x: 4, y: 17), controlPoint1: NSPoint(x: 6.8, y: 12), controlPoint2: NSPoint(x: 5, y: 14.5))
            stem.stroke()
            // 花心
            NSBezierPath(ovalIn: NSRect(x: 5.6, y: 5.6, width: 2.8, height: 2.8)).fill()
            // 绒毛：一圈细线，末端是小方块；右上方缺几根，飘走了
            let c = NSPoint(x: 7, y: 7)
            for deg in stride(from: 0.0, to: 360.0, by: 30.0) where !(deg > 285 && deg < 345) && !(deg > 75 && deg < 130) {
                let a = deg * .pi / 180
                let line = NSBezierPath()
                line.lineWidth = 0.7
                line.move(to: NSPoint(x: c.x + cos(a) * 2.2, y: c.y + sin(a) * 2.2))
                line.line(to: NSPoint(x: c.x + cos(a) * 4.6, y: c.y + sin(a) * 4.6))
                line.stroke()
                let p = NSPoint(x: c.x + cos(a) * 5.4, y: c.y + sin(a) * 5.4)
                NSBezierPath(roundedRect: NSRect(x: p.x - 0.8, y: p.y - 0.8, width: 1.6, height: 1.6), xRadius: 0.35, yRadius: 0.35).fill()
            }
            // 飘走的种子
            for (x, y, s) in [(12.6, 2.6, 1.8), (15.4, 4.8, 1.5), (15.6, 1.0, 1.2)] as [(CGFloat, CGFloat, CGFloat)] {
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: s, height: s), xRadius: 0.35, yRadius: 0.35).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }()
}

/// 扫描时临时用了大量小块内存，用完放掉以后系统内存分配器还留着这些页，活动监视器里看着一直很高：主动还回去
func releaseFreedMemory() {
    malloc_zone_pressure_relief(nil, 0)
}
