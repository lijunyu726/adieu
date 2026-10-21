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
            let title = installed.isEmpty ? "\(unzipped.count) 个压缩包已经解压过了"
                : unzipped.isEmpty ? "\(installed.count) 个安装包对应的应用都已经装好了"
                : "\(installed.count) 个安装包的应用已经装好，\(unzipped.count) 个压缩包已经解压过"
            let tail = installed.isEmpty ? "旁边都有解压好的文件夹。" : "以后要用可以重新下载。"
            return .init(title: title, detail: "删掉能腾出 \(total(both).gbText)，\(tail)", items: both, button: "勾选这 \(both.count) 个")
        case .captures:
            let extra = earlierShotsEachDay(files)
            guard !extra.isEmpty else { return nil }
            let videos = files.filter(isVideo)
            let tail = videos.isEmpty ? "。" : "；录屏占了 \(total(videos).gbText)，要不要留，指着看一眼再决定。"
            return .init(title: "截图每天留最后一张就够", detail: "先勾上每天较早的 \(extra.count) 张（\(total(extra).gbText)）\(tail)",
                         items: extra, button: "每天只留最后一张")
        case .bigFiles:
            let again = files.filter { ["安装包", "系统镜像"].contains($0.kind) }
            guard !again.isEmpty else { return nil }
            return .init(title: "\(again.count) 个安装包和系统镜像可以重新下载", detail: "共 \(total(again).gbText)。装好以后一般就用不上了，需要时再下载。",
                         items: again, button: "勾选这 \(again.count) 个")
        case .stale:
            // 这些都半年没碰过，但“没打开”不等于“不要了”，所以比别的页更保守
            let again = files.filter { ["安装包", "系统镜像"].contains($0.kind) || $0.group == FileCategorizer.unzippedGroup }
            guard !again.isEmpty else { return nil }
            let rest = files.count - again.count
            return .init(title: "\(again.count) 个安装包和镜像很久没用了",
                         detail: "都能重新下载，共 \(total(again).gbText)。" + (rest > 0 ? "其余 \(rest) 个是你自己的文件，指着看一眼再决定。" : ""),
                         items: again, button: "勾选这 \(again.count) 个")
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
