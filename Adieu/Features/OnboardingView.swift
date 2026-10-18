import SwiftUI

/// 首次启动：承诺 → 完全磁盘访问权限 → 首次扫描
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = 1
    @State private var fullDisk = Permissions.hasFullDiskAccess

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 1: welcome
                case 2: permission
                default: scanning
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            HStack(spacing: 8) {
                ForEach(1...3, id: \.self) { i in
                    Capsule().fill(i == step ? Color.primary : Color.secondary.opacity(0.3)).frame(width: i == step ? 22 : 7, height: 7)
                }
            }
            .padding(.bottom, 24)
        }
        .frame(width: 760, height: 560)
        .background { PageBackground() }
        .animation(.smooth, value: step)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fullDisk = Permissions.hasFullDiskAccess
        }
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            AdieuLogo(size: 112)
            Text("好好告别，不留遗憾也不留残渣。").font(.system(size: 30, weight: .bold))
            Text("每一个要删除的文件，都会告诉你它为什么属于那个应用。\n删除都是直接删干净，不用再清空废纸篓，删之前会确认。")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                promise("有证据才建议", "按应用标识和开发者身份匹配，只是名字像的不自动勾选。")
                promise("删之前先确认", "删除不进废纸篓、不能放回，所以每次删之前都会列出要删的东西让你确认。")
                promise("只在本机运行", "扫描结果不上传，不需要账号。")
            }
            .padding(.horizontal, 40)
            Button("继续") { step = 2 }.buttonStyle(.borderedProminent).controlSize(.extraLarge).keyboardShortcut(.defaultAction)
        }
    }

    private func promise(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).fontWeight(.semibold)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("第 2 步，共 3 步").font(.callout.weight(.semibold)).foregroundStyle(.tint)
            Text("需要“完全磁盘访问权限”").font(.system(size: 28, weight: .bold))
            Text("应用的数据和缓存藏在“资源库”里，没有这个权限就看不到，也就没法删干净。").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("拿到权限后，我们不会：").fontWeight(.semibold)
                Label("读取、保存或上传你的文件内容", systemImage: "eye.slash")
                Label("在你确认之前删除任何东西", systemImage: "hand.raised")
                Label("把任何信息发到网上", systemImage: "network.slash")
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
            HStack {
                Button("打开系统设置") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
                .buttonStyle(.borderedProminent)
                Button("已授权，继续") { step = 3 }
                    .disabled(!fullDisk && !model.useSample)
                    .help("授权后回到这里就能点")
                Button("稍后，只清理我的文件") { step = 3 }.buttonStyle(.link)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 80)
    }

    private var scanning: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("第 3 步，共 3 步").font(.callout.weight(.semibold)).foregroundStyle(.tint)
            Text("正在认识你的 Mac").font(.system(size: 28, weight: .bold))
            ForEach(scanRows, id: \.0) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(row.0); Spacer(); Text(row.2 ? row.1 : "扫描中…").foregroundStyle(.secondary) }
                    if row.2 { ProgressView(value: 1) } else { ProgressView().progressViewStyle(.linear) }
                }
            }
            Button("进入首页") {
                if fullDisk != model.hasFullDiskAccess { Task { await model.scanAll(force: true) } }
                model.finishOnboarding()
            }
            .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            Text("扫描在后台继续，可以先进去看。").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 120)
    }

    /// （名称，结果，是否完成）
    private var scanRows: [(String, String, Bool)] {
        let m = model
        let leftover = m.leftovers.flatMap(\.items).compactMap(\.size).reduce(0, +)
        let launch = m.launchGroups.flatMap(\.items).count
        let broken = m.launchGroups.first { $0.id == "broken" }?.items.count ?? 0
        let files = m.fileCategories.first { $0.id == .bigFiles }?.items.count ?? 0
        return [
            ("应用程序", "找到 \(m.apps.count) 个应用及其数据", !m.apps.isEmpty && !m.appsLoading),
            ("残留文件", leftover > 0 ? "约 \(leftover.gbText) 可能已无主" : "没有发现残留", !m.leftoversLoading && (m.useSample || m.fileScan != nil)),
            ("后台项目", "\(launch) 个" + (broken > 0 ? "，其中 \(broken) 个已失效" : ""), !m.launchLoading && launch > 0),
            ("你的文件", "\(files) 个 50 MB 以上的大文件", !m.filesLoading && !m.fileCategories.isEmpty),
            ("开发工具", m.devTools.map(\.name).prefix(3).joined(separator: "、") + (m.devTools.count > 3 ? "…" : ""), !m.devLoading && !m.devTools.isEmpty)
        ]
    }
}
