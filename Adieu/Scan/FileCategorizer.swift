import Foundation

/// 把文件扫描结果整理成各页面要显示的内容：分类、理由、统计
enum FileCategorizer {
    static let big = 50.0 / 1000
    static let staleDays = 180

    // MARK: 安装包对应的应用是否已装好

    /// 只留字母、数字和汉字，转小写
    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// 文件名开头的那个词（去掉版本号、平台等）
    static func leadingWord(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let first = base.split(whereSeparator: { "-_ .".contains($0) || $0.isNumber }).first.map(String.init) ?? base
        return normalize(first)
    }

    /// 返回已经装好的应用名；匹配不上返回 nil
    static func installedApp(for installer: String, apps: [AppItem]) -> String? {
        let file = normalize((installer as NSString).deletingPathExtension)
        let word = leadingWord(installer)
        for app in apps {
            let names = [app.name, app.path.map { ($0 as NSString).lastPathComponent.replacing(/\.app$/, with: "") } ?? ""]
            for n in names.map(normalize) where n.count >= 3 {
                if file.hasPrefix(n) || (word.count >= 4 && n.hasPrefix(word)) { return app.name }
            }
        }
        return nil
    }

    // MARK: 显示用的文字

    static func location(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var rel = path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : path
        rel = (rel as NSString).deletingLastPathComponent
        var parts = rel.split(separator: "/").map(String.init)
        if let first = parts.first, let root = FileScanner.roots.first(where: { $0.dir == first }) { parts[0] = root.name }
        if parts.count > 3 { parts = [parts[0], "…"] + parts.suffix(2) }
        return parts.joined(separator: " › ")
    }

    static func dateText(_ d: Date) -> String {
        Calendar.current.isDate(d, equalTo: .now, toGranularity: .year)
            ? d.formatted(.dateTime.month().day()) : d.formatted(.dateTime.year().month().day())
    }

    static func days(since d: Date) -> Int {
        Calendar.current.dateComponents([.day], from: d, to: .now).day ?? 0
    }

    static func kind(_ f: FileScanner.File) -> String {
        if f.isPackage { return "资源库" }
        switch f.ext {
        case "dmg", "pkg", "mpkg", "xip": return "安装包"
        case "iso", "img": return "系统镜像"
        case _ where FileScanner.archiveExts.contains(f.ext): return "压缩包"
        case "mov", "mp4", "avi", "mkv", "m4v", "wmv", "flv":
            return f.isScreenCapture ? "屏幕录制" : "视频"
        case "png", "jpg", "jpeg", "heic", "gif", "tiff", "psd":
            return f.isScreenCapture ? "截图" : "图片"
        case "pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "key", "pages", "numbers": return "文档"
        case "vmdk", "qcow2", "vdi", "vhd", "vhdx", "utm": return "虚拟磁盘"
        default: return f.ext.isEmpty ? "文件" : f.ext.uppercased() + " 文件"
        }
    }

    static func reason(_ f: FileScanner.File, installedApp: String?, extractedFolder: String?) -> String {
        let idle = days(since: f.lastTouched)
        let idleText = idle >= staleDays ? "\(idle) 天没有打开过。" : ""
        switch kind(f) {
        case "安装包":
            return installedApp.map { "\($0) 已经装好了，安装包可以删，需要时能重新下载。" } ?? "安装包。没找到对应的应用，确认不再需要再删。"
        case "系统镜像": return "系统安装镜像。装好以后一般就用不上了，需要时可以重新下载。" + idleText
        case "压缩包":
            return extractedFolder.map { "旁边已经有解压后的“\($0)”文件夹。" } ?? ("压缩包，旁边没有解压后的同名文件夹。" + idleText)
        case "屏幕录制": return "一段屏幕录制。看过或已经导出的话，原片可以删掉。"
        case "截图": return "截图。用完就可以删。"
        case "视频": return (f.ext == "avi" ? "没有压缩的 AVI 视频，转成 MP4 通常能小很多。" : "") + idleText
        case "虚拟磁盘": return "虚拟机的磁盘文件。还在用这台虚拟机的话不要删。"
        case "资源库": return "一个资源库（如剪辑工程），里面是一整套文件。" + idleText
        default: return idleText.isEmpty ? "比较大的文件。" : idleText
        }
    }

    static func item(_ f: FileScanner.File, apps: [AppItem], modifiedNote: String? = nil) -> FileItem {
        let installed = FileScanner.installerExts.contains(f.ext) ? installedApp(for: f.name, apps: apps) : nil
        let extracted = extractedFolder(f)
        return FileItem(id: f.path, name: f.name, ext: f.isPackage ? "DIR" : (f.ext.isEmpty ? "—" : f.ext.uppercased()),
                        kind: kind(f), location: location(f.path),
                        modified: modifiedNote ?? dateText(f.modified), size: f.size,
                        reason: reason(f, installedApp: installed, extractedFolder: extracted), path: f.path, date: f.modified)
    }

