# 2026-09-10 追加：原生按钮反馈与窗口侧栏连续性

本节为本轮开发交付；下方原视觉升级报告保留为历史记录。原报告的按压缩小规则已被用户最新“按下提亮、扩大、弹性回落”要求取代。

## 基线与范围

- 独立工作树：`/Users/qianmuyan/Documents/GitHub/assignment-app-apple-motion-refinement`。
- 分支：`qianmuyan001/apple-motion-refinement`。
- 基线：`c098c740338ba0a7b97edb6656c5de78e487d862`，来自干净的 Apple visual-polish-ui 分支；已核实包含 `9925878` 与 `AddTaskButton.swift`。遵照用户授权继续新版 Apple UI，没有切回旧 main。
- 最终代码 SHA：`e952e86ba03833335dc155c7c475824f7b862fe8`。最终报告提交 SHA 与工作树状态记录在本工作树 `artifacts/apple-motion/delivery.json` 的 `final_commit` / `working_tree`；该收据在报告提交后写入，避免 Git 提交自引用。
- 仅修改 `AddTaskButton.swift`、`NavigationChrome.swift`、Apple UI 测试和本报告。版本保持 2.1.2 build 2，Schema v4；未修改业务、数据库、迁移、Windows、Web、Backend、Shared。
- 复用已安装 `swiftui-microinteractions` 与 `ecc:liquid-glass-design`，采用系统 SwiftUI/公开 UIKit，无新增依赖。没有可调用 XcodeBuildMCP，使用真实 Xcode。

## 实现与理由

1. **按钮**：iPadOS/Catalyst 26+ 使用系统 `.buttonStyle(.glass)` 和 Capsule，移除原本与系统相反的 `0.96` 缩小和 `0.78` 变暗。由系统负责玻璃高光、轻微膨胀和恢复，避免叠加第二套按压变换。模拟器录屏可见亮度与轮廓变化；这里的“亮”指系统材质高光，不把普通录屏表述为 HDR/EDR 峰值亮度测量。
2. **回退与无障碍**：旧系统保留 regularMaterial；非原生玻璃路径按下放大至 1.06，response 0.3 / dampingFraction 0.68。Reduce Motion 路径只使用 0.1 秒高光反馈，不缩放。Reduce Transparency/Increase Contrast 沿用现有实体背景、前景和边界策略。
3. **窗口侧栏**：不再用宽度分支销毁整个 NavigationSplitView/NavigationStack。相同分栏和详情实例跨宽度保留，通过原生栏位显隐和短弹簧响应宽度变化；搜索和选中页面不会因此重建。紧凑布局从首次布局就依据真实宽度计算，不先展示宽栏再补切状态。
4. **手势冲突**：紧凑模式的左边缘入口属于窗口边界，避免被 iPad 分栏内缩边距移开；入口在一次拖动期间保留。只针对当前 split controller 使用公开 UIKit API 关闭竞争手势/重复系统开关，并在系统重新布局后维持 secondary-only 策略。动画允许输入与中途反向；没有全局 appearance、私有 filter 或延迟重试。侧栏内的水平拖动与原生纵向滚动同时识别。
5. **稳定界面**：保留原 selection、Expanded/Compact、渐变 Material 羽化、Escape、搜索、Cmd-N/F、原新增流程。原 TaskActionViewport 的右/下安全区单一 24pt 间距和列表底部避让保持不变。

## 开发验证

环境：Xcode 27.0 beta `27A5228h`；显式 `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`；SDK 27.0；MacBook Air arm64、macOS 27.0 `26A5425a`。本次独占 iPad Pro 11-inch (M5) 模拟器，iPadOS 26.1 `23B86`，UUID `B65451B5-610B-4D21-B4DA-4CAFC492BC5C`。测试后删除本次创建的模拟器，不动用户模拟器。

| 验证 | 发现 | 执行 | 通过 | 失败 | 跳过 |
|---|---:|---:|---:|---:|---:|
| iPad 全量单元测试 | 199 | 199 | 199 | 0 | 0 |
| Catalyst 全量单元测试 | 199 | 199 | 199 | 0 | 0 |
| iPad 全量 UI 冒烟 | 13 | 13 | 13 | 0 | 0 |
| 最终受影响 UI 补测（子集，不是额外独立用例） | 3 | 3 | 3 | 0 | 0 |

新增 2 个测试：`testGlassPressCanCancelAndActivateOnce`（按住后滑出取消、正常点击打开编辑器）；`testResponsiveSidebarRetainsSearchAndSelection`（真实 SwiftUI 宽度在常规与 620pt 间往返、搜索值保持、覆盖侧栏关闭、返回原页面）。其余原有 11 个 iPad UI 用例均保留，包括安全区、拖出/拖回、搜索、简易/专业、辅助显示和学习页面。

最后一处改动仅将 DEBUG 测试工具按钮改为 `Text(verbatim:)`，避免开发工具标签被误识别为产品本地化键；此后用全新构建目录补跑上述 3 项受影响 UI、iPad 单元测试和 Catalyst Debug 构建。Release 不包含该 DEBUG 标签。

