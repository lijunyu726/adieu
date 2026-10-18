import Foundation

/// 调用命令行工具。从访达打开的应用 PATH 很短，所以先从登录 shell 取一次用户的 PATH
enum Shell {
    static let userPATH: String = {
        let fallback = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let out = SpaceScanner.run(shell, ["-ilc", "printf '__PATH__%s' \"$PATH\""], timeout: 8),
              let r = out.range(of: "__PATH__") else { return fallback }
        let path = String(out[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? fallback : path + ":" + fallback
    }()

    /// 在用户 PATH 里找命令，找不到返回 nil
    static func which(_ name: String) -> String? {
        for dir in userPATH.split(separator: ":") {
            let p = (String(dir) as NSString).expandingTildeInPath + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    struct Output: Sendable {
        let status: Int32
        let out: String
        let err: String
    }

    /// 运行命令并等它结束；超时返回 nil
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 600) -> Output? {
        let p = Process()
        p.executableURL = URL(filePath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = userPATH
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        // 边读边存，避免输出太多把管道塞满
        nonisolated(unsafe) var outData = Data(), errData = Data()
        let lock = NSLock()
        out.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; lock.withLock { outData.append(d) } }
        err.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; lock.withLock { errData.append(d) } }
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return nil }
        usleep(50_000)
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        return lock.withLock {
            Output(status: p.terminationStatus, out: String(decoding: outData, as: UTF8.self), err: String(decoding: errData, as: UTF8.self))
        }
    }
}
