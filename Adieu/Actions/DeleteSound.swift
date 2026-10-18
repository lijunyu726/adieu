import AppKit

/// 删除完成时的提示音。一次操作只响一次：要密码的分两步删，也等全部删完才响
enum DeleteSound: String, CaseIterable, Identifiable {
    case poof, emptyTrash, pop, glass, purr, none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .poof: "一阵烟（程序坞移除图标）"
        case .emptyTrash: "清空废纸篓"
        case .pop: "啵"
        case .glass: "玻璃"
        case .purr: "呼噜"
        case .none: "不播放"
        }
    }

    private var path: String? {
        switch self {
        case .poof: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/poof item off dock.aif"
        case .emptyTrash: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/empty trash.aif"
        case .pop: "/System/Library/Sounds/Pop.aiff"
        case .glass: "/System/Library/Sounds/Glass.aiff"
        case .purr: "/System/Library/Sounds/Purr.aiff"
        case .none: nil
        }
    }

    static let key = "deleteSound"

    /// 以前关掉过“删除音效”的，保持不响
    static var current: DeleteSound {
        if let raw = UserDefaults.standard.string(forKey: key) { return DeleteSound(rawValue: raw) ?? .poof }
        return UserDefaults.standard.object(forKey: "soundEnabled") as? Bool == false ? .none : .poof
    }

    static func play() { current.preview() }

    func preview() {
        guard let path else { return }
        NSSound(contentsOfFile: path, byReference: true)?.play()
    }
}
