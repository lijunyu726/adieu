import SwiftUI

@main
struct AdieuApp: App {
    @State private var model = AppModel()
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
