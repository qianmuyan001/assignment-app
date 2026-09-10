# Apple 视觉整理与开发验证

日期：2026-09-10。本报告记录开发交付，不代表正式产品验收或发布。

## 基线、范围和提交

- 用户明确选择包含 `99258784a04a83d22b62b706d980880d534e5378`、`AddTaskButton.swift` 的新版 Apple UI 分支。
- 基线：`50c2f31c1fdf48c3a76ed4a55c4ca6e98e6f5460`，来自干净的 `qianmuyan001/apple-ui-optimization`。
- 已获取远端引用；当时 `origin/main` 为 `8267cdb120f9c1ef5edec342498e132701eda009`。经用户明确授权使用 Apple UI 基线，没有从旧主干重复创建新增按钮。
- 独立工作树：`/Users/qianmuyan/Documents/GitHub/assignment-app-apple-visual-polish-ui`。
- 分支：`qianmuyan001/apple-visual-polish-ui`。原 `apple-visual-polish` 停止审计工作树保留。
- **最终源码提交：`37c6f958f58a3ea5c1e8e138a7f21a4fd6d4ef7a`**。下一个提交仅交付本报告；报告提交不改变冻结源码。交付头可用 `git log -1 --format=%H -- docs/phase-reports/apple-visual-polish.md` 查询。
- 源码提交后的工作树干净；交付报告后通过 `git status --short` 复核。截图、构建与测试证据位于忽略的 `artifacts/apple-visual-polish/`。
- 仅修改 Apple 视图、界面命令、Debug 测量辅助、Apple UI 测试和本报告。没有修改 Windows、Web、Backend、Shared、Schema、迁移、业务规则或版本号。Apple 仍为 **2.1.2 / build 2 / Schema v4**。

## 审计与设计依据

已阅读并应用 `design-taste-frontend`、`apple-design`、`codebase-design`、`ecc:liquid-glass-design`、`swiftui-microinteractions`。只采用原生设计与深模块原则，没有引入 Web UI、第三方运行库或私有滤镜。

实际查看了用户提供的《提醒.heic》。采用其标题与任务内容的清楚层级、留白、轻分隔和浮动主操作；保持应用现有系统蓝色强调色。设计强度 6、动效强度 4、密度 4。普通任务行和表单继续使用系统背景，玻璃限定在悬浮控制和导航选择。

修改前已构建、运行并截图，确认右下角按钮确实由 `AddTaskButton.swift` 和 `ContentView.assignmentContent` 的底部 inset 生成。原按钮为不透明的 borderedProminent，水平留白 20、垂直留白 12；原大标题已是列表的兄弟视图，因此保留固定标题实现。520×800 时旧 NavigationSplitView 的系统覆盖侧栏压住部分标题；新版采用明确的覆盖导航控制。

## 实现与涉及文件

| 改动 | 文件 | 功能理由 |
| --- | --- | --- |
| 单一 24pt 安全区定位、56pt 最小高度、内容避让 | `AddTaskButton.swift`、`ContentView.swift` | 两个方向使用同一次 padding 和同一语义值；保留自然列表滚动，最后一行可以完整滚到按钮上方 |
| 真正 Liquid Glass 与旧系统 Material 回退 | `AddTaskButton.swift` | 26+ 使用 `.glassEffect(.regular.tint(...).interactive(), in: .capsule)`；轻量透明 tint，不使用不透明强调色圆块 |
| 可打断按压反馈 | `AddTaskButton.swift` | 按下缩放 0.96，spring response 0.3 / damping 0.78；Reduce Motion 使用 0.1 秒透明度反馈，无缩放或循环动画 |
| 宽窗系统分栏、窄窗覆盖导航 | `NavigationChrome.swift` | 复用 `AssignmentView` selection、Expanded/Compact 偏好；宽度小于 700 UIKit pt 或 compact size class 时切换呈现方式 |
| 左边缘拖动、外部点击、关闭按钮、Escape | `NavigationChrome.swift`、`AssignmentApp2App.swift` | 选择项目不会关闭；拖动使用实际显示位置和 predictedEndTranslation；反向操作保留当前弹簧位置 |
| 48pt 背景羽化、可读 Material 侧栏 | `NavigationChrome.swift` | 只 mask 背景，不 mask 导航文字；降低透明度或增加对比度时使用不透明系统背景和清楚边缘 |
| 侧栏可滚动、筛选区与标题对齐 | `NavigationChrome.swift`、`Views.swift` | 大字体时导航可以滚动；筛选区使用 24pt 页面边距、8pt 垂直间距和 subheadline；移除重复 bar 底色与标题下硬分隔 |
| 测量与视觉变体 | `VisualPolishTestSupport.swift`、`AssignmentApp2UITests.swift` | Debug 独立窗口尺寸请求、实际控件 frame 测量、直接控件截图；不写系统显示偏好 |
| 中英文导航文案 | 两份 `Localizable.strings` | 新增“显示侧栏 / 关闭侧栏”，保持键集合一致 |

