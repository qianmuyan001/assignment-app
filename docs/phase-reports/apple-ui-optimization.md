# Apple UI 优化开发报告

日期：2026-09-09。范围为 SwiftUI / Mac Catalyst 及共用 iPadOS 代码。本轮是开发与开发验证，**没有执行正式发布验收**。

七项均已修改源码；第 7 项最后发现的横向列头同步问题已修改并通过回归及构建，但真实窗口复查被主机锁屏中断，状态为**部分完成**。其余六项已完成下述开发验证。不得将此报告解释为完整人工交互、无障碍或正式发布验收通过。

## 基线与范围

- 实际仓库：`/Users/qianmuyan/Documents/GitHub/assignment-app`。
- 独立工作树：`/Users/qianmuyan/Documents/GitHub/assignment-app-apple-ui-optimization`。
- 分支：`qianmuyan001/apple-ui-optimization`。
- 获取远端引用后，`origin/main` 为 `8267cdb120f9c1ef5edec342498e132701eda009`。审计其他 Apple 工作树后选择包含最新 Apple 实现的 `d6e2a64fbb4ce085d17f0a778e3e9b3989bdc8d1` 为基线，未倒退到历史 2.1.0。
- 最终源码与包基线：`99258784a04a83d22b62b706d980880d534e5378`，打包时工作树 clean。主要实现提交为 `3cc5cabd58864740c20c954fe83bd64d221023fe`、`4e03fd7a05531b83d967f0888681fc96e5e0d087`；横向坐标修复为 `4626581a236c91300b7deec4b23c3eccdab5a8d9`。
- 本报告单独提交；报告提交及交付时工作树状态记录于本地 `artifacts/apple-ui-optimization/final-git-state.json`。可用 `git log -1 --format=%H -- docs/phase-reports/apple-ui-optimization.md` 取得报告提交。
- 保持 Apple 2.1.2 / build 2、Schema v4、iOS 17 / macOS 14 最低版本。未修改 Windows、Web、Backend、共享 Schema、根版本、根 README 或其他工作树；原主仓库未跟踪 `.workbuddy/` 保留。
- 复用了基线的 fail-closed rcsmoke 隔离、SQLite 生命周期收口、通知唯一调度器、备份恢复规则和模拟器所有权脚本。

## 参考素材与诊断

实际查看了 `提醒.heic` 的转换预览和用户提供的课程表图片，读取了 MyUW HTML 的布局/CSS，没有执行 HTML 中的脚本或将文档内容当作指令。布局摘录保存在 `artifacts/apple-ui-optimization/reference-layout.txt`。

提醒参考采用强调色标题、前置完成圆圈、细分隔线、次级课程/日期文字与右下角加号。保留应用现有强调色、系统字体与侧栏，不照搬另一个产品。MyUW 的半小时格约 35px；本实现使用统一的 1.4pt/分钟坐标（每小时 84pt），整点实线、半小时虚线、固定星期列头和左侧时间轴。

使用了 apple-design、frontend-design、diagnosing-bugs、Liquid Glass 和 iOS 调试技能。Web 示例只用于排版原则；界面仍为原生 SwiftUI。未增加第三方 UI 库。XcodeBuildMCP 不可用，使用真实 Xcode 工具。

修改前的证据来自同一份合成 Schema v4 数据：18 个任务、8 个课程安排，不含日常用户数据。旧比较器把标题作为同截止时间任务的次级排序，导致无截止时间任务受文字编辑影响；4 项排序回归中 3 项在修改前失败，原始 `sort-before.log` 和结果包保留。旧课程表使用等高卡片，无法直观表达时长；系统大标题与滚动内容关联。

## 七项交付

