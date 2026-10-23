import AppKit

/// 界面语言。开发语言仍是简体中文；没选过时跟随系统。
/// 改完写入 AppleLanguages，下次启动才生效。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en
    case ja
    case ko
    case es
    case fr
    case de

    var id: String { rawValue }

    static let key = "appLanguage"
    /// 这次进程启动时的覆盖语言；nil 表示当时在跟随系统。只在启动时写一次。
    nonisolated(unsafe) private(set) static var startedWith: String?

    static func captureLaunch() {
        startedWith = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first
        _ = Lexicon.load()
    }

    static var current: AppLanguage {
        guard let raw = UserDefaults.standard.string(forKey: key), let lang = AppLanguage(rawValue: raw) else { return .system }
        return lang
    }

    /// 语言名用各自的写法，换成别的语言后仍能找到自己的那一项
    var title: String {
        switch self {
        case .system: String(localized: "跟随系统")
        case .zhHans: "简体中文"
        case .zhHant: "繁體中文"
        case .en: "English"
        case .ja: "日本語"
        case .ko: "한국어"
        case .es: "Español"
        case .fr: "Français"
        case .de: "Deutsch"
        }
    }

    func persist() {
        UserDefaults.standard.set(rawValue, forKey: Self.key)
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }

    var needsRelaunch: Bool {
        switch self {
        case .system:
            return Self.startedWith != nil
        default:
            if let started = Self.startedWith { return !Self.same(started, rawValue) }
            let system = Locale.preferredLanguages.first ?? ""
            return !Self.same(system, rawValue)
        }
    }

    private static func same(_ running: String, _ code: String) -> Bool {
        running == code || running.hasPrefix(code + "-")
    }

    /// 再开一个实例，然后退出这一个
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            guard error == nil else { return }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