少量深模块负责复杂度：`TaskActionViewport` 管布局，`AddTaskButton` 管材质与按压，`AssignmentNavigationShell` 管呈现；无第二套业务导航模型或主题模型。有限的 display link 只在侧栏弹簧收敛期间运行，结束或视图退出时停止。没有新增查询、排序、数据库写入或后台业务任务；未做帧率、能耗或性能提升百分比测量。

## 测试结果

未发现可调用的 XcodeBuildMCP。使用真实 Xcode，所有构建和测试显式设置：

`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`

- Xcode 27.0 beta，build `27A5228h`；macOS 27.0，build `26A5425a`；主机 arm64。
- 拥有的模拟器：`AssignmentApp-RC-8c0041ec-080a-4b1c-a999-5774dac6f91a`，UUID `F578D875-F164-42B3-9F8E-1AFCCA679713`，iPad Pro 11-inch (M5)，iOS 26.1。单元测试由 Xcode 创建该设备的测试 clone。
- 构建 SDK 27；最低部署设置保持 iPadOS 17.0 / macOS 14.0。旧系统分支已编译，但没有旧运行时的实际界面验证。本轮没有宣称 Intel 或 Universal 支持。

以下为冻结源码的最终完整运行，不用历史通过数字替代：

| 检查 | 发现 | 执行 | 通过 | 失败 | 跳过 | 证据（artifacts/apple-visual-polish/after/） |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| iPadOS 全量单元测试，TZ=GMT | 199 | 199 | 199 | 0 | 0 | `ipad-frozen-unit.xcresult`、同名 log、summary.json |
| Catalyst 全量单元测试 | 199 | 199 | 199 | 0 | 0 | `catalyst-frozen-unit.xcresult`、同名 log、summary.json |
| iPad 全量 UI | 11 | 11 | 11 | 0 | 0 | `ui-final.xcresult`、`ui-final.log`、summary.json |
| 最终完整运行合计 | 409 | 409 | 409 | 0 | 0 | 三份原始 xcresult |

新增覆盖：按钮横竖屏边距、覆盖侧栏选择保持/关闭/外部关闭/搜索、边缘拖出拖回、无透明与减少动效策略、简易/专业编辑模式。原有 7 项 UI 测试全部保留，包含 GMT 课程/考试、任务创建与删除、首次引导、备份和中英文设置。

| 构建与静态检查 | 结果 |
| --- | --- |
| iPadOS Debug | 通过；`ipad-debug.log` 及最终 UI/单元构建 |
| Catalyst Debug | 通过；`catalyst-debug-final.log` |
| Catalyst Release | 通过；`catalyst-release-final.log` |
| SQLite 生命周期诊断 | 三份最终全量日志均无匹配警告；`sqlite-diagnostics-final.json` |
| 中英文资源 | 442/442 同键；120 个 L10n 调用和 169 个 SwiftUI literal 检查通过 |
| Apple 版本检查 | 2.1.2 / build 2 一致；没有更改跨平台版本契约 |
| `git diff --check`、冲突标记扫描 | 通过 |

首次 Catalyst 单元运行在读取 Documents 下的源码 VERSION 时阻塞，已有 198 项完成，不能计为全量通过。采样栈保存在 `catalyst-unit-hang.sample.txt`。随后使用 `/private/tmp/apple-polish-validation-source` 下逐文件 SHA-256 一致的源码副本运行，199 项全部完成；`source-mirror-final.json` 记录与冻结提交对应的校验。没有更改系统文件访问权限或删掉版本检查。

额外的 Catalyst UI 自动化选择了 Escape、覆盖导航和搜索三项。第一次 runner 因 ad-hoc 与 Hardened Runtime 库校验不能加载；仅对一次性测试 runner 的构建关闭 Hardened Runtime 后，仍在启用系统 automation mode 时超时。**这两次均未执行应用 UI 用例，不能标记通过。** 未修改系统自动化权限，也没有改变产品 Release 配置。相关日志和 xcresult 均保留。

