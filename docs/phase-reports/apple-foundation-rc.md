# Apple 基础功能补齐与 Release Candidate 收口报告

本报告覆盖 Assignment App 2.0 Apple 平台的「基础功能补齐与 RC 收口」阶段。
全部工作在独立 worktree
`/Users/qianmuyan/Documents/GitHub/assignment-app-apple-phase3a`、
分支 `qianmuyan001/apple-foundation-rc` 上完成。

## 0. 结论一览

| 项目 | 结果 |
| --- | --- |
| 中英双语（函数 1） | ✅ 通过（自动校验 + UI 实测） |
| 任务日历（函数 2） | ✅ 通过（Phase 3A 已交付，本阶段补齐 VoiceOver 日期标签缺键） |
| 备份/导出/预检/恢复（函数 3） | ✅ 通过（全部在临时数据上验证） |
| 首启引导 + 关于 + 更新日志（函数 4） | ✅ 通过（新增首次启动路径的端到端 UI 测试） |
| iPad 单元测试 | ✅ 160/160（19 个 suite） |
| iPad UI 冒烟 | ✅ 6/6 |
| Catalyst 构建（Debug + Release） | ✅ 均 BUILD SUCCEEDED |
| Catalyst 沙箱启动 | ✅ 通过（LaunchServices 路径，App Sandbox 全程启用） |
| Catalyst 主界面截图（宽窗口，中英） | ✅ 通过（`screencapture -l` 抓窗口） |
| Catalyst 单元测试 | ⛔ 未验证 / 需要用户条件（Xcode 27.0 beta 运行器缺陷） |
| Catalyst 窄窗口手工验收 | ⛔ 未验证 / 需要用户条件（Accessibility 权限） |
| 真实系统通知投递 | ⛔ 未验证 / 需要用户条件（授权对话框在无 GUI 权限环境下不返回） |
| Team Spirit 品牌图标 | ⛔ 未验证 / 需要用户条件（未找到授权资源） |
| 签名 / 公证 / TestFlight | 仅 ad-hoc；其余需用户授权 |

## 1. 源码实现（本阶段新增/修改）

基线 `b0d69f7`（Phase 3A Preview 收口）→ 本阶段 HEAD
`fa44fc71e55b42098b62a4ab8fad46a4838b99d3`（本轮收口），五个提交：

1. `9b066a2` — 本地化、引导可测性、Catalyst 测试签名（15 文件，+672/−21）
2. `776aa6a` — Catalyst 启动冒烟改走 LaunchServices（1 文件，+93/−18）
3. `e0dc935` — RC 报告初版（`docs/phase-reports/apple-foundation-rc.md`）
4. `5e0b561` — RC 报告更正（撤回无效「沙箱已排除」A/B 结论，重写证据链；
   同时新增 §10 受阻项 runbook 占位）
5. `fa44fc7`（本轮收口）— 补 Catalyst 中文主界面截图、`build-info.txt` Release
   摘要、SHA256 清单重生成、§6/§10/§11 报告更新

- 工作树：`/Users/qianmuyan/Documents/GitHub/assignment-app-apple-phase3a`
  （干净，仅两个按约定保留的未跟踪用户文件）

要点（均有代码注释说明动因）：

- **本地化缺口修复。** SwiftUI 只对字符串*字面量*走 `LocalizedStringKey`
  自动本地化；`String` 变量（三元 `navigationTitle`、`.help`、
  `.accessibilityLabel`）不会被翻译。修复 8 处 `navigationTitle` 与
  `NavigationChrome.toggleTitle`，全部改走 `L10n.tr()`。
- **补齐 5 个缺失目录键**（`Assignments`、`Use Icon-Only Sidebar`、
  `today`、`Export %@`、`Fires %@`），两份目录各 422 条。
- **新增 `scripts/check_apple_localization.py`**：校验两份目录键集一致、
  源码中 112 个 `L10n.tr` 键 + 166 个字面量键全部收录。
