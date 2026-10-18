<div align="center">

<img src="docs/images/icon.png" width="128" alt="Adieu 图标：一朵正在飘散的蒲公英">

# Adieu

**好好告别。**

给 Mac 里不再需要的东西，一次体面的告别。<br>
卸载应用连同它留下的一切，清走安装包、录屏和开发缓存。每一项都告诉你它是什么、为什么可以删。

[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-0b7fff?logo=apple&logoColor=white)](#安装)
[![Apple Silicon](https://img.shields.io/badge/Apple%20芯片-arm64-555)](#安装)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](#从源码构建)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-原生-1f6feb)](#技术栈)
[![License: MIT](https://img.shields.io/badge/License-MIT-3fa77a)](LICENSE)

[**官网**](https://adieu.lijunyu.com.cn) · [**下载**](https://github.com/lijunyu726/adieu/releases/latest) · [功能](#功能) · [从源码构建](#从源码构建)

<br>

<img src="docs/images/home.webp" width="880" alt="Adieu 概览页：磁盘占用和今日建议">

</div>

## 为什么是 Adieu

把应用拖进废纸篓，只删掉了它的一半：缓存、容器数据、后台服务还留在资源库里，一年下来几个 GB。装完没删的安装包、几个月前的录屏、编译缓存，也在悄悄占满磁盘。

很多清理工具要订阅才能用，或者一键“清理”了一大堆你看不懂的东西。Adieu 的做法不同：

- **免费、开源**：没有订阅、没有内购、没有广告，代码都在这里。
- **只在你的 Mac 上**：不联网、不上传、不收集任何数据。
- **先说清楚，再删**：每个文件都写着它属于谁、为什么能删、证据有多强；拿不准的，一律不显示。
- **删就删干净**：直接删除，不进废纸篓，立刻腾出空间；需要管理员权限时只问一次密码。

## 功能

### 卸载应用，连根带走

卸载时一起列出应用的容器数据、缓存、群组容器、后台服务，每一项都标着它为什么属于这个应用（只认 Bundle ID 完全匹配，不靠名字猜）。卸载前先退出应用、卸载它的后台服务。个人数据默认不勾选。

<img src="docs/images/apps.webp" width="880" alt="卸载 Docker 时列出的相关文件">

### 残留文件：主人早就不在了

应用拖进废纸篓了，数据却还留在 `~/Library`？Adieu 只列出能确定主人已经不在的：标识符找不到任何已装应用、同一开发者也没有其他应用在。只有名字的文件夹不列。

<img src="docs/images/leftovers.webp" width="880" alt="残留文件页">

### 开机与后台：安静开机

登录时打开的应用，随手开关、随时加回来。其他软件留下的后台程序（LaunchAgents / LaunchDaemons），只把程序已经不存在的标出来，一键清掉。

<img src="docs/images/launch.webp" width="880" alt="开机与后台页">

### 给写代码的人

自动检测电脑上装了的开发工具，只清“删了会自动重新下载或重新生成”的缓存，清理命令原样展示：

> Docker · Homebrew · Xcode（DerivedData、真机调试符号、模拟器缓存、打不开的旧模拟器）· Node.js（npm / pnpm / yarn / bun）· Python（uv、pip）· Conda · Go · Rust · Flutter / Dart · Maven / Gradle · Deno / Composer · VS Code / Cursor / Windsurf 旧扩展 · JetBrains · Playwright / Puppeteer / Cypress / Electron

Xcode 归档、模拟器、Rust 工具链、Android SDK、AI 模型（Hugging Face、Ollama、LM Studio）是你的东西：只告诉你多大，不替你做决定。

<img src="docs/images/devTools.webp" width="880" alt="开发工具页">

### 还有

| | |
|---|---|
| **文件清理** | 安装包与压缩包、截图与录屏、大文件、久未打开的文件；按位置、类型、时间筛选，Shift 连选。截图按天排成缩略图，可“每天只留最后一张” |
| **预览** | 每个文件都能用系统的快速查看预览（空格键），文本、图片、视频、PDF 都行 |
| **腾出空间** | 输入想腾出多少，按“安全 → 需要看一眼”分层挑出最贴近的组合 |
| **最近 · 日记** | 每次删了什么都有记录；每次扫描记一笔快照，按周对比磁盘变化 |
| **菜单栏 · 小组件** | 菜单栏看磁盘余量、一键删掉已装好应用的安装包；桌面小组件显示启动盘余量 |
| **自动规则** | 已装好应用的安装包、空间低于 10% 时提醒；每周清开发缓存、桌面截图归档（需手动打开） |
| **保护名单** | 加进去的文件和文件夹（包括应用），Adieu 永远不碰 |
| **提示音** | 删完响一声（程序坞“一阵烟”、清空废纸篓等），可关 |

## 安装

1. 到 [Releases](https://github.com/lijunyu726/adieu/releases/latest) 或 [官网](https://adieu.lijunyu.com.cn) 下载 `Adieu-0.1.2.dmg`，打开后把 Adieu 拖进“应用程序”。
2. Adieu 还没有经过 Apple 公证，第一次打开如果被拦下：到 **系统设置 › 隐私与安全性**，在页面下方点 **仍要打开**，之后不会再问。

需要 **macOS 26** 和 **Apple 芯片**的 Mac。

### 权限

| 权限 | 用途 |
|---|---|
| 完全磁盘访问权限 | 读取其他应用的容器。没有时应用数据会被算进“系统与其他”，残留也会找漏。首页有提示条，授权后按 ⌘R 重新扫描 |
| 自动化（System Events） | 读取和移除“登录时打开”的项目。在设置 › 权限里点“允许”触发系统弹窗 |
| 通知 | 自动规则的提醒 |

## 注意

> [!WARNING]
> Adieu 的所有删除都是**直接删除，不进废纸篓**，删了不能放回。删除前会确认一次，“最近”里能看到每次删了什么。

已知限制：

- 系统级后台程序（`/Library/LaunchAgents`、`/Library/LaunchDaemons`）只在程序已不存在时清理，且只动其中单个 plist
- Docker 不在运行时无法统计和清理
- 应用数据只认 Bundle ID 完全匹配；同一开发者还有应用在的、只有名字的残留都不列
- ad-hoc 签名：每次重新编译后系统可能重新询问文件夹访问权限；询问期间扫描会停住，超过一分钟页面会提示去点“允许”
- 管理员授权框不提供指纹（Touch ID）选项，需要输入开机密码

## 从源码构建

需要 Xcode 27 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)：

```bash
brew install xcodegen
xcodegen generate              # 新增或删除 Swift 文件后都要重新生成
xcodebuild -project Adieu.xcodeproj -scheme Adieu -configuration Debug \
  -derivedDataPath scratch/DerivedData build
open scratch/DerivedData/Build/Products/Debug/Adieu.app
```

调试参数（macOS 会自动读入 UserDefaults）：

```bash
# 跳过欢迎页、直接打开某一页、使用示例数据（示例模式下删除只是模拟，不动真实文件）
open -n scratch/DerivedData/Build/Products/Debug/Adieu.app --args \
  -didOnboard YES -AdieuSection apps -AdieuSample YES
```

`AdieuSection` 可选值见 `Adieu/App/RootView.swift` 的 `AppSection`；`-AdieuSheet goal`（goal、history、diary）直接打开对应面板。`-AdieuLaunchHidden YES` 模拟开机自启：不弹主窗口，只在后台扫描、跑自动规则。

打包安装包（需要 [uv](https://docs.astral.sh/uv/)，用固定版本的 dmgbuild 排安装窗口）：

```bash
scripts/make-dmg.sh            # Release 编译，输出 scratch/Adieu-<版本>.dmg
```

### 技术栈

- SwiftUI + Swift 6，最低 macOS 26（Liquid Glass、Swift Charts），WidgetKit 小组件
- 工程由 XcodeGen 从 `project.yml` 生成，`.xcodeproj` 不进仓库
- 不开沙盒：卸载需要读写 `~/Library` 与 `/Applications`，因此不走 Mac App Store
- 没有任何第三方依赖，也没有任何网络请求

### 目录

```
project.yml          XcodeGen 配置
Adieu/App/           入口、导航、全局状态
Adieu/Design/        共享界面组件
Adieu/Data/          模型、示例数据、腾出空间的计划算法
Adieu/Scan/          真实数据读取（磁盘、应用、文件、残留、后台项、开发工具），只读
Adieu/Actions/       会改动文件的操作：删除、历史、自动规则、日记、权限、通知
Adieu/Features/      各页面
Adieu/AppIcon.icon/  应用图标（Icon Composer 格式）
AdieuWidget/         桌面小组件
scripts/             打包脚本与安装窗口素材
docs/images/         README 截图（示例数据）
```

## 许可

[MIT](LICENSE) © 2026 李俊宇
