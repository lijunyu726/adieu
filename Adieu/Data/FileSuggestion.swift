import Foundation

/// 文件页顶上那条建议：哪些可以放心删。首页“今日建议”用的是同一套规则，两边的数字对得上。
/// 只建议能重新下载、或者已经用过的（装好了的安装包、解压过的压缩包、每天较早的截图）；自己的文档、视频不替人勾
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
        case .captures:
            let extra = earlierShotsEachDay(files)
            guard !extra.isEmpty else { return nil }
            let videos = files.filter(isVideo)
            let extraCount = extra.count
            let extraSize = total(extra).gbText
            let videoSize = total(videos).gbText
            let detail = videos.isEmpty
                ? String(localized: "先勾上每天较早的 \(extraCount) 张（\(extraSize)）。")
                : String(localized: "先勾上每天较早的 \(extraCount) 张（\(extraSize)）；录屏占了 \(videoSize)，要不要留，指着看一眼再决定。")
            return .init(title: String(localized: "截图每天留最后一张就够"), detail: detail,
                         items: extra, button: String(localized: "每天只留最后一张"))
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

    static func isVideo(_ f: FileItem) -> Bool { f.kind == "屏幕录制" || f.kind == "视频" }

    private static func total(_ list: [FileItem]) -> Double { list.map(\.size).reduce(0, +) }

    /// 每一天除最晚那张以外的截图（不含录屏，录屏大，留给人自己看着决定）
    private static func earlierShotsEachDay(_ files: [FileItem]) -> [FileItem] {
        let shots = files.filter { !isVideo($0) && $0.date != nil }
        let days = Dictionary(grouping: shots) { Calendar.current.startOfDay(for: $0.date!) }
        return days.values.flatMap { $0.sorted { $0.date! > $1.date! }.dropFirst() }
    }
}
