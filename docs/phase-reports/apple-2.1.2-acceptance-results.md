# Apple 2.1.2 独立验收结果（可独立执行部分）

日期：2026-09-08。用户已授权“开始验收”，随后要求“先完成可独立执行的部分”。

**结论：独立自动测试、隔离真实启动、内部覆盖升级与删除重装、正式数据保护通过；完整正式验收尚未通过。** 共享版本门禁失败、签名账号条件缺失及人工矩阵未执行仍阻断正式分发。本轮没有修改冻结候选的应用源码，也没有发布。

## 冻结候选与工作树

- 冻结交付 SHA：`d8407fc9d3adfb72efff133255e3e79076ab38e1`；tree：`787b1cd6750ddd391bf6b1b6430368277191cf54`。
- 开发实现 SHA：`bd3c637d2f0c7b9f23e88a9655e5788c5e266a4d`；冻结交付的后续变更仅为文档。本轮全部新测试和新包基于 d8407fc，历史测试没有计入本轮。
- 验收开始时获取的 `origin/main`：`8267cdb120f9c1ef5edec342498e132701eda009`。原安全收口提交 `7086f6f06efd0db1dcf145c36f7106e29f8d5167` 现在已进入主干。相对该旧提交，主干 Apple 差异为工作流增加共享 Web 产物处理；未将并行平台改动合入冻结候选。
- 独立分支：`qianmuyan001/apple-2.1.2-acceptance`。执行工作树：`/private/tmp/assignment-app-apple-2.1.2-acceptance`；交付保存到 `/Users/qianmuyan/Documents/GitHub/assignment-app-apple-2.1.2-acceptance`。原始日志保留执行时路径。
- 开始及打包时 tracked/untracked 工作树状态为空；构建缓存 `/private/tmp/apple212-acceptance-derived` 专属本轮。应用源码持续冻结。最终提交仅更新本报告和验收手册；最终完整 SHA/clean 状态记在本地证据 `final-git-state.json`。可用 `git log -1 --format=%H -- docs/phase-reports/apple-2.1.2-acceptance-results.md` 查得报告提交，避免文档自引用 SHA。
- 原开发工作树、用户未跟踪文件及其他任务工作树未改动。旧版演练另用 `/private/tmp/assignment-app-apple-212-upgrade-old`，仅加入本候选的内部身份隔离兼容补丁，补丁原文已保存。

## 环境与真实测试数量

XcodeBuildMCP 在本轮工具中不可用，使用真实 Xcode：`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`；Xcode 27.0 (`27A5228h`)、Swift 6.4、SDK 27.0。主机 MacBook Air arm64，macOS 27.0 (`26A5425a`)。这是 beta 工具链及系统，不能外推已覆盖最低支持系统。

本轮新建 iPad Pro 11-inch (M5) 模拟器，iOS 26.1 (`23B86`)，UDID `B1277849-022A-4AE0-9FCB-F0C147135A7E`。经 bootstatus 实际就绪后运行，结束已删除该专属模拟器。禁用并行测试；没有以重试、忽略失败或删除测试变绿。编译参数及完整顺序见 `harness/apple212_acceptance_tests.py`；本地宏插件环境使用 `-Xfrontend -disable-sandbox`，应用自身 App Sandbox 仍独立验证为 true。

| 测试组 | 发现 | 执行 | 通过 | 失败 | 跳过 | 本轮证据 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| iPadOS 全量单元 / Debug | 181 | 181 | 181 | 0 | 0 | ipad-unit.xcresult、ipad-unit.log |
| iPad 全量 UI / Debug | 6 | 6 | 6 | 0 | 0 | ipad-ui.xcresult、ipad-ui.log |
| Catalyst 全量单元 / Debug arm64 | 181 | 181 | 181 | 0 | 0 | catalyst-unit.xcresult、catalyst-unit.log |
| Shared v3/v4 合约及学习规则 | 66 | 66 | 66 | 0 | 0 | shared.log |
| Apple 发布脚本安全测试 | 6 | 6 | 6 | 0 | 0 | release-safety.log |
| 合计（跨平台执行次数） | 440 | 440 | 440 | 0 | 0 | test-counts.json、source-discovery.json |

