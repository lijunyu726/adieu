import Foundation

// adieu-mcp：标准 MCP（stdio，一行一条 JSON-RPC）。自己不碰文件，只把工具调用转给正在运行的 Adieu。
// 接入：claude mcp add adieu -- /Applications/Adieu.app/Contents/MacOS/adieu-mcp

let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
setvbuf(stdout, nil, _IOLBF, 0)

func send(_ object: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

func reply(_ id: Any, result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }
func fail(_ id: Any, code: Int, _ message: String) {
    send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

/// 本程序在 Adieu.app/Contents/MacOS 里，往上两层就是应用包
func appBundle() -> URL? {
    let exe = URL(filePath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return app.pathExtension == "app" ? app : nil
}

func connect() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let path = AgentCatalog.socketPath
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        let bytes = Array(path.utf8.prefix(buf.count - 1))
        buf.copyBytes(from: bytes + [0])
    }
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Foundation.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if ok == 0 { return fd }
    close(fd)
    return nil
}

/// 连不上就把 Adieu 在后台打开，等它把通道开起来（设置里没打开“允许 agent 连接”就一直连不上）
func connectOrLaunch() -> Int32? {
    if let fd = connect() { return fd }
    let open = Process()
    open.executableURL = URL(filePath: "/usr/bin/open")
    open.arguments = appBundle().map { ["-g", $0.path] } ?? ["-g", "-b", "com.ljy.adieu"]
    try? open.run()
    open.waitUntilExit()
    for _ in 0..<40 {
        usleep(250_000)
        if let fd = connect() { return fd }
    }
    return nil
}

/// 发一行请求，读一行回复。删除类要等用户在 Adieu 里点，可能等好几分钟
func call(_ name: String, _ arguments: [String: Any]) -> (text: String, isError: Bool) {
    guard let fd = connectOrLaunch() else {
        return ("Cannot reach Adieu. Open Adieu → Settings → General and turn on \"Allow agents to connect\" (允许 agent 连接), then try again.", true)
    }
    defer { close(fd) }
    guard var data = try? JSONSerialization.data(withJSONObject: ["name": name, "arguments": arguments]) else {
        return ("Bad arguments.", true)
    }
    data.append(0x0A)
    let sent = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    guard sent == data.count else { return ("Lost the connection to Adieu.", true) }
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 65_536)
    while !buffer.contains(0x0A) {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { break }
        buffer.append(contentsOf: chunk[0..<n])
    }
    guard let line = buffer.split(separator: 0x0A).first,
          let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
        return ("Adieu closed the connection without an answer.", true)
    }
    return ((object["text"] as? String) ?? "", (object["isError"] as? Bool) ?? false)
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty, let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
    let method = message["method"] as? String ?? ""
    // 没有 id 的是通知（如 notifications/initialized），不回
    guard let id = message["id"] else { continue }
    let params = message["params"] as? [String: Any] ?? [:]
    switch method {
    case "initialize":
        let asked = params["protocolVersion"] as? String
        let supported = ["2025-06-18", "2025-03-26", "2024-11-05"]
        reply(id, result: ["protocolVersion": asked.flatMap { supported.contains($0) ? $0 : nil } ?? supported[0],
                           "capabilities": ["tools": ["listChanged": false]],
                           "serverInfo": ["name": "adieu", "title": "Adieu", "version": version],
                           "instructions": AgentCatalog.instructions])
    case "ping":
        reply(id, result: [:])
    case "tools/list":
        reply(id, result: ["tools": AgentCatalog.listJSON()])
    case "tools/call":
        guard let name = params["name"] as? String, AgentCatalog.tools.contains(where: { $0.name == name }) else {
            fail(id, code: -32602, "Unknown tool")
            continue
        }
        let r = call(name, params["arguments"] as? [String: Any] ?? [:])
        reply(id, result: ["content": [["type": "text", "text": r.text]], "isError": r.isError])
    default:
        fail(id, code: -32601, "Method not found: \(method)")
    }
}
