# AGENTS.md

给智能体的项目约束。用途与构建方式见 README.md。

## 技术约束

- SwiftUI + Swift 6，最低 macOS 26；不引入第三方 Swift 依赖，除非有明确理由
- 工程文件由 XcodeGen 生成：改结构改 `project.yml`，不要手改 `Adieu.xcodeproj`；新增或删除 Swift 文件后必须 `xcodegen generate`
- 不开沙盒、不开 Hardened Runtime（ad-hoc 签名，本地开发用）；将来分发需要开发者账号签名与公证

## 目录规范

- 页面放 `Adieu/Features/`，一页一个文件；跨页面复用的组件放 `Adieu/Design/Components.swift`
- 侧边栏入口由 `AppSection` 定义，面板由 `AppSheet` 定义（都在 `RootView.swift`）。四个文件类入口共用 `FileCategoryView`，数据在 `Sample.fileCategories`；新增一类文件只加数据和一个 `AppSection` case，不新建页面
- 数据模型放 `Adieu/Data/Models.swift`；示例数据只放 `SampleData.swift`，用于预览和 `-AdieuSample YES` 演示模式
- 真实数据读取放 `Adieu/Scan/`，只读；会改动文件的操作放 `Adieu/Actions/`。结果挂在 `AppModel`，页面不直接调用扫描函数。扫描函数不依赖界面，可以单独用 `swiftc -swift-version 6` 连同 `Models.swift`、`SampleData.swift` 编译成命令行程序验证
- 构建产物、截图放 `scratch/`（已在 .gitignore）

## 验证方式

- 编译：`xcodebuild ... -derivedDataPath scratch/DerivedData build`，要求零 error、零 warning
- 界面：用 `-didOnboard YES -AdieuSection <页面>` 启动，再用 `screencapture -l <窗口ID>` 截图检查；连续截图时必须等上一个进程完全退出，否则会截到旧窗口；从终端启动的窗口可能不在屏幕上（取不到窗口 ID），先用 System Events 把进程设为前台
- 截图用启动参数（调试与截图用，正常启动不受影响，界面上没有入口）：`-AdieuFileMode grid|list|cards` 文件页直接进某种查看方式（该页没有这种方式时忽略）；`-AdieuUninstall YES` 应用程序页直接打开第一个应用的卸载确认；`-AdieuSettingsTab safety|rules|general|permissions|about` 设置停在某一页；`-AdieuSheet menuBar|onboarding` 把菜单栏面板、欢迎页放在主窗口右边显示（`AppSheet.isPreview`，不走 sheet）。官网手册（adieu-site 的 `website/manual/`）的图都这样截：`open -n -g <Debug 版> --args -didOnboard YES -AdieuSample YES …`，只 kill 自己开的那个 PID，不动 /Applications 里正在用的 Adieu
- 后台截图的坑：`CGEventPostToPid` 发的按键能送到后台实例（鼠标点击不行，后台窗口不响应）；窗口上挂着 sheet 或 alert 时 `screencapture -o -l` 一直截不到、不带 `-o` 也时好时坏，要先给该 PID 发几次 Shift 和鼠标移动唤醒，再不带 `-o` 截、按 alpha 裁掉阴影，必要时重开实例；启动时弹出的欢迎页 sheet 始终截不到，所以有了 `-AdieuSheet onboarding`。ScreenCaptureKit 截单窗口报 -3811，不可用
- **DerivedData 必须放在 `scratch/`（外置盘 S690）**：开发机系统盘只剩个位数 GB，默认的 `~/Library/Developer/Xcode/DerivedData` 会把系统盘挤满

## 安全边界（不可放松）

1. 所有删除都经过 `TrashService.delete`，**按用户要求一律直接删除**（卸载、文件、残留、开发缓存都不进废纸篓、不能放回，“最近”里只留记录）；删除前的确认（设置“删除前总是再确认一次”，默认开）是唯一的后悔机会，不要去掉默认确认。`restore` 只给旧版本留在废纸篓的记录用。权限不够的（App Store 应用归 root）通过 `osascript … with administrator privileges` 弹系统密码窗口，一次处理完，Adieu 不接触密码，路径照样先过 `check`；范围限定为家目录下至少 2 层（`~/Library` 内至少 3 层）、`/Applications/*`、`/Volumes/盘/x`，保护名单双向生效（本身、里面的、包含它的上级都不动）
2. 每个待删项必须带证据等级（`Evidence`）：只有“应用包 / 标识符完全匹配 / 同一开发者”可默认勾选，“名称相似 / 其他应用也在用”默认不勾
3. 卸载应用时默认全勾（含聊天记录等个人数据，用户 2026-10-17 决定），确认面板里逐项列出可取消；残留文件只列“应用已经不在了”一组，默认全勾；对应程序正在运行的不列，最近 30 天还有改动的列出但不勾（直接删除不能撤销，“找不到应用”不等于没人在用）
4. 开发者空间只调用各工具的官方清理命令，并原样展示；`docker volume prune` 等会删数据的命令列入“永不执行”
5. 开发者空间只覆盖本机实测过的工具；检测不到的工具不显示，版本未验证的只展示不提供一键清理

