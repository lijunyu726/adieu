import SwiftUI

/// 界面阶段使用的示例数据。数字来自 2026-10 对开发者本机的实测；
/// 接入真实扫描后，这个文件只用于 SwiftUI 预览。
enum Sample {
    static let diskTotal = 460.4
    static let diskUsed = 436.3
    static var diskFree: Double { diskTotal - diskUsed }

    // MARK: 空间分布（首页长条图）
    static let categories: [SpaceCategory] = [
        .init(id: "appdata", label: "应用数据", size: 162.5, color: .purple,
              hint: "系统设置会把它们算进“系统数据”。Docker 一个就占了 70 GB。",
              parts: [.init(label: "Docker", size: 70.4, note: "其中约 14 GB 是没在用的镜像"),
                      .init(label: "微信", size: 22.8, note: "聊天记录与收到的文件"),
                      .init(label: "其他应用", size: 69.3)],
              link: .apps),
        .init(id: "other", label: "隐藏文件与开发缓存", size: 81.8, color: .gray, hint: "主要是各种开发工具的缓存和环境。", link: .devTools),
        .init(id: "mine", label: "你的文件", size: 69.0, color: .orange, hint: "你自己放进来的文件。",
              parts: [.init(label: "文稿", size: 33.7), .init(label: "下载", size: 24.4), .init(label: "影片和桌面", size: 10.9)],
              link: .bigFiles),
        .init(id: "apps", label: "应用程序", size: 65.0, color: .blue, hint: "应用本身。看看哪些很久没用了。", link: .apps),
        .init(id: "system", label: "macOS 系统", size: 42.0, color: Color(white: 0.42), hint: "约 42 GB，属于正常范围。它由这几部分组成：",
              parts: [.init(label: "系统卷", size: 13.1, note: "只读且有签名保护，不能也不需要清理"),
                      .init(label: "启动与更新暂存", size: 21.2, note: "含一个已下载的 macOS 27.0.1 更新，装好重启后回收一部分"),
                      .init(label: "交换与休眠文件", size: 4.0, note: "内存不够时临时写到磁盘，重启后会减少"),
                      .init(label: "恢复分区", size: 3.7, note: "用于重装和修复系统，请保留"),
                      .init(label: "本地快照 3 个", size: nil, note: "系统更新创建的，系统会自动清理，不要手动删")]),
        .init(id: "brew", label: "Homebrew", size: 16.0, color: .teal, hint: "旧版本和下载缓存可以清理。", link: .devTools),
        .init(id: "free", label: "可用", size: 24.1, color: Color.primary.opacity(0.2), hint: "建议至少保留 46 GB（10%）。")
    ]