181 个 Swift Testing 声明、6 个 XCTest UI 方法与 xcresult 实际数字一致；Shared 与脚本使用完整指定套件发现/执行。iPad UI 包括 GMT 课程保存回归。单元测试包含通知调度/路由、数据库迁移、失败恢复和备份数据库/附件往返。

- Catalyst Debug 和 Release arm64 均重新构建成功。
- ZIP 解压后严格深度验签、包结构检查通过；DMG 校验和及只读挂载后的包内版本、严格验签、Sandbox 通过。未把 DMG 安装/Gatekeeper 正式验收填为通过。
- 27 份原始测试和内部应用 stdout/stderr 日志均经 SQLite 诊断门禁，无 integrity API violation、vnode unlinked、未关闭连接或数据库被占用等目标警告。`sqlite-final-gate.json` 保留输入日志字节数及 SHA。系统字体/TSM 等 beta 系统日志原样保留，未过滤警告。
- 中英文资源各 423 键，集合一致；Apple 独立版本校验 2.1.2/build 2 通过；源码冲突标记扫描及 `git diff --check` 通过。
- **共享根版本检查失败**：根 `VERSION=2.1.0` 与 Apple 2.1.2 不一致，退出码 1。现有 `docs/release/patches/platform-version-contract.patch` 仍是待协调补丁，未擅自修改 Windows/Web 版本或删除检查。线上 Apple CI 未运行；本地等价检查通过，线上 CI 等待获准推送后运行（共享版本门禁需先协调）。

## 正式用户数据保护

`protected-before.json` 在本轮应用启动和测试前生成，`protected-final.json` 在全部内部进程退出且无数据库/附件句柄后生成。正式路径仅用普通文件读取生成指纹，没有建立 SQLite 连接。两份内容完全相同，涵盖正式沙箱和历史非沙箱路径、数据库/sidecar、附件树、备份、未来新增文件和偏好。不存在的路径仍不存在，目录元数据和子项也相同。中途检查同样通过；未通过恢复文件或时间戳掩盖变化。

下表记录主数据库及 sidecar 的前后共同值。完整目录和偏好证据保留本地，避免将私人路径/备份清单写入 Git。

| 位置 | 文件 | 存在 | 大小 bytes | mtime_ns | SHA-256（前后相同） |
| --- | --- | --- | ---: | --- | --- |
| 历史非沙箱 | assignments.db | 是 | 245760 | 1788169951465757769 | `035467f85d845e0c9b67355b0756e9fefe15f53c97b102a67f5b1ea75f4baead` |
| 历史非沙箱 | assignments.db-shm | 是 | 32768 | 1788430427384922245 | `fd4c9fda9cd3f9ae7c962b0ddf37232294d55580e1aa165aa06129b8549389eb` |
| 历史非沙箱 | assignments.db-wal | 是 | 0 | 1788169951466426395 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| 正式沙箱 | assignments.db | 是 | 245760 | 1788429834724653826 | `e9a3853fa4ab56716c433e19f677fbfd149e1046549fa7a3dcf22a18990c1bce` |
| 正式沙箱 | assignments.db-shm | 是 | 32768 | 1788766279344307836 | `fd4c9fda9cd3f9ae7c962b0ddf37232294d55580e1aa165aa06129b8549389eb` |
| 正式沙箱 | assignments.db-wal | 是 | 0 | 1788429834725932452 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

## 真实启动、升级及故障恢复

随机冒烟 ID：`com.qianmuyan.assignmentapp.rcsmoke.7442fdc7-3854-4cab-84a9-eb8d74461ef6`，仅用于一次性启动。LaunchServices 真正启动应用，lsof 证实实际打开的路径为该 ID 的独立容器：`~/Library/Containers/<该 rcsmoke ID>/Data/Library/Application Support/AssignmentApp2/assignments.db`。Schema v4、quick_check、外键、11 表、22 个任务字段、38 索引、14 触发器均通过，进程随后退出，隔离数据按脚本清理。完整实际绝对路径见 `logs/catalyst-launch-smoke.log`。

