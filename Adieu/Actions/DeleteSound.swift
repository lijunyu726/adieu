import AppKit

/// 删除完成时的提示音。一次操作只响一次：要密码的分两步删，也等全部删完才响。
/// 卸载应用、删文件、删残留、清开发缓存都用同一个，默认是清空废纸篓的声音
enum DeleteSound: String, CaseIterable, Identifiable {
    case emptyTrash, moveToTrash, poof, pop, glass, purr, none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .emptyTrash: "清空废纸篓"
        case .moveToTrash: "移到废纸篓"
        case .poof: "一阵烟（程序坞移除图标）"
        case .pop: "啵"
        case .glass: "玻璃"
        case .purr: "呼噜"
        case .none: "不播放"
        }
    }

    private static let systemSounds = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds"

    private var path: String? {
        switch self {
        case .emptyTrash: "\(Self.systemSounds)/finder/empty trash.aif"
        case .moveToTrash: "\(Self.systemSounds)/finder/move to trash.aif"
        case .poof: "\(Self.systemSounds)/dock/poof item off dock.aif"
        case .pop: "/System/Library/Sounds/Pop.aiff"
        case .glass: "/System/Library/Sounds/Glass.aiff"
        case .purr: "/System/Library/Sounds/Purr.aiff"
        case .none: nil
        }
    }

    static let key = "deleteSound"

    /// 以前关掉过“删除音效”的，保持不响
    static var current: DeleteSound {
        if let raw = UserDefaults.standard.string(forKey: key) { return DeleteSound(rawValue: raw) ?? .emptyTrash }
        return UserDefaults.standard.object(forKey: "soundEnabled") as? Bool == false ? .none : .emptyTrash
    }

    static func play() { current.preview() }

    func preview() {
        guard let path else { return }
        NSSound(contentsOfFile: path, byReference: true)?.play()
    }
}
