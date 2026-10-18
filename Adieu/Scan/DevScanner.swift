import Foundation

/// 开发工具占用的空间。只统计和检测，清理由 DevRunner 按用户的点击执行。
/// 按一份常见开发工具的名单逐个检测，电脑上没有的不显示。
/// 只清“删了会自动重新下载或重新生成”的缓存；SDK、模型、工具链、归档这类是用户的东西，只显示大小不清理
enum DevScanner {
    static func scan() -> [DevTool] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func size(_ p: String) -> Double { AppScanner.allocatedSize(URL(filePath: p)) ?? 0 }
        func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }
        func short(_ p: String) -> String { p.replacing(home, with: "~") }
        var tools: [DevTool] = []

        /// 一组“可以直接删的缓存目录”：存在的才计入，删除就是删目录
        func caches(_ list: [(String, String)]) -> (parts: [DevPart], paths: [String]) {
            var parts: [DevPart] = [], paths: [String] = []
            for (label, p) in list where exists(p) {
                let s = size(p)
                guard s > 0 else { continue }
                parts.append(.init(label: label, size: s, reclaimable: s)); paths.append(p)
            }
            return (parts, paths)
        }
        /// 只显示大小、不清理的部分
        func kept(_ list: [(String, String)]) -> [DevPart] {
            list.filter { exists($0.1) }.map { .init(label: $0.0, size: size($0.1), reclaimable: 0) }.filter { $0.size > 0 }
        }

        // Docker：用它自己的 system df 统计；没运行时只能看虚拟磁盘大小
        let dockerData = "\(home)/Library/Containers/com.docker.docker"
        if let docker = Shell.which("docker") ?? (exists("/Applications/Docker.app/Contents/Resources/bin/docker") ? "/Applications/Docker.app/Contents/Resources/bin/docker" : nil) {
            let df = Shell.run(docker, ["system", "df", "--format", "{{json .}}"], timeout: 20)
            var parts: [DevPart] = []
            if let df, df.status == 0 {
                for line in df.out.split(separator: "\n") {
                    guard let data = line.data(using: .utf8),
                          let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    let type = row["Type"] as? String ?? ""
                    let total = parseSize(row["Size"] as? String ?? "")
                    let reclaim = parseSize(row["Reclaimable"] as? String ?? "")
                    let count = row["TotalCount"].map { "\($0)" } ?? ""
                    let label = ["Images": "镜像 \(count) 个", "Containers": "容器 \(count) 个", "Local Volumes": "数据卷 \(count) 个", "Build Cache": "构建缓存"][type] ?? type
                    // 数据卷可能有数据库，永远不清理
                    parts.append(DevPart(label: label, size: total, reclaimable: type == "Local Volumes" ? 0 : reclaim))
                }
                tools.append(DevTool(id: "docker", name: "Docker", location: "~/Library/Containers/com.docker.docker",
                                     note: "只清理没被任何容器使用的镜像、构建缓存和已停止的容器；数据卷里可能有数据库，永远不自动清。",
                                     parts: parts, commands: [], never: "docker volume prune（会删除数据卷）",
                                     actions: [.command(executable: docker, args: ["image", "prune", "-a", "-f"]),
                                               .command(executable: docker, args: ["builder", "prune", "-f"]),
                                               .command(executable: docker, args: ["container", "prune", "-f"])]))
            } else if exists(dockerData) {
                tools.append(DevTool(id: "docker", name: "Docker", location: "~/Library/Containers/com.docker.docker",
                                     note: "Docker 没有运行，看不到镜像和缓存里哪些能回收。打开 Docker Desktop 后点“重新统计”。",
                                     parts: [.init(label: "虚拟磁盘（含镜像、容器、数据卷）", size: size(dockerData), reclaimable: 0)],
                                     commands: [], never: "docker volume prune（会删除数据卷）", blocked: "Docker 没有运行"))
            }
        }

        // Homebrew：下载缓存和旧版本
        if let brew = Shell.which("brew") {
            let cache = Shell.run(brew, ["--cache"], timeout: 20)?.out.trimmingCharacters(in: .whitespacesAndNewlines) ?? "\(home)/Library/Caches/Homebrew"
            let prefix = Shell.run(brew, ["--prefix"], timeout: 20)?.out.trimmingCharacters(in: .whitespacesAndNewlines) ?? "/opt/homebrew"
            let cacheSize = size(cache)
            let dry = Shell.run(brew, ["cleanup", "-s", "-n"], timeout: 120)
            // 干跑没有“approximately …”这一行，说明已经没有可清的；只有干跑本身失败时才拿缓存目录大小估算。
            // 缓存目录里还有 Homebrew 自己的索引（api、bootsnap），清完也会留着，不能算可回收
            let freeable = dry.map { parseBrewFree($0.out + $0.err) ?? 0 } ?? cacheSize
            let cellar = size("\(prefix)/Cellar") + size("\(prefix)/Caskroom")
            tools.append(DevTool(id: "brew", name: "Homebrew", location: "\(prefix) · ~/Library/Caches/Homebrew",
                                 note: "下载缓存和旧版本可以放心清，装好的工具不受影响。",
                                 parts: [.init(label: "下载缓存与旧版本", size: freeable, reclaimable: freeable),
                                         .init(label: "已安装的包", size: cellar, reclaimable: 0)],
                                 commands: [], never: nil,
                                 actions: [.command(executable: brew, args: ["cleanup", "-s"]), .command(executable: brew, args: ["autoremove"])]))
        }

        // npm / pnpm / bun：都是下载缓存
        var nodeParts: [DevPart] = [], nodeActions: [DevAction] = [], nodeLoc: [String] = []
        if exists("\(home)/.npm/_cacache") {
            let s = size("\(home)/.npm/_cacache")
            nodeParts.append(.init(label: "npm 缓存", size: s, reclaimable: s)); nodeLoc.append("~/.npm")
            if let npm = Shell.which("npm") { nodeActions.append(.command(executable: npm, args: ["cache", "clean", "--force"])) }
            else { nodeActions.append(.trash(paths: ["\(home)/.npm/_cacache"])) }
        }
        let pnpmStore = "\(home)/Library/pnpm/store"
        if exists(pnpmStore) {
            let s = size(pnpmStore)
            nodeParts.append(.init(label: "pnpm 存储（未被项目引用的部分可回收）", size: s, reclaimable: 0)); nodeLoc.append("~/Library/pnpm/store")
            if let pnpm = Shell.which("pnpm") { nodeActions.append(.command(executable: pnpm, args: ["store", "prune"])) }
        }
        if exists("\(home)/.bun/install/cache") {
            let s = size("\(home)/.bun/install/cache")
            nodeParts.append(.init(label: "bun 缓存", size: s, reclaimable: s)); nodeLoc.append("~/.bun/install/cache")
            // 不用 bun pm cache rm：它要求当前目录有 package.json，从 Adieu 里运行会失败、什么也没删
            nodeActions.append(.trash(paths: ["\(home)/.bun/install/cache"]))
        }
        let nodeMore = caches([("yarn 缓存", "\(home)/Library/Caches/Yarn"), ("node-gyp 头文件", "\(home)/Library/Caches/node-gyp")])
        if !nodeMore.paths.isEmpty {
            nodeParts += nodeMore.parts; nodeLoc += nodeMore.paths.map(short)
            nodeActions.append(.trash(paths: nodeMore.paths))
        }
        if !nodeParts.isEmpty {
            tools.append(DevTool(id: "node", name: "Node.js", location: nodeLoc.joined(separator: " · "),
                                 note: "都是下载缓存，下次安装依赖时会重新下载。pnpm 只清掉没有项目在用的包。",
                                 parts: nodeParts, commands: [], never: nil, actions: nodeActions))
        }

        // VS Code：同一扩展的旧版本、扩展安装包缓存
        let extDir = "\(home)/.vscode/extensions"
        let vsix = "\(home)/Library/Application Support/Code/CachedExtensionVSIXs"
        if exists(extDir) || exists(vsix) {
            let old = oldVSCodeExtensions(extDir)
            let oldSize = old.map(size).reduce(0, +)
            let vsixSize = exists(vsix) ? size(vsix) : 0
            let all = exists(extDir) ? size(extDir) : 0
            var actions: [DevAction] = []
            if !old.isEmpty { actions.append(.trash(paths: old)) }
            if vsixSize > 0 { actions.append(.trash(paths: [vsix])) }
            tools.append(DevTool(id: "vscode", name: "VS Code", location: "~/.vscode · ~/Library/Application Support/Code",
                                 note: old.isEmpty ? "扩展都是最新的一份。扩展安装包缓存可以清。" : "有 \(old.count) 个扩展存了旧版本，正在用的是最新的那个。",
                                 parts: [.init(label: "旧版扩展 \(old.count) 个", size: oldSize, reclaimable: oldSize),
                                         .init(label: "扩展安装包缓存", size: vsixSize, reclaimable: vsixSize),
                                         .init(label: "正在使用的扩展", size: max(0, all - oldSize), reclaimable: 0)],
                                 commands: [], never: nil, actions: actions))
        }

        // Cursor、Windsurf：和 VS Code 同一套扩展目录结构
        for (id, name, dot, support) in [("cursor", "Cursor", ".cursor", "Cursor"), ("windsurf", "Windsurf", ".windsurf", "Windsurf")] {
            let dir = "\(home)/\(dot)/extensions", cache = "\(home)/Library/Application Support/\(support)/CachedExtensionVSIXs"
            guard exists(dir) else { continue }
            let old = oldVSCodeExtensions(dir)
            let oldSize = old.map(size).reduce(0, +)
            let cacheSize = exists(cache) ? size(cache) : 0
            var actions: [DevAction] = []
            if !old.isEmpty { actions.append(.trash(paths: old)) }
            if cacheSize > 0 { actions.append(.trash(paths: [cache])) }
            tools.append(DevTool(id: id, name: name, location: "~/\(dot) · ~/Library/Application Support/\(support)",
                                 note: old.isEmpty ? "扩展都是最新的一份。" : "有 \(old.count) 个扩展存了旧版本，正在用的是最新的那个。",
                                 parts: [.init(label: "旧版扩展 \(old.count) 个", size: oldSize, reclaimable: oldSize),
                                         .init(label: "扩展安装包缓存", size: cacheSize, reclaimable: cacheSize),
                                         .init(label: "正在使用的扩展", size: max(0, size(dir) - oldSize), reclaimable: 0)],
                                 commands: [], never: nil, actions: actions))
        }

        // Python
        var pyParts: [DevPart] = [], pyActions: [DevAction] = [], pyLoc: [String] = []
        let uvCache = Shell.which("uv").flatMap { Shell.run($0, ["cache", "dir"], timeout: 10)?.out.trimmingCharacters(in: .whitespacesAndNewlines) } ?? "\(home)/.cache/uv"
        if exists(uvCache) {
            let s = size(uvCache)
            pyParts.append(.init(label: "uv 缓存", size: s, reclaimable: s)); pyLoc.append("~/.cache/uv")
            pyActions.append(Shell.which("uv").map { .command(executable: $0, args: ["cache", "clean"]) } ?? .trash(paths: [uvCache]))
        }
        let pipCache = "\(home)/Library/Caches/pip"
        if exists(pipCache) {
            let s = size(pipCache)
            pyParts.append(.init(label: "pip 缓存", size: s, reclaimable: s)); pyLoc.append("~/Library/Caches/pip")
            pyActions.append(Shell.which("pip3").map { .command(executable: $0, args: ["cache", "purge"]) } ?? .trash(paths: [pipCache]))
        }
        if exists("\(home)/.local/pipx") {
            pyParts.append(.init(label: "pipx 工具环境", size: size("\(home)/.local/pipx"), reclaimable: 0)); pyLoc.append("~/.local/pipx")
        }
        if !pyParts.isEmpty {
            tools.append(DevTool(id: "python", name: "Python", location: pyLoc.joined(separator: " · "),
                                 note: "uv 和 pip 的缓存可以清。pipx 里装的命令行工具是你在用的，不动。",
                                 parts: pyParts, commands: [], never: nil, actions: pyActions))
        }

        // Go
        let goMod = Shell.which("go").flatMap { Shell.run($0, ["env", "GOMODCACHE"], timeout: 10)?.out.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/go/pkg/mod"
        let goBuild = "\(home)/Library/Caches/go-build"
        if exists(goMod) || exists(goBuild) {
            var parts: [DevPart] = [], actions: [DevAction] = []
            let go = Shell.which("go")
            if exists(goMod) {
                let s = size(goMod)
                parts.append(.init(label: "模块缓存", size: s, reclaimable: s))
                actions.append(go.map { .command(executable: $0, args: ["clean", "-modcache"]) } ?? .trash(paths: [goMod]))
            }
            if exists(goBuild) {
                let s = size(goBuild)
                parts.append(.init(label: "编译缓存", size: s, reclaimable: s))
                actions.append(go.map { .command(executable: $0, args: ["clean", "-cache"]) } ?? .trash(paths: [goBuild]))
            }
            tools.append(DevTool(id: "go", name: "Go", location: [goMod, goBuild].filter(exists).map(short).joined(separator: " · "),
                                 note: "模块下载缓存和编译缓存，下次编译时会重新生成。",
                                 parts: parts, commands: [], never: nil, actions: actions))
        }

        // Maven / Gradle：没有通用的清理命令，直接删除缓存目录
        var jvmParts: [DevPart] = [], jvmPaths: [String] = []
        for (label, p) in [("Gradle 缓存", "\(home)/.gradle/caches"), ("Gradle 各版本发行包", "\(home)/.gradle/wrapper/dists"),
                           ("Maven 仓库", "\(home)/.m2/repository")] where exists(p) {
            let s = size(p)
            jvmParts.append(.init(label: label, size: s, reclaimable: s)); jvmPaths.append(p)
        }
        if !jvmParts.isEmpty {
            tools.append(DevTool(id: "jvm", name: "Maven / Gradle", location: "~/.m2 · ~/.gradle",
                                 note: "依赖缓存，下次构建时会重新下载。Gradle 和 Maven 都没有通用的清理命令，所以直接删除缓存目录。",
                                 parts: jvmParts, commands: [], never: nil, actions: [.trash(paths: jvmPaths)]))
        }

        // Xcode：编译中间产物、真机调试符号、模拟器缓存都会自动重新生成；归档里有上架用的符号文件，不清
        let dev = "\(home)/Library/Developer"
        if exists("\(dev)/Xcode") || exists("\(dev)/CoreSimulator") {
            let c = caches([("编译中间产物（DerivedData）", "\(dev)/Xcode/DerivedData"),
                            ("iOS 真机调试符号", "\(dev)/Xcode/iOS DeviceSupport"),
                            ("watchOS 真机调试符号", "\(dev)/Xcode/watchOS DeviceSupport"),
                            ("macOS 真机调试符号", "\(dev)/Xcode/macOS DeviceSupport"),
                            ("模拟器缓存", "\(dev)/CoreSimulator/Caches"),
                            ("Swift 包缓存", "\(home)/Library/Caches/org.swift.swiftpm"),
                            ("CocoaPods 缓存", "\(home)/Library/Caches/CocoaPods")])
            var actions: [DevAction] = c.paths.isEmpty ? [] : [.trash(paths: c.paths)]
            if let xcrun = Shell.which("xcrun"), exists("\(dev)/CoreSimulator/Devices") {
                // 系统版本已经卸掉、再也打不开的模拟器
                actions.append(.command(executable: xcrun, args: ["simctl", "delete", "unavailable"]))
            }
            let parts = c.parts + kept([("归档（上架用，不清）", "\(dev)/Xcode/Archives"), ("模拟器（不清）", "\(dev)/CoreSimulator/Devices")])
            if !parts.isEmpty {
                tools.append(DevTool(id: "xcode", name: "Xcode", location: "~/Library/Developer",
                                     note: "编译中间产物、调试符号和缓存删了会自动重新生成，第一次编译或连真机会慢一些。打不开的旧模拟器会一起删掉；归档和还能用的模拟器不动。",
                                     parts: parts, commands: [], never: "删除 Archives（里面有上架和崩溃分析要用的符号文件）", actions: actions))
            }
        }

        // Rust：下载的源码包可以删；工具链是装好的编译器，不动
        let cargo = "\(home)/.cargo"
        if exists(cargo) {
            let c = caches([("下载的包", "\(cargo)/registry/cache"), ("解压的源码", "\(cargo)/registry/src"), ("Git 依赖", "\(cargo)/git/checkouts")])
            let parts = c.parts + kept([("工具链（不清）", "\(home)/.rustup/toolchains")])
            if !parts.isEmpty {
                tools.append(DevTool(id: "rust", name: "Rust", location: "~/.cargo · ~/.rustup",
                                     note: "Cargo 下载的依赖，下次编译时会重新下载。各项目里的 target 文件夹不在这里统计。",
                                     parts: parts, commands: [], never: nil, actions: c.paths.isEmpty ? [] : [.trash(paths: c.paths)]))
            }
        }

        // Flutter / Dart：hosted 和 git 是下载的包；global_packages 是全局装的命令，不动
        let pub = "\(home)/.pub-cache"
        if exists(pub) {
            let c = caches([("下载的包", "\(pub)/hosted"), ("Git 依赖", "\(pub)/git")])
            if !c.parts.isEmpty {
                tools.append(DevTool(id: "dart", name: "Flutter / Dart", location: "~/.pub-cache",
                                     note: "下载的依赖，下次 flutter pub get 时会重新下载。全局安装的命令不动。",
                                     parts: c.parts, commands: [], never: nil, actions: [.trash(paths: c.paths)]))
            }
        }

        // Conda：有 conda 命令才清（conda clean 会处理好硬链接），否则只显示
        let condaRoots = ["miniconda3", "anaconda3", "miniforge3", "mambaforge", "opt/miniconda3", "opt/anaconda3"].map { "\(home)/\($0)" }
            + ["/opt/homebrew/Caskroom/miniconda/base", "/opt/homebrew/Caskroom/miniforge/base"]
        if let root = condaRoots.first(where: { exists("\($0)/pkgs") }) {
            let s = size("\(root)/pkgs")
            let conda = Shell.which("conda") ?? (exists("\(root)/bin/conda") ? "\(root)/bin/conda" : nil)
            tools.append(DevTool(id: "conda", name: "Conda", location: short(root) + "/pkgs",
                                 note: "下载过的安装包。conda clean 只删没有环境在用的，环境本身不受影响。",
                                 parts: [.init(label: "安装包缓存", size: s, reclaimable: conda == nil ? 0 : s)],
                                 commands: [], never: "删除 envs 里的环境",
                                 actions: conda.map { [.command(executable: $0, args: ["clean", "--all", "-y"])] } ?? []))
        }

        // 浏览器自动化与 Electron：下载的浏览器内核和 Electron 安装包
        let web = caches([("Playwright 浏览器", "\(home)/Library/Caches/ms-playwright"),
                          ("Puppeteer 浏览器", "\(home)/.cache/puppeteer"),
                          ("Cypress", "\(home)/Library/Caches/Cypress"),
                          ("Electron 安装包", "\(home)/Library/Caches/electron")])
        if !web.parts.isEmpty {
            tools.append(DevTool(id: "webtest", name: "浏览器自动化与 Electron", location: web.paths.map(short).joined(separator: " · "),
                                 note: "测试用的浏览器内核和 Electron 下载包。删了以后，下次跑测试或打包时会重新下载（几百 MB）。",
                                 parts: web.parts, commands: [], never: nil, actions: [.trash(paths: web.paths)]))
        }

        // JetBrains：索引和缓存，IDE 下次打开会重建
        let jb = caches([("索引与缓存", "\(home)/Library/Caches/JetBrains")])
        if !jb.parts.isEmpty {
            tools.append(DevTool(id: "jetbrains", name: "JetBrains IDE", location: "~/Library/Caches/JetBrains",
                                 note: "IDE 的索引和缓存，下次打开项目会重新建索引（会慢一会儿）。最好先关掉 IDE 再清。",
                                 parts: jb.parts, commands: [], never: nil, actions: [.trash(paths: jb.paths)]))
        }

        // 其他语言的包缓存
        let other = caches([("Deno", "\(home)/Library/Caches/deno"), ("Composer（PHP）", "\(home)/Library/Caches/composer"),
                            ("Composer（PHP）", "\(home)/.composer/cache")])
        if !other.parts.isEmpty {
            tools.append(DevTool(id: "otherpkg", name: "Deno / Composer", location: other.paths.map(short).joined(separator: " · "),
                                 note: "下载的依赖，下次安装时会重新下载。", parts: other.parts, commands: [], never: nil, actions: [.trash(paths: other.paths)]))
        }

        // 只显示不清理：SDK 和 AI 模型是你下载来用的，删了要重新下几 GB
        let big = kept([("Android SDK", "\(home)/Library/Android/sdk"), ("Android 模拟器", "\(home)/.android/avd"),
                        ("Hugging Face 模型", "\(home)/.cache/huggingface"), ("Ollama 模型", "\(home)/.ollama/models"),
                        ("LM Studio 模型", "\(home)/.lmstudio/models")])
        if !big.isEmpty {
            tools.append(DevTool(id: "sdk", name: "SDK 与 AI 模型", location: "~/Library/Android · ~/.cache/huggingface · ~/.ollama",
                                 note: "这些是你下载来用的 SDK 和模型，Adieu 不清理。不用了的话在对应工具里删（如 Android Studio 的 SDK Manager、ollama rm）。",
                                 parts: big, commands: [], never: "自动删除 SDK 或模型"))
        }
        return tools.sorted { $0.reclaimable > $1.reclaimable }
    }

    /// “58.27GB”“14.18GB (24%)”“512MB”“0B” → GB
    static func parseSize(_ s: String) -> Double {
        let token = s.split(separator: " ").first.map(String.init) ?? ""
        let units: [(String, Double)] = [("TB", 1000), ("GB", 1), ("MB", 1.0 / 1000), ("kB", 1.0 / 1_000_000), ("KB", 1.0 / 1_000_000), ("B", 1.0 / 1_000_000_000)]
        for (u, f) in units where token.hasSuffix(u) {
            return (Double(token.dropLast(u.count)) ?? 0) * f * 1e9 / bytesPerGB
        }
        return 0
    }

    /// brew cleanup -n 最后一行：“This operation would free approximately 1.2GB of disk space.”
    static func parseBrewFree(_ s: String) -> Double? {
        guard let r = s.range(of: #"approximately ([\d.]+)([KMGT]?B)"#, options: .regularExpression) else { return nil }
        let m = String(s[r]).replacing("approximately ", with: "")
        return parseSize(m)
    }

    /// 同一个扩展（发布者.名字）只保留 extensions.json 里登记的那份，其余是旧版本
    static func oldVSCodeExtensions(_ dir: String) -> [String] {
        var current: Set<String> = []
        if let data = FileManager.default.contents(atPath: dir + "/extensions.json"),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for e in list { if let rel = e["relativeLocation"] as? String { current.insert(rel) } }
        }
        guard !current.isEmpty else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let currentIDs = Set(current.compactMap(extensionID))
        return names.filter { n in
            guard let id = extensionID(n), !current.contains(n) else { return false }
            return currentIDs.contains(id)
        }.map { dir + "/" + $0 }
    }

    /// “openai.chatgpt-1.2.3-darwin-arm64” → “openai.chatgpt”
    static func extensionID(_ folder: String) -> String? {
        guard let r = folder.range(of: #"-\d+\.\d+"#, options: .regularExpression) else { return nil }
        return String(folder[..<r.lowerBound]).lowercased()
    }
}
