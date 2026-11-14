import SwiftUI

struct CloudDriveView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: Set<CloudDriveFile.ID> = []
    @State private var confirming = false
    @State private var showOnlineOnly = false

    var body: some View {
        let files = model.cloudDrive?.files ?? []
        let chosen = files.filter { $0.canEvict && selected.contains($0.id) }
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(.cloudDrive, subtitle: "查看 iCloud Drive 文件在这台 Mac 上占用的空间。") {
                Button("刷新") { Task { await model.loadCloudDrive() } }
                    .disabled(model.cloudDriveBusy)
            }

            if let scan = model.cloudDrive {
                HStack {
                    Text("已扫描文件的本机占用 \(size(scan.allocatedBytes))")
                        .font(.headline)
                    Spacer()
                    Toggle("显示仅在云端的文件", isOn: $showOnlineOnly)
                }
                if scan.unreadable > 0 {
                    Label("有 \(scan.unreadable) 项无法读取，统计可能不完整。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
                let visible = showOnlineOnly ? files : files.filter { $0.state != .onlineOnly }
                if visible.isEmpty {
                    ContentUnavailableView(showOnlineOnly ? String(localized: "没有找到 iCloud Drive 文件")
                                           : String(localized: "没有本机下载的文件"),
                                           systemImage: "icloud")
                } else {
                    List(visible) { file in
                        HStack(spacing: 12) {
                            Toggle(isOn: Binding(get: { selected.contains(file.id) }, set: {
                                if $0 { selected.insert(file.id) } else { selected.remove(file.id) }
                            })) { Text(file.relativePath) }
                                .labelsHidden()
                                .disabled(!file.canEvict || model.cloudDriveBusy)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.relativePath).lineLimit(1).truncationMode(.middle)
                                    .help(file.relativePath)
                                Text(file.state.title).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(size(file.allocatedBytes)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            } else if let error = model.cloudDriveError {
                ContentUnavailableView("无法读取 iCloud Drive", systemImage: "icloud.slash", description: Text(error))
            } else if model.cloudDriveBusy {
                ProgressView("正在检查 iCloud Drive…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer(minLength: 0)
            if let result = model.cloudDriveRemoval {
                if !result.removed.isEmpty {
                    Text("已移除 \(result.removed.count) 项下载。").foregroundStyle(.secondary)
                }
                if !result.failed.isEmpty {
                    DisclosureGroup("有 \(result.failed.count) 项未移除") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(result.failed, id: \.path) { failure in
                                    Text("\(failure.path) · \(failure.reason)").textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 130)
                    }
                }
            }
            HStack {
                if model.cloudDriveBusy && model.cloudDrive != nil { ProgressView().controlSize(.small) }
                Spacer()
                if !chosen.isEmpty {
                    Text("已选 \(chosen.count) 项 · \(size(chosen.reduce(0) { $0 + $1.allocatedBytes }))")
                        .foregroundStyle(.secondary)
                }
                Button("移除下载…") { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen.isEmpty || model.cloudDriveBusy || model.useSample)
            }
        }
        .padding(32)
        .task {
            if model.cloudDrive == nil { await model.loadCloudDrive() }
        }
        .onChange(of: model.cloudDriveBusy) { _, busy in
            if !busy { selected.removeAll() }
        }
        .alert("移除 iCloud Drive 下载？", isPresented: $confirming, presenting: chosen) { files in
            Button("移除下载") { Task { await model.removeCloudDownloads(files) } }
            Button("取消", role: .cancel) {}
        } message: { files in
            Text("将移除此 Mac 上的 \(files.count) 项下载。文件仍保存在 iCloud Drive 中，需要时可以重新下载。")
        }
    }

    private func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
