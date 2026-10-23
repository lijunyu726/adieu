import SwiftUI

struct GoalView: View {
    @Environment(AppModel.self) private var model
    @State private var target: Double = 20
    /// 自定义输入的值；为 nil 时用的是预设按钮
    @State private var custom: Double?

    @State private var confirming = false
    @State private var running = false
    private var plan: GoalPlanner.Plan { GoalPlanner.plan(target: target, from: model.goalCandidates) }
    private var maxPossible: Double { model.goalCandidates.map(\.size).reduce(0, +) }

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            question.frame(width: 400)
            planColumn
        }
        .padding(40)
    }

    private var question: some View {
        VStack(alignment: .leading, spacing: 26) {
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Text("可用 \(model.disk.free.gbText) · 共 \(model.disk.total.gbText)").foregroundStyle(.secondary)
                Text("想腾出\n多少空间？").font(.system(size: 40, weight: .bold)).lineSpacing(2)
            }
            HStack(spacing: 8) {
                ForEach([5.0, 20, 50], id: \.self) { v in
                    let on = custom == nil && target == v
                    Button("\(Int(v)) GB") { withAnimation(.smooth) { custom = nil; target = v } }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .tint(on ? .primary : .secondary)
                        .fontWeight(on ? .bold : .regular)
                }
                customField
            }
            Text(explanation)
                .font(.callout)
                .lineSpacing(3)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14))
            Spacer()
        }
    }

    /// 自定义大小：回车或离开输入框时生效，允许一位小数，上限是已用空间
    private var customField: some View {
        HStack(spacing: 6) {
            Text("自定义").foregroundStyle(custom == nil ? .secondary : .primary)
            TextField("输入", value: $custom, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .accessibilityLabel("自定义要腾出的空间，单位 GB")
            Text("GB").foregroundStyle(.secondary)
        }
        .controlSize(.large)
        .onChange(of: custom) { _, v in
            guard let v else { return }
            if v > 0 { withAnimation(.smooth) { target = min(v, model.disk.used) } } else { custom = nil }
        }
    }

    private var explanation: String {
        if model.scanning && plan.total < target {
            return String(localized: "还在扫描，找到的可清理项会陆续加进计划里。")
        }
        if plan.total < target {
            let biggest = model.apps.max { $0.total < $1.total }
            if let biggest {
                return String(localized: "只靠清理，最多能腾出约 \(maxPossible.gbText)。再多就要卸载应用了：最大的是 \(biggest.name)，它占了 \(biggest.total.gbText)。")
            }
            return String(localized: "只靠清理，最多能腾出约 \(maxPossible.gbText)。再多就要卸载应用了。")
        }
        if plan.reviewCount == 0 {
            return String(localized: "只做 \(plan.items.count) 件稳妥的事就够了，全是缓存和能重新下载的东西，不会碰你的文件。")
        }
        return String(localized: "稳妥的部分加起来只有 \(plan.safeTotal.gbText)，还需要 \(plan.reviewCount) 项要你确认的内容，理由都写在旁边了。")
    }

    private var planColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("计划 · \(plan.items.count) 项").foregroundStyle(.secondary)
                    Text("腾出 \(plan.total.gbText)").font(.system(size: 32, weight: .bold)).monospacedDigit()
                        .contentTransition(.numericText())
                }
                Spacer()
                Button(running ? "正在执行…" : "按计划执行") { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(plan.items.isEmpty || running || model.useSample)
                    .alert("按计划腾出 \(plan.total.gbText)？", isPresented: $confirming) {
                        Button("执行") {
                            running = true
                            Task { await model.execute(plan); running = false }
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("文件会直接删除，不进废纸篓；开发工具的缓存用它们自己的命令清理，需要时会重新下载。")
                    }
            }
            meter
            HStack(spacing: 16) {
                Label("稳妥：可再生或可重新下载", systemImage: "circle.fill").foregroundStyle(.green)
                Label("需要你看一眼", systemImage: "circle.fill").foregroundStyle(.orange)
            }
            .font(.caption)
            .labelStyle(.titleAndIcon)

            List {
                ForEach(Array(plan.items.enumerated()), id: \.element.id) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(i + 1)").font(.caption.bold()).foregroundStyle(.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { Text(Copy.text(item.title)).fontWeight(.semibold); Chip(text: item.safety.label, tint: item.safety.color) }
                            Text(Copy.text(item.detail)).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(item.size.gbText).fontWeight(.semibold).monospacedDigit()
                    }
                    .padding(.vertical, 4)
                }
                if plan.total < target {
                    Label("还差 \((target - plan.total).gbText)。可以到“应用程序”里看看哪些应用很久没用了。", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
            .clipShape(.rect(cornerRadius: 14))
            .animation(.smooth, value: target)
        }
    }

    private var meter: some View {
        let scale = max(target, plan.total) * 1.08
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary.opacity(0.6))
                HStack(spacing: 0) {
                    Rectangle().fill(.green).frame(width: geo.size.width * plan.safeTotal / scale)
                    Rectangle().fill(.orange).frame(width: geo.size.width * (plan.total - plan.safeTotal) / scale)
                }
                .clipShape(.capsule)
                Rectangle().fill(.primary).frame(width: 2, height: 16)
                    .offset(x: geo.size.width * target / scale)
            }
        }
        .frame(height: 10)
        .animation(.smooth, value: target)
        .accessibilityHidden(true)
    }
}