iPad 的 XCTest Escape 注入没有到达已取得 first responder 的 UIKit 控件，本机缺少交互式 Simulator.app，故 Escape 自动用例单独声明在 Catalyst；iPad 打开/关闭/外部点击/搜索仍完整执行。早期诊断失败和 runner 错误保留在 `all-attempt-results.json` 及原始结果中，没有过滤失败日志。iPad 物理键盘 Escape 仍待设备验证。

## 安全区与真实界面检查

Debug 测量探针是不可点击的 UIKit 可访问性叶节点，frame 来自实际布局；值来自 bounds，允许测试换算 Catalyst 系统坐标与 UIKit 逻辑坐标。没有把预期边距写成测量结果。

| 最终 iPad 测量 | 窗口 frame | 内容安全区 frame | 按钮 frame | 右 / 下 / 差值 |
| --- | --- | --- | --- | --- |
| 竖屏 | 0,0,834,1210 | 82,216,752,974 | 659,1110,151,56 | 24 / 24 / 0 pt |
| 横屏 | 0,0,1210,834 | 82,216,1128,598 | 1035,734,151,56 | 24 / 24 / 0 pt |

竖屏安全区底部是 1190，窗口底部是 1210，Home Indicator 区域没有被当作按钮边距。Catalyst 实际窗口请求并截图为 520×800 和 1024×800 系统坐标；没有将 Catalyst 的位图像素直接当作 UIKit pt。Catalyst 的 frame 自动断言仍受上述 runner 条件限制。

最终 Catalyst 窗口实际完成：打开覆盖侧栏、选择 Today 后保持、Escape 关闭、Command-F 搜索、Escape 恢复标题、Command-N 打开同一个 Quick Add 编辑器并取消、长列表滚到底部检查避让。简易编辑器没有“已完成”。这些是开发实机操作证据，不代替正式人工验收。

## 截图与产物

证据根目录：`/Users/qianmuyan/Documents/GitHub/assignment-app-apple-visual-polish-ui/artifacts/apple-visual-polish/`。

| 场景 | 修改前 | 修改后 |
| --- | --- | --- |
| Catalyst 宽窗浅色 | `before/catalyst-wide-light.png` | `after/catalyst-wide-light.png` |
| Catalyst 520×800 | `before/catalyst-520x800.png` | `after/catalyst-frozen-520x800.png` |
| 窄窗侧栏 | 前一项中的系统覆盖侧栏 | `after/catalyst-sidebar-open.png` |
| iPad 竖屏 / 横屏 | `before/baseline-ipad-portrait-all.png` / `baseline-ipad-landscape-all.png` | `after/visual-ipad-portrait.png` / `visual-ipad-landscape.png` |
| 按钮近景 | `before/baseline-add-button-closeup.png` | `after/visual-add-button-closeup.png` |
| 深色 | `before/catalyst-dark.png` | `after/catalyst-dark.png` |
| 大字体策略 | `before/catalyst-large-type.png`、`before/ipad-compact-accessibility-xxxl.png` | `after/catalyst-large-type.png`、`after/ipad-compact-accessibility-xxxl.png` |
| Reduce Transparency / Contrast / Motion | 未采集修改前系统组合 | `after/catalyst-reduce-transparency.png`、`catalyst-sidebar-opaque.png`、`visual-dark-opaque-contrast.png` |
| 搜索 / 末行避让 | 原始导航截图 | `after/catalyst-search.png`、`catalyst-final-row-clearance.png` |

截图来自运行应用；按钮近景由 XCTest 对真实按钮直接 screenshot。补拍的基线使用基线源码归档，加上只设置窗口大小/主题/大字体的 Debug 截图辅助，没有套用新版视觉组件。宽窗基线与新版均使用 18 个合成任务；部分基线变体是空库，因此不能当作相同数据的逐像素比较。

无透明、对比度和减少动效截图是 **Debug 注入现有 NavigationChromeAccessibilityPolicy 的策略变体**，不是声称已切换真实系统设置。大字体使用 SwiftUI accessibility5；Catalyst 的系统字体呈现与 iPad 不同，不冒充完整 macOS 字号无障碍验收。