## 关键设计决策与踩坑

- 项目前身是 `/Volumes/S690/codes/sweep`（Node + Electron 版）。改用 SwiftUI 是为了原生质感与体积（本应用约 5 MB，Electron 版仅运行时就约 250 MB）。Sweep 这个名字已有同名商业软件，因此改名 Adieu；名字只做过初步查重，正式分发前需要查商标和 App Store
- 智能助手、⌘K 命令面板、快捷指令按产品决定**不做**（助手第一版不做，以后再议）
- 导航按“要处理的东西”（应用、文件、开发工具）分组，不按“处理方式”分组。逐个看、自动规则是各页面里的动作，腾出空间、最近操作、存储日记是面板。原因：按处理方式分入口时同一个文件会出现在好几处，用户反馈入口多、找不到功能（曾有 15 个入口）。改导航前先对照代码逐项盘点功能，别漏
- 大文件方块图已去掉：和首页长条图重复，具体文件由“大文件”列表回答
- 首页空间分布用长条图，不用环形图（用户比较后认为环形看不清）。顶部一整条按磁盘总量分段；下面每类一行，条以最大的一类为满格，否则小类几乎看不见
- 应用的数据目录只认 Bundle ID 完全匹配的位置（`AppScanner.dataLocations`）；残留文件只认标识符：曾有“同一开发者的残留”“无法确定归属”两组，按名字猜会误判（如两个字的“抖音”、开发商名“Citro Labs”），用户决定不显示这两组，不要加回来
- 系统自带应用（`com.apple.` 且没有 `Contents/_MASReceipt`）不列出；App Store 来的 Apple 应用（iMovie、Xcode 等）列出
- 应用大小先列表、后并行统计：77 个应用串行统计约 11 秒，所以列表先出，每算完一个更新一个
- 容量单位按 1000³ 字节为 1 GB（`bytesPerGB`），和访达、系统设置一致；用过 1024³，首页数字和系统设置对不上；可用空间取 `volumeAvailableCapacityForImportantUsage`，含可清除空间，和访达一致
- 开发机当前屏幕可能处在其他应用的全屏空间里，这时取不到 Adieu 窗口 ID；不要退而截整个屏幕（会截到用户的私人内容），改用命令行验证或请用户自己看
- 开发者空间里 Docker 自报的镜像大小会重复计算共享层（示例数据合计 76.5 GB，而磁盘实际占用 70.4 GB）；接入真实数据时，总量应以磁盘实际占用为准
- 测试开发工具清理时，用环境变量把缓存指到临时目录（如 `npm_config_cache`、`UV_CACHE_DIR`、`GOMODCACHE`、`HOMEBREW_CACHE`），不要动开发者真实缓存；Docker 用带专用 label 的测试镜像
- 有工具数据但没有命令行的情况真实存在（本机有 `~/.gradle` 却没有 `gradle`、有 VS Code 扩展却没有 `code`）：检测按“数据目录”与“命令”两层分别判断

