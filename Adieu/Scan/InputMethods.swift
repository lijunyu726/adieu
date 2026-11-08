import Carbon
import Foundation

/// 第三方输入法：装在“输入法”文件夹里的应用包。
/// 删除前先在系统里停用，否则系统会一直把它拉起来，输入法菜单里也会留着。
enum InputMethods {
    static func roots(home: URL) -> [URL] {
        [URL(filePath: "/Library/Input Methods"), home.appending(path: "Library/Input Methods")]
    }

    /// 在输入法文件夹里，或者包里声明了输入模式的
    static func isInputMethod(_ url: URL, info: [String: Any]?) -> Bool {
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent == "Input Methods" || info?["tsInputModeListKey"] != nil || info?["InputMethodConnectionName"] != nil
    }

    /// 在系统里停用这个输入法的全部输入源。输入法接口要在主线程调用
    @MainActor
    static func disable(bundleID: String) {
        let filter = [kTISPropertyBundleID as String: bundleID] as CFDictionary
        let sources = (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource]) ?? []
        for source in sources { TISDisableInputSource(source) }
    }
}