    // MARK: 应用
    static let apps: [AppItem] = [
        AppItem(id: "docker", name: "Docker", monogram: "D", color: Color(red: 0.11, green: 0.39, blue: 0.93),
                meta: "版本 4.89.0 · com.docker.docker", isRunning: true,
                notice: "Docker 正在运行，卸载前会先将它退出。两个后台服务位于系统目录，移除时需要输入管理员密码。",
                parts: [
                    .init(id: "a", kind: .app, label: "Docker.app", path: "/Applications/Docker.app", size: 2.1, evidence: .bundle, defaultOn: true),
                    .init(id: "c", kind: .data, label: "容器数据（含虚拟磁盘）", path: "~/Library/Containers/com.docker.docker", size: 70.4, evidence: .exact, defaultOn: true),
                    .init(id: "i", kind: .data, label: "安装残留", path: "~/Library/Application Support/com.docker.install", size: 2.2, evidence: .exact, defaultOn: true),
                    .init(id: "g", kind: .data, label: "共享容器", path: "~/Library/Group Containers/group.com.docker", size: nil, evidence: .exact, defaultOn: true),
                    .init(id: "d", kind: .background, label: "后台服务 vmnetd、socket", path: "/Library/LaunchDaemons/com.docker.*.plist", size: nil, evidence: .exact, defaultOn: true)
                ]),
        AppItem(id: "wechat", name: "微信", monogram: "微", color: Color(red: 0.03, green: 0.76, blue: 0.38),
                meta: "版本 4.1.15 · com.tencent.xinWeChat",
                notice: "应用数据里有聊天记录和收到的文件，默认不勾选。确认已备份后再选中，删除后无法从微信找回。",
                parts: [
                    .init(id: "a", kind: .app, label: "WeChat.app", path: "/Applications/WeChat.app", size: 1.4, evidence: .bundle, defaultOn: true),
                    .init(id: "c", kind: .data, label: "聊天记录与文件", path: "~/Library/Containers/com.tencent.xinWeChat", size: 22.8, evidence: .exact, defaultOn: false),
                    .init(id: "g", kind: .data, label: "共享容器", path: "~/Library/Group Containers/5A4RE8SF68.com.tencent.xinWeChat", size: nil, evidence: .team, defaultOn: true)
                ]),
        AppItem(id: "ps", name: "Adobe Photoshop 2026", monogram: "Ps", color: Color(red: 0.12, green: 0.37, blue: 0.66),
                meta: "com.adobe.Photoshop",
                notice: "建议优先用 Creative Cloud 卸载。Adobe 的共享组件其他 Adobe 应用也在用，默认不勾选。",
                parts: [
                    .init(id: "a", kind: .app, label: "Adobe Photoshop 2026", path: "/Applications/Adobe Photoshop 2026", size: 6.0, evidence: .bundle, defaultOn: true),
                    .init(id: "u", kind: .data, label: "偏好与插件数据", path: "~/Library/Application Support/Adobe/Adobe Photoshop 2026", size: 4.1, evidence: .name, defaultOn: true),
                    .init(id: "s", kind: .shared, label: "Adobe 共享组件", path: "/Library/Application Support/Adobe", size: 8.2, evidence: .shared, defaultOn: false)
                ]),
        AppItem(id: "quark", name: "夸克", monogram: "夸", color: Color(red: 0.3, green: 0.43, blue: 0.96),
                meta: "数据 5.2 GB，其中统计数据库 3.3 GB",
                parts: [
                    .init(id: "a", kind: .app, label: "Quark.app", path: "/Applications/Quark.app", size: 1.8, evidence: .bundle, defaultOn: true),
                    .init(id: "u", kind: .data, label: "应用数据", path: "~/Library/Application Support/Quark", size: 5.2, evidence: .name, defaultOn: true)
                ]),
        AppItem(id: "qq", name: "QQ", monogram: "Q", color: Color(red: 0.07, green: 0.72, blue: 0.96),
                meta: "com.tencent.qq",
                notice: "腾讯的共享容器可能被同一开发者的其他应用使用，默认不勾选。",
                parts: [
                    .init(id: "a", kind: .app, label: "QQ.app", path: "/Applications/QQ.app", size: 1.1, evidence: .bundle, defaultOn: true),
                    .init(id: "c", kind: .data, label: "聊天记录与文件", path: "~/Library/Containers/com.tencent.qq", size: 4.7, evidence: .exact, defaultOn: false),
                    .init(id: "g", kind: .shared, label: "腾讯共享容器", path: "~/Library/Group Containers/FN2V63AD2J.com.tencent", size: 0.81, evidence: .team, defaultOn: false)
                ]),
        AppItem(id: "soda", name: "汽水音乐", monogram: "汽", color: Color(white: 0.1),
                meta: "com.soda.music",
                parts: [
                    .init(id: "a", kind: .app, label: "汽水音乐.app", path: "/Applications/汽水音乐.app", size: 0.3, evidence: .bundle, defaultOn: true),
                    .init(id: "c", kind: .data, label: "离线歌曲与缓存", path: "~/Library/Containers/com.soda.music", size: 5.1, evidence: .exact, defaultOn: true)
                ]),
        AppItem(id: "as", name: "Android Studio", monogram: "A", color: Color(red: 0.24, green: 0.86, blue: 0.52),
                meta: "com.google.android.studio",
                parts: [
                    .init(id: "a", kind: .app, label: "Android Studio.app", path: "/Applications/Android Studio.app", size: 3.2, evidence: .bundle, defaultOn: true),
                    .init(id: "s", kind: .data, label: "SDK 与模拟器", path: "~/Library/Android", size: 2.1, evidence: .name, defaultOn: true)
                ]),
        AppItem(id: "imovie", name: "iMovie", monogram: "i", color: Color(red: 0.43, green: 0.29, blue: 0.86),
                meta: "App Store · 随时可以重新下载",
                notice: "这是 App Store 应用，卸载后可以在 App Store 免费重新下载。",
                parts: [
                    .init(id: "a", kind: .app, label: "iMovie.app", path: "/Applications/iMovie.app", size: 3.7, evidence: .bundle, defaultOn: true)
                ]),
        AppItem(id: "maccy", name: "Maccy", monogram: "M", color: Color(red: 0.37, green: 0.36, blue: 0.9),
                meta: "剪贴板历史 1.8 GB，其中图片约 1.5 GB",
                notice: "占空间的是剪贴板历史而不是应用本身。如果还想用它，可以选“只清理数据”。",
                parts: [
                    .init(id: "a", kind: .app, label: "Maccy.app", path: "/Applications/Maccy.app", size: 0.0087, evidence: .bundle, defaultOn: true),
                    .init(id: "c", kind: .data, label: "剪贴板历史", path: "~/Library/Containers/org.p0deje.Maccy", size: 1.8, evidence: .exact, defaultOn: true)
                ])
    ]

