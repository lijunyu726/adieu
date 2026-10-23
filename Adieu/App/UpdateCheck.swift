import AppKit
import SwiftUI

/// 只问 GitHub 最新版本的安装包，不上传任何东西。示例模式不检查，免得截图时弹出。
enum UpdateCheck {
    static let bundleID = "com.ljy.adieu"

    struct Release: Sendable {
        let version: String
        let dmg: URL
    }

    enum Outcome: Sendable {
        case newer(Release)
        case current
        case failed
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func look() async -> Outcome {
        guard let url = URL(string: "https://api.github.com/repos/lijunyu726/adieu/releases/latest") else { return .failed }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Adieu", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return .failed }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard newer(version, than: currentVersion) else { return .current }
            guard let dmg = dmgURL(in: json, version: version) else { return .failed }
            return .newer(Release(version: version, dmg: dmg))
        } catch {
            return .failed
        }
    }

    /// 只收这个仓库 Releases 上的 Adieu-版本号.dmg
    private static func dmgURL(in json: [String: Any], version: String) -> URL? {
        guard let assets = json["assets"] as? [[String: Any]] else { return nil }
        let name = "Adieu-\(version).dmg"
        for asset in assets {
            guard asset["name"] as? String == name,
                  let text = asset["browser_download_url"] as? String,
                  let url = URL(string: text),
                  url.scheme == "https", url.host == "github.com",
                  url.path.hasPrefix("/lijunyu726/adieu/releases/download/") else { continue }
            return url
        }
        return nil
    }

    private static func newer(_ remote: String, than local: String) -> Bool {
        let a = parts(remote), b = parts(local)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func parts(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }
}

@MainActor
enum UpdatePrompt {
    private static var checking = false
    private static var installing = false
    private static var fetcher: DmgFetcher?
    /// 截图用：`-AdieuUpdatePreview YES` 只把进度条放出来，不下载、不替换
    private static var previewWindow: UpdateProgressWindow?

    /// 截图用。正常启动没有这个入口
    static func preview() {
        let model = UpdateProgressModel()
        model.title = String(localized: "正在下载…")
        model.determinate = true
        let window = UpdateProgressWindow(model: model)
        previewWindow = window
        window.show()
        Task {
            for percent in 1...80 {
                try? await Task.sleep(for: .milliseconds(40))
                model.fraction = Double(percent) / 100
            }
            model.canCancel = false
            model.title = String(localized: "正在换上…")
            for percent in 81...100 {
                try? await Task.sleep(for: .milliseconds(50))
                model.fraction = Double(percent) / 100
            }
        }
    }

    /// 打开后自己看一次。有新版本才问；没有、或连不上，不打扰
    static func automatic() async {
        guard !UserDefaults.standard.bool(forKey: "AdieuSample") else { return }
        guard case .newer(let release) = await UpdateCheck.look() else { return }
        ask(release)
    }

    /// 关于页里点的：有没有新版本都告诉你
    static func manual() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        switch await UpdateCheck.look() {
        case .newer(let release): ask(release)
        case .current: note(String(localized: "已经是最新的。"))
        case .failed: note(String(localized: "没连上 GitHub，过会儿再试。"))
        }
    }

    private static func ask(_ release: UpdateCheck.Release) {
        let alert = NSAlert()
        alert.messageText = String(localized: "有新版本 \(release.version)。现在更新吗？")
        alert.informativeText = String(localized: "会下载并换上，然后重新打开。")
        alert.addButton(withTitle: String(localized: "更新"))
        alert.addButton(withTitle: String(localized: "以后再说"))
        guard !installing, alert.runModal() == .alertFirstButtonReturn else { return }
        installing = true
        Task {
            await install(release)
            installing = false
        }
    }

    /// 下载占进度条的前 80%，换上当前应用占剩下的。总长度未知时先转圈，知道字节数后再按比例走
    private static func install(_ release: UpdateCheck.Release) async {
        let model = UpdateProgressModel()
        model.title = String(localized: "正在下载…")
        let window = UpdateProgressWindow(model: model)
        window.show()
        let (stream, continuation) = AsyncStream.makeStream(of: Double.self)
        let fetcher = DmgFetcher { continuation.yield($0) }
        self.fetcher = fetcher
        model.onCancel = { fetcher.cancel() }
        let watch = Task {
            for await fraction in stream {
                model.determinate = true
                let next = min(0.8, fraction * 0.8)
                if next > model.fraction { model.fraction = next }
            }
        }
        do {
            let dmg = try await fetcher.fetch(release.dmg)
            continuation.finish()
            model.canCancel = false
            model.determinate = true
            model.title = String(localized: "正在换上…")
            model.fraction = 0.86
            let staged = await blocking { () -> URL? in
                try? UpdateInstaller.stage(dmg, version: release.version)
            }
            guard let staged else { throw CocoaError(.fileReadUnknown) }
            model.fraction = 0.95
            try handoff(staged)
            model.fraction = 1
            NSApp.terminate(nil)
        } catch is CancellationError {
            continuation.finish()
            window.close()
        } catch {
            continuation.finish()
            window.close()
            note(String(localized: "没换上，过会儿再试。"))
        }
        watch.cancel()
        self.fetcher = nil
    }

