import Foundation
import UserNotifications

/// 自动规则的提醒。第一次开启规则时请求通知权限
enum Notifier {
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// 同一个 id 的通知会替换上一条，不会堆起来
    static func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// 没问过（notAsked）时系统设置里也没有 Adieu，要先调 requestAuthorization 让系统弹窗
    static func state() async -> Permissions.State {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        default: .notAsked
        }
    }
}