- **引导页可访问性标识符修复。** SwiftUI 会把容器上的
  `accessibilityIdentifier` 复制到它承载的每个控件上——原来 Skip、
  Next、页指示器、分页 CollectionView 全部顶着同一个标识符，各自真正的
  标识符被吞掉。解法：容器（`onboarding-sheet`、`onboarding-root`）上
  不再设标识符，只给控件命名。
- **新增 DEBUG-only 测试钩子 `-assignmentApp.uiTestResetOnboarding`。**
  `UserDefaults` 在长期存活的模拟器上跨 run 存活，完成过一次引导后
  首次启动路径永远无法再被测试；该钩子使 `testOnboardingWalkthroughSmoke`
  能以真实首启形态走完整流程。
- **UI 测试语言固定。** `-assignmentApp.uiTestLanguage:<rawValue>` 在
  `LanguagePreference.init` 中读取并**同时写入存储**（显示与存储必须一致），
  防止某个测试切到中文后泄漏到后续所有 suite。
- **Catalyst 测试目标补 ad-hoc 签名配置。**
  `CODE_SIGN_IDENTITY[sdk=macosx*] = "-"` 原本只在 app target 上有，
  测试目标缺它会在 macOS SDK 下报 "requires a development team"。
- **打包脚本修复（见 §5）。**

**用户文件按约定原样保留（未暂存、未提交、未修改）：**
`CONTEXT.md`、`native/apple/AssignmentApp2Tests/NotificationAuthorizationProbeTests.swift`。

## 2. 自动化测试（实际结果，无硬编码）

| 套件 | 结果 | 证据 |
| --- | --- | --- |
| shared Python | **86 passed + 18 subtests** | 本机 pytest 9.1.1 |
| backend Python | **20 passed** | 同上 |
| iPad 单元测试 | **160 passed / 0 failed**（19 suite 全 exit=0） | `logs/ipad-unit-suites.txt` |
| iPad UI 冒烟 | **6/6，144.1 秒，TEST SUCCEEDED** | `logs/ipad-ui-smoke.log` |
| Catalyst 单元测试 | ⛔ 未验证（见 §7） | `logs/catalyst-tests-hang.log` |
| `git diff --check` | 干净 | — |
| 版本同步 | OK（root/README/CHANGELOG/Apple/Windows = 2.0.0） | `scripts/check_version_sync.py` |
| 本地化校验 | OK（112 L10n + 166 字面量键；两目录各 422 条） | `scripts/check_apple_localization.py` |

**iPad 单元测试执行方式说明。** 整包一次跑会在随机位置卡死（两次观测：
第 151、150 个用例后，卡点不同，日志均断在半行——Xcode 27.0 beta 的
运行器缺陷，非用例问题）。因此按 suite 分批执行（每个 suite 一次
`xcodebuild -only-testing:`），19 个 suite 全部独立通过。
`BackupRestoreTests` 单独跑 3/3 通过（restoreRoundTrip /
failedRestoreRollsBack / restoreCreatesSafetyBackup）。

新增 UI 用例 `testOnboardingWalkthroughSmoke` 覆盖：首启引导打开
（Reset 钩子保证是首启形态而非从设置重开）、Skip 按钮存在、四页依次
翻页（welcome/privacy/modes/notifications）、每页截图、通知页提供
授权入口但**不点击**（拒绝授权不得阻断完成）、末页按钮为
Get Started、完成后引导消失、**重启后不再出现**（完成状态持久化）、
以及简体中文下的同一引导（标题「作业管理，不添噪音」、按钮「下一步」）。

## 3. iPad 构建与运行

- 模拟器：iPad Pro 11-inch (M4) `55D6D2F6-FB7A-429C-ADFA-8BF9F8F2286F`
  （UI 测试）与 iPad Pro 11-inch (M5)
  `DA03DABB-7E72-415D-8F99-E31BB5244B7E`（单元测试）。
- M4 不能跑单元测试的原因：设备克隆失败，CoreSimulator.log 显示设备
  数据目录内 Spotlight 索引（`index.spotlightV2`）权限错误 Code=513。
  未删除 `~/Library` 下任何内容，改用 M5。
- 34 张截图（含新增引导四页 + Skip + 中文版）位于 `screenshots/`。

