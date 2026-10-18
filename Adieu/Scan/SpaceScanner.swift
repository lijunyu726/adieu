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
        return r
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
