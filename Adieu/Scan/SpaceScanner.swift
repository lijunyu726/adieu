import Foundation

/// 首页“空间分布”需要的几个大块。~/Library 有几十万个文件，统计要几十秒，放在后台跑
enum SpaceScanner {
    struct Result: Sendable {
        var library = 0.0
        var containers = 0.0
        var groupContainers = 0.0
        var appSupport = 0.0
        var caches = 0.0
        var developer = 0.0
        /// 主目录里以点开头的隐藏文件夹（各种工具的配置和缓存）
        var dotDirs = 0.0
        var biggestDotDirs: [(name: String, size: Double)] = []
        var homebrew: Double?
        var swap = 0.0
        var snapshots = 0
        /// 下面是“macOS 系统与其他”的细分，读不到的是 nil
        var systemVolume: Double?
        var preboot: Double?
        var recovery: Double?
        /// VM 卷：交换文件
        var vmVolume: Double?
        var sleepImage: Double?
        var logs: Double?
        /// /var/folders 下当前用户的临时文件和缓存（T、C）
        var temp: Double?
        /// /System/Library/AssetsV2：系统按需下载的字体、语音、模型等
        var assets: Double?
        var clones = CodeSignClones.Summary()
        /// 有已下载、还没安装的系统更新（本地快照里有 os.update / MSUPrepareUpdate）
        var pendingUpdate = false
        /// 已下载的系统更新包
        var updateDownload: Double?
        var hotspots: [Hotspot] = []
    }

    /// 常见大户：不归 Adieu 删，但值得知道有多大、正确的处理办法是什么
    struct Hotspot: Identifiable, Hashable, Sendable {
        let id: String
        let label: String
        let path: String
        let size: Double
        let grade: Safety
        /// 怎么处理（不是删文件夹）
        let note: String
        /// Docker 虚拟磁盘这类稀疏文件：看着有多大
        var logical: Double? = nil
    }