## 4. Catalyst 构建

- Debug：`package-catalyst.sh` 内 `clean build`，**BUILD SUCCEEDED**，
  沙箱启用，ad-hoc 签名，ZIP 校验通过（无 AppleDouble）。
- Release：同一 HEAD `776aa6a` 独立构建，**BUILD SUCCEEDED**
  （`logs/catalyst-release-build2.log`），ad-hoc + 沙箱权利签名
  （`logs/codesign-release.log`、`logs/release-entitlements.plist`），
  LaunchServices 启动验证通过（`logs/catalyst-release-launch.log`）。
- Swift 宏插件服务器规避：`OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend
  -disable-sandbox` 仅禁用 Swift 编译器前端自身的沙箱，**不是**
  `ENABLE_APP_SANDBOX` 或权利变更；正式包的
  `com.apple.security.app-sandbox` 始终为 `true`。该规避已写入打包脚本
  使其可复现。

## 5. Catalyst 沙箱启动（原 `_libsecinit_appsandbox` 问题）

**根因定位（保留原始证据）：**

1. 直接 exec 沙箱化 Catalyst 二进制 → 在
   `_libsecinit_appsandbox.cold.9` 内 EXC_BREAKPOINT（SIGTRAP），
   签名 `SYSCALL_SET_USERLAND_PROFILE`。崩溃报告：
   `~/Library/Logs/DiagnosticReports/Assignment App-2026-09-04-011421.ips`
   （脚本自动拷贝至 `logs/catalyst-launch-crash.ips`）。
2. **同一二进制经 `open`（LaunchServices）启动完全正常**——用户态沙箱
   profile 由 LaunchServices 在进程映像加载前应用，shell 直接 exec 跳过
   了这一步。这是启动*方式*的问题，不是沙箱或应用的问题。
3. 2026-08-31 的旧打包产物当时以同样方式崩溃（`debug-20260831` 的
   crash log）——即这不是本阶段引入的回归，而是该问题首次被定位并修复。

**修复（不关闭沙箱）：** 打包脚本的启动冒烟改用 `open` 启动；数据库
验证改为经 `lsof` 确认**被启动进程自己持有打开**的数据库（比原先
`ASSIGNMENT_DB_PATH` 覆盖更强的主张——环境覆盖在 LaunchServices
启动下不可靠：`open --env` 观测到一次生效后对相同调用不再生效，
`launchctl setenv` 被权限拒绝）。两处附带修复：`lsof` NAME 列含空格
（`Application Support`）需保留整列而非 `awk '{print $NF}'`；契约索引
改为**超集**校验（经 v3→v4 迁移的库合法保留旧索引，缺契约索引才算缺陷）。

**最终证据（Debug 与 Release 均通过）：** 进程存活、lsof 显示持有沙箱
容器内 `assignments.db`、`user_version=4`、`quick_check=ok`、外键 0 错、
identity 1 行、表/列/触发器精确匹配、契约索引齐全
（`logs/catalyst-launch-smoke.log`、`logs/catalyst-release-launch.log`）。
沙箱容器数据库早于本次运行存在（v3→v4 迁移而来），故本冒烟证明的是
「打包应用打开合法 v4 库」；从零建库由单元套件（SchemaV3 与备份套件，
全部在临时路径上）覆盖。

## 6. 手工 UI 验收 / 中英文验收 / 备份恢复验收

- **UI 自动化覆盖（iPad 6/6）**：首启隔离数据库启动、侧栏与搜索状态、
  最大字号 + Reduce Motion 场景下的紧凑侧栏、学习场景冒烟、基础页面
  冒烟（引导跳过→日历→备份中心→创建备份→About→诊断复制→更新日志→
  切中文→验证导航标题与侧栏标签本地化→中文 About）。
- **备份/恢复验收（单元级，全部临时库 + 临时附件目录，从未触碰真实
  用户数据）**：备份创建（preflight 计数、manifest 完整性、内部一致性）、
  导出（重名不覆盖）、拒绝（损坏/校验和不符/未知格式）、恢复（往返
  一致、失败回滚、恢复前自动安全备份）。
