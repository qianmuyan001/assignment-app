# Apple / Mac Catalyst 2.1.2 开发与发布准备

日期：2026-09-08。**Mac 2.1.1 安全稳定性收口及 2.1.2 开发、自动自测和发布准备已完成；正式验收尚未执行。** 等待用户明确说“开始验收”。这不是 2.1.2 正式版已验收、已签名公证或已发布的结论。

## 1. 基线、提交与工作树

- 真实仓库：`/Users/qianmuyan/Documents/GitHub/assignment-app`；已核对远端 `https://github.com/qianmuyan001/assignment-app.git` 并 fetch 最新引用。
- 本轮主干基线：`a181e9ef706f5e254c1bd33c74f26f0be9f5bba5`。开始时 origin/main 未新增提交；此前安全修复**尚未进入主干**。
- 从最新 origin/main 新建 `qianmuyan001/apple-2.1.2-preparation`，快进带入安全分支至 `7086f6f06efd0db1dcf145c36f7106e29f8d5167`，该 SHA 是本轮新增开发的基线。既有修复没有重复实现。
- **最终实现及内部包源码 SHA：`bd3c637d2f0c7b9f23e88a9655e5788c5e266a4d`。** 单元/UI 测试与该提交的 Apple 源码相同。打包时 `source_tree_dirty=false`。
- 持久交付工作树：`/Users/qianmuyan/Documents/GitHub/assignment-app-apple-2.1.2-preparation`。开发构建在 `/private/tmp/assignment-app-apple-2.1.2-preparation` 完成，随后整棵独立 worktree 迁到上述目录；原日志中的构建路径因此保留临时路径，包哈希不变。
- 本报告随后作仅文档提交。完整**最终交付 SHA**、父提交与提交后 clean 状态见 [final-git-state.json](../../artifacts/apple-2.1.2-development/final-git-state.json)。也可用 `git log -1 --format=%H -- docs/phase-reports/apple-2.1.2-development.md` 解析报告最终提交；报告无法内嵌自身内容所决定的哈希。
- 最终 Git 工作树 clean；忽略的 `artifacts/` 保存本轮证据和合成数据库。没有提交真实用户数据库。原仓库 `.workbuddy/`、安全修复工作树和其他工作树均保留；本轮没有并行写入共用工作树。
- 修改限定 Apple 源码/测试/脚本、Apple workflow 和独立报告/发布文档。没有修改 Windows、Backend、Web、共享 Schema、跨平台业务规则、根 VERSION/README/CHANGELOG。Schema 仍为 v4。

## 2. 复用与新增

复用 `7086f6f` 之前已实现的：随机 rcsmoke 身份和 LaunchServices 数据隔离、测试目录生命周期作用域、SQLite statement/连接释放检查、系统 GMT → UTC 编辑器修正、独立 iPad 模拟器及原始日志门禁。历史 169/169、UI 6/6 仅作背景，本轮全部重新执行。

本轮新增：

1. 固定内部升级身份 `com.qianmuyan.assignmentapp.internal.upgrade`，与随机 smoke 身份分开；保留严格容器校验，并让拼错的保留身份直接失败。隔离数据库、附件、备份和偏好均不回退到正式数据。
2. 正式数据保护从 DB/sidecar/附件扩展到完整数据根（含备份/恢复文件）和正式偏好文件；只做原始文件读取和 SHA-256，不建立正式 SQLite 连接。
3. 通知中心适配层保持唯一 scheduler，完整操作跨 await 串行；同 ID、内容和触发时刻相同则不重新 add。权限撤销删除待调度请求，恢复权限/重启/激活后重新核对；完成、删除、禁用、过期的取消得到回归覆盖。原固定/相对提醒与截止日期变更计算继续复用仓库实现。
4. UIApplication launch delegate 提前安装通知代理，支持运行/冷启动响应进入统一队列。数据库成功加载且引导/现有编辑/警告关闭后才消费；缺失任务显示中英文提示，重复 delivery event 不重复定位。逻辑经单元测试验证；真实系统横幅和完整冷启动人工矩阵未执行。
5. 引导期间禁用后台 Command-N/F/R 等操作；搜索栏最小宽度由 190pt 调整为 120pt，减少窄窗口工具栏挤压。现有长文本、侧栏、搜索状态、最大字号和页面流程自动测试保留。520pt 桌面实际最小尺寸、VoiceOver 与人工矩阵未执行，未假定通过。
6. 主动复制的诊断摘要增加元数据字符约束、Git SHA/数据库 UUID 校验及精确输出结构校验，拒绝换行注入及伪造允许字段。未启用遥测或第三方崩溃上传。失败包仅能复制属于本次启动路径的崩溃报告。
7. Apple 独立 VERSION 2.1.2、BUILD_NUMBER 2，所有 Apple target 与 About/Apple CHANGELOG 一致。新增 Apple 元数据检查，原共享版本门禁原样保留，协调补丁单独存放。
8. 内部 packager 支持 Debug/Release 和 `.app + ZIP + DMG`；嵌套代码从内向外签名、严格验签、嵌入源码 SHA、记录真实构建元数据。新增 Developer ID/公证流程前置检查和显式操作入口；新增合成 v2+WAL、固定身份升级准备脚本。
9. Apple weekly workflow 复用完整 Apple CI，每周生成内部包及证据，不发布。增加脚本安全用例，保留现有 CI 失败信号与失败日志。

