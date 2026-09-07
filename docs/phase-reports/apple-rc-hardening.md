# Apple / macOS Catalyst RC 安全收口

验收日期：2026-09-07。结论：本阶段 Apple 本地必选门槛全部通过；正式用户数据库及 sidecar 前后完全不变，SQLite 生命周期警告为零，完整单元/UI 测试、Debug/Release 构建及隔离 LaunchServices 启动通过。**线上 CI 等待推送后验证。**

## 1. 基线、最终源码与边界

- 真实仓库：`/Users/qianmuyan/Documents/GitHub/assignment-app`，远端 `https://github.com/qianmuyan001/assignment-app.git`。
- 开始时已获取最新远端引用。`origin/main` 仍为 `a181e9ef706f5e254c1bd33c74f26f0be9f5bba5`，与用户给定整合提交相同，无新增提交需要另行审计。
- 基线 SHA：`a181e9ef706f5e254c1bd33c74f26f0be9f5bba5`。
- 独立工作树：`/Users/qianmuyan/Documents/GitHub/assignment-app-apple-rc-hardening`。
- 交付分支：`qianmuyan001/apple-rc-hardening`。
- **最终实现及打包源码 SHA：`ef85701553fdd15bf3f1f845acb62da94cf0ca74`。** 包内 `build-info.txt` 记录相同 SHA，`source_tree_dirty=false`。
- 本报告随后以仅文档提交落盘。最终交付提交的完整 SHA、父提交、分支和提交后工作树状态保存在 [final-git-state.json](../../artifacts/apple-rc-hardening/evidence/final-git-state.json)。报告不能内嵌自身提交哈希；可执行 `git log -1 --format=%H -- docs/phase-reports/apple-rc-hardening.md` 独立核对。
- 独立工作树在最终报告提交后核验为 clean；产物和证据保存在已被仓库忽略的 `artifacts/`，没有把测试数据库提交到 Git。
- 主工作树保持原有 `release/2.1`，其未跟踪 `.workbuddy/` 被保留。其他既有工作树及未跟踪文件未清理。两个修复子任务各有独立工作树，提交串行 cherry-pick 后统一执行验收，未共用写入工作树。
- 版本保持 **2.1.0 / build 1 / Schema v4**。未修改版本号、根 README、Windows、Web、backend；未开发 AI、MCP、同步或新产品功能。范围检查见 [scope-check.log](../../artifacts/apple-rc-hardening/evidence/scope-check.log)。

## 2. 修复内容与远端失败依据

### Catalyst 打包隔离