- **Catalyst 主界面截图（补充本阶段收口）**：宽窗口 1024×768 已通过
  `screencapture -l <CGWindowID>` 直接捕获
  （`screenshots/catalyst-main-wide.png` 与 `catalyst-main-zh.png`，
  分别 2140×1628 高 DPI 视图，含侧栏展开、筛选器、空态、Quick Add
  完整可见）。窄窗口（≤600pt）的窗口级截图**仍然受阻**——
  `osascript` / AppleScript System Events 被 Accessibility 拒绝
  （-10004 privilege violation），无法程序化把窗口调窄；该环境
  亦无窗口手动操作权限，故仅有宽窗口素材。运行期功能（启动、显示
  偏好、本地化切换、沙箱链路、数据库 schema v4 验证）已由脚本化
  冒烟与 lsof 链路覆盖（§4、§5）。
- **Catalyst 窄窗口的手工交互验收**：⛔ 未能执行——本环境无 UI 自动化
  （屏幕录制已具备，但 Accessibility 拒绝 System Events）权限，
  AppleScript 不可用。

## 7. 未验证 / 需要用户条件（如实列出，不降低标准）

1. **Catalyst 单元测试**：构建修复（签名配置）后，运行器在建立连接前
   挂起，最终报 `The test runner hung before establishing connection.`
   证据链（原始日志均在 `logs/`）：
   - **宿主进程采样**（`sample`，见下）：测试宿主正常启动并停在自己的
     主 run loop（`App.main()` → `mach_msg`）—— 无崩溃、无
     `_libsecinit` 卡死；是 **XCTest 机制从未接管宿主**，测试 bundle
     没有被注入/连接。
   - **沙箱无法从测试宿主上移除**（三轮递进验证）：
     ① `ENABLE_APP_SANDBOX=NO` 无效——沙箱键写在 entitlements 文件里；
     ② 命令行 `CODE_SIGN_ENTITLEMENTS` 覆盖无效——SDK 作用域的项目
     设置优先；
     ③ **直接把 entitlements 文件换成无沙箱版**（换前确认 0 个沙箱
     键、测试后已恢复原文件并 `git diff` 验证一致），签出的宿主
     **仍带 `app-sandbox`**，连同 `get-task-allow` 与 testmanagerd 的
     mach-lookup 例外——**Xcode 27.0 beta 对 macOS/Catalyst 测试宿主
     强制注入沙箱**，项目层面无法绕过。
   - 结论：Xcode 27.0 beta 的 Catalyst 测试运行器缺陷（宿主可启动、
     可采样，但 XCTest 注入不发生）。本机未安装稳定版 Xcode；装上
     稳定版后重跑 `AssignmentApp2Tests` 即可闭环。诊断期间对仓库的
     临时改动（entitlements 文件）已恢复，`git diff` 为空。
2. **真实系统通知投递**：`UNUserNotificationCenter.requestAuthorization`
   在无法呈现权限对话框的环境下 continuation 不恢复，
   `NotificationAuthorizationProbeTests` 会挂住 Swift Testing runner。
   需要在有 GUI 交互条件的真机/本机上人工观察一次横幅。
3. **Team Spirit 品牌图标**：仓库内未找到用户提供的授权 SVG 或
   ≥1024×1024 透明 PNG（仅 `Team_Falcons_Logo.svg.webp`，非所需资源）。
   按约定未下载/描摹/伪造，沿用现有图标。提供资源后即可生成
   iPad + Catalyst AppIcon 并检查明暗/小尺寸/圆角。
4. **签名/公证/TestFlight/发布**：本机 `security find-identity` 0 个有效
   身份，产物为 **ad-hoc 本地测试包**。Developer ID 公证、TestFlight、
   公开发布均需用户明确授权后另行执行。
5. **Catalyst 宽窄窗口手工验收**：同 §6 末条。

## 8. Apple 与 Windows 差异（供后续集成）