| 需求 | 状态 | 实现与主要文件 | 开发验证及限制 |
| --- | --- | --- | --- |
| 1. 标题不参与回弹 | 完成 | `ContentView.swift` 将固定标题放在 List 外，原生导航使用 inline；没有反向抵消滚动或全局禁用回弹 | 真实 Catalyst 滚轮滚动时行位置变化，标题屏幕 y 始终为 157.47；UI 测试覆盖创建/刷新后的标题。短/空/长列表及触控板连续弹性手势完整人工矩阵未验证 |
| 2. 快速添加无“已完成” | 完成 | `TaskEditorView.swift` 新建界面移除状态区，保存为 todo；原有任务编辑仍显示状态，模型/Repository 对 done 支持保留 | 实际快速添加截图无状态区；UI 测试验证新建待办。专业字段保留既有 draft 保存机制，无 schema 或历史数据改写 |
| 3. 刷新真实反馈 | 完成 | `AssignmentViewModel.swift` 合并刷新、后台读取、修订号阻止旧快照覆盖新写入；`ContentView.swift` 显示真实进度、完成时间、错误重试 | 控制读操作交接的测试验证合并/并发写入/失败保留旧数据；UI 验证真实刷新后完成标识。未用固定转圈时间或假延迟；未移除显式刷新，因为任意外部写入并无持续观察保证 |
| 4. 任务排版与右下角添加 | 完成 | `Views.swift`、`AddTaskButton.swift`、`ContentView.swift`：前置完成圈、分层元数据、统一边距、窄布局回退、锚定内容视口的主按钮；与 Cmd-N 共用流程 | 实际宽窗截图、520×768 窄窗检查；底部显式留白 88pt。滚到底时最后一行 y=699.55、底部=738.05，按钮顶部=822.75，无遮挡。完整焦点/深浅主题/动态字体人工矩阵未验证 |
| 5. 稳定排序 | 完成 | `TaskRules.swift` 默认截止时间升序、nil 最后、创建时间升序、持久化 ID 最终裁决；其他排序保留主规则并稳定次序；持久化排序偏好 | 覆盖混合/无截止时间、相同时间戳、连续新增、重新读取、普通改名不移动。刷新保持筛选；新任务被筛选隐藏时显示保存提示。不改写历史创建时间，不用数组下标或临时 UUID 作为行 identity |
| 6. 删除流程统一 | 完成 | `TaskDeleteConfirmation.swift` 集中持久化目标 ID、锚点、错误与确认状态；行侧滑/右键/编辑详情接同一删除操作，保留软删除与提醒取消 | 原生编辑按钮锚定 popover 已真实截图；Cancel/Escape 路径不调用写操作，删除失败保留目标和错误；单元测试覆盖取消/失败/目标 ID，UI 测试覆盖确认流程。完整侧滑手势、VoiceOver 焦点恢复人工矩阵未验证 |
| 7. 课程时间网格 | 部分完成 | `TimetableGeometry.swift`、`TimetableGrid.swift`、`TimetableView.swift`：秒精度时间→坐标、动态范围、重叠分栏、短课真实高度与至少 44pt 点击区、横向滚动、纵向固定列头及独立时间轴 | 6 项几何测试通过；真实网格/重叠/窄窗截图；纵向滚动列头 y=250.4475 不变，课程 y 从 316.86 到 216.76。横向检查曾发现课程移动而标题未同步，已改用原生 `onGeometryChange` 全局坐标；修复后全量回归/构建通过，但主机锁屏使最终视觉复查未执行 |

网格按课程已保存的本地钟表时间绘制，并保留时区标识、日期生效与既有 CRUD/冲突规则；周视图仍是循环星期课程表，不新增日期导航、拖拽、轮换或数据库字段。早晚课程自动扩展时间范围。极短课程不虚增色块高度，完整信息可通过 tooltip、无障碍名称和编辑器取得。

## 有证据的代码优化