    // MARK: 目标驱动的候选
    static let goalCandidates: [CleanupItem] = [
        .init(id: "docker-img", title: "Docker 里没在用的镜像", detail: "Docker 自己统计的可回收量；以后需要时会重新拉取。", size: 14.2, safety: .safe),
        .init(id: "brew", title: "Homebrew 下载缓存", detail: "安装过的工具不受影响，需要时会重新下载。", size: 6.6, safety: .safe),
        .init(id: "pkgs", title: "已安装应用的安装包", detail: "24 个 .dmg / .pkg，对应的应用都已经装好。", size: 3.5, safety: .safe),
        .init(id: "docker-build", title: "Docker 构建缓存", detail: "下次构建时会自动重新生成。", size: 3.2, safety: .safe),
        .init(id: "vscode", title: "VS Code 旧版扩展与安装包缓存", detail: "正在用的是最新版本，旧版本已经不会再加载。", size: 3.0, safety: .safe),
        .init(id: "chrome", title: "Chrome 网页缓存", detail: "只是缓存，清理后第一次打开网页会稍慢。", size: 2.1, safety: .safe),
        .init(id: "zips", title: "已解压的压缩包", detail: "旁边已经有解压后的同名文件夹。", size: 0.38, safety: .safe),
        .init(id: "wx-video", title: "微信里的视频", detail: "在微信的“存储空间管理”里清理；之后旧聊天里的视频可能看不了。", size: 9.5, safety: .review),
        .init(id: "win-iso", title: "Windows 11 安装镜像", detail: "可以从微软官网重新下载；还要装虚拟机就先留着。", size: 6.7, safety: .review),
        .init(id: "avi", title: "未压缩的 AVI 录像", detail: "转成 MP4 通常能小很多，不一定要删。", size: 4.5, safety: .review),
        .init(id: "kali", title: "Kali Linux 安装镜像", detail: "199 天没动过，从未在访达中打开。", size: 3.7, safety: .review),
        .init(id: "rec", title: "9 月 17 日的屏幕录制", detail: "看过或已导出的话，原片可以删掉。", size: 3.3, safety: .review)
    ]

    // MARK: 大文件（也是“逐个看”的卡片）
    static let bigFiles: [FileItem] = [
        .init(id: "win", name: "26200.9457.260913-0221.25h2_ge_release_svc_refresh_CLIENTCONSUMER_RET_A64FRE_zh-cn.iso", ext: "ISO", kind: "系统镜像", location: "下载", modified: "2026 年 9 月", size: 6.7, reason: "Windows 11 的安装镜像。虚拟机已经装好的话就用不上了，需要时可以从微软官网重新下载。"),
        .init(id: "avi", name: "2026-06-14 17-01-54.avi", ext: "AVI", kind: "视频", location: "影片", modified: "2026 年 6 月 14 日", size: 4.5, reason: "没有压缩的 AVI 录像。如果还想留着，转成 MP4 通常只占现在的一小部分。"),
        .init(id: "kali", name: "kali-linux-2026.1-installer-arm64.iso", ext: "ISO", kind: "系统镜像", location: "jingxiang", modified: "2026 年 3 月 20 日", size: 3.7, reason: "199 天没有改动，也从没在访达里打开过。靶场环境搭好后，安装镜像一般就不再需要了。", idleDays: 199),
        .init(id: "rec", name: "录屏2026-09-17 16.01.27.mov", ext: "MOV", kind: "屏幕录制", location: "文稿", modified: "2026 年 9 月 17 日", size: 3.3, reason: "一段屏幕录制。已经剪辑或导出过的话，原片可以删掉。"),
        .init(id: "zip", name: "大创赛视频.zip", ext: "ZIP", kind: "压缩包", location: "文稿 › 国创校赛演讲", modified: "2026 年 9 月", size: 0.18, reason: "旁边已经有解压后的“大创赛视频”文件夹，两份内容相同。"),
        .init(id: "php", name: "phpStudy_64.zip", ext: "ZIP", kind: "压缩包", location: "下载", modified: "约 3 年前", size: 0.079, reason: "1106 天没有改动的安装包压缩文件。", idleDays: 1106)
    ]