`git rev-list --left-right --count origin/release/2.1...HEAD` →
`8  17`（release/2.1 有 8 个提交不在本分支；本分支有 17 个提交不在
release/2.1）。本阶段未触碰 Windows `release/2.1`。未来集成时需要
按此差异清单逐项核对（尤其：测试目标的 macOS ad-hoc 签名设置、
`package-catalyst.sh` 的 LaunchServices 冒烟、本地化目录新增的 5 键）。

## 9. 环境

- macOS 27.0 (26A5425a)，SIP 启用。
- Xcode 27.0 beta (27A5228h)——**本机唯一安装**，已如实记录；无稳定版。
- Apple Swift 6.4 (swiftlang-6.4.0.27.1)。
- 签名身份：0 个有效（ad-hoc）。

## 10. 分支 / 工作树 / 产物路径

- 分支：`qianmuyan001/apple-foundation-rc`（自
  `qianmuyan001/apple-phase3a-preview` @ `b0d69f7` 分出）
- HEAD：`b312d4f`（fa44fc7 + 1 次 SHA 自指修正；实质内容为 fa44fc7）
- 工作树：`/Users/qianmuyan/Documents/GitHub/assignment-app-apple-phase3a`
  （干净，仅两个按约定保留的未跟踪用户文件）
- 远程：`https://github.com/qianmuyan001/assignment-app.git`（未 push）
- RC 产物：`artifacts/apple-rc-776aa6a/`
  - `AssignmentApp-Catalyst-Debug.app` +
    `Assignment-App-2.0.0-Catalyst-Debug-arm64.zip`
  - `AssignmentApp-Catalyst-Release.app` +
    `AssignmentApp-Catalyst-Release-arm64.zip`
  - `build-info.txt`（Git SHA / 版本 / 环境 / 沙箱 / 签名 / 测试结果 /
    启动结果 / schema 版本）
  - `SHA256.txt`（55 条：包、build-info、.app/Contents 内全部文件、
    全部截图；自校验 `shasum -a 256 -c` 全 OK）
  - `screenshots/`（36 张：iPad 主界面/日历/备份/About/引导四页+中文/
    最大字号/横竖屏/课程表/考试/搜索；Catalyst 主界面英文 `catalyst-main-wide.png` +
    中文 `catalyst-main-zh.png`）
  - `logs/`（构建 / 签名 / 冒烟 / 测试 / 挂起 A/B / 分批结果等原始日志）
- 打包脚本中间产物：`artifacts/apple/debug-20260904-final/`
  （及失败尝试 `debug-20260903-rc2` ~ `rc5`，保留作为证据）

**未执行任何 push / merge / tag / PR / Release / 公证 / TestFlight，
未修改真实用户数据库。**

## 11. 受阻项闭环 runbook（供后续在用户条件下闭环）

每条都列出：要恢复的产物、触发条件、可立即执行的命令、产出/验收点。
环境差异（无 GUI 权限 / 无 signing identity / 无品牌资源）在本节
末尾的「人工授权清单」集中说明。

### 11.1 Catalyst 单元测试（Xcode 27.0 beta 运行器缺陷）

**前置：** 装上稳定版 Xcode（≥ 16.x，已知 XCTest 在 arm64 Mac 上
对 Catalyst host 注入正常）。

**命令（在本工作树根目录执行）：**

```bash
cd /Users/qianmuyan/Documents/GitHub/assignment-app-apple-phase3a

# 1. 选 Xcode：替换为已装的稳定版路径
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -version

# 2. 列出测试目标
xcodebuild \
  -project native/apple/AssignmentApp2.xcodeproj \
  -scheme AssignmentApp2 \
  -destination 'platform=macOS,arch=arm64,variant=Mac Catalyst' \
  -showTestPlans 2>&1 | head -30

# 3. 一次跑一个 suite（与 iPad 一样的分批策略，规避可能的运行器挂死）
for suite in AssignmentRepositoryTests AssignmentViewModelTests \
             AssignmentRulesTests BackupCenterViewModelTests \
             LocalizationTests ExamRuleTests CalendarPlannerTests; do
  xcodebuild test \
    -project native/apple/AssignmentApp2.xcodeproj \
    -scheme AssignmentApp2 \
    -destination 'platform=macOS,arch=arm64,variant=Mac Catalyst' \
    -only-testing:"AssignmentApp2Tests/$suite" \
    2>&1 | tee logs/catalyst-suite-$suite.log | tail -3
done
```

