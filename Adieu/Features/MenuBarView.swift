import SwiftUI

/// 菜单栏面板：剩余空间、刚装好应用留下的安装包、低空间提醒
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var cleaned = false

    /// 对应应用已经装好的安装包，最多显示 3 个
    private var packages: [FileItem] {
        if model.useSample {
            return [.init(id: "1", name: "WeChatMac_4.1.15.dmg", ext: "DMG", kind: "", location: "", modified: "微信已安装", size: 541.0 / 1000, reason: ""),
                    .init(id: "2", name: "WorkBuddy-darwin-arm64-5.6.2….dmg", ext: "DMG", kind: "", location: "", modified: "WorkBuddy AI 已安装", size: 533.0 / 1000, reason: ""),
                    .init(id: "3", name: "MiniMax Design-3.0.20-arm64.dmg", ext: "DMG", kind: "", location: "", modified: "MiniMax Design 已安装", size: 406.0 / 1000, reason: "")]
        }
        return (model.category(.installers)?.items ?? []).filter { $0.modified.hasSuffix("已安装") && !model.removedKeys.contains($0.path ?? "") }
    }

    var body: some View {
        let used = model.disk.used / model.disk.total
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Gauge(value: used) { EmptyView() }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(used > 0.9 ? .red : .accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("可用 \(model.disk.free.gbText)").font(.title3.bold()).monospacedDigit()
                    if used > 0.9 {
                        Text("只剩 \(Int((1 - used) * 100))%，系统更新可能装不上").font(.caption).foregroundStyle(.red)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("刚装好的应用留下的安装包").font(.caption.weight(.semibold))
                    Spacer()
                    Text(cleaned ? "已删除" : "\(packages.count) 个 · \(packages.map(\.size).reduce(0, +).gbText)").font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
                if packages.isEmpty && !cleaned {
                    Divider()
                    Text("没有了。").font(.caption).foregroundStyle(.secondary).padding(10)
                }
                ForEach(packages.prefix(3)) { p in
                    Divider()
                    HStack(spacing: 8) {
                        Thumbnail(path: p.path, ext: "DMG", tint: .purple, pixels: CGSize(width: 24, height: 24)).frame(width: 24, height: 24).clipShape(.rect(cornerRadius: 5))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(p.name).font(.caption.weight(.semibold)).lineLimit(1)
                            Text(p.modified).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(p.size.gbText).font(.caption).monospacedDigit()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .opacity(cleaned ? 0.4 : 1)
                }
                Divider()
                Button("删除") { withAnimation { clean() } }
                    .disabled(cleaned)
                    .disabled(packages.isEmpty && !cleaned)
                    .buttonStyle(.borderedProminent)
                    .tint(cleaned ? .secondary : .accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(10)
            }
            .background(.background.opacity(0.7), in: .rect(cornerRadius: 12))

            HStack {
                Button("腾出空间…") { model.sheet = .goal; activateMainWindow() }
                Spacer()
                Button("打开 Adieu") { activateMainWindow() }
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    /// 菜单栏里点的就是确认，不再弹窗
    private func clean() {
        if model.useSample { cleaned = true; return }
        let items = packages
        model.perform(.init(title: String(localized: "删除 \(items.count) 个安装包"), source: "菜单栏",
                            urls: items.compactMap(\.path).map { URL(filePath: $0) },
                            sizes: Dictionary(uniqueKeysWithValues: items.compactMap { f in f.path.map { ($0, f.size) } }),
                            keys: items.compactMap(\.path),
                            onDone: { cleaned = $0 != nil }))
    }

    private func activateMainWindow() {
        NSApp.activate()
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            openWindow(id: "main")
        }
    }
}