1. 将筛选/排序与课程列表投影缓存到 ViewModel，依赖变更时才重算；避免 SwiftUI 每次 body 求值重复排序。测试验证失效和持久化排序。
2. SQLite 任务列表读取移出主线程；沿用线程安全 Repository。合并重载，读期间发生写入时丢弃旧结果并重新读取；错误保留旧快照。退出时取消结果应用，测试等待读取与通知任务结束才释放临时数据库。
3. 集中删除状态和执行入口，移除旧中间 alert 与重复辅助实现；失败时任务仍可见。
4. 课程几何/分栏按输入快照计算，移除旧卡片课程表；水平滚动不重复进行课程分栏。
5. 实际 Debug 打包曾因嵌套 debug.dylib 的 ad-hoc Team ID 与 Hardened Runtime 不匹配而启动失败。打包增加 `ENABLE_DEBUG_DYLIB=NO` 生成常规可执行文件，未关闭 library validation 或 App Sandbox；后续 Debug/Release 启动成功。
6. 中英文键完整扫描发现三个缺口，已统一 `Add Task` tooltip 并补齐任务失效错误、来源链接文案。最终两种语言各 440 键，完整扫描通过。

测量限定：同一 Catalyst 单元测试中的 5,000 任务、50 次投影读取，缓存读取 0.000027333 秒，对照重新计算 0.192795375 秒（`catalyst-delivery.log` 的 `UI_PROJECTION_BENCHMARK`）。这是局部微基准，**不是整机 FPS、启动或用户感知性能结论**。组织数据读取、启动迁移及部分附件编辑协调仍有同步路径；本轮未作大范围架构重写，也不声称全部 I/O 已离开主线程。

## 自动验证

| 测试组 | 发现 | 执行 | 通过 | 失败 | 跳过 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Catalyst 单元 | 199 | 199 | 199 | 0 | 0 |
| iPadOS 单元 | 199 | 199 | 199 | 0 | 0 |
| iPad UI | 7 | 7 | 7 | 0 | 0 |
| Shared 回归 | 131 | 131 | 131 | 0 | 0 |
| Apple 脚本 | 6 | 6 | 6 | 0 | 0 |
| 平台执行次数合计 | 542 | 542 | 542 | 0 | 0 |

合计包含同一单元用例在不同平台的执行，不是 542 个独立业务用例。Swift 源码实际发现 199 个单元测试与 7 个 UI 测试；已有 6 个 UI 用例未删除。Shared 最后完整 discover 为 131 项，覆盖范围大于前序针对性运行的 66 项。

最终全量 Apple 测试为 `4626581`，之后 `9925878` 仅补两个资源键及统一 tooltip 大小写；该最终源码已重跑完整本地化检查、Shared/脚本测试并重建 Debug/Release。包的 build-info 明确记录测试对应提交，没有把更早基线结果冒充本轮验证。

- Xcode 27.0 beta，build `27A5228h`；SDK 27.0；主机 macOS 27.0 (`26A5425a`)、arm64。
- 显式 `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`。编译期 Swift macro 沙箱绕过只用于 beta 编译工具；产物 App Sandbox 保留。
- iPad Pro 11-inch (M5)，iOS Simulator 26.1 (`23B86`)，独立 UUID `78EEA8B5-6BC7-4CB9-AE4C-3046E85945A5`。通过自有脚本创建并真实 bootstatus 就绪，测试后已按所有权凭据关闭/删除。
- 最终 `catalyst-final-ui.xcresult`、`ipad-unit-final-ui.xcresult`、`ipad-ui-final-ui.xcresult` 及原始日志保存在证据目录。
- 对 67 个最终测试、打包及内部运行原始日志执行 SQLite 诊断检查，通过；没有过滤日志或忽略生命周期警告。系统 beta AX/ScreenTime 提示仍保留原文。
- Debug/Release 构建、LaunchServices 隔离启动、Schema v4 检查、ZIP 解压后严格验签、App Sandbox、DMG 结构检查通过。
- Apple 版本检查、本地化完整检查、`git diff --check`、源码冲突标记和修改范围检查通过。
- 根跨平台版本校验仍失败：根 `VERSION=2.1.0` 与基线 Apple `2.1.2` 不一致。属于已存在的协调依赖，未删除校验、未擅改其他平台版本。
- 早期真实失败日志保留：排序 4 项中 3 项失败、UI 父级 AX 标识覆盖子按钮、保存提示遮挡刷新完成标识，以及 Debug dyld 失败。均修改原因后重新运行，未靠重试或缩减覆盖隐藏。