## 3. 本轮开发自测结果

环境：Xcode **27.0 / 27A5228h**，`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`，Swift 6.4，macOS **27.0 / 26A5425a**；macOS/iOS SDK 27.0。未发现可调用 XcodeBuildMCP，复用已有 iOS 调试技能与真实 Xcode 工具。构建使用既有 Swift 宏宿主兼容参数 `-Xfrontend -disable-sandbox`，不关闭产物 App Sandbox。

iPad 为本轮全新 **iPad Pro 11-inch M5 / iOS 26.1**，UDID `29E181D6-DCC7-4E22-80BA-B0660CC5AD74`，命名 `AssignmentApp-RC-81e44a0a-6c7e-4c81-8caa-4f8af9670fdc`。启动使用 bootstatus 真实就绪检查，UI 每例 UUID 数据库，禁用并行测试分发。测试完成后只关闭并删除本轮模拟器，ownership receipt 保留。

| 最终开发自测 | 发现 | 执行 | 通过 | 失败 | 跳过 |
| --- | ---: | ---: | ---: | ---: | ---: |
| iPadOS 全量单元（Debug） | 181 | 181 | 181 | 0 | 0 |
| iPad UI 全量冒烟（Debug） | 6 | 6 | 6 | 0 | 0 |
| Catalyst 全量单元（Debug，arm64） | 181 | 181 | 181 | 0 | 0 |
| Shared 相关合同/规则回归 | 66 | 66 | 66 | 0 | 0 |
| Apple 发布脚本安全测试 | 6 | 6 | 6 | 0 | 0 |
| 合计执行次数 | 440 | 440 | 440 | 0 | 0 |

源码实际发现 181 个 Swift Testing 入口、6 个 UI XCTest 入口；xcresult 汇总逐项核对。前导 XCTest 的 “Executed 0 tests”不是 Swift Testing 的数量。Shared 运行 v3 合同（含 v2 迁移）、v4 合同、学习规则三组，未改 Shared 源码。最初 pytest 工具不可用，改用仓库原生 unittest 运行相关 66 项，不把工具缺失算成通过结果。脚本测试覆盖缺失文件不创建、同大小/mtime 内容篡改、符号链接失败、合成 WAL、安装授权及公证独立授权。

证据均在 [artifacts/apple-2.1.2-development](../../artifacts/apple-2.1.2-development)：

- `test-counts.json`；`ipad-unit-summary.json`、`ipad-ui-summary.json`、`catalyst-unit-summary.json`。
- `ipad-unit-final.log/.xcresult`、`ipad-ui.log/.xcresult`、`catalyst-unit-final.log/.xcresult`。UI 六例包含 GMT 课程保存、首次引导、任务/学习/备份/About、侧栏/搜索、最大字体。
- `shared-tests.log`、`script-tests.log`。迁移失败回滚、v2/v3 → v4、WAL/并发备份、备份往返/附件损坏和恢复已由完整 Apple 与相关 Shared 套件覆盖；安装升级的人工演练仍未执行。
- `catalyst-debug-final.log`：最终源码独立 Debug build 成功。`release-package.log`：最终 clean Release build 成功。
- `sqlite-final-gate.json`：扫描所有本轮单元/UI 原始日志和内部启动 stdout/stderr，**SQLite 生命周期/API violation findings=0**。没有过滤日志或隐藏警告。
- `localization.json`：en **423** / zh-Hans **423**，键集合完全相同且无重复；资源文件存在，plutil 校验通过。`static-checks.json`：源码冲突标记 0、资源缺失 0。Git diff 格式检查通过。

Xcode beta 的系统服务/元数据提示保留在原始日志，未将其过滤成“完全没有任何日志警告”。没有测试失败或编译错误被忽略；初始提交格式检查发现补丁空白行后已修复。

## 4. 正式用户数据保护

开始前 `protected-before.json`，结束后 `protected-after.json`，`protected-final-comparison.log` 为 `protected_data_unchanged=true`。正式容器与历史 Application Support 均比较存在状态、大小、mtime_ns 和 SHA-256；目录递归检查包含附件、备份、恢复文件。原本不存在的受保护文件仍不存在。

正式容器根为 `~/Library/Containers/com.qianmuyan.assignmentapp/Data/Library/Application Support/AssignmentApp2`，本轮实测：