连续演练使用固定内部身份 `com.qianmuyan.assignmentapp.internal.upgrade`，安装位置 `~/Applications/Assignment Upgrade Internal.app`；实际数据为 `~/Library/Containers/com.qianmuyan.assignmentapp.internal.upgrade/Data/Library/Application Support/AssignmentApp2/assignments.db`。所有演练 SQL 只指向合成数据容器，旧进程退出并确认无句柄后才替换数据或应用。

| 独立操作 | 结果与范围 | 证据 |
| --- | --- | --- |
| 空内部容器启动 | 旧版 2.1.0/build 1 实际安装、首次启动及引导；新 2.1.2 随机空容器启动通过。完整 2.1.2 首次引导人工矩阵未执行 | old-210-*、新包 smoke |
| 旧版覆盖新版本 | 旧版基于 7086f6f，仅回移稳定内部身份隔离代码；2.1.0 和 2.1.2 均实际加载并显示同一长中英任务，同 ID/容器覆盖通过 | old-210-isolation-only.patch、valid-old2-*、upgrade-verdict.json |
| 数据逐字段保留 | 比较所有表所有字段及附件实际字节 SHA。任务描述、截止/完成时间、课程/项目/标签/子任务关系和附件相同；夹具未含考试/课程安排/提醒行，不能扩称这些非空关系已实际升级验证 | valid-upgrade-before/after.json |
| v2 + 已提交 WAL → v4 | 合成 v2 的非空 WAL 经 prepare/seed receipt 验证，实际候选迁移后任务可见、逻辑内容保留、quick_check/外键通过，并留下迁移备份 | synthetic-v2-wal、wal-migration-* |
| v3 → v4 | 本轮 Repository/Shared 自动回归通过；独立安装环境中的 v3 旧应用升级人工场景未执行 | 全量单元及 shared.log |
| 故障迁移 | 合成 v2 非法空 course_name，应用明确展示错误。事务回滚，原逻辑数据仍是 v2 且完全相同，迁移备份保留 | fault-before/after.json、fault-ui.txt、fault-verdict.json |
| 故障后恢复可用 | 退出故障应用，恢复演练前保留的完整有效 v4 数据目录，候选真实显示原任务且全部字段/附件相同。此项验证已知良好目录恢复；不声称实际执行了 UI 导入故障迁移备份 | restored-ui.txt、restored-v4.json |
| 实际删除 app 后重装 | 先压缩留存并删除本轮拥有的安装 app 及旧版 app 副本，测试容器不删除；重装 2.1.2 后任务可见，所有数据/附件相同，图标侧栏偏好保留 | removed-internal-apps、physical-reinstall-verdict.json、physical-reinstall-data.json |

演练夹具构建过程有两次错误：审计时间不合规、课程 normalized_name 未规范化。应用正确拒绝打开；早期仅凭逻辑快照相同作出的“升级通过”口头判断已撤回。修正合成夹具并验证语义后，重新完成旧版和新版真实加载，只有 `valid-*` 证据计入通过。重装验证辅助断言还曾误查不存在的 `Acceptance212` 无空格标题，改按界面已有的实际中文长标题核对；没有改动应用或隐藏失败。旧日志和拒绝界面截图保留，`candidate-narrow.png` 是错误夹具警告，不能当作正常窄窗口证据。

所有内部应用最终已停止，无数据库/附件句柄；固定内部安装包和有效合成数据保留供后续人工检查。故障 v2、已迁移 v2 目录另外保留，不含真实用户数据。删除应用与删除容器是独立操作，本轮没有清空正式数据或把卸载当作删数据。

## 实际桌面观察的边界