    // MARK: 文件分类
    static let fileCategories: [FileCategory] = [
        FileCategory(
            id: .installers,
            subtitle: "下载回来、已经用过的东西：应用装好了的安装包，解压过的压缩包。",
            stats: [.init(label: "安装包", value: "62 个 · 10.0 GB"),
                    .init(label: "其中应用已装好", value: "24 个 · 3.5 GB", highlight: true),
                    .init(label: "已解压的压缩包", value: "15 个 · 377 MB", highlight: true)],
            items: [
                .init(id: "wx-dmg", name: "WeChatMac_4.1.15.dmg", ext: "DMG", kind: "安装包", location: "下载", modified: "微信已安装", size: 541.0 / 1000, reason: "微信已经装好了。", group: FileCategorizer.installedGroup),
                .init(id: "wb-dmg", name: "WorkBuddy-darwin-arm64-5.6.2….dmg", ext: "DMG", kind: "安装包", location: "下载", modified: "WorkBuddy AI 已安装", size: 533.0 / 1000, reason: "WorkBuddy AI 已经装好了。", group: FileCategorizer.installedGroup),
                .init(id: "mm-dmg", name: "MiniMax Design-3.0.20-arm64.dmg", ext: "DMG", kind: "安装包", location: "下载", modified: "MiniMax Design 已安装", size: 406.0 / 1000, reason: "MiniMax Design 已经装好了。", group: FileCategorizer.installedGroup),
                .init(id: "pkg-rest", name: "其余 21 个应用已装好的安装包", ext: "PKG", kind: "安装包", location: "下载", modified: "对应的应用都在“应用程序”里", size: 2.06, reason: "", isSummary: true, group: FileCategorizer.installedGroup),
                .init(id: "zip", name: "大创赛视频.zip", ext: "ZIP", kind: "压缩包", location: "文稿 › 国创校赛演讲", modified: "旁边已经有解压后的同名文件夹", size: 0.18, reason: "旁边已经有解压后的“大创赛视频”文件夹，两份内容相同。", group: FileCategorizer.unzippedGroup),
                .init(id: "zip-rest", name: "其余 14 个已解压的压缩包", ext: "ZIP", kind: "压缩包", location: "下载与文稿", modified: "旁边都已经有解压后的文件夹", size: 193.0 / 1000, reason: "", isSummary: true, group: FileCategorizer.unzippedGroup)
            ],
            reviewable: false, ruleID: "pkg"),
        FileCategory(
            id: .captures,
            subtitle: "屏幕录制往往很大，看过或导出过就可以删掉。",
            stats: [.init(label: "截图与录屏", value: "40 个 · 4.2 GB"),
                    .init(label: "最大的一段录屏", value: "3.3 GB", highlight: true)],
            items: [
                bigFiles[3],
                .init(id: "sr", name: "ScreenRecording_08-20-2026 02-31-01_1.MP4", ext: "MP4", kind: "屏幕录制", location: "文稿", modified: "8 月 20 日", size: 0.125, reason: "下载里还有一份一样的。"),
                .init(id: "cap-rest", name: "其余 38 个截图与录屏", ext: "PNG", kind: "截图", location: "大多在桌面和文稿", modified: "合计约 0.8 GB", size: 0.78, reason: "", isSummary: true)
            ],
            reviewable: true, ruleID: "shot"),
        FileCategory(
            id: .bigFiles,
            subtitle: "50 MB 以上的文件和文件夹，按体积排序。每个都说明它是什么、能不能重新下载。",
            stats: [.init(label: "50 MB 以上", value: "17 个"),
                    .init(label: "最大的 5 个", value: "32.2 GB", highlight: true),
                    .init(label: "可以重新下载的", value: "2 个 · 10.4 GB", highlight: true)],
            items: [
                .init(id: "codex", name: "Codex 任务目录 2026-09-28", ext: "DIR", kind: "文件夹", location: "文稿 › Codex", modified: "2026 年 9 月 28 日", size: 14.0, reason: "9 月 28 日那次任务的实验目录，不常改动。")
            ] + bigFiles,
            reviewable: true, ruleID: "s690"),
        FileCategory(
            id: .stale,
            subtitle: "50 MB 以上、半年没打开过的文件。不一定要删，确认不用了再清理。",
            stats: [.init(label: "半年没打开", value: "7 个 · 5.0 GB"),
                    .init(label: "最久的", value: "1106 天")],
            items: [
                bigFiles[2],
                bigFiles[5],
                .init(id: "stale-rest", name: "其余 5 个", ext: "DOC", kind: "文件", location: "文稿和下载", modified: "合计约 1.2 GB", size: 1.22, reason: "", isSummary: true)
            ],
            reviewable: true, ruleID: nil)
    ]

