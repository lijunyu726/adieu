import SwiftUI
import Quartz

/// 文件页右侧的预览栏：显示鼠标指着（或用 ↑↓ 选到）的那个文件。
/// 真实文件用 Quick Look 直接显示内容；示例数据没有文件，显示系统给这种类型的图标
struct FilePreviewPane: View {
    let item: FileItem?
    let selected: Bool
    let toggle: () -> Void

    var body: some View {
        Group {
            if let item { detail(item) } else { empty }
        }
        .padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 16)
        .frame(width: 300)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.background.opacity(0.35))
    }

    private var empty: some View {
        Text("把鼠标移到一个文件上，\n这里就显示它。")
            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detail(_ f: FileItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 先占好一块 4:3 的地方，预览叠在上面，图标小也不会把框缩小
            Color.clear
                .aspectRatio(4 / 3, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay { preview(f) }
                .background(.primary.opacity(0.04), in: .rect(cornerRadius: 12, style: .continuous))
                .clipShape(.rect(cornerRadius: 12, style: .continuous))
            Text(f.name).font(.headline).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                fact("大小", f.size.gbText)
                fact("种类", f.kind)
                fact("位置", f.location)
                fact("修改", f.timeText)
                if let days = f.idleDays, days >= 30 { fact("没打开", "\(days) 天") }
                if f.date != nil, f.modified != FileCategorizer.dateText(f.date!), !f.modified.hasSuffix("天没打开") { fact("状态", f.modified) }
            }
            .font(.caption)
            if !f.reason.isEmpty {
                Text(f.reason).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.brand.opacity(0.07), in: .rect(cornerRadius: 8))
            }
            HStack(spacing: 6) {
                if selected {
                    Button("取消勾选", action: toggle)
                } else {
                    Button("勾选", action: toggle).buttonStyle(.borderedProminent)
                }
                if let p = f.path {
                    Button("打开") { NSWorkspace.shared.open(URL(filePath: p)) }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: p)]) } label: { Image(systemName: "folder") }
                        .help("在访达中显示")
                }
            }
            .controlSize(.small)
            Spacer(minLength: 0)
            Text("按空格放大看，↑↓ 换一个").font(.caption).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private func preview(_ f: FileItem) -> some View {
        if let p = f.path, FileManager.default.fileExists(atPath: p) {
            QuickLookView(url: URL(filePath: p))
        } else {
            FileIcon(path: f.path ?? f.name, folder: f.ext == "DIR" ? true : nil, size: 120)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().lineLimit(2).textSelection(.enabled)
        }
    }
}

/// Quick Look 的内嵌预览。只建一次，换文件时改 previewItem，来回指不会闪
struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact)!
        view.autostarts = false
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