## 正式数据保护与一次偏好隔离事故

所有应用运行使用随机、一次性的 `com.qianmuyan.assignmentapp.rcsmoke.*` 身份和独立容器；正式文件只做文件指纹读取，不建立正式 SQLite 连接。附件与数据库均使用合成夹具。

**数据库安全结果：**正式 `assignments.db`、`-wal`、`-shm`、附件、备份目录和其他受保护数据，自最初快照到最终快照的存在状态、大小、mtime_ns 和 SHA-256 一致。原本不存在的受保护数据库/sidecar 未被创建。

**不能声称所有偏好全程不变：**本轮初版 Catalyst 单元测试中，排序属性初始化触发持久化 observer，向正式偏好文件 `~/Library/Preferences/com.qianmuyan.assignmentapp.plist` 写入 `assignmentApp.taskSortOrder=due_date`。已在执行过程中告知用户。发现后改为只读属性包装器初始化，并让 XCTest 默认使用唯一隔离 preferences suite，补充隔离测试。

只移除了本轮引入的键，移除过程中其他键值与紧邻移除前的快照一致。**未能还原最初二进制序列化字节及 mtime，因此原始指纹未恢复；没有伪造时间戳。**

| 偏好文件时点 | 大小 | mtime_ns | SHA-256 |
| --- | ---: | ---: | --- |
| 最初 | 468 | 1786331288494819059 | `d965433dcde2091539d0fc0f4f250ff268c0e4ad33d8444179fab0fb58d55bed` |
| 意外写入后 | 513 | 1788938225171824070 | `e9c7ffd9e835e7fec9abf0735265a1150a27d88f59e5cd9b1eeeb264d421115d` |
| 移除自引入键后 | 见本地指纹 JSON | 保留实际修改时间 | `12a3575512749feb685536fa8f241d08e158c0d48a396a1ae47d057acfce67d1` |

修复后的独立基线→最终文件指纹**全部不变**。原始基线→最终的唯一变化仍是上述正式偏好文件。证据为 `preferences-incident.json`、`protected-before.json`、`protected-after-preference-repair.json`、`protected-final.json`、`protected-original-comparison.json`、`protected-final-retest.log`。私有偏好副本仅留本地，未提交。

## 截图与可复现步骤

以下链接均为该工作树内的本地证据；不将合成示例当作真实用户数据。截图保留原始 PNG，没有美化或拼造界面。

| 页面 | 修改前（d6e2a64f） | 修改后（4e03fd7） |
| --- | --- | --- |
| 全部任务 | [before/tasks.png](../../artifacts/apple-ui-optimization/before/tasks.png) | [delivery/tasks.png](../../artifacts/apple-ui-optimization/delivery/tasks.png) |
| 课程表 | [before/timetable.png](../../artifacts/apple-ui-optimization/before/timetable.png) | [delivery/timetable.png](../../artifacts/apple-ui-optimization/delivery/timetable.png) |
| 快速添加 | [before/quick-add.png](../../artifacts/apple-ui-optimization/before/quick-add.png) | [delivery/quick-add.png](../../artifacts/apple-ui-optimization/delivery/quick-add.png) |

其他证据：[列表底部留白](../../artifacts/apple-ui-optimization/delivery/tasks-bottom.png)、[520pt 课程表](../../artifacts/apple-ui-optimization/delivery/timetable-narrow.png)、[删除锚定 popover（3cc5cab 实现）](../../artifacts/apple-ui-optimization/after-first/delete-editor.png)。这些不是最终 `9925878` 全界面验收截图：在最后横向列头和文案修复后，系统 `IOConsoleLocked=Yes`，无法获取有效窗口/截图，未将截图失败或锁屏画面当作通过。

没有录制短视频，提供以下可复现步骤作为交付。需在**新的独立内部测试身份**中进行；不要启动正式身份包或拿正式数据库作夹具。不得将下列“待复查”步骤预填通过。