- iPad Debug、Catalyst Debug、Catalyst Release：构建通过。部署目标维持 iPadOS 17 / macOS 14。
- 安全区：iPad 横/竖屏实际 UI frame 测量均右侧 24pt、底部 24pt，差值 0；按钮点击区域不小于 44pt。
- 中英文资源：442 / 442 键一致，所有实际引用键完整；Apple 版本检查通过。
- 原始全量测试日志的 SQLite 生命周期检查通过；没有过滤、隐藏或吞掉警告。
- `git diff --check`、Apple 源码冲突标记扫描通过。
- 测试结果/运行环境摘要：`artifacts/apple-motion/logs/test-results.json`；原始 xcresult 保存在 `artifacts/apple-motion/tests/`；源码副本逐文件 SHA-256 校验保存在 `logs/frozen-source.json`。

中间开发回归曾发现重复原生侧栏/竞争手势；旧增量目录还出现与当前源码诊断及行号不一致的执行。失败日志均保留在 `artifacts/apple-motion/logs/apple-motion-*.log`，不计为通过。最终使用新构建目录、逐文件相同的隔离源码副本完成以上通过结果，没有删除用例或用固定等待掩盖失败。

## 实际窗口与影像

已在真实 Catalyst 应用检查 520×800 窄窗口；同一窗口经系统标题栏双击放宽，再收回，页面与任务数据保持。检查了覆盖侧栏选择后保持、Escape 关闭、Cmd-F 打开搜索、Escape 恢复标题。模拟器录屏验证了原生玻璃按压与同一详情树上的宽度切换。测试宽度切换按钮仅 DEBUG + 显式测试参数可见，不进入正常产品流程。

本工作树的 `artifacts/apple-motion/`：

- 修改前实际 Catalyst：`before/catalyst-wide.png`（上一阶段基线产物的本轮隔离启动）。
- 修改后实际 Catalyst：`after/catalyst-wide-final.png`、`after/catalyst-narrow.png`、`after/catalyst-sidebar-open.png`、`after/catalyst-resized-back.png`。
- 实际模拟器按压前/中：`after/ipad-button-idle.png`、`after/ipad-button-pressed.png`。
- 8 秒原生按压录屏：`after/native-glass-press.mp4`。
- 同一详情页宽度切换/搜索保留录屏：`after/sidebar-resize-and-search.mp4`（DEBUG 宽度工具触发真实原生布局，不是静态 Mock）。
- 全套本轮 iPad 截图与清单：`after/ipad-suite/manifest.json`；包括横/竖屏、安全区、深色及辅助显示测试。
- 影像校验：`SHA256SUMS.txt`。

可复现操作：打开下述隔离演示 app → 按住右下角新增按钮，滑出再松开应取消；普通点击应只打开一次编辑器 → 取消 → 双击系统标题栏放宽/收回 → 窄窗口点击侧栏按钮、选择 Today，侧栏保持 → Escape 关闭 → Cmd-F 输入查询，往返调整宽度，查询保持。

## 数据隔离与内部应用

交付运行 app：`/private/tmp/Assignment-Polish-delivery-c5d62d6c-4305-40db-b01e-f82819b7a876.app`。

- 实际版本 2.1.2 build 2，arm64 Catalyst Debug，独立身份 `com.qianmuyan.assignmentapp.rcsmoke.c5d62d6c-4305-40db-b01e-f82819b7a876`；ad-hoc、App Sandbox、未公证，仅内部开发演示。
- 源码 SHA、二进制 SHA-256、工具版本与测试记录：`artifacts/apple-motion/build-info.json`。
- 只复制已构建应用，再更换一次性身份并重新严格签名；没有通过正式身份启动 GUI。真实 `lsof` 句柄确认 app 使用该随机容器的 assignments.db/WAL/SHM。该数据库由合成 fixture 生成，只读验证 Schema 4 / quick_check=ok。
- 句柄/容器证据：`logs/runtime-isolation.json`、`delivery.json`。旧的本次演示进程已退出，只保留最终隔离应用供查看，没有在连接存活时删除临时数据库。
- 本轮没有读取正式数据库/sidecar/附件或建立正式 SQLite 连接。遵守最新“不访问正式数据库”边界，没有为做指纹而额外读取这些文件；证据针对本轮 app/test 路径，不声称审计了其他进程的活动。

## 未验收及未执行

旧版 iPadOS 17–25 运行时回退、真机手指触感、VoiceOver 人工矩阵、真实系统 Reduce Motion/Transparency/Contrast 设置组合、连续手工拖动窗口的主观弹性手感仍未正式验收。辅助设置测试使用现有 DEBUG 策略注入，不冒充真实系统设置验收。没有测量或宣称帧率、GPU 能耗、真实 HDR 峰值或性能提升百分比。

本轮为开发验证，未执行独立正式发布验收、push、合并 main、tag、Release、Developer ID 签名、公证上传或 TestFlight。

---

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
