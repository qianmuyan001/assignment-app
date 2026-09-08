# Apple 2.1.2 发布工程 runbook

本轮仅完成开发与发布准备。正式验收、签名、公证上传、发布及用户 Beta 均未执行。Schema 保持 v4，Apple 版本 2.1.2 / build 2。正式 Bundle ID 为 `com.qianmuyan.assignmentapp`；当前仅声明 arm64 构建能力，未声明 Intel/Universal 或最低系统实机通过。

## 1. 前提与版本协调

采用真实 Xcode，显式设置：

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
python3 native/apple/scripts/check-apple-version.py
python3 scripts/check_version_sync.py
```

Apple 的 VERSION、BUILD_NUMBER、全部 target 配置、包内版本和 About 使用同一元数据；About 打包 Apple CHANGELOG。根 VERSION/README/CHANGELOG、Windows/Web 版本未改动。现有共享检查仍强制 Apple 与根版本相同，因此当前会真实失败。`patches/platform-version-contract.patch` 是待协调补丁，尚未应用：保留根/Windows 原校验，为 Apple 读取自己的 VERSION。主干集成前需所有者批准策略并应用、运行共享检查；不得删检查或忽略失败。

Apple CI 分为独立的共享版本门禁与 Apple 自测 job，版本协调失败不会掩盖 Apple 测试结果，但 workflow 整体不会被声称绿色。每周内部 workflow 复用完整 Apple job，周一 UTC 02:00，仅上传 Actions 内部产物；没有发布或 Apple 上传步骤。当前未 push，线上 CI 待运行。

## 2. 开发内部包（已允许的流程）

```bash
ASSIGNMENT_REQUIRE_CLEAN_TREE=1 \
ASSIGNMENT_CONFIGURATION=Release \
ASSIGNMENT_RUN_STAMP=dev-212-unique \
./native/apple/package-catalyst.sh
```

默认 `ASSIGNMENT_CREATE_DMG=1`。输出 `.app + ZIP + DMG + build-info.txt + logs`；Debug 可用相同入口指定 Debug。不要复用 output stamp。脚本从干净源码 clean build；Xcode 编译宏兼容参数只影响编译器宿主，产物仍具 App Sandbox。当前 Xcode beta 不是对未来不同工具链字节级可复现性的承诺；固定源码/工具链/配置可复现构建流程，随机测试 ID 和时间戳会使字节哈希不同。

每包随机 `com.qianmuyan.assignmentapp.rcsmoke.<UUID>`，只用于一次性测试。实际可转移 app 的身份在签名前写入；日志以 LaunchServices 实际进程文件句柄验证数据库路径，然后只读检查 v4、完整性、外键、表/列/索引/触发器。退出并检查连接释放后清理本轮数据。正式数据库、sidecar、整个附件/备份树及偏好前后做只读文件指纹比较；任何差异使打包失败。

ZIP 解压后严格验签，DMG 做结构校验，均非正式安装验收。签名用系统 codesign 从嵌套 Mach-O/代码容器向外完成，`--deep` 仅用于验证。内部包为 **ad-hoc、未公证、非正式发布包**；DMG 存在不代表可以对外分发。不要用“打开仍被系统阻止”作为跳过正式签名的理由。

`build-info.txt` 记录源 SHA/tree、实际版本/build、架构、配置、最低系统、SDK/Xcode、Bundle ID、签名/公证状态、测试声明和文件 SHA。packager 自己不执行单元/UI 测试；测试环境变量只能由已有真实测试证据填写。

## 3. Developer ID 与公证（未执行）

依据 Apple 的 [Developer ID](https://developer.apple.com/developer-id/)、[签名证书](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)、[分发前公证](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)及 [Catalyst 归档](https://help.apple.com/xcode/mac/current/en.lproj/dev88332a81e.html)流程。通知代理的早期安装遵循 [UNUserNotificationCenterDelegate](https://developer.apple.com/documentation/usernotifications/unusernotificationcenterdelegate)。脚本复用 Apple 自带 Xcode/codesign/notarytool/stapler/hdiutil，不安装第三方签名器。

本机只读检查目前为 **0 个有效签名身份**。账号持有人须先在 Xcode/钥匙串准备 Developer ID Application 身份；不导出私钥、不修改证书信任。当前本地通知不需要 APNs entitlement。若后续启用受限制能力，需匹配 Team/正式 ID、未过期且不含调试权限的 Developer ID provisioning；脚本可检查 `--profile`，不要凭空增加 capability。

以下命令仅在完成验收准备、满足账号条件并获得相应授权后执行；身份及 keychain profile 是操作者实际配置值：

```bash
python3 native/apple/scripts/developer-id-release.py preflight \
  --identity 'Developer ID Application: ACCOUNT NAME (TEAMID)'