    /// 等这个进程退出后，用临时副本换掉正在运行的 Adieu，再打开
    private static func handoff(_ staged: URL) throws {
        let dest = Bundle.main.bundleURL.path
        let parent = (dest as NSString).deletingLastPathComponent
        // 从安装盘里打开的不能换；所在文件夹也不能写的话，换到一半会把应用弄没
        guard !dest.hasPrefix("/Volumes/"), FileManager.default.isWritableFile(atPath: parent) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done
        next=\(shellQuote(dest + ".new"))
        old=\(shellQuote(dest + ".old"))
        src=\(shellQuote(staged.path))
        dest=\(shellQuote(dest))
        /bin/rm -rf "$next"
        if /usr/bin/ditto "$src" "$next"; then
          /bin/rm -rf "$old"
          if /bin/mv "$dest" "$old" && /bin/mv "$next" "$dest"; then
            /bin/rm -rf "$old"
            /usr/bin/xattr -cr "$dest"
            /usr/bin/touch "$dest"
            /usr/bin/open "$dest"
          else
            /bin/mv "$old" "$dest" 2>/dev/null
            /bin/rm -rf "$next"
            /usr/bin/open "$dest"
          fi
        else
          /bin/rm -rf "$next"
          /usr/bin/open "$dest"
        fi
        """
        let file = FileManager.default.temporaryDirectory.appending(path: "adieu-update.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = [file.path]
        try process.run()
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func note(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: String(localized: "好"))
        alert.runModal()
    }
}

/// 挂上安装包、核对是不是 Adieu 的这一版，再复制出来。放在后台线程，不占主线程。
private enum UpdateInstaller {
    static func stage(_ dmg: URL, version: String) throws -> URL {
        _ = command("/usr/bin/xattr", ["-d", "com.apple.quarantine", dmg.path])
        let (status, data) = command("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-plist", dmg.path])
        guard status == 0, let mount = mountPoint(data) else { throw CocoaError(.fileReadUnknown) }
        defer { _ = command("/usr/bin/hdiutil", ["detach", mount, "-quiet"]) }
        let app = URL(filePath: mount).appending(path: "Adieu.app")
        guard let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == UpdateCheck.bundleID,
              info["CFBundleShortVersionString"] as? String == version else { throw CocoaError(.fileReadCorruptFile) }
        let staged = FileManager.default.temporaryDirectory.appending(path: "Adieu-update.app")
        if FileManager.default.fileExists(atPath: staged.path) { try FileManager.default.removeItem(at: staged) }
        let copied = command("/usr/bin/ditto", [app.path, staged.path])
        guard copied.0 == 0 else { throw CocoaError(.fileWriteUnknown) }
        _ = command("/usr/bin/xattr", ["-cr", staged.path])
        return staged
    }

    private static func command(_ exe: String, _ args: [String]) -> (Int32, Data) {
        let process = Process()
        process.executableURL = URL(filePath: exe)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (1, Data()) }
        process.waitUntilExit()
        return (process.terminationStatus, out.fileHandleForReading.readDataToEndOfFile())
    }

    private static func mountPoint(_ data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        return entities.compactMap { $0["mount-point"] as? String }.first { !$0.isEmpty }
    }
}

private final class DmgFetcher: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private let onProgress: @Sendable (Double) -> Void
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var cancelled = false

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func fetch(_ url: URL) async throws -> URL {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 300
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            var request = URLRequest(url: url)
            request.setValue("Adieu", forHTTPHeaderField: "User-Agent")
            let task = session.downloadTask(with: request)
            lock.lock()
            self.task = task
            let alreadyCancelled = cancelled
            lock.unlock()
            if alreadyCancelled { task.cancel() } else { task.resume() }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            finish { $0.resume(throwing: URLError(.badServerResponse)) }
            return
        }
        let dest = FileManager.default.temporaryDirectory.appending(path: "Adieu-update.dmg")
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: location, to: dest)
            finish { $0.resume(returning: dest) }
        } catch {
            finish { $0.resume(throwing: error) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let cancelled = (error as? URLError)?.code == .cancelled
            finish { $0.resume(throwing: cancelled ? CancellationError() : error) }
        }
        session.finishTasksAndInvalidate()
    }

    private func finish(_ body: (CheckedContinuation<URL, Error>) -> Void) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        if let continuation { body(continuation) }
    }
}

@MainActor
@Observable
private final class UpdateProgressModel {
    var title = ""
    var fraction = 0.0
    var determinate = false
    var canCancel = true
    var onCancel: () -> Void = {}
}

private struct UpdateProgressView: View {
    @Bindable var model: UpdateProgressModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.title).font(.headline)
            Group {
                if model.determinate {
                    ProgressView(value: model.fraction)
                } else {
                    ProgressView()
                }
            }
            .tint(Theme.brand)
            HStack {
                Text(model.determinate ? "\(Int((model.fraction * 100).rounded()))%" : " ")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if model.canCancel {
                    Button(String(localized: "取消"), action: model.onCancel)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
        }
        .padding(22)
        .frame(width: 320)
    }
}

@MainActor
private final class UpdateProgressWindow {
    let model: UpdateProgressModel
    let window: NSWindow
    let host: NSHostingView<AnyView>

    init(model: UpdateProgressModel) {
        self.model = model
        host = NSHostingView(rootView: AnyView(UpdateProgressView(model: model).preferredColorScheme(.light)))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 148), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Adieu"
        window.contentView = host
        window.isReleasedWhenClosed = false
    }

    func show() {
        let size = host.fittingSize
        if size.width > 100, size.height > 40 { window.setContentSize(size) }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close() { window.close() }
}
