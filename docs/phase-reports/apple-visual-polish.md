# Apple 视觉升级：基线不一致核对报告

日期：2026-09-10。**本次未进行视觉升级源码修改。** 已完成最新主干定位、独立工作树、真实 iPadOS/Catalyst 构建与启动、按钮来源核对；确认版本不一致后，按用户要求停止。

用户的明确停止条件是：“如果运行中的应用存在右下角按钮，但当前源码没有，先核对安装包版本、Bundle ID、Git SHA 和当前分支。存在版本不一致时停止并报告，不能在错误版本里重复创建一个按钮。” 本报告记录的主干和对照包截图不是本次视觉升级的前后效果。

## 仓库与提交

- 仓库：`/Users/qianmuyan/Documents/GitHub/assignment-app`；远端 `https://github.com/qianmuyan001/assignment-app.git` 已 fetch。
- 基线：最新 `origin/main` 的 `8267cdb120f9c1ef5edec342498e132701eda009`。
- 新工作树：`/Users/qianmuyan/Documents/GitHub/assignment-app-apple-visual-polish`。
- 新分支：`qianmuyan001/apple-visual-polish`，直接从上述 `origin/main` 创建。
- 最终源码 SHA 与基线相同：`8267cdb120f9c1ef5edec342498e132701eda009`。本分支只增加本报告；报告提交的最终 SHA 与 clean 状态另记于本地 `artifacts/apple-visual-polish/final-git-state.json`，可通过 `git log -1 --format=%H` 取得。
- 保留原工作树与用户文件，没有 cherry-pick、合并或改变任何平台源码、版本、数据库规则。

## 实际按钮来源

| 核对项 | 最新主干构建 | 已有 UI 优化内部包 |
| --- | --- | --- |
| 源码 SHA | `8267cdb120f9c1ef5edec342498e132701eda009` | `99258784a04a83d22b62b706d980880d534e5378` |
| 来源分支 | `qianmuyan001/apple-visual-polish`，基于 origin/main | `qianmuyan001/apple-ui-optimization` |
| 实际包版本 / build | 2.1.0 / 1 | 2.1.2 / 2 |
| 右下角按钮 | 不存在 | 存在，AX ID 为 `add-task`，名称为 Add Task |
| 添加入口 | 顶部工具栏 plus、空状态中央 Quick Add | 内容区右下角浮动主按钮 |
| 一次性测试 Bundle ID | `com.qianmuyan.assignmentapp.rcsmoke.bd9d198a-1029-46f2-a4c5-d7037a6cb0c8` | `com.qianmuyan.assignmentapp.rcsmoke.3a7b5422-465a-4e5a-b947-8aea2180757a` |

主干 `native/apple/AssignmentApp2/ContentView.swift` 的 `.toolbar` 中是 Quick Add / New Task 的 plus；空状态中是中央按钮。主干不存在 `AddTaskButton.swift`。

实际右下角按钮属于未进入主干的优化分支：`native/apple/AssignmentApp2/AddTaskButton.swift` 定义 `AddTaskButton(isEnabled:action:)`，由该分支 `ContentView.swift` 的 `.safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0)` 调用。调用处确实是 `.padding(.horizontal, 20).padding(.vertical, 12)`；按钮内部还有 52pt 容器高度，不能把这两个 padding 值当成最终安全区实测边距。其当前样式为 `.borderedProminent`，并非本次要求的真实 Liquid Glass 浮动按钮。

为了核对来源，复制了上一轮 clean-SHA Release 内部包，分配新的 rcsmoke 身份后重新 ad-hoc 签名，只运行空白隔离数据库。签名会改变 Mach-O 签名区，因此另比较签名区之前的代码载荷 SHA-256，确认与原包一致；证据在 `prior-ui/identity.json`。未将该包冒充最新主干构建，也未启动正式身份的已安装应用。

**结论：本次“必须从最新主干开始”的要求，与需要修改的现有浮动按钮不在同一源码基线。停止新增或重复实现按钮。** 后续需先协调该 Apple UI 实现进入主干，或由用户明确调整本任务基线；本任务未擅自执行其中任一种操作。

## 技能与设计规则

操作前按文件分段完整读取了五个已安装 SKILL.md：`design-taste-frontend`、`apple-design`、`codebase-design`、`ecc:liquid-glass-design`、`swiftui-microinteractions`。最后一个虽未出现在初始技能目录列表中，但在 `/Users/qianmuyan/.codex/skills/swiftui-microinteractions/SKILL.md` 实际存在。复用审计、原生构建、隔离和窗口观察能力，没有安装第三方库。

后续实现的约束已经明确，但**本次尚未应用到产品**：

- 设计参数 6 / 4 / 4，系统字体与 SF Symbols，单一系统强调色；8pt 间距节奏，浮动控制圆形/胶囊，静态内容统一连续圆角与系统背景。
- 浮动按钮以单一语义 inset 定位在安全区；底部与 trailing 差值不超过 1pt。需要实际安全区 frame 测试，不能仅比较源码 padding。
- iOS/macCatalyst 26+ 使用真正的 `.glass` 或 `.glassEffect` 轻透明 tint；17–25 为 Material 与轻微语义色回退。普通任务行和大面积侧栏本体不套玻璃卡片。
- 短弹簧与立即按压反馈集中在深模块中，保持输入可中断；Reduce Motion 改用颜色/透明度反馈，Reduce Transparency 使用近不透明系统背景，Increase Contrast 增强边界与选择状态。
- 紧凑侧栏继续沿用既有 selection，稳定 Material 背景与外侧羽化，渐变不影响导航文字；避免第二套导航或无障碍状态。

