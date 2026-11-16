import SwiftUI

/// agent 要删东西时弹出来的清单。只有用户点“删除”才执行，agent 没法替用户点
struct AgentConfirmView: View {
    @Environment(AppModel.self) private var model
    let request: AgentTools.Request

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.title).font(.title3.bold())
                    Text("来自连接到 Adieu 的 agent（\(request.tool)）").font(.callout).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(request.lines, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(line.label).lineLimit(1).truncationMode(.middle)
                                Text(line.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if let size = line.size { Text(size.gbText).monospacedDigit().foregroundStyle(.secondary) }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 10))
            Label(request.note, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消") { model.agent.answer(false) }.keyboardShortcut(.cancelAction)
                Button("删除", role: .destructive) { model.agent.answer(true) }
                    .buttonStyle(.borderedProminent).tint(.red)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