python3 native/apple/scripts/developer-id-release.py build \
  --identity 'Developer ID Application: ACCOUNT NAME (TEAMID)' \
  --output /private/tmp/assignment-212-distribution-unique \
  --authorize-signing
```

脚本要求 clean 源码，Release archive，固定正式 ID，arm64；按嵌套顺序手工签名并验证 Developer ID、Sandbox、Hardened Runtime、时间戳和无 get-task-allow。适用时提供 `--profile /path/to/approved.provisionprofile`。证书/账号未具备，本轮只能校验脚本语法、授权拒绝与缺失前提，不声称完整签名路径跑通。

公证凭据由账号持有人自行用 `xcrun notarytool store-credentials` 交互式保存在钥匙串，不把密码或 API 私钥写入参数日志/仓库。上传需要单独授权：

```bash
python3 native/apple/scripts/developer-id-release.py submit \
  --app '/path/Assignment App.app' --dmg /path/Assignment-App-2.1.2-Catalyst-Release-arm64.dmg \
  --keychain-profile ACTUAL_PROFILE --authorize-notarization-upload
python3 native/apple/scripts/developer-id-release.py status \
  --submission-id ACTUAL_ID --keychain-profile ACTUAL_PROFILE
python3 native/apple/scripts/developer-id-release.py staple \
  --app '/path/Assignment App.app' --dmg /path/Assignment-App-2.1.2-Catalyst-Release-arm64.dmg \
  --submission-id ACTUAL_ID --keychain-profile ACTUAL_PROFILE
```

提交前挂载只读 DMG 校验实际 payload。仅 Accepted 才允许 stapling；失败保留 notary JSON，并用 `xcrun notarytool log ACTUAL_ID --keychain-profile ACTUAL_PROFILE` 查明原因，不重试掩盖失败。staple 后验证票据、严格签名和 Gatekeeper，重新生成带票据 ZIP，记录 `.distribution-status.json` 的最终哈希；它替代 build-info 的公证前哈希。必须再用真实下载路径及隔离属性做独立安装验收。

TestFlight 单独使用 App Store Connect App 记录、对应签名/provisioning、archive/upload 与测试组。需明确 TestFlight 分发授权；不以 TestFlight 代替 Mac Developer ID 分发工程。

## 4. 连续升级的合成环境（操作未执行）

准备阶段可以执行：

```bash
python3 native/apple/scripts/upgrade-rehearsal.py prepare --fixture /private/tmp/assignment-v2-fixture-unique
python3 native/apple/scripts/upgrade-rehearsal.py package \
  --app '/path/to/built/Assignment App.app' --output '/private/tmp/Assignment Upgrade Internal.app'
