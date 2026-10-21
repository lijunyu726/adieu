import SwiftUI

/// 最近操作：每次删除都有记录。以前的版本移到废纸篓的，还在废纸篓里就能放回
struct HistoryView: View {
    @Environment(AppModel.self) private var model

    private var monthFreed: Double {
        let start = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .distantPast
        return model.history.filter { $0.date >= start && !$0.restored }.map(\.total).reduce(0, +)
    }
    private var stillInTrash: Double {
        model.history.filter(\.canRestore).flatMap(\.files).filter(\.isInTrash).compactMap(\.size).reduce(0, +)
    }

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 40) {
                VStack(alignment: .leading, spacing: 22) {
                    PageHeader("最近操作", subtitle: "每一次删除都会记在这里。", symbol: "clock.arrow.circlepath", tint: .indigo)
                    if model.history.isEmpty {
                        ContentUnavailableView("还没有操作记录", systemImage: "clock.arrow.circlepath",
                                               description: Text("在 Adieu 里删掉的东西，都会记在这里。"))
                            .frame(maxWidth: .infinity, minHeight: 240)
                    } else {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(model.history) { entry($0) }
                        }
                        .padding(.leading, 26)
                        .background(alignment: .leading) {
                            Rectangle().fill(.quaternary).frame(width: 2).padding(.leading, 7).padding(.vertical, 10)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("本月通过 Adieu 删除").font(.caption).foregroundStyle(.secondary)
                        Text(monthFreed.gbText).font(.system(size: 30, weight: .bold)).monospacedDigit()
                        if stillInTrash > 0 {
                            Text("以前移到废纸篓的还有 \(stillInTrash.gbText) 没清空")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
                }
                .frame(width: 280)
                .padding(.top, 8)
            }
            .padding(32)
        }
    }

    private func entry(_ e: HistoryEntry) -> some View {
        let state: (String, Color) = e.deleted == true ? ("已删除", .secondary) : e.restored ? ("已放回", .secondary)
            : (e.canRestore ? ("可恢复", .blue) : (e.files.isEmpty && e.commandNote != nil ? ("命令清理", .orange) : ("已清空", .red)))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(e.title).font(.headline)
                Text("\(e.date.formatted(.dateTime.month().day().hour().minute())) · \(e.source)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Chip(text: state.0, tint: state.1)
            }
            ForEach(Array(e.files.prefix(8).enumerated()), id: \.offset) { _, f in
                HStack(spacing: 8) {
                    FileIcon(path: f.originalPath, folder: f.folder, size: 20)
                    Text(f.name).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(f.size.gbText).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                .help(f.originalPath)
            }
            if let note = e.commandNote {
                HStack {
                    Text(note).font(.callout.monospaced()).lineLimit(2)
                    Spacer()
                    Text("约 \(e.total.gbText)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if e.files.count > 8 {
                Text("还有 \(e.files.count - 8) 项").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text(e.deleted == true ? "直接删除，没有进废纸篓" : e.restored ? "已放回原来的文件夹" : (e.canRestore ? "还在废纸篓里，清空之前随时可以放回" : (e.files.isEmpty ? "工具命令直接清理，不经过废纸篓，需要时会重新下载" : "废纸篓已经清空，不能再放回")))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if e.canRestore {
                    Button("放回原处") { withAnimation { model.restore(e.id) } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
        .card()
        .overlay(alignment: .topLeading) {
            Circle().fill(e.canRestore ? Color.accentColor : .secondary)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(.background, lineWidth: 3))
                .offset(x: -25, y: 18)
        }
    }
}
