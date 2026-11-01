import SwiftUI

/// 删后核对的结果：窗口底部浮一条“实际腾出 X”。和预计差不多时几秒后自己消失；
/// 明显比预计少时留着，把可能的原因列出来，等用户关
struct FreedToast: View {
    @Environment(AppModel.self) private var model
    let report: AppModel.FreedReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: report.short ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.title2).foregroundStyle(report.short ? .orange : .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("实际腾出 \(Text(report.actual.gbText).fontWeight(.bold).monospacedDigit())")
                    Text(report.short ? "预计 \(report.expected.gbText)，少了一些" : report.title)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 12)
                Button { model.freedReport = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("关闭")
            }
            if report.short {
                Text("可能的原因：").font(.callout).foregroundStyle(.secondary)
                ForEach(report.reasons, id: \.self) { r in
                    Text("· \(r)").font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(width: report.short ? 460 : 320, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(20)
        .task(id: report.id) {
            guard !report.short else { return }
            try? await Task.sleep(for: .seconds(6))
            if model.freedReport?.id == report.id { withAnimation { model.freedReport = nil } }
        }
    }
}
