import SwiftUI

/// 删除前的确认和结果提示。主窗口和面板各挂一个，`active` 决定当前由谁负责
struct TrashConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    let active: Bool

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .alert(model.pendingTrash?.title ?? "", isPresented: Binding(
                get: { active && model.pendingTrash != nil },
                set: { if !$0 { model.pendingTrash = nil } }
            ), presenting: model.pendingTrash) { req in
                Button("删除", role: .destructive) { model.perform(req) }
                Button("取消", role: .cancel) { model.pendingTrash = nil }
            } message: { req in
                let size = req.sizes.values.reduce(0, +)
                let what = size > 0
                    ? String(localized: "\(req.urls.count) 项、共 \(size.gbText)")
                    : String(localized: "\(req.urls.count) 项")
                Text(String(localized: "将直接删除 \(what)，不进废纸篓，删了不能放回。"))
            }
            .alert("提示", isPresented: Binding(
                get: { active && model.notice != nil },
                set: { if !$0 { model.notice = nil } }
            )) {
                Button("好") { model.notice = nil }
            } message: {
                Text(model.notice ?? "")
            }
    }
}

extension View {
    func trashConfirmation(active: Bool = true) -> some View { modifier(TrashConfirmation(active: active)) }
}