    static func scan() -> Result {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let lib = home.appending(path: "Library")
        var r = Result()
        // 分开统计几个大的子目录，再统计整个资源库
        var libSub: [String: Double] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: lib.path)) ?? [] {
            libSub[name] = AppScanner.allocatedSize(lib.appending(path: name)) ?? 0
        }
        r.library = libSub.values.reduce(0, +)
        r.containers = libSub["Containers"] ?? 0
        r.groupContainers = libSub["Group Containers"] ?? 0
        r.appSupport = libSub["Application Support"] ?? 0
        r.caches = libSub["Caches"] ?? 0
        r.developer = libSub["Developer"] ?? 0

        var dots: [(String, Double)] = []
        for name in (try? fm.contentsOfDirectory(atPath: home.path)) ?? [] where name.hasPrefix(".") && name != ".Trash" {
            let url = home.appending(path: name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            dots.append((name, AppScanner.allocatedSize(url) ?? 0))
        }
        r.dotDirs = dots.map(\.1).reduce(0, +)
        r.biggestDotDirs = dots.sorted { $0.1 > $1.1 }.prefix(3).map { ($0.0, $0.1) }

        if fm.fileExists(atPath: "/opt/homebrew") { r.homebrew = AppScanner.allocatedSize(URL(filePath: "/opt/homebrew")) }
        else if fm.fileExists(atPath: "/usr/local/Homebrew") { r.homebrew = AppScanner.allocatedSize(URL(filePath: "/usr/local/Homebrew")) }

        r.swap = swapUsed()
        let snaps = (run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]) ?? "")
            .split(separator: "\n").filter { $0.contains("com.apple") }
        r.snapshots = snaps.count
        r.pendingUpdate = snaps.contains { $0.contains("os.update") || $0.contains("MSUPrepareUpdate") }
        r.updateDownload = AppScanner.allocatedSize(URL(filePath: "/System/Library/AssetsV2/com_apple_MobileAsset_MacSoftwareUpdate"))
        systemParts(into: &r)
        r.hotspots = hotspots(home: home)
        return r
    }

    /// 0.5 GB 以上的才列。大小都按实际占用算（APFS 克隆、稀疏文件不重复算）
    static func hotspots(home: URL) -> [Hotspot] {
        let fm = FileManager.default
        var list: [Hotspot] = []
        func add(_ id: String, _ label: String, _ path: String, _ grade: Safety, _ note: String) {
            let url = URL(filePath: (path as NSString).expandingTildeInPath)
            guard let size = AppScanner.allocatedSize(url), size >= 0.5 else { return }
            list.append(.init(id: id, label: label, path: url.path, size: size, grade: grade, note: note))
        }
        add("ios-backup", String(localized: "iPhone / iPad 备份"), "~/Library/Application Support/MobileSync/Backup", .review,
            String(localized: "在访达侧边栏点设备 →「管理备份…」，删掉不要的旧备份。不要直接删这个文件夹，备份之间共用文件。"))
        for name in ((try? fm.contentsOfDirectory(atPath: home.appending(path: "Pictures").path)) ?? []).sorted()
        where name.hasSuffix(".photoslibrary") {
            add("photos.\(name)", (name as NSString).deletingPathExtension, "~/Pictures/\(name)", .keep,
                String(localized: "照片图库只在「照片」里管理：打开「照片」→ 设置 → iCloud，选“优化 Mac 储存空间”，原图留在 iCloud；删照片也在「照片」里删。手动动图库会损坏它。"))
        }
        let raw = home.appending(path: "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
        if let size = AppScanner.allocatedSize(raw), size >= 0.5 {
            let logical = (try? raw.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Double($0) / bytesPerGB }
            list.append(.init(id: "docker-raw", label: String(localized: "Docker 虚拟磁盘"), path: raw.path, size: size, grade: .review,
                              note: String(localized: "Docker 的镜像和数据都在里面。用「开发工具」页或 docker image prune、docker builder prune 清；清完没缩小，到 Docker Desktop → 设置 → Resources 调小磁盘上限。不要直接删这个文件，也不要用 docker system prune --volumes（会删数据库卷）。"),
                              logical: logical))
        }
        add("mail", String(localized: "邮件"), "~/Library/Mail", .review,
            String(localized: "大多是邮件和附件的本地副本。在「邮件」里删掉带大附件的旧邮件，或者在账户设置里不下载附件。不要手删这个文件夹。"))
        add("messages", String(localized: "信息的附件"), "~/Library/Messages/Attachments", .review,
            String(localized: "在「信息」→ 设置 → 通用里把“保留信息”改成 30 天或 1 年，或在「系统设置 → 通用 → 储存空间 → 信息」里删大附件。"))
        add("garageband", "GarageBand", "/Library/Application Support/GarageBand", .review,
            String(localized: "乐器和音效素材。不用了就卸载 GarageBand，或在 GarageBand →“声音资源库”里删掉下载的内容。"))
        add("logic", "Logic Pro", "/Library/Application Support/Logic", .review,
            String(localized: "乐器和音效素材。在 Logic Pro →“声音资源库”→“管理声音资源库”里删，或移到外接硬盘。"))
        return list.sorted { $0.size > $1.size }
    }

    /// 系统那一块能看清的部分：APFS 各卷、睡眠镜像、日志、临时文件、系统素材、签名副本。都不用管理员权限
    static func systemParts(into r: inout Result) {
        let volumes = apfsVolumes()
        r.systemVolume = volumes["System"]
        r.preboot = volumes["Preboot"]
        r.recovery = volumes["Recovery"]
        r.vmVolume = volumes["VM"]
        r.sleepImage = AppScanner.allocatedSize(URL(filePath: "/private/var/vm/sleepimage"))
        let logs = ["/private/var/db/diagnostics", "/private/var/db/uuidtext", "/private/var/log"]
            .compactMap { AppScanner.allocatedSize(URL(filePath: $0)) }
        r.logs = logs.isEmpty ? nil : logs.reduce(0, +)
        if let x = CodeSignClones.root {
            let base = x.deletingLastPathComponent()
            let temp = ["T", "C"].compactMap { AppScanner.allocatedSize(base.appending(path: $0)) }
            r.temp = temp.isEmpty ? nil : temp.reduce(0, +)
        }
        r.assets = AppScanner.allocatedSize(URL(filePath: "/System/Library/AssetsV2"))
        r.clones = CodeSignClones.scan()
    }

    /// 启动盘所在 APFS 容器里各卷的占用（GB），按角色（System、Preboot、Recovery、VM、Data）
    static func apfsVolumes() -> [String: Double] {
        guard let out = Shell.run("/usr/sbin/diskutil", ["apfs", "list", "-plist"], timeout: 10)?.out,
              let plist = try? PropertyListSerialization.propertyList(from: Data(out.utf8), format: nil) as? [String: Any],
              let containers = plist["Containers"] as? [[String: Any]] else { return [:] }
        for c in containers {
            let volumes = c["Volumes"] as? [[String: Any]] ?? []
            let roles = volumes.flatMap { $0["Roles"] as? [String] ?? [] }
            guard roles.contains("System"), roles.contains("Data") else { continue }
            var sizes: [String: Double] = [:]
            for v in volumes {
                guard let role = (v["Roles"] as? [String])?.first, let used = v["CapacityInUse"] as? Int else { continue }
                sizes[role, default: 0] += Double(used) / bytesPerGB
            }
            return sizes
        }
        return [:]
    }

    /// 交换文件占用（GB），来自 sysctl vm.swapusage
    static func swapUsed() -> Double {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return Double(usage.xsu_used) / bytesPerGB
    }

    /// 跑一个只读命令，返回标准输出；失败或超时（10 秒）返回 nil
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 10) -> String? {
        let p = Process()
        p.executableURL = URL(filePath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