**验收点：** 全部 suite 报 `Test Suite '<name>' passed`；
`logs/` 下新增 `catalyst-suite-*.log`；没有 `The test runner hung
before establishing connection`；没有
`_libsecinit_appsandbox` 崩溃。**至少 160/160 与 iPad 单元套件
一一对应**，外加 Catalyst 专属 `SmokeUITests`（若有新增）。

### 11.2 真实系统通知投递

**前置：** 真机/本机（不能是无 GUI 沙箱 CI 容器）；NSUserNotificationsUsage
已注册。

**命令：**

```bash
# 1. 重置通知授权到未决状态
defaults write com.qianmuyan.assignmentapp \
  NotificationAuthorizationRequested -bool NO

# 2. 启动
open /Users/qianmuyan/Documents/GitHub/assignment-app-apple-phase3a/\
artifacts/apple-rc-776aa6a/AssignmentApp-Catalyst-Release.app

# 3. 在 Settings → Notifications 里点 "Allow Notifications"；系统弹出
#    权限对话框时人工同意。引导页同样有人工按钮。
```

**验收点：**

1. 系统设置 → 通知 → Assignment App 显示"已启用"。
2. 在 App 内创建一个 due date 在 1 分钟内的任务，把"提前提醒"设为
   due；到时间后**横幅**应出现在屏幕右上角、**通知中心**应保留条目。
3. `logs/system.log` 或 `~/Library/Logs/DiagnosticReports/` 应有
   `usernoted` / `UNUserNotificationService` 投递记录。
4. `NotificationAuthorizationProbeTests`（用户原文件，未提交）应在
   真机环境下回归通过。

### 11.3 Team Spirit 品牌图标

**前置：** 用户提供的（任一）：

- 1024×1024 无圆角透明 PNG（理想）
- 或矢量 SVG（需透明背景，理想 ≥ 1024pt viewBox）
- 或品牌使用授权的 PNG / SVG，并保留原文件名

**落位（建议）：**

```
native/apple/AssignmentApp2/Assets.xcassets/AppIcon.appiconset/
  ├── AppIcon-1024.png        (1024×1024 @1x iOS)
  ├── AppIcon-128.png         (128×128 @1x)
  ├── AppIcon-32.png          (32×32 @1x)
  ├── icon_512x512@2x.png     (Catalyst 主入口)
  └── ...其余按 Xcode AppIcon 槽位填充
```

**Xcode 步骤：**

1. Xcode 打开 `AssignmentApp2.xcodeproj` → Targets → AssignmentApp2
   → General → App Icons Source 选 "Asset Catalog" →
   AppIcon.appiconset。
2. 拖入对应尺寸 PNG（或拖入一个 1024×1024 让 Xcode 自动生成其他）。
3. macOS Catalyst 的 AppIcon 单独校验（targets → My Mac (Mac Catalyst)
   → General → App Icon）。

**验收点：**

1. 真机/模拟器主屏应用图标显示品牌图，明暗外观、Spotlight、小尺寸
   （Spotlight 120×120）均无锯齿/灰边。
2. `assetcatalogd` 日志无 `missing required icon` 告警。
3. `xcodebuild` 不报 `The app icon is missing a 1024×1024 image`。

### 11.4 Developer ID 签名 / 公证 / TestFlight / 公开发布

**前置（按用户授权分阶段执行，本阶段未触碰）：**

1. Apple Developer Program 账号。
2. Mac 上 `security find-identity -p codesigning` 至少一个 Developer ID
   Application 身份。
3. App Store Connect 账号、App ID `com.qianmuyan.assignmentapp`、对应
   provisioning profile。

**命令模板（不要在本报告 PR 中执行，仅留作清单）：**

