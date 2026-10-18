import SwiftUI
import QuickLook

/// 逐个看：一次只看一个文件，← 保留，↓ 稍后，→ 删除（直接删，不进废纸篓）。
/// 用在“截图与录屏”“大文件”“久未打开”页面的“逐个看”模式里。卡片上是缩略图，空格键用快速查看打开。
struct FileReviewDeck: View {
    /// 进入时固定一份：移走的文件会从页面的列表里消失，按序号往后翻时不能跟着变短，否则会跳过下一个
    @State private var deck: [FileItem]
    /// 决定删除时立即执行
    var onDelete: (FileItem) -> Void

    init(deck: [FileItem], onDelete: @escaping (FileItem) -> Void) {
        _deck = State(initialValue: deck)
        self.onDelete = onDelete
    }

    @State private var index = 0
    @State private var freed = 0.0
    @State private var kept = 0
    @State private var later = 0
    @FocusState private var focused: Bool
    @State private var preview: URL?

    private var current: FileItem? { index < deck.count ? deck[index] : nil }

    var body: some View {
        VStack(spacing: 24) {
            progress
            if let file = current {
                card(file)
                    .id(file.id)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .scale(scale: 0.9).combined(with: .opacity)))
                controls
            } else {
                finished
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { decide(.keep); return .handled }
        .onKeyPress(.rightArrow) { decide(.trash); return .handled }
        .onKeyPress(.downArrow) { decide(.later); return .handled }
        .onKeyPress(.space) { quickLook(); return .handled }
        .quickLookPreview($preview)
    }

    private enum Decision { case keep, later, trash }

    /// 快速查看放不了的视频（如 utvideo 编码的 AVI，系统解不了）交给默认播放器
    private func quickLook() {
        guard let path = current?.path else { return }
        let url = URL(filePath: path)
        guard preview == nil else { preview = nil; return }
        Task { if await quickLookCanOpen(url) { preview = url } else { NSWorkspace.shared.open(url) } }
    }

    private func decide(_ d: Decision) {
        guard let file = current else { return }
        withAnimation(.smooth) {
            switch d {
            case .keep: kept += 1
            case .later: later += 1
            case .trash:
                freed += file.size
                onDelete(file)
            }
            index += 1
        }
    }

    private var progress: some View {
        HStack(spacing: 20) {
            ProgressView(value: Double(min(index, deck.count)), total: Double(deck.count)).frame(maxWidth: 320)
            Text(current == nil ? "完成" : "第 \(index + 1) / \(deck.count) 个").foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Text("已删除 \(Text(freed.gbText).bold().foregroundStyle(.green))").foregroundStyle(.secondary)
            Text("保留 \(kept) · 稍后 \(later)").foregroundStyle(.secondary)
        }
    }

    private func card(_ f: FileItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Thumbnail(path: f.path, ext: f.ext, tint: tint(f), pixels: CGSize(width: 1120, height: 560))
                Chip(text: f.kind, tint: tint(f)).padding(16)
            }
            .frame(height: 280)
            .overlay(alignment: .bottomTrailing) {
                if f.path != nil {
                    Button("预览", systemImage: "eye", action: quickLook)
                        .buttonStyle(.borderedProminent).tint(.black.opacity(0.55))
                        .help("用快速查看打开（空格键）")
                        .padding(14)
                }
            }
            .contentShape(.rect)
            .onTapGesture(count: 2, perform: quickLook)
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(f.name).font(.title3.bold()).lineLimit(2)
                    Spacer()
                    Text(f.size.gbText).font(.title.bold()).monospacedDigit()
                }
                HStack(spacing: 24) {
                    Label(f.location, systemImage: "folder")
                    Label(f.modified, systemImage: "calendar")
                }
                .font(.callout).foregroundStyle(.secondary)
                Text(f.reason).font(.callout)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
            }
            .padding(22)
        }
        .frame(width: 560)
        .background(.background, in: .rect(cornerRadius: 24))
        .clipShape(.rect(cornerRadius: 24))
        .shadow(color: .black.opacity(0.12), radius: 24, y: 12)
        .background(alignment: .top) {
            RoundedRectangle(cornerRadius: 24).fill(.background.opacity(0.6))
                .frame(width: 520).offset(y: 14).shadow(radius: 1)
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button { decide(.keep) } label: { Label("保留", systemImage: "arrow.left") }
            Button { decide(.later) } label: { Label("稍后", systemImage: "arrow.down") }
            Button { decide(.trash) } label: { Label("删除", systemImage: "arrow.right") }
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.extraLarge)
    }

    private var finished: some View {
        ContentUnavailableView {
            Label("这一轮整理完了", systemImage: "checkmark.circle")
        } description: {
            Text("删除 \(freed.gbText) · 保留 \(kept) 个 · 留到下次 \(later) 个")
        } actions: {
            Button("重新开始") { withAnimation { index = 0; freed = 0; kept = 0; later = 0 } }
                .buttonStyle(.borderedProminent)
        }
    }

    private func tint(_ f: FileItem) -> Color {
        switch f.ext {
        case "ISO": .indigo
        case "ZIP": .brown
        default: .red
        }
    }
}