- 应用自管的目录（CapCut、剪映等的素材缓存）不进文件类扫描：删了会让应用里的项目损坏
- 腾出空间用“分层 best-fit”：每层（安全 → 需要看一眼）里先找不小于缺口的最小一项，找不到就取最大的继续补，避免为了 5 GB 动 60 GB
- 自动规则没有后台守护进程，只在 Adieu 运行时（含仅菜单栏）检查；默认只开提醒类，会动文件的规则必须用户自己打开
- 开机自启（设置里“登录时打开 Adieu”，`SMAppService.mainApp`）时不弹主窗口：`AppDelegate` 从启动时的“打开应用”Apple 事件里认出 `keyAELaunchedAsLogInItem`，关掉 SwiftUI 摆出来的主窗口，并直接调 `scanAll()`——扫描原本挂在窗口内容的 `.task` 上，窗口关了它就不跑，自动规则的计时器（在扫描结束时启动）也就起不来。`AppModel` 因此改由 `AppDelegate` 持有。`scanAll` 用 `scanInFlight` 防止后台扫描还没完时打开窗口又开一遍。真正的登录启动只能重启验证；`-AdieuLaunchHidden YES` 走同一条路径，用来验证“不弹窗口”
- 没有完全磁盘访问权限时，其他应用的容器读不到：应用数据合计会明显偏小（本机实测 99.5 GB 对命令行 155.7 GB），差额算进“系统与其他”
- 截图验证只截 Adieu 自己的窗口（`CGWindowListCopyWindowInfo` 取窗口号再 `screencapture -l`），**禁止截整屏**；`pkill` 后立刻 `open` 会报 LaunchServices -600，要等进程完全退出再隔几秒
- 小组件是沙盒扩展，自己读 `/` 的容量，不和主程序共享数据
- 阻塞的磁盘读取和命令一律用 `blocking { }`（GCD 线程），不要用 `Task.detached` 或任务组直接跑：协作线程池只有 CPU 核数个线程，77 个应用的大小统计曾把它占满，文件扫描和开发工具扫描排队超过 75 秒（命令行单独跑只要 3 秒），页面一直显示“没有找到”。应用大小统计同时最多 6 个
- 页面的“没有找到”必须同时判断对应的 loading 标志；`model.scanning` 为真时，“0 MB”“空”都不可信
- 文件扫描跳过 `.photoslibrary`：一读里面就弹“照片”权限，而且图库内部文件不能单独删

- 图标（蒲公英：种子是小方块，被风吹走）和安装窗口背景（浅蓝渐变，左右两个白框对应 settings.py 里的图标位置）都是图像生成（codex）出的实色图，不用透明玻璃风格（和界面不统一，用户否决过）；用户明确不要代码绘制的图标。图标用 `.icon` 格式，图层是一整张满版图（主体在中间约 76% 内），关掉了图层自身的玻璃、投影和半透明，圆角、边缘高光由系统加。改图标后用 `NSWorkspace.icon(forFile:)` 渲染出来看实际效果
- 安装窗口布局用 dmgbuild 直接写 .DS_Store，不用 AppleScript 驱动访达（后者要自动化权限、在无界面环境会失败）；图标坐标要对准背景里的两块空位

## 开源与配套站点

- 本仓库是公开的开源仓库（MIT），只放软件本身。官网和宣传片在私有仓库 lijunyu726/adieu-site（本机 `/Volumes/S690/codes/adieu-site`），不要把它们、服务器地址或部署细节提交到这里
- README 截图在 `docs/images/`，只能用 `-AdieuSample YES` 演示数据截，不能出现用户自己的应用和文件
- 发版：`scripts/make-dmg.sh` 打包后，`gh release create v<版本> scratch/Adieu-<版本>.dmg`；官网下载的 dmg 由 adieu-site 的部署脚本从本仓库 `scratch/` 取

## 回退