1. **标题与滚动：**进入全部任务，分别准备 0、2、30 条合成任务；向下滚动到中部、返回顶部并继续滚轮/触控板下拉。标题和工具栏应固定，行保留自然回弹。Cmd-F 展开搜索，Escape/外部关闭后标题恢复。真实普通滚轮位移已验证；持续手势与全矩阵待复查。
2. **刷新：**保留搜索/筛选，单击刷新或触发既有快捷入口；读取过程中重复请求应合并，结束显示实际刷新时间。隔离测试中注入读取失败，应保留旧任务并允许重试；新任务不符合筛选时显示已保存但被筛选隐藏。自动测试已验证异常/并发，不假造用户可见长加载时间。
3. **删除：**在合成任务行侧滑或右键选择删除；核对锚定确认里的任务名，Cancel/Escape 后数量不变。再次确认删除，目标按 ID 删除且成功后只显示轻量反馈；详情页使用同一流程。故障注入测试应保留任务和原因。原生编辑锚点截图及自动路径已有证据，完整手势/焦点矩阵待人工。
4. **时间轴最后复查（未执行）：**用最终包加载合成课程，缩到约 520pt，关闭侧栏浮层。纵向滚动时星期标题固定；连续水平滚动时星期标题应与课程块以相同 dx 移动，左侧时间刻度 x 不变。检查最早/最晚课、重叠和短课。旧实现错位截图已保留为缺陷证据，不作为最终通过证据。

## 最终内部包

最终源码 `99258784a04a83d22b62b706d980880d534e5378`；Apple 2.1.2 / build 2，Release，arm64，最低 macOS 14.0。只宣称 arm64，未构建或验证 Intel/Universal。**ad-hoc、未公证、仅内部测试，不是正式发布包。**

- [Release ZIP](../../artifacts/apple-ui-optimization/packages/release-ui-9925878/Assignment-App-2.1.2-Catalyst-Release-arm64.zip)
  - SHA-256：`e1e60f4ff0deebbb98e316d5296ac39f5748d1e662bec6189ad31ab589d9f1b4`
- [Release DMG](../../artifacts/apple-ui-optimization/packages/release-ui-9925878/Assignment-App-2.1.2-Catalyst-Release-arm64.dmg)
  - SHA-256：`cda4ac42cd5f15fc98693cf88ea2221b7592212d8dbaffe5089f4de1794c3112`
- [Release build-info](../../artifacts/apple-ui-optimization/packages/release-ui-9925878/build-info.txt)；同级 `.app` 与 `logs/` 保留。
- Debug 对照包与 build-info：`artifacts/apple-ui-optimization/packages/debug-ui-9925878/`。
- Release 身份：`com.qianmuyan.assignmentapp.rcsmoke.165fe358-3887-4614-96b4-fa7199e89567`。
- 实际隔离数据库为该身份容器下 `Data/Library/Application Support/AssignmentApp2/assignments.db`，运行日志明确输出路径并验证 Schema v4。
- 测试应用进程已停止、数据库句柄已检查释放；打包烟测数据按脚本清理。合成 UI 夹具容器和截图留作复查，不清理任何用户容器。随机身份包不得复用为正式发布或连续升级验收身份。

## 剩余条件与停止边界

- 第 7 项最终横向同步视觉复查：等待解锁 Mac 后重新启动最终隔离包。最终截图、中文/深色修复后的完整截图矩阵也未执行。
- VoiceOver 全流程、动态字体/对比度、降低透明度、Reduce Motion、键盘焦点、触控板连续回弹、中英文深浅主题与所有页面宽窄矩阵：仅保留既有系统支持并做局部开发验证，完整人工矩阵**未验证**。
- 系统通知横幅/冷启动、正式安装升级卸载、Alpha/Beta、Developer ID、公证、Gatekeeper、TestFlight、品牌素材：本轮**未执行**，不能用本地自动测试代替。
- 根版本同步需要跨平台协调；正式偏好文件的原始字节/mtime 未恢复，不能给出“所有受保护文件全程未变”的结论。
- 没有 push、合并 main、打 tag、创建 Release、上传公证或分发 TestFlight。交付后停止，不自动进入正式验收或下一版本。