截图包：[Apple-visual-polish-screenshots.zip](../../artifacts/apple-visual-polish/Apple-visual-polish-screenshots.zip)，已检查 ZIP CRC；各 PNG 尺寸与 SHA-256 见 `screenshots-manifest.json`。

ZIP SHA-256：`c4d7bdeb9a105fef91aafbcd704e95fba9e3dae54c3ef910ef09286e7cbfe34a`。

构建输出路径、真实包内版本、SDK、架构、可执行文件 SHA-256 见 `build-info.json`。实际运行的副本均为随机 `com.qianmuyan.assignmentapp.rcsmoke.<UUID>`、arm64、App Sandbox、ad-hoc、未公证；签名结构严格验证通过。它们是内部开发副本，不能作为正式发布包。正式身份的原始构建输出没有用于人工启动。

## 数据保护证据

没有运行可能打开正式数据库的旧打包脚本，没有读取、打开、迁移或写入日常数据库及 sidecar，也没有为指纹检查读取其内容。没有访问正式附件目录。

复用现有 fail-closed `AppleRuntimeIsolation`：保留身份必须匹配合法 UUID 和同名 Sandbox home，否则在数据库打开前失败。iPad UI 使用每次生成的 `testDatabaseToken`；单元测试使用已有 XCTest 临时路径与隔离偏好机制。

`after/isolation-evidence.json` 记录本轮 11 个实际运行副本的身份、PID、`lsof` 观察到的数据库路径和 Schema v4 / quick_check=ok；对应 `*-open-files.txt` 保留原始句柄清单。最终五种视觉副本在启动前仅向各自新 UUID 容器写入合成 fixture 与内部首次引导偏好。所有观察到的 assignments.db 句柄均属于各自隔离身份。

补启动的冻结副本 `frozen-narrow` 的 Mach-O UUID 与冻结提交重建的 Debug 产物相同，另保存 `catalyst-frozen-escape-state.txt`、`catalyst-frozen-escape.png`；证明该构建实际完成选择保持与 Escape 关闭。其余 Catalyst 视觉矩阵截图在冻结前功能完成构建上拍摄，之后仅补充 Debug frame 换算和整理无效视图修饰，未更换视觉设计。

本次拥有的 iPad 模拟器已按所有权凭据删除，清理日志为 `simulator-cleanup.log`。所有上述 Catalyst 副本已经退出，数据库句柄确认关闭，容器保留供复核；没有在连接仍存在时删除测试数据库目录。证据来自隔离路由审计、实际句柄与隔离数据库验证，**不是全时段内核文件访问审计**，也没有伪造正式数据库前后哈希比较。

## 复现与尚未完成

1. 使用本报告源码提交构建 Debug，将副本改为新 UUID 的 rcsmoke 身份并 ad-hoc Sandbox 签名，再启动；不要直接启动正式身份原始产物。已有 `AppleRuntimeIsolation` 与 `scripts/sign-apple-bundle.py` 可复用。
2. 宽窗打开 All Tasks，滚动到顶部继续滚动：标题保持固定，列表自然回弹；展开搜索后点击关闭或 Escape，标题恢复。
3. 将窗口设为约 520×800，点击左上侧栏按钮，选择 Today：侧栏应保持。点击 X、外部区域或 Escape 分别关闭；左边缘拖出，侧栏内部向左拖回。
4. 滚到长列表最后一项，检查可点击区域在浮动按钮上方；点击按钮及 Command-N 都应进入同一个创建流程。取消不保存。
5. 在真实 iPad、真实系统 Reduce Motion / Reduce Transparency / Increase Contrast、VoiceOver 和分屏环境继续检查。旧系统 Material 回退、连续中途反向拖动的视觉手感、所有页面的完整焦点矩阵尚未人工验收。
6. 如需运行桌面 XCTest，在 Xcode 中处理系统实际提出的开发工具/自动化权限条件，再重跑 `AssignmentApp2UISmoke` 中三个桌面相关用例。当前没有线上 CI 结果，也没有宣称桌面 XCTest 为绿。

缺少的修改前无透明组合截图、iPad 物理键盘 Escape、完整 VoiceOver/系统设置/旧系统/分屏人工矩阵明确保留为未完成。没有做全新 UI 架构、通知规则、课程时间规则或数据库重构。

本轮未 push、未合并 main、未打 tag、未创建 Release、未上传公证或 TestFlight。正式视觉验收仍待用户另行指令。
