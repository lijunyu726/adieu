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
        r.snapshots = (run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]) ?? "")
            .split(separator: "\n").filter { $0.contains("com.apple") }.count
        systemParts(into: &r)
        return r
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