    /// 压缩包旁边有同名文件夹，就认为已经解压过
    static func extractedFolder(_ f: FileScanner.File) -> String? {
        guard FileScanner.archiveExts.contains(f.ext) else { return nil }
        var base = f.url.deletingPathExtension()
        if base.pathExtension == "tar" { base = base.deletingPathExtension() }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: base.path, isDirectory: &isDir) && isDir.boolValue ? base.lastPathComponent : nil
    }

    // MARK: 四类页面

    static func categories(_ scan: FileScanner.Result, apps: [AppItem]) -> [FileCategory] {
        let files = scan.files
        func count(_ fs: [FileScanner.File]) -> String { "\(fs.count) 个 · \(fs.map(\.size).reduce(0, +).gbText)" }
        let template = Dictionary(uniqueKeysWithValues: Sample.fileCategories.map { ($0.id, $0) })

        // 安装包与压缩包：已装好的、已解压的排前面
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let inDownloadRoots = { (f: FileScanner.File) in
            FileScanner.downloadRoots.contains { f.path.hasPrefix("\(home)/\($0)/") }
        }
        let installers = files.filter { FileScanner.installerExts.contains($0.ext) && inDownloadRoots($0) }
        let installedPairs = installers.map { ($0, installedApp(for: $0.name, apps: apps)) }
        let archives = files.filter { FileScanner.archiveExts.contains($0.ext) && !$0.isPackage && inDownloadRoots($0) }
        let extracted = archives.filter { extractedFolder($0) != nil }
        let doneInstallers = installedPairs.filter { $0.1 != nil }.map(\.0)
        let installerItems = (installedPairs.sorted { ($0.1 != nil ? 1 : 0, $0.0.size) > ($1.1 != nil ? 1 : 0, $1.0.size) }.map { f, app in
            item(f, apps: apps, modifiedNote: app.map { "\($0) 已安装" } ?? dateText(f.modified))
        }) + archives.sorted { (extractedFolder($0) != nil ? 1 : 0, $0.size) > (extractedFolder($1) != nil ? 1 : 0, $1.size) }.map { f in
            item(f, apps: apps, modifiedNote: extractedFolder(f) != nil ? "旁边已经有解压后的文件夹" : dateText(f.modified))
        }

        // 截图与录屏
        let captures = files.filter(\.isScreenCapture).sorted { $0.size > $1.size }

        // 大文件
        let bigs = files.filter { $0.size >= big }.sorted { $0.size > $1.size }
        let redownloadable = bigs.filter { ["安装包", "系统镜像"].contains(kind($0)) }

        // 久未打开
        let stale = bigs.filter { days(since: $0.lastTouched) >= staleDays }
        let oldest = stale.map { days(since: $0.lastTouched) }.max()

        return [
            FileCategory(id: .installers, subtitle: template[.installers]!.subtitle,
                         stats: [.init(label: "安装包", value: count(installers)),
                                 .init(label: "其中应用已装好", value: count(doneInstallers), highlight: !doneInstallers.isEmpty),
                                 .init(label: "已解压的压缩包", value: count(extracted), highlight: !extracted.isEmpty)],
                         items: installerItems, reviewable: false, ruleID: "pkg"),
            FileCategory(id: .captures, subtitle: template[.captures]!.subtitle,
                         stats: [.init(label: "截图与录屏", value: count(captures)),
                                 .init(label: "最大的一个", value: captures.first?.size.gbText ?? "—", highlight: !captures.isEmpty),
                                 .init(label: "其中录屏", value: "\(captures.filter { kind($0) == "屏幕录制" }.count) 个")],
                         items: captures.map { item($0, apps: apps) }, reviewable: true, ruleID: "shot"),
            FileCategory(id: .bigFiles, subtitle: "50 MB 以上的文件，按体积排序。每个都说明它是什么、能不能重新下载。",
                         stats: [.init(label: "50 MB 以上", value: count(bigs)),
                                 .init(label: "最大的 5 个", value: bigs.prefix(5).map(\.size).reduce(0, +).gbText, highlight: !bigs.isEmpty),
                                 .init(label: "可以重新下载的", value: count(redownloadable), highlight: !redownloadable.isEmpty)],
                         items: bigs.map { item($0, apps: apps) }, reviewable: true, ruleID: "s690"),
            FileCategory(id: .stale, subtitle: template[.stale]!.subtitle,
                         stats: [.init(label: "半年没打开", value: count(stale)),
                                 .init(label: "最久的", value: oldest.map { "\($0) 天" } ?? "—")],
                         items: stale.map { item($0, apps: apps, modifiedNote: "\(days(since: $0.lastTouched)) 天没打开") }, reviewable: true, ruleID: nil)
        ]
    }

}
