import Foundation

/// 数据里的固定词换成当前界面语言。判断仍用简体原文，不把原文嵌进别的语言的句子。
enum Copy {
    static func text(_ source: String) -> String {
        Bundle.main.localizedString(forKey: source, value: source, table: nil)
    }

    /// “PDF 文件”这类带扩展名的种类；其余是固定词
    static func kind(_ kind: String) -> String {
        let suffix = " 文件"
        if kind.hasSuffix(suffix), kind != "文件" {
            let ext = String(kind.dropLast(suffix.count))
            return String(localized: "\(ext) 文件")
        }
        return text(kind)
    }

    /// 位置的第一段是桌面、文稿这些根目录，后面是用户自己的文件夹名
    static func location(_ location: String) -> String {
        var parts = location.components(separatedBy: " › ")
        guard let first = parts.first else { return location }
        parts[0] = text(first)
        return parts.joined(separator: " › ")
    }

    /// 修改时间有时是状态（“微信 已安装”“120 天没打开”），不是日期
    static func status(_ modified: String) -> String {
        let installed = "已安装"
        if modified.hasSuffix(installed) {
            let name = modified.dropLast(installed.count).trimmingCharacters(in: .whitespaces)
            if name.isEmpty { return text(installed) }
            return String(localized: "\(name) 已安装")
        }
        let idle = "天没打开"
        if modified.hasSuffix(idle), let n = Int(modified.dropLast(idle.count).trimmingCharacters(in: .whitespaces)) {
            return String(localized: "\(n) 天没打开")
        }
        return text(modified)
    }

    static func facet(_ title: String, _ value: String) -> String {
        title == "类型" ? kind(value) : text(value)
    }

    static func labeledCount(_ name: String, _ n: Int) -> String {
        String(localized: "\(name)（\(n)）")
    }
}

/// 存在数据里的简体词。集中写一遍，字符串目录才收得到。
enum Lexicon {
    static func load() -> [String] {
        [
            String(localized: "安装包"), String(localized: "系统镜像"), String(localized: "压缩包"),
            String(localized: "屏幕录制"), String(localized: "视频"), String(localized: "截图"),
            String(localized: "图片"), String(localized: "文档"), String(localized: "虚拟磁盘"),
            String(localized: "资源库"), String(localized: "文件"), String(localized: "文件夹"),
            String(localized: "应用已经装好了"), String(localized: "已经解压过"), String(localized: "其他"),
            String(localized: "桌面"), String(localized: "文稿"), String(localized: "下载"),
            String(localized: "影片"), String(localized: "音乐"),
            String(localized: "旁边已经有解压后的文件夹"), String(localized: "旁边已经有解压后的同名文件夹"),
            String(localized: "已安装"),
            String(localized: "可用"), String(localized: "你的文件"), String(localized: "统计中…"),
            String(localized: "应用数据"), String(localized: "其他应用"), String(localized: "隐藏文件与开发缓存"),
            String(localized: "应用程序"), String(localized: "macOS 系统与其他"), String(localized: "交换文件"),
            String(localized: "应用缓存"), String(localized: "系统卷"),
            String(localized: "以后要用可以重新下载"), String(localized: "旁边有解压好的文件夹"),
            String(localized: "没找到对应的应用，确认不要了再删"),
            String(localized: "两年多没打开"), String(localized: "一年多没打开"), String(localized: "半年多没打开"),
            String(localized: "这一组"), String(localized: "这一天"),
            String(localized: "缩略图"), String(localized: "列表"), String(localized: "逐个看"),
            String(localized: "最大的在前"), String(localized: "最新的在前"), String(localized: "最旧的在前"), String(localized: "按名称"),
            String(localized: "今天"), String(localized: "一周内"), String(localized: "一个月内"),
            String(localized: "半年内"), String(localized: "半年以前"), String(localized: "不清楚"),
            String(localized: "昨天"), String(localized: "日期未知"),
            String(localized: "应用"), String(localized: "开发"),
            String(localized: "下载与文稿"), String(localized: "大多在桌面和文稿"), String(localized: "文稿和下载"),
            String(localized: "其中应用已装好"), String(localized: "已解压的压缩包"), String(localized: "截图与录屏"),
            String(localized: "最大的一个"), String(localized: "其中录屏"), String(localized: "50 MB 以上"),
            String(localized: "最大的 5 个"), String(localized: "可以重新下载的"), String(localized: "半年没打开"),
            String(localized: "最久的"), String(localized: "最大的一段录屏"),
            String(localized: "稳妥"), String(localized: "看一眼"),
            String(localized: "应用本身"), String(localized: "确定是它的"), String(localized: "同一家开发商"),
            String(localized: "名字像，要你确认"), String(localized: "别的应用也在用"),
            String(localized: "应用本体"), String(localized: "后台项目"), String(localized: "共享组件"),
            String(localized: "自动执行"), String(localized: "只提醒"),
            String(localized: "下载回来、已经用过的东西：应用装好了的安装包，解压过的压缩包。"),
            String(localized: "屏幕录制往往很大，看过或导出过就可以删掉。"),
            String(localized: "50 MB 以上的文件，按体积排序。每个都说明它是什么、能不能重新下载。"),
            String(localized: "50 MB 以上的文件和文件夹，按体积排序。每个都说明它是什么、能不能重新下载。"),
            String(localized: "50 MB 以上、半年没打开过的文件。不一定要删，确认不用了再清理。"),
            String(localized: "类型"), String(localized: "位置"), String(localized: "时间"),
            String(localized: "当"), String(localized: "里的安装包对应的应用"), String(localized: "已安装超过 7 天"),
            String(localized: "时，"), String(localized: "提醒我"), String(localized: "可用空间低于 10%"),
            String(localized: "发通知并给出一键方案"), String(localized: "每"), String(localized: "周日 21:00"),
            String(localized: "，"), String(localized: "清理 Homebrew、npm、uv 的缓存"),
            String(localized: "上的截图"), String(localized: "放了 30 天"), String(localized: "移到“图片/截图归档”"),
            String(localized: "微信的数据超过 20 GB"), String(localized: "提醒我去微信里清理"),
            String(localized: "装好的应用，安装包别留着"), String(localized: "空间告急时提醒"),
            String(localized: "每周清一次开发缓存"), String(localized: "桌面截图自动归档"), String(localized: "微信太大时提醒"),
        ]
    }
}
