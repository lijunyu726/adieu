import SwiftUI
import Charts

/// 存储日记：像“屏幕使用时间”，讲这周磁盘为什么变满。数据来自 DiaryStore 每天的快照
struct DiaryView: View {
    @Environment(AppModel.self) private var model
    private let serif = Font.system(size: 44, weight: .semibold, design: .serif)

    var body: some View {
        if model.useSample { SampleDiary() }
        else if let w = DiaryStore.week(model) { real(w) }
        else {
            ContentUnavailableView {
                Label("日记从今天开始记", systemImage: "book.closed")
            } description: {
                Text("Adieu 每天记一次磁盘的样子（打开 Adieu 并扫描完就会记）。有两天以上的记录，这里就会讲清楚空间去哪了。")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func real(_ w: DiaryStore.Week) -> some View {
        ScrollView {
            HStack(alignment: .top, spacing: 56) {
                VStack(alignment: .leading, spacing: 26) {
                    Text(w.range).foregroundStyle(.secondary)
                    Text("这一周，\n\(w.headline)").font(serif).lineSpacing(4)
                    if w.cleaned > 0 {
                        Text("其中你用 Adieu 移走了 \(w.cleaned.gbText)。").font(.system(size: 18, design: .serif)).foregroundStyle(.secondary)
                    }
                    if !w.days.isEmpty {
                        let maxGB = w.days.map(\.gb).max() ?? 0
                        Chart(Array(w.days.enumerated()), id: \.offset) { _, d in
                            BarMark(x: .value("日期", d.day), y: .value("变化", d.gb))
                                .foregroundStyle(d.gb == maxGB && d.gb > 0 ? Color.primary : Color.secondary.opacity(0.35))
                                .cornerRadius(5)
                                .annotation(position: d.gb >= 0 ? .top : .bottom) {
                                    Text((d.gb >= 0 ? "+" : "−") + abs(d.gb).gbText).font(.caption).foregroundStyle(.secondary)
                                }
                        }
                        .chartYAxis(.hidden)
                        .frame(height: 200)
                        Text("每天比前一天多用（+）或空出（−）的空间。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("谁用掉了空间").font(.callout.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 10)
                    if w.movers.isEmpty {
                        Divider()
                        Text("没有哪一类变化超过 0.5 GB。").foregroundStyle(.secondary).padding(.vertical, 12)
                    }
                    ForEach(Array(w.movers.enumerated()), id: \.offset) { _, x in
                        Divider()
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text((x.delta > 0 ? "+" : "−") + abs(x.delta).gbText).font(.headline).monospacedDigit()
                                .foregroundStyle(x.delta > 0 ? .red : .green).frame(width: 90, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(Copy.text(x.name)).fontWeight(.semibold)
                                Text(Copy.text(x.why)).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            // 多出来的才需要去处理
                            if x.delta > 0, let link = x.link {
                                Button("去\(link.title)看看") { model.sheet = nil; model.section = link }
                                    .buttonStyle(.link).font(.callout)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    if let best = model.goalCandidates.filter({ $0.safety == .safe }).max(by: { $0.size < $1.size }) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("下周只做一件事：\(best.title)，大约能拿回 \(best.size.gbText)。").font(.system(size: 16, design: .serif))
                            Button("去腾出空间") { model.sheet = .goal }.buttonStyle(.borderedProminent)
                        }
                        .padding(16)
                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14))
                        .padding(.top, 14)
                    }
                }
                .frame(width: 400)
            }
            .padding(48)
        }
    }
}

/// 示例模式下的日记（演示用）
private struct SampleDiary: View {
    private let days: [(day: String, gb: Double)] = [("周日", 1.2), ("周一", 0.8), ("周二", 2.1), ("周三", 9.4), ("周四", 1.6), ("周五", 2.9), ("周六", 0.6)]
    private let who: [(delta: String, grew: Bool, name: String, why: String)] = [
        ("+9.2 GB", true, "Docker", "虚拟磁盘又长大了，大多是新拉取的镜像。"),
        ("+3.3 GB", true, "屏幕录制", "周三录的一段 40 分钟的屏幕录像。"),
        ("+3.1 GB", true, "微信", "群里收到的视频和文件。"),
        ("+2.8 GB", true, "下载", "4 个安装包，其中 3 个对应的应用已经装好。"),
        ("−1.6 GB", false, "你清理了", "周五清掉了 Homebrew 的旧版本。")
    ]
    private let serif = Font.system(size: 44, weight: .semibold, design: .serif)

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 56) {
                VStack(alignment: .leading, spacing: 26) {
                    HStack {
                        Text("10 月 5 日 – 10 月 11 日 · 第 41 周").foregroundStyle(.secondary)
                        Chip(text: "示意数据", tint: .orange)
                    }
                    Text("这一周，\n你的磁盘少了 18.6 GB。").font(serif).lineSpacing(4)
                    Text("将近一半是 Docker 悄悄长大的虚拟磁盘。另外，你下载的 4 个安装包里，有 3 个对应的应用已经装好了。")
                        .font(.system(size: 18, design: .serif)).foregroundStyle(.secondary).lineSpacing(6)
                    Chart(days, id: \.day) { d in
                        BarMark(x: .value("日期", d.day), y: .value("新增", d.gb))
                            .foregroundStyle(d.gb == days.map(\.gb).max() ? Color.primary : Color.secondary.opacity(0.35))
                            .cornerRadius(5)
                            .annotation(position: .top) { Text("+\(d.gb, specifier: "%.1f")").font(.caption).foregroundStyle(.secondary) }
                    }
                    .chartYAxis(.hidden)
                    .frame(height: 200)
                    Text("每天新增占用。周三那一下是 Docker 拉取了新镜像。").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("谁用掉了空间").font(.callout.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 10)
                    ForEach(who, id: \.name) { w in
                        Divider()
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text(w.delta).font(.headline).monospacedDigit().foregroundStyle(w.grew ? .red : .green).frame(width: 80, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(w.name).fontWeight(.semibold)
                                Text(w.why).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("下周只做一件事：在 Docker 里清掉没在用的镜像，大约能拿回 14 GB。").font(.system(size: 16, design: .serif))
                        Button("现在就做") {}.buttonStyle(.borderedProminent)
                    }
                    .padding(16)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14))
                    .padding(.top, 14)
                }
                .frame(width: 400)
            }
            .padding(48)
        }
    }
}
