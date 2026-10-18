import Foundation

/// 启动盘的容量。GB 按 1000³ 字节计，和系统设置显示的一致
struct DiskInfo: Sendable {
    let name: String
    let total: Double
    /// 用的是“重要用途可用容量”，含可清除空间，和访达显示的“可用”一致
    let free: Double
    var used: Double { total - free }

    static let sample = DiskInfo(name: "Macintosh HD", total: Sample.diskTotal, free: Sample.diskFree)

    static func current() -> DiskInfo? {
        let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? URL(filePath: "/").resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity,
              let free = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return DiskInfo(name: v.volumeLocalizedName ?? "Macintosh HD", total: Double(total) / bytesPerGB, free: Double(free) / bytesPerGB)
    }
}

/// 和访达、系统设置一致：1 GB = 1000³ 字节
let bytesPerGB = 1_000_000_000.0