- 有效候选任务页面实际窗口达到 **520×768 pt**，长中英标题换行，主控件可见；已查看隔离窗口截图 `candidate-loaded-narrow.png`。宽窗口设为 **1100×800 pt**。这只覆盖该页面及操作，尚未完成全部页面、中英文、多窗口和最低尺寸系统矩阵。
- 通过系统辅助功能操作了搜索展开/输入/Escape、Command-F/关闭、侧栏图标模式、设置页。重装后图标侧栏偏好仍存在。完整焦点/标题恢复/Command-N/R/Tab 顺序矩阵未逐项证实，保留未执行。
- 点击内部应用“Allow Notifications”后，设置页实际显示 `System notifications, Allowed`。仅确认此次授权反馈；未观察系统通知横幅、声音或通知点击/冷启动定位。
- VoiceOver、动态字体、对比度、Reduce Motion 全矩阵及 Alpha/学生 Beta 未执行。用户明确先完成独立部分，本轮不把自动操作替代这些人工结果。

## 新产物

交付目录：`artifacts/apple/release-acceptance-d8407fc/`（随本独立工作树保存在 Documents）。

| 属性 | 实际值 |
| --- | --- |
| 源码 / 工作树 | d8407fc9d3adfb72efff133255e3e79076ab38e1 / 打包时 clean |
| 版本 / build / Schema | 2.1.2 / 2 / v4 |
| 配置 / 架构 | Release / arm64；未声明 Intel 或 Universal 已验证 |
| 最低系统 / SDK | macOS 14.0 / SDK 27.0；最低系统未实机覆盖 |
| Bundle ID | 本次随机 rcsmoke ID，仅供隔离内部测试 |
| 签名 / Sandbox | ad-hoc / true；严格验签通过，runtime flags 见签名日志 |
| 公证 / 正式发布 | 未公证；不是正式发布包；正式稳定身份分发未执行 |

- ZIP：`Assignment-App-2.1.2-Catalyst-Release-arm64.zip`，SHA-256 `03237484db270f9b34be3c41619a9b19ded7383405d6179f496ad6b28047def2`。
- DMG：`Assignment-App-2.1.2-Catalyst-Release-arm64.dmg`，SHA-256 `ccc5257f1275b918a60d7d58828144fa1f04b0ccd90824b2b4e60989a3e6a744`。
- `build-info.txt` 保存源码、dirty 状态、版本、工具链、架构、路径和测试信息。打包器的 `formal_acceptance=not-executed` 与 DMG 安装状态是打包时的保守记录，未篡改原产物元数据；本报告补充后续独立检查，完整正式验收仍未通过。

所有原始日志、xcresult、指纹、合成夹具、演练辅助脚本与截图保存在 `artifacts/apple-2.1.2-acceptance/`，不提交私人路径清单或二进制到 Git。`evidence-manifest.json` 提供证据文件 SHA，`final-git-state.json` 记录报告提交与最终工作树状态。

## 阻断、待执行及下一步

1. **版本协调阻断**：审阅已有平台版本协调补丁，由平台负责人确认独立版本策略，应用协调变更后重新执行根版本门禁。不得仅重命名产物。
2. **正式分发条件不足**：本机只读检查 `0 valid identities found`。需可用 Developer ID Application/适用 provisioning 与账号条件，按 release runbook 本地签名验证；公证上传仍须单独明确授权。正式身份、时间戳、公证、stapling、最终 Gatekeeper 全部未执行。
3. **人工待验**：在已安装的固定内部应用使用合成数据，先执行手册通知横幅与退出后点击定位，再完成宽窄窗口/语言/键盘/无障碍矩阵；填写真实时间及观察结果。用户目前未参与，不预填通过。
4. **剩余安装矩阵**：补非空考试/课程安排关系的升级、独立 v3→v4、UI 导入迁移备份与最终签名 DMG 安装测试。已有单元测试和本轮内部安装证据保留，不能替代未覆盖场景。
5. **品牌及参与者**：等待授权 Team Spirit 图标素材；Alpha 指定参与者及真实学生 Beta 尚无执行证据。TestFlight 是单独流程，未执行。
6. **发布操作**：未 push、未合并 main、未 tag、未创建 Release、未公证上传、未 TestFlight 分发；线上 CI 等待授权后的真实运行。

后续如修改源码修复验收发现的问题，必须重新冻结候选，按影响面复测，并重做正式数据保护检查；本轮通过结论只适用于上述 SHA 和具体证据范围。
