import Foundation

/// 调试用：启动参数 `-AdieuHangLog YES` 时，后台每 20 毫秒往主线程投一个空任务，
/// 主线程超过 100 毫秒才接住，就把那一下停了多久写到标准错误。用来验证扫描、删除时界面没有停住
enum HangLog {
    static let on = UserDefaults.standard.bool(forKey: "AdieuHangLog")
    private static let queue = DispatchQueue(label: "com.ljy.adieu.hanglog")
    private static let launch = DispatchTime.now()

    static func start() {
        guard on else { return }
        _ = launch
        queue.async(execute: ping)
    }

    /// 记一个时间点（如“扫描完成”），和停顿放在同一条时间线上
    static func mark(_ what: String) {
        guard on else { return }
        write("\(elapsed(DispatchTime.now())) \(what)")
    }

    private static func ping() {
        let sent = DispatchTime.now()
        DispatchQueue.main.async {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - sent.uptimeNanoseconds) / 1_000_000
            if ms > 100 { write("\(elapsed(sent)) 主线程停了 \(Int(ms)) ms") }
            queue.asyncAfter(deadline: .now() + .milliseconds(20), execute: ping)
        }
    }

    private static func elapsed(_ t: DispatchTime) -> String {
        // 两个都是无符号数，先转 Double 再相减，t 早于 launch 也不会溢出
        String(format: "%6.2fs", (Double(t.uptimeNanoseconds) - Double(launch.uptimeNanoseconds)) / 1_000_000_000)
    }

    private static func write(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
