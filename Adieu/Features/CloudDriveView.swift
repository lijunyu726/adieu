import SwiftUI

struct CloudDriveView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: Set<CloudDriveFile.ID> = []
    @State private var confirming = false
    @State private var showOnlineOnly = true
    @State private var search = ""
    @State private var editor: CloudDriveEditor.Mode?

    var body: some View {
        let files = model.cloudDrive?.files ?? []
        let folders = model.cloudDrive?.folders ?? []
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = files.filter {
            (showOnlineOnly || $0.state != .onlineOnly) &&
                (query.isEmpty || $0.relativePath.localizedCaseInsensitiveContains(query))
        }
        let chosen = visible.filter { selected.contains($0.id) }
        let downloads = chosen.filter(\.canEvict)
        let canOrganize = !model.cloudDriveBusy && !model.useSample
        let canOrganizeSelection = canOrganize && !chosen.isEmpty && chosen.allSatisfy(\.canOrganize)
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(.cloudDrive, subtitle: "整理云端文件，查看它们在这台 Mac 上占用的空间。") {
                Button("刷新") { Task { await model.loadCloudDrive() } }
                    .disabled(model.cloudDriveBusy)
            }

            if let scan = model.cloudDrive {
                TextField("搜索文件名或路径", text: $search)
                    .textFieldStyle(.roundedBorder)
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
                if visible.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView(showOnlineOnly ? String(localized: "没有找到 iCloud Drive 文件")
                                               : String(localized: "没有本机下载的文件"), systemImage: "icloud")
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                } else {
                    List(visible) { file in
                        HStack(spacing: 12) {
                            Toggle(isOn: Binding(get: { selected.contains(file.id) }, set: {
                                if $0 { selected.insert(file.id) } else { selected.remove(file.id) }
                            })) { Text(file.relativePath) }
                                .labelsHidden()
                                .disabled((!file.canEvict && !file.canOrganize) || model.cloudDriveBusy)
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
                failures(result.failed, title: String(localized: "有 \(result.failed.count) 项未移除"))
            }
            if let result = model.cloudDriveOrganization {
                if result.completed > 0 {
                    Text("已整理 \(result.completed) 项。").foregroundStyle(.secondary)
                }
                failures(result.failed, title: String(localized: "有 \(result.failed.count) 项未整理"))
            }
            HStack {
                if model.cloudDriveBusy && model.cloudDrive != nil { ProgressView().controlSize(.small) }
                Button("新建文件夹…") { editor = .createFolder }
                    .disabled(!canOrganize || folders.isEmpty)
                Button("重命名…") {
                    if let file = chosen.first { editor = .rename(file) }
                }
                .disabled(!canOrganizeSelection || chosen.count != 1)
                Button("移动到…") { editor = .move(chosen) }
                    .disabled(!canOrganizeSelection || folders.isEmpty)
                Spacer()
                if !chosen.isEmpty {
                    Text("已选 \(chosen.count) 项 · \(size(chosen.reduce(0) { $0 + $1.allocatedBytes }))")
                        .foregroundStyle(.secondary)
                }
                Button("移除下载…") { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(downloads.isEmpty || !canOrganize)
            }
        }
        .padding(32)
        .task {
            if model.cloudDrive == nil { await model.loadCloudDrive() }
        }
        .onChange(of: model.cloudDriveBusy) { _, busy in
            if !busy { selected.removeAll() }
        }
        .onChange(of: search) { selected.removeAll() }
        .onChange(of: showOnlineOnly) { selected.removeAll() }
        .sheet(item: $editor) { mode in
            CloudDriveEditor(mode: mode, folders: folders) { change in
                Task { await model.organizeCloudDrive(change) }
            }
        }
        .alert("移除 iCloud Drive 下载？", isPresented: $confirming, presenting: downloads) { files in
            Button("移除下载") { Task { await model.removeCloudDownloads(files) } }
            Button("取消", role: .cancel) {}
        } message: { files in
            Text("将移除此 Mac 上的 \(files.count) 项下载。文件仍保存在 iCloud Drive 中，需要时可以重新下载。")
        }
    }

    @ViewBuilder
    private func failures(_ failures: [(path: String, reason: String)], title: String) -> some View {
        if !failures.isEmpty {
            DisclosureGroup(title) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                            Text("\(failure.path) · \(failure.reason)").textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 130)
            }
        }
    }

    private func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

private struct CloudDriveEditor: View {
    enum Mode: Identifiable {
        case createFolder, rename(CloudDriveFile), move([CloudDriveFile])

        var id: String {
            switch self {
            case .createFolder: "createFolder"
            case .rename: "rename"
            case .move: "move"
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .createFolder: "新建文件夹"
            case .rename: "重命名文件"
            case .move: "移动文件"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    let folders: [CloudDriveFolder]
    let apply: (CloudDriveOrganization.Change) -> Void
    @State private var name = ""
    @State private var folderID: CloudDriveFolder.ID?
    @State private var search = ""

    var body: some View {
        let folder = folders.first { $0.id == folderID }
        VStack(alignment: .leading, spacing: 14) {
            Text(mode.title).font(.title2.bold())
            switch mode {
            case .createFolder:
                TextField("文件夹名称", text: $name)
                folderList
            case .rename(let file):
                Text(file.relativePath).foregroundStyle(.secondary)
                TextField("文件名称", text: $name)
            case .move(let files):
                Text("要移动 \(files.count) 个文件").foregroundStyle(.secondary)
                folderList
            }
            if let folder {
                Text("目标文件夹 \(folderTitle(folder))").foregroundStyle(.secondary)
            }
            Text("更改会同步到使用同一 Apple 账户的设备。").font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(mode.title) {
                    if let change = change(folder: folder) {
                        dismiss()
                        apply(change)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(change(folder: folder) == nil)
            }
        }
        .padding(24)
        .frame(width: 500)
        .onAppear {
            switch mode {
            case .rename(let file): name = file.url.lastPathComponent
            case .createFolder: folderID = folders.first { $0.relativePath.isEmpty }?.id
            case .move: break
            }
        }
    }

    private var folderList: some View {
        let visible = folders.filter { search.isEmpty || folderTitle($0).localizedCaseInsensitiveContains(search) }
        return VStack(alignment: .leading, spacing: 8) {
            TextField("搜索目标文件夹", text: $search)
            List(visible, selection: $folderID) { folder in
                Label(folderTitle(folder), systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle)
                    .help(folderTitle(folder))
                    .tag(folder.id)
            }
            .frame(height: 220)
        }
    }

    private func folderTitle(_ folder: CloudDriveFolder) -> String {
        folder.relativePath.isEmpty ? String(localized: "iCloud Drive 根目录") : folder.relativePath
    }

    private func change(folder: CloudDriveFolder?) -> CloudDriveOrganization.Change? {
        switch mode {
        case .createFolder:
            guard let folder, CloudDriveOrganization.validName(name) else { return nil }
            return .createFolder(name: name, in: folder)
        case .rename(let file):
            guard name != file.url.lastPathComponent, CloudDriveOrganization.validName(name) else { return nil }
            return .rename(file, name: name)
        case .move(let files):
            guard let folder, files.contains(where: { $0.url.deletingLastPathComponent().path != folder.url.path })
            else { return nil }
            return .move(files, to: folder)
        }
    }
}