## 已构建、已运行、未测试的区别

| 项目 | 本次结果 |
| --- | --- |
| iPadOS Debug 构建，最新主干 | 成功 |
| Catalyst Debug 构建，最新主干 | 成功 |
| iPadOS 独立模拟器安装与启动 | 成功，已截图 |
| Catalyst 独立内部身份启动 | 成功，已截图 |
| 已有浮动按钮包的真实窗口来源核对 | 完成，已截图；不是本次构建的新视觉效果 |
| Catalyst Release 新构建 | 未执行，基线不一致后停止 |
| Apple 全量单元 / iPad UI / 新增边距与侧栏测试 | 未执行；没有测试发现清单，执行数 0，不能标为通过或跳过 |
| 新搜索 / 简易专业模式回归 | 未执行 |
| 右下角安全区边距测量 | 未执行：当前主干无此按钮，对照包只做来源核对 |
| 中英文资源校验 | 未执行，没有资源改动 |
| git diff --check、修改范围与报告冲突标记检查 | 通过 |

工具：XcodeBuildMCP 未发现可调用能力，使用真实 `/Applications/Xcode-beta.app`，显式设置 `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`。Xcode 27.0 beta (`27A5228h`)，SDK 27.0，Catalyst arm64。Debug 构建使用 `ENABLE_DEBUG_DYLIB=NO` 以避免旧打包链的 ad-hoc debug dylib 问题，仅为构建参数，没有修改项目设置。

iPad 模拟器：iPad Pro 11-inch (M5)，iOS 26.1，独立 UUID `69090667-BD3A-49C1-B8DC-0DE875A6662A`。使用仓库脚本创建、真实 bootstatus 就绪，停止时按所有权凭据清理。Catalyst 截图由原生窗口工具取得，iPad 截图来自实际模拟器；最初终端截图权限路径失败没有计为成功证据，后续通过 CUA 得到真实窗口截图。

## 数据隔离证据

- 没有打开正式 Bundle ID 的 Mac 应用，没有读取正式数据库、WAL/SHM 内容、执行迁移或采集其 SHA 指纹。本任务遵循“不得访问”的限制，不把本轮结果说成正式文件前后指纹校验。
- 两个 Catalyst 应用的 Bundle ID 都是新生成的一次性 UUID，正式身份仅作为原始构建元数据读取；实际运行前已改为独立 rcsmoke 身份并加 App Sandbox。
- 主干现有 `AppleRuntimeIsolation.packagedDatabaseURL` 校验 Bundle ID UUID 与 `~/Library/Containers/<该身份>/Data`，不合法时在数据库连接前失败；此次没有依赖环境变量传递路径。
- 主干日志记录 `assignment_rc_database_path=.../Containers/com.qianmuyan.assignmentapp.rcsmoke.bd9d198a-1029-46f2-a4c5-d7037a6cb0c8/Data/Library/Application Support/AssignmentApp2/assignments.db`。
- 两个实际进程的 `lsof` 数据库、WAL/SHM 路径全部落在各自新容器中，只对这些隔离文件以只读 SQLite 连接查询 Schema，均为 v4。路径检查及原始打开文件列表在 `database-isolation.json`、各阶段 `open-files.txt`。这提供代码路径、沙箱与现场句柄证据，不冒充完整文件系统访问审计。
- iPad 使用新建模拟器和 `-assignmentApp.testDatabaseToken`，实际路径由日志记录在该模拟器 app 自己的临时目录中。
- 未导入真实任务、课程、附件或备份。停止时关闭任务拥有的测试进程并检查连接释放；Catalyst 空白测试容器保留，未删除任何用户容器。

## 真实截图

本地证据根目录：`artifacts/apple-visual-polish/`。

- [最新主干 Catalyst，修改前](../../artifacts/apple-visual-polish/baseline/catalyst.png)
- [最新主干 iPad 竖屏，修改前](../../artifacts/apple-visual-polish/baseline/ipad.png)
- [未合并 UI 分支的 Catalyst 包，按钮来源对照](../../artifacts/apple-visual-polish/prior-ui/catalyst.png)

**没有“修改后”截图**，因为在修改前基线核对阶段停止。520×800 窄窗、横屏、按钮近景、侧栏展开、深色、Reduce Transparency 和大字体的升级前后矩阵均未执行，不能用历史截图或静态 Mock 补齐。

## 改动与停止状态

本分支唯一提交文件为 `docs/phase-reports/apple-visual-polish.md`。Apple 源码、UI 测试、业务逻辑、Schema v4、迁移规则和版本号均未变；Windows/Web/Shared 未变。构建产物、截图、身份凭据与日志留在 ignored artifacts 中。

未实现本轮视觉升级，未执行正式验收，未 push、合并 main、打 tag、创建 Release 或公开分发。停止原因来自用户明确的基线不一致停止条件，不是技能要求额外审批。