```bash
# 1. 解锁钥匙串并选身份
security unlock-keychain -p "$KEYCHAIN_PW" ~/Library/Keychains/login.keychain-db
IDENTITY="Developer ID Application: <Team Name> (<TEAMID>)"
security find-identity -p codesigning -v | grep "$IDENTITY"

# 2. 重新签（含 entitlements，可加 hardened runtime）
codesign --force --deep --options runtime --timestamp \
  --sign "$IDENTITY" \
  --entitlements native/apple/AssignmentApp2/AssignmentApp2.entitlements \
  artifacts/apple-rc-776aa6a/AssignmentApp-Catalyst-Release.app

# 3. 公证
xcrun notarytool submit \
  artifacts/apple-rc-776aa6a/AssignmentApp-Catalyst-Release-arm64.zip \
  --keychain-profile "notary-<profile>" \
  --wait
xcrun stapler staple \
  artifacts/apple-rc-776aa6a/AssignmentApp-Catalyst-Release.app

# 4. TestFlight：xcodebuild -exportArchive + transporter
xcodebuild -exportArchive \
  -archivePath <DerivedData>/AssignmentApp2.xcarchive \
  -exportPath artifacts/tf-export \
  -exportOptionsPlist native/apple/exportOptions-TestFlight.plist
xcrun altool --upload-app -f artifacts/tf-export/AssignmentApp2.ipa \
  -t ios -u "<apple-id>" --asc-provider "<TEAMID>"
```

**验收点：**

1. `codesign -dvvv` 显示签名身份是 Developer ID 而非 "-"（adhoc）。
2. `xcrun notarytool info <submission-id>` 返回
   `Accepted`。
3. TestFlight build 出现在 App Store Connect 的 build 列表，
   `xcrun altool` / Transporter 不报 `ITMS-9xxx`。

### 11.5 Catalyst 窄窗口手工验收

**前置：** 装好稳定版 Xcode 且本机具备 Accessibility 权限
（System Settings → Privacy & Security → Accessibility 勾选
Terminal/WorkBuddy）。

**脚本：**

```bash
# 1. 启动
open /Users/qianmuyan/Documents/GitHub/assignment-app-apple-phase3a/\
artifacts/apple-rc-776aa6a/AssignmentApp-Catalyst-Release.app

# 2. 切到中文（也可走应用内 Settings → 语言）
defaults write com.qianmuyan.assignmentapp \
  "assignmentApp.language" simplifiedChinese
defaults write com.qianmuyan.assignmentapp AppleLanguages -array zh-Hans
kill "$(pgrep -f AssignmentApp-Catalyst-Release.app/Contents/MacOS)"
open <上一步的 .app 路径>

# 3. 用窗口操作把窗口拖窄到 ~520×800：
#    - 程序化：osascript -e 'tell application "System Events" to set ...'（需 Accessibility）
#    - 手工：直接拖窗口左/右边缘
#
# 4. 截图
screencapture -l $(swift /private/tmp/a2-grab-app2.swift "Assignment App" | \
  awk -F'id=' '{print $2}' | awk '{print $1}') \
  /private/tmp/cat-narrow-zh.png
```

**验收点：** 窗口内导航折叠为 iPhone-like 紧凑模式（侧栏与
详情并列变堆叠），Quick Add 表单字段全部可见、空态文案完整、
暗色背景正确延伸、中文标题不被截断。

### 11.6 人工授权清单（汇总）

| 序号 | 受阻项 | 必要的人工授权 / 资源 | 关闭后交付 |
| --- | --- | --- | --- |
| 1 | Catalyst 单元测试 | 安装稳定版 Xcode（≥ 16.x） | 160/160 测试结果 + suite log |
| 2 | 真实通知投递 | GUI 交互条件（真机/本机） | 横幅截图 + usernoted 日志 |
| 3 | Team Spirit 图标 | 用户提供的 1024×1024 透明 PNG 或授权 SVG | 完整 AppIcon appiconset |
| 4 | Developer ID/公证/TestFlight | Apple Developer Program + signing identity + App Store Connect 账号 | signed+notarized app / TF build |
| 5 | Catalyst 窄窗口验收 | Accessibility 权限授予终端 | 520×800 截图 + 折叠态验证 |

— 报告结束 —