```

prepare 复用 Shared v2 DDL，仅生成合成记录及进程退出后仍存在的已提交 WAL，记录文件 SHA。package 将实际 app 重签为固定 `com.qianmuyan.assignmentapp.internal.upgrade`。旧版和新版均需此 ID；旧版从指定历史源码构建，并带入仅存储隔离所必需的补丁，记录补丁和 SHA。不要把已迁移 v4 的库交给不兼容旧客户端写入。

收到“开始验收”后，才可运行 `install / launch / seed / check / uninstall` 并显式传 `--authorize-acceptance`。安装目的地限定为 `~/Applications/Assignment Upgrade Internal.app`。例如：

```bash
python3 native/apple/scripts/upgrade-rehearsal.py install \
  --app '/private/tmp/Assignment Upgrade Internal.app' \
  --destination "$HOME/Applications/Assignment Upgrade Internal.app" --authorize-acceptance
python3 native/apple/scripts/upgrade-rehearsal.py launch \
  --app "$HOME/Applications/Assignment Upgrade Internal.app" --authorize-acceptance
```

首次运行创建内部容器，退出后先归档内部 `AssignmentApp2` 数据目录到同一容器的明确新名字，才执行 seed；seed 拒绝覆盖现存目录或被改动的 fixture。对已有数据的升级只替换 app，不执行 seed。用旧内部客户端创建附件、课程/项目/标签/子任务等，再记录逐字段快照与附件 SHA。升级后 check 验证 v4 及合成旧字段；其余字段/关系按验收表逐项核对，不把计数相同当作保留成功。

卸载入口会将内部 app 移出安装路径，保留可回退副本及全部内部用户数据；确认退出后，可由操作者删除归档的 app。**删除应用与删除用户数据是两种不同操作。** 脚本不自动删除用户数据。旧 app 归档仅用于兼容性分析，不能自动回写新 Schema。

迁移失败时：停止写入 → 保留故障库/WAL/迁移备份 → 在独立内部容器验证备份 → 使用备份中心恢复到兼容客户端 → 核对完整字段/附件/关系。不要只复制活跃的主数据库而遗漏 WAL，也不要将安全备份覆盖到仍有连接的目录。

## 5. Alpha、Beta、缺陷及紧急修复

- Alpha：执行验收手册所有核心矩阵，固定包 SHA；数据损坏/越界读写/启动失败/关键功能不可用为 P0/P1，阻断发包。P2 为有明确可用绕行的功能缺陷；P3 为不影响可用性的视觉或文字问题。每项须有负责人、复现、修复提交及回归证据。
- Beta：仅在签名、数据安全、升级恢复和 Alpha 阻断项通过后，邀请已同意的真实学生。说明本地数据备份、已知问题和退出方法；记录参与人数、使用周期与反馈，不伪造用户量或评价。当前 Beta 未开始。
- 反馈模板：`包名/SHA；版本/build；系统/机型；复现步骤；期望；实际；频率；是否阻断；脱敏附件；可选诊断摘要`。About 的“复制诊断”由用户主动执行，只含版本/系统/Schema/权限/计数/数据库 UUID 等允许字段；不含任务正文、附件名、路径、凭据，不上传遥测。
- 阻断项：正式数据指纹变化、迁移/恢复失败、SQLite API 生命周期警告、单元/UI 测试失败、未解释崩溃、签名/公证/Gatekeeper 失败、版本/身份不符或 P0/P1 未关闭。不能删除测试、过滤日志、长等待或重复重试变绿。
- 热修复：从实际发布 SHA 独立分支，最小修复，递增 Apple build/版本需先确认平台策略，执行受影响测试及必要全量回归，重新冻结验收。发布操作另行授权。
- 回滚：先停止分发并备份数据。只有旧客户端明确支持现有 Schema 和字段语义时才允许降级打开；否则恢复到该旧版支持的、已验证且由用户授权的升级前备份。新 Schema 绝不直接交给旧客户端写入；恢复将丢失备份之后的变更，必须先说明并获得同意。

当前已知外部条件：共享版本策略待协调、线上 CI 待 push 后运行、Developer ID/账号缺失、Team Spirit 授权素材缺失、正式桌面/通知/安装矩阵未执行、Alpha/Beta 未执行。现有图标继续保留，没有临摹或生成品牌标志。
