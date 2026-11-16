import SwiftUI

struct CloudDriveView: View {
    @Environment(AppModel.self) private var model
    @State private var folderPath = ""
    @State private var selected: Set<CloudDriveFile.ID> = []
    @State private var confirming = false
    @State private var showOnlineOnly = true
    @State private var search = ""
    @State private var sort: Sort = .name
    @State private var editor: CloudDriveEditor.Mode?

    private enum Sort: Hashable {
        case name, size
    }

    var body: some View {
        let scan = model.cloudDrive
        let folder = scan?.nearestFolder(to: folderPath)
        let path = folder?.relativePath ?? ""
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let searching = !query.isEmpty
        let matched = searching
            ? (scan?.folders ?? []).filter { $0.relativePath.localizedCaseInsensitiveContains(query) }
            : scan?.foldersByParent[path] ?? []
        let folders = sort == .size
            ? matched.sorted { (scan?.folderBytes[$0.relativePath] ?? 0) > (scan?.folderBytes[$1.relativePath] ?? 0) }
            : matched
        let scope = searching ? scan?.files ?? [] : scan?.filesByFolder[path] ?? []
        let filtered = scope.filter {
            (showOnlineOnly || $0.state != .onlineOnly) &&
                (!searching || $0.relativePath.localizedCaseInsensitiveContains(query))
        }
        let files = sort == .size ? filtered : filtered.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            if order == .orderedSame { return $0.relativePath < $1.relativePath }
            return order == .orderedAscending
        }
        let selectable = files.filter(\.canOrganize)
        let chosen = selectable.filter { selected.contains($0.id) }
        let downloads = chosen.filter(\.canEvict)
        let canEdit = !model.cloudDriveBusy && !model.useSample