    // MARK: 残留
    static let leftoverGroups: [LeftoverGroup] = [
        .init(id: "gone", title: "应用已经不在了", subtitle: "在“应用程序”里找不到对应的应用，默认勾选", items: [
            .init(id: "trae", name: "TRAE SOLO CN 的数据", path: "~/Library/Application Support/TRAE SOLO CN", evidence: "“应用程序”里没有找到 TRAE", size: 3.28, defaultOn: true),
            .init(id: "zap", name: "ZAP 的数据", path: "~/Library/Application Support/ZAP", evidence: "没有找到 ZAP（OWASP 安全扫描工具）", size: 0.99, defaultOn: true),
            .init(id: "netdisk", name: "百度网盘的开机启动项", path: "~/Library/LaunchAgents/netdisk_service.plist", evidence: "它要启动的 BaiduNetdisk_mac.app 已经不存在", size: nil, defaultOn: true)
        ])
    ]

    // MARK: 后台项目
    static let launchGroups: [LaunchGroup] = [
        .init(id: "broken", title: "已失效", note: "要启动的程序已经不存在了，每次开机都会白白失败一次。", color: .red, action: "可以移除",
              items: [.init(owner: "百度网盘", label: "netdisk_service.plist")]),
        .init(id: "root", title: "以管理员权限运行", note: "这些服务权限很高。确认是你信任、正在用的软件；不用远程控制时可以关掉 ToDesk 和 UU 远程。", color: .orange, action: "需要密码",
              items: [.init(owner: "ToDesk", label: "com.youqu.todesk.service"), .init(owner: "ToDesk", label: "com.youqu.todesk.UninstallerHelper"), .init(owner: "ToDesk", label: "com.youqu.todesk.UninstallerWatcher"),
                      .init(owner: "网易 UU 远程", label: "com.netease.uuremote.daemon"), .init(owner: "Docker", label: "com.docker.vmnetd · com.docker.socket"), .init(owner: "Hayaku", label: "com.qiuchenly.hayaku.daemon"), .init(owner: "Tailscale", label: "homebrew.mxcl.tailscale")]),
        .init(id: "updater", title: "自动更新程序", note: "只负责检查更新。关掉后应用照常使用，只是不会在后台自动更新。", color: .blue, action: "可以关闭",
              items: [.init(owner: "Google 更新程序", label: "com.google.GoogleUpdater.wake"), .init(owner: "Google 更新程序", label: "com.google.keystone.agent · xpcservice"),
                      .init(owner: "Ego 更新程序", label: "com.citrolabs.EgoUpdater.wake"), .init(owner: "Ego 更新程序", label: "com.citrolabs.keystone.agent · xpcservice")]),
        .init(id: "mine", title: "你自己创建的", note: "指向你主目录里的脚本和工具，大概率是你自己配置的，不会建议删除。", color: .green, action: "保留",
              items: [.init(owner: "hermes", label: "ai.hermes.gateway"), .init(owner: "openclaw", label: "ai.openclaw.gateway"), .init(owner: "headroom", label: "com.headroom.proxy"),
                      .init(owner: "SSH 隧道", label: "com.ljy.dsh-tunnel · com.ljy.mcp-tunnel"), .init(owner: "reasonix", label: "com.reasonix.bot · qq-gateway · tibo-alert")])
    ]

