import Foundation

/// 给 adieu-mcp 用的本机通道：~/Library/Application Support/Adieu/agent.sock。
/// 文件权限 0600，连进来的还要核对是同一个用户（getpeereid）。一条连接一个请求：读一行 JSON，回一行 JSON
final class AgentServer: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: Int32 = -1
    private let handler: @Sendable (Data) async -> Data

    init(handler: @escaping @Sendable (Data) async -> Data) {
        self.handler = handler
    }

    var isRunning: Bool { lock.withLock { listener >= 0 } }

    func start() throws {
        guard !isRunning else { return }
        let path = AgentCatalog.socketPath
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        // 先收紧权限再建文件：建出来就是只有自己能读写
        let old = umask(0o177)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(old)
        guard bound == 0, listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        chmod(path, 0o600)
        lock.withLock { listener = fd }
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "Adieu agent server"
        thread.start()
    }

    func stop() {
        let fd = lock.withLock { () -> Int32 in
            let fd = listener
            listener = -1
            return fd
        }
        guard fd >= 0 else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(AgentCatalog.socketPath)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                close(client)
                continue
            }
            let handler = handler
            Thread.detachNewThread {
                guard let request = Self.readLine(client) else { close(client); return }
                let done = DispatchSemaphore(value: 0)
                let box = ReplyBox()
                Task {
                    box.data = await handler(request)
                    done.signal()
                }
                done.wait()
                var reply = box.data
                reply.append(0x0A)
                reply.withUnsafeBytes { buf in
                    var sent = 0
                    while sent < buf.count {
                        let n = write(client, buf.baseAddress! + sent, buf.count - sent)
                        if n <= 0 { break }
                        sent += n
                    }
                }
                close(client)
            }
        }
    }

    /// 读到换行为止，最多 4 MB
    private static func readLine(_ fd: Int32) -> Data? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while data.count < 4 << 20 {
            if let i = data.firstIndex(of: 0x0A) { return data[..<i] }
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return data.isEmpty ? nil : data }
            data.append(contentsOf: chunk[0..<n])
        }
        return nil
    }
}

private final class ReplyBox: @unchecked Sendable {
    var data = Data()
}
