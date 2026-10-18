import SwiftUI

struct LeftoversView: View {
    @Environment(AppModel.self) private var model
    @State private var overrides: [String: Bool] = [:]

    private func isOn(_ item: LeftoverItem) -> Bool { overrides[item.id] ?? item.defaultOn }
    private var allItems: [LeftoverItem] { model.leftovers.flatMap(\.items) }
    private var chosen: [LeftoverItem] { allItems.filter(isOn) }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    PageHeader(.leftovers, subtitle: "应用已经删掉了，它们还留在电脑里。只列能确定是哪个应用留下的。")
                    if model.leftovers.isEmpty {
                        Group {
                            if model.leftoversLoading { ProgressView("正在对照已装应用查找残留…") }
                            else { ContentUnavailableView("没有找到残留", systemImage: "checkmark.circle", description: Text("资源库里的数据都能对上已装的应用。")) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 300)
                    }
                    ForEach(model.leftovers) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(group.title).font(.headline)
                                Text(group.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                            VStack(spacing: 0) {
                                ForEach(group.items) { item in
                                    row(item)
                                    if item.id != group.items.last?.id { Divider() }
                                }
                            }
                            .card()
                        }
                    }
                }
                .padding(32)
                .padding(.bottom, 80)
            }
            if !chosen.isEmpty {
                ActionBar(summary: "已选 \(chosen.count) 项 · \(chosen.compactMap(\.size).reduce(0, +).gbText)") {
                    Button("在访达中查看") {
                        NSWorkspace.shared.activateFileViewerSelecting(chosen.flatMap(\.paths).prefix(20).map { URL(filePath: $0) })
                    }
                    Button("删除", action: trash).buttonStyle(.borderedProminent)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth, value: chosen.count)
    }

    private func trash() {
        let items = chosen
        var sizes: [String: Double] = [:]
        for i in items where i.paths.count == 1 { if let s = i.size { sizes[i.paths[0]] = s } }
        // 失效的开机启动项要启动的程序已经不在了，先停用不会有影响；plist 删掉后就没法按路径停用了
        for i in items where i.paths.first?.contains("/LaunchAgents/") == true {
            LaunchScanner.unload(LaunchItem(owner: i.name, label: "", plist: i.paths[0], isUser: true))
        }
        model.requestTrash(.init(title: "删除 \(items.count) 项残留", source: "残留文件",
                                 urls: items.flatMap(\.paths).map { URL(filePath: $0) }, sizes: sizes, onDone: { _ in
            withAnimation {
                // 只去掉真的删掉了的（取消输密码、没权限的留在列表里）
                let gone = items.filter { $0.paths.allSatisfy { model.removedKeys.contains($0) } }.map(\.id)
                for g in model.leftovers.indices { model.leftovers[g].items.removeAll { gone.contains($0.id) } }
                model.leftovers.removeAll { $0.items.isEmpty }
            }
        }))
    }

    private func row(_ item: LeftoverItem) -> some View {
        HStack(spacing: 14) {
            Toggle(isOn: Binding(get: { isOn(item) }, set: { overrides[item.id] = $0 })) { EmptyView() }
                .toggleStyle(.checkbox).labelsHidden().accessibilityLabel(item.name)
            VStack(alignment: .leading, spacing: 3) {
                NameAndPath(name: item.name, path: item.path)
                Text(item.evidence).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(item.size.gbText).fontWeight(.semibold).monospacedDigit()
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
}