    static let loginApps: [(name: String, color: Color)] = [
        ("Motrix", .blue), ("QQ", .cyan), ("拼多多商家版", .red), ("微信", .green), ("Maccy", .indigo), ("Tailscale", Color(white: 0.15)),
        ("Amphetamine", .orange), ("网易有道翻译", .red), ("FlClash", .purple), ("汽水音乐", Color(white: 0.1)), ("千牛", .orange), ("PixPin", .teal)
    ]

    // MARK: 开发者空间
    static let devTools: [DevTool] = [
        .init(id: "docker", name: "Docker", location: "~/Library/Containers/com.docker.docker",
              note: "虚拟磁盘里大部分是镜像。只清理没被任何容器使用的镜像、构建缓存和已停止的容器；数据卷里可能有数据库，永远不自动清。",
              parts: [.init(label: "镜像 32 个", size: 58.27, reclaimable: 14.18), .init(label: "构建缓存", size: 10.71, reclaimable: 3.21),
                      .init(label: "数据卷 22 个", size: 7.04, reclaimable: 0), .init(label: "容器 23 个", size: 0.44, reclaimable: 0.44)],
              commands: ["docker image prune -a", "docker builder prune", "docker container prune"], never: "docker volume prune（会删除数据卷）"),
        .init(id: "brew", name: "Homebrew", location: "/opt/homebrew · ~/Library/Caches/Homebrew",
              note: "下载缓存和旧版本可以放心清。大包是 llvm、qemu、tesseract-lang、pytorch、gcc，是否卸载要看有没有别的工具依赖它们。",
              parts: [.init(label: "下载缓存", size: 6.6, reclaimable: 6.6), .init(label: "旧版本与旧依赖", size: 0.3, reclaimable: 0.3),
                      .init(label: "已安装的包", size: 8.3, reclaimable: 0), .init(label: "其他", size: 7.4, reclaimable: 0)],
              commands: ["brew cleanup -s", "brew autoremove"], never: nil),
        .init(id: "node", name: "npm / pnpm", location: "~/.npm · ~/Library/Caches/pnpm",
              note: "都是下载缓存，下次安装依赖时会重新下载。",
              parts: [.init(label: "npm 缓存", size: 2.1, reclaimable: 2.1), .init(label: "pnpm 缓存", size: 0.58, reclaimable: 0.58)],
              commands: ["npm cache clean --force", "pnpm store prune"], never: nil),
        .init(id: "vscode", name: "VS Code", location: "~/.vscode · ~/Library/Application Support/Code",
              note: "同一个扩展存了 3 个版本，正在用的是最新的那个；另外还有 25 个扩展安装包缓存。",
              parts: [.init(label: "旧版扩展（openai.chatgpt ×2）", size: 1.5, reclaimable: 1.5), .init(label: "扩展安装包缓存", size: 1.3, reclaimable: 1.3),
                      .init(label: "旧版扩展（claude-code ×1）", size: 0.22, reclaimable: 0.22), .init(label: "正在使用的扩展", size: 1.8, reclaimable: 0)],
              commands: ["移到废纸篓 旧版扩展目录 ×3", "移到废纸篓 CachedExtensionVSIXs"], never: nil),
        .init(id: "python", name: "Python", location: "~/.cache/uv · ~/.local/pipx",
              note: "uv 和 pip 的缓存可以清。pipx 里装的命令行工具是你在用的，不动。",
              parts: [.init(label: "uv 缓存", size: 1.2, reclaimable: 1.2), .init(label: "pip 缓存", size: 0.09, reclaimable: 0.09), .init(label: "pipx 工具环境", size: 2.3, reclaimable: 0)],
              commands: ["uv cache clean", "pip cache purge"], never: nil),
        .init(id: "go", name: "Go", location: "~/go/pkg", note: "模块下载缓存，下次编译时会重新下载。",
              parts: [.init(label: "模块缓存", size: 0.92, reclaimable: 0.92)], commands: ["go clean -modcache"], never: nil),
        .init(id: "jvm", name: "Maven / Gradle", location: "~/.m2 · ~/.gradle",
              note: "依赖缓存。你没有 gradle 命令，这份缓存来自 Android Studio 自带的 Gradle，所以直接移到废纸篓。",
              parts: [.init(label: "Gradle 缓存", size: 0.64, reclaimable: 0.64), .init(label: "Maven 仓库", size: 0.48, reclaimable: 0.48)],
              commands: ["移到废纸篓 ~/.gradle/caches", "移到废纸篓 ~/.m2/repository"], never: nil)
    ]

