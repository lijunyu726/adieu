import SwiftUI
import QuickLook

/// 逐个看：一次只看一个文件，← 保留，↓ 稍后，→ 待删，⌘Z 退回上一张。
/// → 只是标记（和列表共用一份勾选），看完列出待删的，确认一次才真删——直接删除不能撤销，不能一按方向键就没了。
/// 用在“截图与录屏”“大文件”“久未打开”页面的“逐个看”模式里。卡片上是缩略图，空格键用快速查看打开。
struct FileReviewDeck: View {
    /// 进入时固定一份：移走的文件会从页面的列表里消失，按序号往后翻时不能跟着变短，否则会跳过下一个
    @State private var deck: [FileItem]
    /// 和列表共用的勾选
    @Binding var marked: Set<String>
    let key: (FileItem) -> String
    /// 删除已标记的（走页面的确认）
    var onDelete: () -> Void
    /// 回到列表复核
    var onList: () -> Void

    init(deck: [FileItem], marked: Binding<Set<String>>, key: @escaping (FileItem) -> String,
         onDelete: @escaping () -> Void, onList: @escaping () -> Void) {
        _deck = State(initialValue: deck)
        _marked = marked
        self.key = key
        self.onDelete = onDelete
        self.onList = onList
    }

    @State private var index = 0
    /// 每一步的决定，以及这个文件原来有没有勾着；⌘Z 按它恢复原状
    @State private var history: [(decision: Decision, was: Bool)] = []
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
        .onKeyPress(keys: ["z"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            undo()
            return .handled
        }
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

    private var pending: [FileItem] { deck.filter { marked.contains(key($0)) } }
    private var kept: Int { history.filter { $0.decision == .keep }.count }
    private var later: Int { history.filter { $0.decision == .later }.count }

    private func decide(_ d: Decision) {
        guard let file = current else { return }
        let k = key(file)
        withAnimation(.smooth) {
            history.append((d, marked.contains(k)))
            switch d {
            case .keep: marked.remove(k)
            case .later: break
            case .trash: marked.insert(k)
            }
            index += 1
        }
    }

    private func undo() {
        guard index > 0, let last = history.last else { return }
        withAnimation(.smooth) {
            history.removeLast()
            index -= 1
            let k = key(deck[index])
            if last.was { marked.insert(k) } else { marked.remove(k) }
        }
    }

    private var progress: some View {
        HStack(spacing: 20) {
            ProgressView(value: Double(min(index, deck.count)), total: Double(deck.count)).frame(maxWidth: 320)
            Text(current == nil ? "完成" : "第 \(index + 1) / \(deck.count) 个").foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Text("待删 \(pending.count) 个 · \(Text(pending.map(\.size).reduce(0, +).gbText).bold())").foregroundStyle(.secondary)
            Text("保留 \(kept) · 稍后 \(later)").foregroundStyle(.secondary)
            Button("退回上一张", systemImage: "arrow.uturn.backward", action: undo)
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .help("退回上一张（⌘Z）")
                .disabled(index == 0)
        }
    }

    private func card(_ f: FileItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Thumbnail(path: f.path, ext: f.ext, tint: tint(f), pixels: CGSize(width: 560, height: 280))
                Chip(text: Copy.kind(f.kind), tint: tint(f)).padding(16)
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
                    Label(Copy.status(f.modified), systemImage: "calendar")
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
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                Button { decide(.keep) } label: { Label("保留", systemImage: "arrow.left") }
                Button { decide(.later) } label: { Label("稍后", systemImage: "arrow.down") }
                Button { decide(.trash) } label: { Label("待删", systemImage: "arrow.right") }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.extraLarge)
            // 按钮上的箭头就是键盘上的方向键，写明白，不用记
            HStack(spacing: 16) {
                KeyHint("直接按方向键", keys: "←", "↓", "→")
                KeyHint("放大看", keys: "空格")
                KeyHint("退回上一张", keys: "⌘", "Z")
            }
        }
    }

    private var finished: some View {
        let pending = pending
        return ContentUnavailableView {
            Label("这一轮看完了", systemImage: "checkmark.circle")
        } description: {
            Text(pending.isEmpty ? "没有要删的。保留 \(kept) 个 · 留到下次 \(later) 个"
                 : "待删 \(pending.count) 个，共 \(pending.map(\.size).reduce(0, +).gbText)。保留 \(kept) 个 · 留到下次 \(later) 个")
        } actions: {
            if !pending.isEmpty {
                Button("删除这 \(pending.count) 个…", action: onDelete)
                    .buttonStyle(.borderedProminent)
                Button("在列表里复核", action: onList)
            }
            Button("重新开始") { withAnimation { index = 0; history = [] } }
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
