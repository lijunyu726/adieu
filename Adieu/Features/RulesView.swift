import SwiftUI

/// 设置里的“自动规则”：一句话描述的规则，默认只提醒。
/// 开关和各文件页面底部的规则条共用 AppModel.enabledRules。
struct RulesView: View {
    @Environment(AppModel.self) private var model
    private var enabled: Set<String> { model.enabledRules }
    @State private var notifications: Permissions.State = .granted

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Text("打开后 Adieu 会替你盯着。大部分只是提醒你；只有缓存这类删了还能重新生成的，才会自己动手。")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("已开启 \(enabled.count) 条").foregroundStyle(.secondary)
                }
                if notifications != .granted {
                    HStack(spacing: 10) {
                        Image(systemName: "bell.slash").foregroundStyle(.orange)
                        Text(notifications == .denied ? "通知被关掉了，规则发现情况时没法提醒你。" : "通知还没开，规则发现情况时没法提醒你。")
                        Spacer()
                        Button(notifications == .denied ? "打开系统设置" : "允许通知") {
                            if notifications == .denied { NSWorkspace.shared.open(Permissions.notificationSettings) }
                            else { Task { _ = await Notifier.requestAuthorization(); notifications = await Notifier.state() } }
                        }
                    }
                    .padding(12)
                    .background(.orange.opacity(0.1), in: .rect(cornerRadius: 10))
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 14) {
                    ForEach(Sample.rules) { card($0) }
                }
                Text("规则在 Adieu 运行时生效（关掉窗口、只留在菜单栏也算）。想开机就生效，在“通用”里打开“登录时打开 Adieu”。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .animation(.smooth, value: enabled)
        }
        .task { notifications = await Notifier.state() }
    }

    private func card(_ r: RuleItem) -> some View {
        let on = enabled.contains(r.id)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                SymbolTile(symbol: r.symbol, tint: r.color, size: 30)
                Text(r.name).fontWeight(.semibold)
                Spacer()
                Toggle(r.name, isOn: Binding(get: { on }, set: { model.setRule(r.id, on: $0) }))
                    .toggleStyle(.switch).labelsHidden()
            }
            sentence(r.sentence)
            HStack(spacing: 8) {
                Chip(text: r.automatic ? "自动执行" : "只提醒", tint: r.automatic ? .orange : .secondary)
                Text(RuleEngine.status(r.id, model)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .card()
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(on ? Color.green.opacity(0.5) : .clear))
        .opacity(on ? 1 : 0.65)
    }

    /// 把“普通文字 + 词块”拼成一句可读的规则
    private func sentence(_ tokens: [RuleToken]) -> some View {
        var text = AttributedString()
        for t in tokens {
            switch t {
            case .text(let s):
                text += AttributedString(s)
            case .condition(let s):
                var a = AttributedString(" \(s) ")
                a.foregroundColor = .blue
                a.backgroundColor = .blue.opacity(0.12)
                a.font = .body.weight(.semibold)
                text += a
            case .action(let s):
                var a = AttributedString(" \(s) ")
                a.foregroundColor = .green
                a.backgroundColor = .green.opacity(0.12)
                a.font = .body.weight(.semibold)
                text += a
            }
        }
        return Text(text).font(.title3).lineSpacing(8)
    }
}