- 远端是 GitHub 公开仓库 lijunyu726/adieu；开源前的完整私有历史（含官网）备份在本机 `scratch/adieu-private-history-20261018.bundle`，可 `git clone` 它找回旧提交
- 用 `git revert` 回退，不要改写已公开的历史
- `xcodegen generate` 可随时重建工程文件
- 视觉统一走 `Components.swift`：`Theme`（取自图标的玻璃蓝、天空蓝、暖光）、`PageBackground`（浅蓝渐变）、`PageHeader(section, …)`（大标题，不带图标块）、`.card()`（白底圆角 14、淡蓝投影）、胶囊形 `Chip` / `FilterChip`。侧边栏用单色系统图标。开发工具页不再用终端风格，和其他页面一致；命令仍原样展示
- 文件类页面的勾选、筛选都在 `FileCategoryView` 里；`FileItem.modified` 有时是状态说明（“微信已安装”），筛选和精确时间用 `date`，位置筛选用 `root`（location 第一段）
- 文件页交互（用户 2026-10-21 认可的原型）：鼠标指着哪个，右边预览栏（`FilePreviewPane`，内嵌 `QLPreviewView`）就显示哪个，停 150 ms 才切换，免得划过时一路刷新；预览栏开关存在 `filePreviewPane`，页面窄于 900 点自动收起，这时原因改写在每一行里。整行（整张缩略图）都是勾选目标，没有眼睛、放大镜按钮（在右键菜单和预览栏里）。拖动连选靠 `RowFrames` 记下每行在 `files` 坐标空间里的位置，按下那一行的原状态决定这一笔是勾还是取消；`RowFrames` 是普通 class，改它不触发刷新
- 列表有焦点时：空格快速查看当前项（不勾选），↑↓ 换当前项，回车勾选或取消当前项，⌘A 全选显示中的（已经全勾上时再按一次全不选），esc 全部取消，⌘⌫ 删除已勾选。删除键在 `onKeyPress` 里要同时认 `.delete`（U+0008）和 U+007F：Mac 键盘的删除键发的是后者，只写 `.delete` 时 ⌘⌫ 完全没反应（曾经这样上线过）。可以用 `CGEventPostToPid` 给 `open -n -g` 开的示例实例发按键，再 `screencapture -l` 截它的窗口来验证，不打扰前台。⌘⌫ 和“逐个看”攒下的一批一律走 `AppModel.confirmTrash`，不管设置里关没关确认：访达里 ⌘⌫ 是进废纸篓，这里是直接删除
- 快捷键要画在页面上（用户反馈记不住）：键帽用 `Components.swift` 里的 `KeyCap` / `KeyHint`，按钮自带的快捷键用 `ShortcutLabel` 写在按钮文字后面（全选 ⌘A、删除 ⌘⌫）。预览栏底部常驻空格、↑↓、回车、⌘A、esc、⌘⌫；底栏没勾东西时写 ⇧ 连选和鼠标用法，预览栏收起时再加空格、方向键和回车，“清除”按钮带 esc，放不下用 `ViewThatFits` 依次省掉；“逐个看”在三个按钮下面一排键帽，没勾东西时不显示底栏。新增快捷键时同步加提示
- 每页顶上的建议卡只是一键勾上，规则在 `FileSuggestion`（首页“今日建议”共用这一份，两边数字对得上），规则保守：安装包页勾“应用已经装好 / 已经解压过”，截图页每天只留最晚一张（不含录屏），大文件页勾安装包和系统镜像，久未打开页只勾能重新下载的。分组：安装包按 `FileItem.group`（`FileCategorizer` 里三组），截图按天（全都没日期的示例数据不分天），久未打开按 `idleDays`；大文件不分组，从大到小一列
- 首页“今日建议”：开发工具最大的可回收项、四个文件页的建议、默认勾选的残留，按大小取前三；同一个文件可能同时在安装包、大文件、久未打开里，和已列出的有重叠就跳过。文件类的按钮是“去 X 勾选”：设 `AppModel.pickOnOpen`，那一页 `onAppear` 时替人按一下建议按钮（逐个看模式会切回列表），删不删还是用户自己点
- 使用手册在官网 `https://adieu.lijunyu.com.cn/manual/`（`URL.adieuManual`，定义在 `AdieuApp.swift`）：帮助菜单“Adieu 使用手册”（⌘?，替换系统默认的帮助项）、侧边栏底部系统样式的“?”按钮（`HelpLink`）、设置的“关于”页。官网改路径时这里要一起改。只是交给浏览器打开，Adieu 本身仍不联网
- 存储日记（`DiaryStore`）：每次扫描完记当天快照，留 60 天。“谁用掉了空间”先列应用（新进前 30 名的写“可能是新装的”，消失且已不在本机的写“卸载了”），再列文件夹（`parts`：只记“你的文件”和“隐藏文件与开发缓存”的细分，不记“其他”），分类只报文件夹解释不了的那部分。`parts` 从 2026-10-21 起才有，旧快照没有：对照日晚于这周第一天时写明“从 X 起”，分类照旧整段报、不相减。首页记录不到两天时只留一行字，不放空卡片
- 自定义 `Layout`（`FlowLayout`）量最小尺寸时宽度会给 0，若照常换行会算出极高的最小高度，把整个窗口内容顶出窗口；已按一行处理，详情区也加了 `minHeight: 0` 兜底
- 扫描卡在 `open()` 不动时，多半是系统权限弹窗在等用户（ad-hoc 签名重编译后会重新问）。可用 `CGWindowListCopyWindowInfo` 只看窗口所属进程名（`UserNotificationCenter`）确认，不要截整屏，也不要替用户点
- 用户明确要求所有删除“直接删除，不进垃圾桶”，也不要多一个勾选框：不要改回废纸篓、不要加“撤销”
- 已经不存在的文件（如卸载时某个数据目录早没了）直接跳过，不算失败，不然完成页会出现“文件已经不在了”这种吓人的失败项
- 已移除“搬到外置盘”和“重复文件”：用户认为这两个功能用起来麻烦，决定不要。不要再加回来
- 开机与后台只面向普通用户：登录项是主角（开关、添加应用）；其他软件的后台程序只清理程序已不存在的，还在用的折叠起来只展示，不提供逐个移除
- 开发工具只清“删了会自动重新下载或重新生成”的缓存；SDK、模型、工具链、Xcode 归档、能用的模拟器是用户的东西，只显示大小（`kept`）不清理。Conda 只在找得到 conda 命令时用 `conda clean --all -y` 清，pkgs 里有环境硬链接的文件，不能直接删目录。新增条目前先确认路径能通过 `TrashService.check`（主目录下至少两层，资源库下至少三层）
- 开发工具里 `bun pm cache rm` 要求当前目录有 package.json，从 Adieu 里运行会报错、什么也不删，所以 bun 缓存改为直接删除缓存目录
- Homebrew 可回收量以 `brew cleanup -s -n` 的 “approximately …” 为准，没有这一行就是 0；缓存目录里的 api、bootsnap 是 Homebrew 自己的索引，清完也会留着，不能拿目录大小当可回收量（曾因此清完仍显示 64 MB）
- 管理员操作走 `osascript … with administrator privileges`。据苹果 DTS 在开发者论坛的说法，这种授权框只给苹果签名的进程提供指纹，Adieu 的密码框不会有指纹选项（本机未实测）。已决定保持输密码：走访达删除会进废纸篓，与“直接删除”冲突；特权助手需要 Developer ID 签名，等有开发者账号再考虑
- 安装窗口背景是 1800×1200 点的大图，布局只占左上角 660×400，右边和下边延伸同色渐变：Finder 不缩放背景，窗口拉大会露出白底
- 换图标后替换安装仍显示旧图标：程序坞和聚焦搜索的图标缓存按“标识符 + 构建号”认，重启程序坞没用。make-dmg.sh 每次用时间做构建号（CURRENT_PROJECT_VERSION），并 touch .app
- 文件类页面的汇总数字、侧边栏数字、首页建议都来自 `fileCategories`，`removedKeys`（删掉的路径）一变就 `rebuildFileCategories()`（排除已删的）；曾经只在列表里隐藏，汇总一直不变
- `FileReviewDeck` 进入时固定一份列表：页面列表会随删除变短，按序号翻页会跳过下一个。→ 只是标成待删（和列表共用 `selected`），看完列出待删的再确认删除；⌘Z 退回上一张时按记录恢复这一项原来的勾选状态。以前按 → 直接删、不确认，删了找不回
- `uv cache clean` 遇到别的 uv 进程开着（正在跑的 Python 程序、编辑器插件）会无限等待，界面一直“正在清理”。`Shell.run` 看到 stderr 里的 `Cache is currently in-use` 就停掉命令并标记 `busy`，提示用户关掉占用的程序再试；不加 `--force`，它会弄坏正在运行的环境
- 开发工具可以同时清多个（`devRunning` 是集合），同一个工具不会重复开始；“清出多少”按该工具清理前后的统计差算，不再用磁盘可用空间的差，否则并行时会互相算进去
- 文件图标和访达一致：能预览用 Quick Look 预览图，否则用文件自己的图标；一律完整显示（`scaledToFit`），不裁切、不垫底色。用户要求所有文件都保留原来的图标预览
- 列表里要删的东西（卸载详情的相关文件、卸载确认、残留文件、“最近”记录）都用访达里的图标（`FileIcon`），不用 SF Symbols 色块。文件已经删掉时：卸载掉的应用用删之前存下的图标（`IconStore`，`~/Library/Application Support/Adieu/icons/<应用包名>.png`，在 `TrashService.delete` 删之前存），文件夹用文件夹图标（删除记录里的 `folder`），其余按扩展名取系统类型图标；没有扩展名或扩展名系统不认识的（`com.tencent.xinWeChat`）按文件夹处理
- 删除音效默认“清空废纸篓”（用户要求，卸载、删文件、删残留、清开发缓存都响同一声，只跑了清理命令的也响）；设置里可换