        VStack(alignment: .leading, spacing: 16) {
            PageHeader(.cloudDrive, subtitle: "整理云端文件，查看它们在这台 Mac 上占用的空间。") {
                Button("刷新") { Task { await model.loadCloudDrive() } }
                    .disabled(model.cloudDriveBusy)
            }

            if let scan {
                HStack {
                    Text("iCloud Drive 在这台 Mac 上共占用 \(size(scan.allocatedBytes))").font(.headline)
                    Spacer()
                    Button("到搬家页整理…") {
                        model.mover.show(folder?.url ?? CloudDriveScanner.root)
                        model.section = .mover
                    }
                    .help("在搬家页里打开这个文件夹，可以拖动、批量改名，或搬到外接硬盘")
                }
                HStack(spacing: 12) {
                    TextField("搜索整个 iCloud Drive", text: $search)
                        .textFieldStyle(.roundedBorder)
                    Picker("排序方式", selection: $sort) {
                        Text("按名称").tag(Sort.name)
                        Text("按本机占用").tag(Sort.size)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                HStack {
                    if searching {
                        Text("全盘搜索结果").font(.headline)
                    } else {
                        CloudDrivePathBar(path: path, open: openFolder)
                    }
                    Spacer()
                    Toggle("显示仅在云端的文件", isOn: $showOnlineOnly)
                        .fixedSize()
                }
                if scan.unreadable > 0 {
                    Label("有 \(scan.unreadable) 项无法读取，统计可能不完整。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
                if !folders.isEmpty || !files.isEmpty {
                    fileList(folders: folders, files: files, searching: searching, canEdit: canEdit)
                } else if searching {
                    ContentUnavailableView.search(text: query)
                } else {
                    ContentUnavailableView(
                        showOnlineOnly ? String(localized: "此文件夹为空") : String(localized: "没有本机下载的文件"),
                        systemImage: "folder"
                    )
                }
            } else if let error = model.cloudDriveError {
                ContentUnavailableView("无法读取 iCloud Drive", systemImage: "icloud.slash", description: Text(error))
            } else if model.cloudDriveBusy {
                ProgressView("正在检查 iCloud Drive…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer(minLength: 0)
            operationResults
            HStack {
                if model.cloudDriveBusy && scan != nil { ProgressView().controlSize(.small) }
                if !selectable.isEmpty {
                    let all = selectable.count == chosen.count
                    Button(all ? String(localized: "取消全选") : String(localized: "全选可整理文件")) {
                        selected = all ? [] : Set(selectable.map(\.id))
                    }
                    .disabled(!canEdit)
                }
                Spacer()
                if scan != nil && chosen.isEmpty {
                    Text("当前列表的本机占用 \(size(files.reduce(0) { $0 + $1.allocatedBytes }))")
                        .foregroundStyle(.secondary)
                } else if !chosen.isEmpty {
                    Text("已选 \(chosen.count) 项 · \(size(chosen.reduce(0) { $0 + $1.allocatedBytes }))")
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("新建文件夹…") {
                    if let folder { editor = .createFolder(folder) }
                }
                .disabled(!canEdit || folder == nil || searching)
                Button("重命名…") {
                    if let file = chosen.first { editor = .rename(file) }
                }
                .disabled(!canEdit || chosen.count != 1)
                Button("移动到…") { editor = .move(chosen) }
                    .disabled(!canEdit || chosen.isEmpty || scan?.folders.isEmpty != false)
                Spacer()
                Button("移除下载…") { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(downloads.isEmpty || !canEdit)
            }
        }
        .padding(32)
        .task {
            if model.cloudDrive == nil { await model.loadCloudDrive() }
        }
        .onChange(of: model.cloudDriveBusy) { _, busy in
            if !busy {
                selected.removeAll()
                if let scan = model.cloudDrive {
                    folderPath = scan.nearestFolder(to: folderPath)?.relativePath ?? ""
                }
            }
        }
        .onChange(of: search) { selected.removeAll() }
        .onChange(of: showOnlineOnly) { selected.removeAll() }
        .sheet(item: $editor) { mode in
            if let scan {
                CloudDriveEditor(mode: mode, scan: scan, startPath: path) { change in
                    Task { await model.organizeCloudDrive(change) }
                }
            }
        }
        .alert("移除 iCloud Drive 下载？", isPresented: $confirming, presenting: downloads) { files in
            Button("移除下载") { Task { await model.removeCloudDownloads(files) } }
            Button("取消", role: .cancel) {}
        } message: { files in
            Text("将移除此 Mac 上的 \(files.count) 项下载。文件仍保存在 iCloud Drive 中，需要时可以重新下载。")
        }
    }

    private func openFolder(_ path: String) {
        folderPath = path
        search = ""
        selected.removeAll()
    }

    private func fileList(folders: [CloudDriveFolder], files: [CloudDriveFile], searching: Bool, canEdit: Bool) -> some View {
        List {
            if !folders.isEmpty {
                Section("文件夹") {
                    ForEach(folders) { folder in
                        CloudDriveFolderRow(folder: folder, showPath: searching, bytes: model.cloudDrive?.folderBytes[folder.relativePath] ?? 0) {
                            openFolder(folder.relativePath)
                        }
                    }
                }
            }
            if !files.isEmpty {
                Section("文件") {
                    ForEach(files) { file in
                        HStack(spacing: 12) {
                            Toggle(isOn: Binding(get: { selected.contains(file.id) }, set: {
                                if $0 { selected.insert(file.id) } else { selected.remove(file.id) }
                            })) { Text(file.relativePath) }
                                .labelsHidden()
                                .disabled(!file.canOrganize || !canEdit)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.name).lineLimit(1).truncationMode(.middle)
                                if searching {
                                    Button(file.parentPath.isEmpty ? "iCloud Drive" : file.parentPath) {
                                        openFolder(file.parentPath)
                                    }
                                    .buttonStyle(.link)
                                    .font(.caption)
                                    .lineLimit(1).truncationMode(.middle)
                                    .help("前往所在文件夹")
                                }
                                Text(file.state.title).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(size(file.allocatedBytes)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .help(file.relativePath)
                        .contextMenu {
                            if searching {
                                Button("前往所在文件夹") { openFolder(file.parentPath) }
                            }
                            Button("重命名…") { editor = .rename(file) }
                                .disabled(!file.canOrganize || !canEdit)
                            Button("移动到…") { editor = .move([file]) }
                                .disabled(!file.canOrganize || !canEdit)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .card(padding: 8)
    }

    @ViewBuilder
    private var operationResults: some View {
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
        guard bytes > 0 else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

private struct CloudDrivePathBar: View {
    let path: String
    let open: (String) -> Void

    var body: some View {
        let components = path.split(separator: "/")
        HStack(spacing: 8) {
            Button {
                open(CloudDriveScan.parent(of: path))
            } label: {
                Label("返回上一级文件夹", systemImage: "chevron.up")
                    .labelStyle(.iconOnly)
            }
            .help("返回上一级文件夹")
            .disabled(path.isEmpty)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if path.isEmpty {
                        Text("iCloud Drive").fontWeight(.semibold)
                    } else {
                        Button("iCloud Drive") { open("") }
                        ForEach(components.indices, id: \.self) { index in
                            Image(systemName: "chevron.right").font(.caption2)
                                .foregroundStyle(.secondary).accessibilityHidden(true)
                            if index == components.count - 1 {
                                Text(components[index]).fontWeight(.semibold)
                            } else {
                                Button(String(components[index])) {
                                    open(components.prefix(index + 1).joined(separator: "/"))
                                }
                            }
                        }
                    }
                }
                .buttonStyle(.link)
            }
            .defaultScrollAnchor(.trailing, for: .initialOffset)
            .defaultScrollAnchor(.leading, for: .alignment)
            .scrollIndicators(.hidden)
        }
        .help(path.isEmpty ? "iCloud Drive" : path)
    }
}

private struct CloudDriveFolderRow: View {
    let folder: CloudDriveFolder
    let showPath: Bool
    /// 整个文件夹在本机的占用；移动窗口里不显示
    var bytes: Int? = nil
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(folder.name)
                        if showPath && !folder.parentPath.isEmpty {
                            Text(folder.parentPath).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: "folder.fill").foregroundStyle(.blue)
                }
                Spacer()
                if let bytes {
                    Text(bytes > 0 ? ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) : "0 B")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption)
                    .foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(folder.relativePath)
    }
}

private struct CloudDriveEditor: View {
    enum Mode: Identifiable {
        case createFolder(CloudDriveFolder), rename(CloudDriveFile), move([CloudDriveFile])

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
    let scan: CloudDriveScan
    let startPath: String
    let apply: (CloudDriveOrganization.Change) -> Void
    @State private var name = ""
    @State private var folderPath = ""
    @State private var search = ""

    var body: some View {
        let target = scan.folder(at: folderPath)
        let change = change(target: target)
        VStack(alignment: .leading, spacing: 14) {
            Text(mode.title).font(.title2.bold())
            switch mode {
            case .createFolder(let folder):
                Text("目标文件夹 \(folderTitle(folder))").foregroundStyle(.secondary)
                TextField("文件夹名称", text: $name)
            case .rename(let file):
                Text(file.relativePath).foregroundStyle(.secondary)
                TextField("文件名称", text: $name)
            case .move(let files):
                let count = target.map { target in files.filter { $0.parentPath != target.relativePath }.count } ?? files.count
                if count == 0 {
                    Text("请选择其他文件夹。").foregroundStyle(.secondary)
                } else {
                    Text("要移动 \(count) 个文件").foregroundStyle(.secondary)
                }
                folderList
                if let target {
                    Text("目标文件夹 \(folderTitle(target))").foregroundStyle(.secondary)
                }
            }
            Text("更改会同步到使用同一 Apple 账户的设备。").font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(mode.title) {
                    if let change {
                        dismiss()
                        apply(change)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(change == nil)
            }
        }
        .padding(24)
        .frame(width: 500)
        .onAppear {
            if case .rename(let file) = mode { name = file.name }
            folderPath = scan.nearestFolder(to: startPath)?.relativePath ?? ""
        }
    }

    private var folderList: some View {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = query.isEmpty ? scan.foldersByParent[folderPath] ?? []
            : scan.folders.filter { folderTitle($0).localizedCaseInsensitiveContains(query) }
        return VStack(alignment: .leading, spacing: 8) {
            TextField("搜索目标文件夹", text: $search)
            CloudDrivePathBar(path: folderPath, open: openFolder)
            List(visible) { folder in
                CloudDriveFolderRow(folder: folder, showPath: !query.isEmpty) { openFolder(folder.relativePath) }
            }
            .overlay {
                if visible.isEmpty {
                    Text(query.isEmpty ? String(localized: "没有子文件夹") : String(localized: "没有匹配的文件夹"))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 220)
        }
    }

    private func openFolder(_ path: String) {
        folderPath = path
        search = ""
    }

    private func folderTitle(_ folder: CloudDriveFolder) -> String {
        folder.relativePath.isEmpty ? String(localized: "iCloud Drive 根目录") : folder.relativePath
    }

    private func change(target: CloudDriveFolder?) -> CloudDriveOrganization.Change? {
        switch mode {
        case .createFolder(let folder):
            guard CloudDriveOrganization.validName(name) else { return nil }
            return .createFolder(name: name, in: folder)
        case .rename(let file):
            guard name != file.name, CloudDriveOrganization.validName(name) else { return nil }
            return .rename(file, name: name)
        case .move(let files):
            guard let target else { return nil }
            let moving = files.filter { $0.parentPath != target.relativePath }
            return moving.isEmpty ? nil : .move(moving, to: target)
        }
    }
}