    // MARK: 最近操作（10 月 5 日的真实记录）
    static let history: [HistoryEntry] = [
        HistoryEntry(date: Date(timeIntervalSince1970: 1_791_190_440), title: "移到废纸篓 1 个文件", source: "大文件",
                     files: [.init(name: "新小文件 copy.pdf", originalPath: "~/Downloads/新小文件 copy.pdf", trashedPath: nil, size: 2.0 / 1000)]),
        HistoryEntry(date: Date(timeIntervalSince1970: 1_791_189_840), title: "移到废纸篓 3 个安装包", source: "安装包与压缩包",
                     files: [.init(name: "Cursor-darwin-arm64.dmg", originalPath: "~/Downloads/Cursor-darwin-arm64.dmg", trashedPath: nil, size: 292.0 / 1000),
                             .init(name: "Crow5_1.3.22_universal.dmg", originalPath: "~/Downloads/Crow5_1.3.22_universal.dmg", trashedPath: nil, size: 279.0 / 1000),
                             .init(name: "QiuChenAppStore-v1.4.4-2026-08-18.dmg", originalPath: "~/Downloads/QiuChenAppStore-v1.4.4-2026-08-18.dmg", trashedPath: nil, size: 233.0 / 1000)])
    ]

    // MARK: 自动规则
    static let rules: [RuleItem] = [
        .init(id: "pkg", name: "装好的应用，安装包别留着", symbol: "arrow.down.circle", color: .purple,
              sentence: [.text("当"), .condition("下载"), .text("里的安装包对应的应用"), .condition("已安装超过 7 天"), .text("时，"), .action("提醒我")],
              automatic: false, status: "目前有 24 个符合，共 3.5 GB"),
        .init(id: "low", name: "空间告急时提醒", symbol: "exclamationmark.triangle", color: .red,
              sentence: [.text("当"), .condition("可用空间低于 10%"), .text("时，"), .action("发通知并给出一键方案")],
              automatic: false, status: "现在可用 5%，已触发"),
        .init(id: "cache", name: "每周清一次开发缓存", symbol: "hammer.fill", color: .green,
              sentence: [.text("每"), .condition("周日 21:00"), .text("，"), .action("清理 Homebrew、npm、uv 的缓存")],
              automatic: true, status: "现在可回收约 10.5 GB"),
        .init(id: "shot", name: "桌面截图自动归档", symbol: "camera.viewfinder", color: .teal,
              sentence: [.text("当"), .condition("桌面"), .text("上的截图"), .condition("放了 30 天"), .text("时，"), .action("移到“图片/截图归档”")],
              automatic: true, status: "只移动，不删除"),
        .init(id: "wx", name: "微信太大时提醒", symbol: "message", color: .green,
              sentence: [.text("当"), .condition("微信的数据超过 20 GB"), .text("时，"), .action("提醒我去微信里清理")],
              automatic: false, status: "现在是 22.8 GB")
    ]
}

// MARK: - 格式化

extension Double {
    /// GB 数值转成“74.7 GB / 892 MB”
    var gbText: String {
        if self >= 1 { return String(format: "%.1f GB", self) }
        if self <= 0 { return "0 MB" }
        let mb = self * 1000
        return mb < 1 ? "不到 1 MB" : "\(Int(mb.rounded())) MB"
    }
}

extension Optional where Wrapped == Double {
    var gbText: String { self.map(\.gbText) ?? "—" }
}