采用现有 macOS LaunchServices、`open`、`codesign`、`ditto` 和 SQLite 工具组合，无新增第三方运行依赖。实际交付 ZIP 内的 app 在签名前改用每次唯一的 `com.qianmuyan.assignmentapp.rcsmoke.<UUID>`，之后重新 ad-hoc 签名。Apple 的沙箱容器按 Bundle ID 分离，见 [App Sandbox 容器说明](https://developer.apple.com/documentation/security/migrating-your-app-s-files-to-its-app-sandbox-container)。

`AppleRuntimeIsolation` 在默认数据库解析最前面识别内部身份，严格检查 UUID 和实际沙箱主目录；异常直接停止，不能回落到正式数据库或 `ASSIGNMENT_DB_PATH`。附件、暂存、预览和备份从实际数据库父目录派生。此身份保留在 ZIP 内，因此以后 Finder 双击仍使用测试容器。

冒烟使用 `open -n` 加本次解压 app 的绝对路径，不通过环境变量传递数据库路径。先核对 Bundle ID、严格签名和 App Sandbox，再以 `lsof -Fn` 验证进程实际打开的路径；只有路径与本次容器精确匹配后，才运行 `sqlite3 -readonly`。正式容器和旧 Application Support 数据路径均属于禁止命中的进程文件路径。

打包在首次保护快照之后立即注册退出清理。逐个终止本次进程并确认退出，再检查数据库目录是否仍有文件句柄；检查错误或仍有占用时保留数据并失败，不能静默删除。默认构建目录也改为每次独立目录，拒绝不带 App Sandbox 的打包模式。

本报告替代旧 `apple-foundation-rc.md` 中使用正式数据库进行打包冒烟的结论；旧结论不作为本阶段隔离验收证据。

### SQLite 测试生命周期

将四个 SQLite 测试文件中的 **56 个临时数据库作用域**统一到 `withTemporarySQLiteDatabase`。测试闭包完整返回、Repository 释放、autoreleasepool 排空后，才删除目录。原始 SQLite 辅助连接检查未释放 statement 以及 `sqlite3_close` 结果；泄漏、关闭失败、删除失败都会记录测试失败。

保留原有测试断言及覆盖；新增 6 项运行隔离测试和 3 项 GMT 回归测试，单元测试从基线的 160 项增加到 169 项。UI 测试先终止 app 并确认 `.notRunning`，整套结束后关闭并删除本次专属模拟器。

### Apple CI 的实际失败原因

已读取 [远端 run 33792555908](https://github.com/qianmuyan001/assignment-app/actions/runs/33792555908) 的原始日志及 xcresult 附件。该 run 基于基线 SHA，使用 Xcode 27.0 `27A5252f`。UI 执行 6 项，5 通过、1 失败；Catalyst 测试和打包随后被跳过。

失败为 `testLearningScenesSmoke` 的“Saved meeting appears”。实际 UI hierarchy 显示保存弹出 **`Check the Meeting: Unrecognized IANA time zone: GMT.`**。远端系统时区为 GMT，编辑器直接把系统标识传给只接受 UTC 或标准 IANA 名称的存储校验，课程没有保存。之后的 600 秒诊断采集超时是次生问题，不是原始保存失败原因。证据见 [远端元数据](../../artifacts/apple-rc-hardening/evidence/remote-ci/run-metadata.json)、[失败 hierarchy](../../artifacts/apple-rc-hardening/evidence/remote-ci/learning-save-failure-hierarchy.txt) 和 [截图](../../artifacts/apple-rc-hardening/evidence/remote-ci/learning-meeting-editor-GMT.png)。

课程表与考试编辑器现在把系统提供的 GMT 规范化为 UTC；自定义 GMT、EST 或无效时区仍按原合同拒绝。UI 学习场景显式在 `TZ=GMT` 下重现远端条件，并验证保存结果。这里的 TZ 仅用于 XCTest 重现系统时区，数据库隔离使用 UUID 启动参数。

CI 创建有所有权凭证的全新 iPad 模拟器，使用 `bootstatus` 等待真实就绪；不擦除已有设备、不用固定长延迟、不中途减少覆盖、不重试掩盖失败。加入 Release 构建及原始 SQLite 日志门禁，保留 stdout、stderr 和失败诊断。**未推送，未运行新的线上 CI，不能把本地通过写成线上绿色。**

## 3. 工具链与完整测试结果

- 当前会话未暴露 XcodeBuildMCP，仓库没有对应的已跟踪 MCP 配置，采用真实 Xcode 原生工具回退。
- 每次显式设置 `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`；未修改全局 `xcode-select`。
- Xcode **27.0 / 27A5228h**；Apple Swift **6.4 / swiftlang-6.4.0.27.1**。
- 主机：Apple Silicon MacBook Air，macOS **27.0 / 26A5425a**。
- iPad：**iPad Pro 11-inch (M5)，iOS 26.1 / 23B86，arm64**。
- 模拟器 UDID：`6157CDAC-FD73-4466-BB4E-6A024974BC98`，名称 `AssignmentApp-RC-e0371fd7-6494-4024-86c4-b9dabccf594e`。本轮专属设备已关闭、删除，凭证见 [ipad-simulator.json](../../artifacts/apple-rc-hardening/evidence/ipad-simulator.json)。
- 三套测试配置均为 Debug；iPad 和 Catalyst 测试均明确关闭 Xcode 并行分发。Catalyst destination 为 `platform=macOS,arch=arm64,variant=Mac Catalyst`。
- 本地 Xcode beta 构建使用 `OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -disable-sandbox` 解决 Swift 宏编译器宿主沙箱兼容；该参数不关闭产物 App Sandbox，产物 entitlement 已独立验证。

| 最终验收轮次 | 发现 | 执行 | 通过 | 失败 | 跳过 |
| --- | ---: | ---: | ---: | ---: | ---: |
| iPadOS 全量单元测试 | 169 | 169 | 169 | 0 | 0 |
| iPad UI 全量冒烟 | 6 | 6 | 6 | 0 | 0 |
| Mac Catalyst 全量单元测试 | 169 | 169 | 169 | 0 | 0 |
| 合计（跨平台执行次数） | 344 | 344 | 344 | 0 | 0 |

数字由当前源码入口、Xcode 测试枚举及实际 xcresult 交叉核对，见 [test-counts.json](../../artifacts/apple-rc-hardening/evidence/test-counts.json)。Swift Testing 前的 XCTest “Executed 0 tests”前导信息不是 Swift Testing 的执行数量。

证据：

- [iPad 单元完整日志](../../artifacts/apple-rc-hardening/evidence/ipad-unit-final.log)、[xcresult 汇总](../../artifacts/apple-rc-hardening/evidence/ipad-unit-final-summary.json)、`evidence/ipad-unit-final.xcresult`。
- [iPad UI 完整日志](../../artifacts/apple-rc-hardening/evidence/ipad-ui.log)、[xcresult 汇总](../../artifacts/apple-rc-hardening/evidence/ipad-ui-summary.json)、`evidence/ipad-ui.xcresult`。
- [Catalyst 单元完整日志](../../artifacts/apple-rc-hardening/evidence/catalyst-unit.log)、[xcresult 汇总](../../artifacts/apple-rc-hardening/evidence/catalyst-unit-summary.json)、`evidence/catalyst-unit.xcresult`。
- iPad 最终测试源码为 `ceb02a01c32794d2e89309911ee34687e7901ca9`；Catalyst 测试及 Release 为 `31a887b5f443476c3ae87c4bd90479685c63d488`。这些提交至最终打包 SHA 的 app、单元、UI 源码差异为空；后续变动只有 CI、日志门禁及打包元数据，见 [源码等价检查](../../artifacts/apple-rc-hardening/evidence/tested-source-equivalence.log)。

开发中曾出现新测试闭包的 Swift 抛错推断编译错误，以及把模拟器规范路径 `/tmp` 硬比为 `/private/tmp` 的 1 项测试断言错误；均已修复。原始 `ipad-unit-initial.log/.xcresult` 和 `ipad-unit.log/.xcresult` 保留在 evidence，不作为最终通过轮次。最终三套 xcresult 均为 Passed、expectedFailures 为 0。

## 4. 构建、签名和静态门禁

| 验收项 | 结果与证据 |
| --- | --- |
| Catalyst Debug | 最终打包脚本执行 clean build，成功；`evidence/catalyst-package-final.log` |
| Catalyst Release | 成功；[完整日志](../../artifacts/apple-rc-hardening/evidence/catalyst-release.log)；`CODE_SIGNING_ALLOWED=NO`，仅构建，未启动这个正式 ID 的未签名产物 |
| LaunchServices 隔离启动 | 通过；实际进程打开本次独立容器数据库，随后退出；见下节 |
| ZIP 完整性 | `unzip -t` 通过，无 AppleDouble / Finder 元数据条目 |
| ZIP 解压后严格签名结构 | `codesign --verify --deep --strict` 通过，主程序及嵌套 dylib 均验证 |
| App Sandbox | 解压 app 的 `com.apple.security.app-sandbox=true` |
| 覆盖插桩残留 | 产物中未发现 LLVM profile / coverage 残留 |
| 中英文资源键 | en 422 / zh-Hans 422，差集为空；[资源检查](../../artifacts/apple-rc-hardening/evidence/localization-parity.json) |
| 版本同步 | `scripts/check_version_sync.py` 通过，全部仍为 2.1.0 |
| `git diff --check` | 通过 |
| 源码冲突标记 | Apple 源码及 Apple workflow 扫描通过，0 处 |
| SQLite 生命周期警告 | 最终三套完整测试日志及打包运行 stdout/stderr 检查通过，0 条；[原始日志门禁及 SHA-256](../../artifacts/apple-rc-hardening/evidence/sqlite-diagnostics-gate-final.json) |

日志保留了其他非失败的 Xcode/macOS beta 系统服务诊断；没有过滤或改写日志，也没有声称所有控制台诊断均消失。

Release 构建路径：`/private/tmp/assignment-apple-rc-hardening-derived/Build/Products/Release-maccatalyst/Assignment App.app`。最终 Debug 打包构建目录：`/private/tmp/assignment-apple-rc-hardening-package-derived`。两者都独立于主工作树及其他任务构建目录。

## 5. 正式数据保护与隔离数据库证据

首次验收前、iPad 后、Catalyst 后、每次打包前后及最终验收均执行只读文件指纹检查。指纹程序只读取文件字节计算哈希和文件元数据，不向正式数据库建立 SQLite 连接；对符号链接或检查期间发生变化的文件拒绝通过。

保护范围包含以下两个根目录的 `assignments.db`、`assignments.db-wal`、`assignments.db-shm`，以及 `attachments`、`.attachment-staging`、`.attachment-presentations`：

- 正式沙箱：`/Users/qianmuyan/Library/Containers/com.qianmuyan.assignmentapp/Data/Library/Application Support/AssignmentApp2`。
- 额外保护的旧目录：`/Users/qianmuyan/Library/Application Support/AssignmentApp2`。

下表每个值均在前后完全一致；mtime 采用纳秒精度。完整证据为 [protected-before.json](../../artifacts/apple-rc-hardening/evidence/protected-before.json) 与 [protected-final.json](../../artifacts/apple-rc-hardening/evidence/protected-final.json)。

| 位置 / 文件 | 前后存在 | 大小 bytes | mtime_ns（前后相同） | SHA-256（前后相同） |
| --- | --- | ---: | ---: | --- |
| 正式 / assignments.db | 是 / 是 | 245760 | 1788429834724653826 | `e9a3853fa4ab56716c433e19f677fbfd149e1046549fa7a3dcf22a18990c1bce` |
| 正式 / assignments.db-wal | 是 / 是 | 0 | 1788429834725932452 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| 正式 / assignments.db-shm | 是 / 是 | 32768 | 1788766279344307836 | `fd4c9fda9cd3f9ae7c962b0ddf37232294d55580e1aa165aa06129b8549389eb` |
| 旧目录 / assignments.db | 是 / 是 | 245760 | 1788169951465757769 | `035467f85d845e0c9b67355b0756e9fefe15f53c97b102a67f5b1ea75f4baead` |
| 旧目录 / assignments.db-wal | 是 / 是 | 0 | 1788169951466426395 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| 旧目录 / assignments.db-shm | 是 / 是 | 32768 | 1788430427384922245 | `fd4c9fda9cd3f9ae7c962b0ddf37232294d55580e1aa165aa06129b8549389eb` |

两个根目录的三个附件相关目录均为“不存在 → 不存在”，没有创建。所有保护路径均无大小、mtime 或哈希变化。

最终 ZIP 的内部身份：

```text
com.qianmuyan.assignmentapp.rcsmoke.405b2148-c3d9-4adb-8949-300a627533a6
```

本次进程实际使用的隔离数据库：

```text
/Users/qianmuyan/Library/Containers/com.qianmuyan.assignmentapp.rcsmoke.405b2148-c3d9-4adb-8949-300a627533a6/Data/Library/Application Support/AssignmentApp2/assignments.db
```

打包前该独立容器不存在。app stderr 的 `assignment_rc_database_path` 和 `lsof` 路径一致，冒烟日志记录真实进程 PID、路径、就绪时间及验证后仍存活的状态。Schema 检查通过：`user_version=4`、`quick_check=ok`、外键错误 0、合法身份行 1；11 张合同表（含数据库身份表）、22 个任务字段、38 个合同索引及 14 个触发器全部满足合同。

进程终止及句柄释放后，保留隔离数据库副本到包的 `logs/isolated-assignments.db*`，再次只读检查副本为合法 v4。原冒烟数据目录已删除，进程已退出。最终记录见 [acceptance.json](../../artifacts/apple-rc-hardening/evidence/acceptance.json)。另一轮独立 Bundle ID 的打包启动也已通过；最终轮次修正了打包时间戳与运行标识的区分，正式数据在两轮后均不变。

## 6. 最终内部测试包

**仅供内部测试：ad-hoc、未公证、不是正式发布包。**

- [最终 ZIP](../../artifacts/apple-rc-hardening/debug-rc-hardening-final-20260907-ef85701/Assignment-App-2.1.0-Catalyst-Debug-arm64.zip)
- 大小：**2,534,246 bytes**；2.1.0 / Debug / arm64 / Mac Catalyst。
- SHA-256：`7bb382c7175ec41c70af0cbe5d4c8b4f159fc04a4fa181cb7d1c71f71abf451e`。
- [SHA256SUMS](../../artifacts/apple-rc-hardening/debug-rc-hardening-final-20260907-ef85701/SHA256SUMS)、[build-info.txt](../../artifacts/apple-rc-hardening/debug-rc-hardening-final-20260907-ef85701/build-info.txt)。
- 验证日志在同目录 `logs/`：`archive-codesign-verify.log`、`archive-entitlements.plist`、`zip-verify.log`、`catalyst-launch-smoke.log`、`catalyst-open-files.log`、运行时 stdout/stderr、前后保护快照与比较结果。
- 所有本地证据根目录：`/Users/qianmuyan/Documents/GitHub/assignment-app-apple-rc-hardening/artifacts/apple-rc-hardening`。

## 7. 外部验收 runbook

以下项目本阶段均未标记通过。后续 GUI 验收继续使用本次隔离 ZIP，先确认设置页显示 `rcsmoke` 数据路径，不启动旧正式 ID 包。

| 外部项目 | 必要条件与可执行步骤 | 通过证据 |
| --- | --- | --- |
| 系统通知横幅真实送达 | 可见 macOS GUI；在隔离包内允许通知，在系统设置开启横幅、关闭专注模式。创建未完成测试任务，添加数分钟后触发的固定提醒，切到其他 app 等待实际投递。 | 横幅截图、通知中心条目、预定/实际触发时间和包 SHA。授权或调度 API 成功不等于横幅送达。 |
| Team Spirit 品牌图标 | 用户提供已授权官方 SVG 或至少 1024×1024 PNG 及来源许可；完成 AppIcon 外观资源后，在 iPad 主屏幕、Finder、Dock 实际检查。 | 授权来源、资源清单、各平台外观截图；不以无关、临摹或生成图代替官方素材。 |
| Developer ID 签名 | Apple Developer Program 团队权限、有效 Developer ID Application 证书和私钥；后续按明确提交重新归档签名，保留 Sandbox，配置 Hardened Runtime 与时间戳，解包严格验签。 | 证书/Team ID、签名及 entitlement 日志、提交 SHA、产物 SHA。当前 ad-hoc 包不满足此项。 |
| Apple 公证 | Developer ID 条件满足且另获上传授权后，用 Xcode 或 notarytool 提交；等待 Accepted，附加票据，验证票据/Gatekeeper，再生成最终 ZIP。 | 提交 ID、Accepted 结果、票据/Gatekeeper 日志及最终 SHA。参见 [Apple 公证文档](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。 |
| TestFlight | App Store Connect 应用记录、上传权限、匹配应用标识的分发配置；另获上传/分发授权后重新归档上传，等待处理与必要审核，再由测试者安装启动。 | 构建记录、测试组和 TestFlight 安装/启动证据。随机 rcsmoke 标识的 ad-hoc ZIP 不能直接用于 TestFlight。 |
| Catalyst 窄窗口人工交互 | GUI 内拖至约 520×800 并记录实际尺寸；系统若限制最小宽度则如实记录。切换中英文及明暗主题，检查导航、搜索、任务编辑、课程表、考试、设置，验证 Command-N/F、Escape 和表单滚动。 | 两种语言的实际窄窗截图、尺寸和逐项交互记录；iPad UI 自动测试不替代本项。人工拖拽不要求给终端授予 Accessibility 权限。 |

## 8. 发布操作边界

已实现 Apple 安全修复，已完成本地自动测试、真实隔离启动、内部包及报告交付。**未 push、未合并 main、未打 tag、未创建 Release、未执行 Developer ID 分发、公证或 TestFlight 上传。** 线上 Apple CI 保持“等待推送后验证”，后续发布操作需要用户另行明确授权。