| 文件 | 前后存在 | 大小 | mtime_ns（前后相同） | SHA-256（前后相同） |
| --- | --- | ---: | --- | --- |
| assignments.db | 是 | 245760 | 1788429834724653826 | `e9a3853fa4ab56716c433e19f677fbfd149e1046549fa7a3dcf22a18990c1bce` |
| assignments.db-wal | 是 | 0 | 1788429834725932452 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| assignments.db-shm | 是 | 32768 | 1788766279344307836 | `fd4c9fda9cd3f9ae7c962b0ddf37232294d55580e1aa165aa06129b8549389eb` |

历史根三文件、完整目录及偏好的详细记录保留在 JSON，没有读取或复制任务内容进入报告。保护脚本只读文件；只有已确认的隔离数据库才交给 sqlite3。

## 5. 真实内部产物与启动

产物目录：[release-dev-212-bd3c637](../../artifacts/apple/release-dev-212-bd3c637)。包含 `.app`、ZIP、DMG 和 [build-info.txt](../../artifacts/apple/release-dev-212-bd3c637/build-info.txt)。目录迁移仅改变位置，原始 build-info 中构建路径保留不改。

- 实际版本 **2.1.2 / build 2**，Release，arm64，声明最低 macOS 14.0 / iPadOS 17.0；最低系统和 Intel/Universal 未做实机验证，不宣称支持验证通过。
- 实际包 ID：`com.qianmuyan.assignmentapp.rcsmoke.9980987a-6379-404b-bc97-17e712a7fe81`。
- **ad-hoc、未公证、内部测试包，不能称为正式发布包。** 签名 flags 包含 adhoc/runtime，Sandbox=true，TeamIdentifier 未设置，未做 Developer ID 时间戳。正式身份签名流程未执行。
- LaunchServices 真实启动 PID 13016，stderr 的 `assignment_rc_database_path` 与 lsof 路径完全一致：`~/Library/Containers/com.qianmuyan.assignmentapp.rcsmoke.9980987a-6379-404b-bc97-17e712a7fe81/Data/Library/Application Support/AssignmentApp2/assignments.db`。
- Schema v4、quick_check=ok、外键错误 0、合法数据库 identity 1、11 表/22 assignments 列/38 合同索引/14 触发器通过。随后本次进程退出，句柄释放后清理其临时数据；隔离 DB 证据保留于包日志。
- ZIP 完整性、无 AppleDouble、解压后严格签名和 Sandbox 验证通过。DMG checksum 通过，并只读挂载验证包内版本和严格签名后卸载；未安装 DMG，未执行安装人工验收。Release 主程序未残留 LLVM coverage 插桩。

| 产物 | SHA-256 |
| --- | --- |
| `Assignment-App-2.1.2-Catalyst-Release-arm64.zip` | `9597fc31701c685278614952464580948feb1872bfbc30bee6e1b26fc912b301` |
| `Assignment-App-2.1.2-Catalyst-Release-arm64.dmg` | `8b89dee574cdf0886dcc7dae173ec8cb9a7b937da36cd33f1d88062511837fc7` |

## 6. CI、协调与未执行项

此前远端 Apple run `33792555908` 的 UI 失败是 GMT 被编辑器当作非法 IANA 时区，6 例中 1 例保存失败；后续诊断超时是次要症状。继承修复保留此真实回归，本轮 UI 对应场景再次通过。专属模拟器、就绪检查、GMT、全量单元/UI、Debug/Release、SQLite 原日志检查及失败证据继续保留。

**Apple 本地等价自测通过，线上 CI 待运行。** 没有 push 工作流，不能报告线上绿色。原跨平台版本检查当前真实失败，详见 `shared-version-dependency.log`；[待协调补丁](../release/patches/platform-version-contract.patch) 未应用，`git apply --check --unidiff-zero` 已验证适用。该门禁必须在主干集成前协调解决。

外部条件：

- 真实通知横幅、完整冷启动矩阵、桌面 520pt/宽窗口/无障碍人工矩阵、独立冻结候选验收、安装/升级/卸载/重装：**未执行**。
- Developer ID 签名、公证/stapling/Gatekeeper：**未执行**。只读 preflight 当前 0 个有效签名身份，未导出私钥、改证书信任或上传产物。脚本完成语法/安全前置检查，账号分支尚未端到端执行。
- Team Spirit：未提供授权素材；只发现无关 Team Falcons 文件，未使用，保留现有图标。品牌图标需求**未完成**。
- Alpha 人工及真实用户 Beta、TestFlight：**未执行**。
- push、合并 main、tag、创建 Release、公证上传、TestFlight 分发：**均未执行**，仍需单独明确授权。

交付 [正式验收手册](../release/apple-2.1.2-acceptance.md) 与 [发布 runbook](../release/apple-2.1.2-release-runbook.md)，含安装升级、回滚、缺陷分级、阻断条件、主动诊断和反馈模板。验收表全部保留“未执行”。本阶段停止，等待“开始验收”。
