import Foundation

/// 文件页顶上那条建议：哪些可以放心删。首页“今日建议”用的是同一套规则，两边的数字对得上。
/// 只建议能重新下载、或者已经用过的（装好了的安装包、解压过的压缩包）；自己的文档、图片、视频不替人勾
struct FileSuggestion {
    let title: String
    let detail: String
    let items: [FileItem]
    let button: String

    var size: Double { Self.total(items) }

    /// files 不含汇总行和已经删掉的
    static func make(_ section: AppSection, files: [FileItem]) -> FileSuggestion? {
        switch section {
        case .installers:
            let installed = files.filter { $0.group == FileCategorizer.installedGroup }
            let unzipped = files.filter { $0.group == FileCategorizer.unzippedGroup }
            let both = installed + unzipped
            guard !both.isEmpty else { return nil }
            let title = installed.isEmpty ? String(localized: "\(unzipped.count) 个压缩包已经解压过了")
                : unzipped.isEmpty ? String(localized: "\(installed.count) 个安装包对应的应用都已经装好了")
                : String(localized: "\(installed.count) 个安装包的应用已经装好，\(unzipped.count) 个压缩包已经解压过")
            let tail = installed.isEmpty ? String(localized: "旁边都有解压好的文件夹。") : String(localized: "以后要用可以重新下载。")
            let size = total(both).gbText
            return .init(title: title, detail: String(localized: "删掉能腾出 \(size)，\(tail)"), items: both, button: String(localized: "勾选这 \(both.count) 个"))
        case .bigFiles:
            let again = files.filter { ["安装包", "系统镜像"].contains($0.kind) }
            guard !again.isEmpty else { return nil }
            let n = again.count
            let size = total(again).gbText
            return .init(title: String(localized: "\(n) 个安装包和系统镜像可以重新下载"), detail: String(localized: "共 \(size)。装好以后一般就用不上了，需要时再下载。"),
                         items: again, button: String(localized: "勾选这 \(n) 个"))
        case .stale:
            // 这些都半年没碰过，但“没打开”不等于“不要了”，所以比别的页更保守
            let again = files.filter { ["安装包", "系统镜像"].contains($0.kind) || $0.group == FileCategorizer.unzippedGroup }
            guard !again.isEmpty else { return nil }
            let rest = files.count - again.count
            let n = again.count
            let size = total(again).gbText
            let detail = rest > 0
                ? String(localized: "都能重新下载，共 \(size)。其余 \(rest) 个是你自己的文件，指着看一眼再决定。")
                : String(localized: "都能重新下载，共 \(size)。")
            return .init(title: String(localized: "\(n) 个安装包和镜像很久没用了"),
                         detail: detail,
                         items: again, button: String(localized: "勾选这 \(n) 个"))
        default:
            return nil
        }
    }

    static func isVideo(_ f: FileItem) -> Bool { f.kind == "视频" }

    private static func total(_ list: [FileItem]) -> Double { list.map(\.size).reduce(0, +) }
}
