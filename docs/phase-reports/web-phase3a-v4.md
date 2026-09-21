# Web / Backend Phase 3A — Schema v4 追平报告

验收日期：2026-09-07。结论：本阶段实现、自动测试及真实 Chromium 验收完成。所有测试使用临时数据；没有打开、迁移或修改真实用户数据库。没有 push、合并 main、tag 或 Release。

## 1. 仓库、基线与最终源码

| 项目 | 准确记录 |
|---|---|
| 真实仓库 | `/Users/qianmuyan/Documents/GitHub/assignment-app` |
| 远端 | `https://github.com/qianmuyan001/assignment-app.git` |
| 独立工作树 | `/Users/qianmuyan/Documents/GitHub/assignment-app-web-phase3a-v4` |
| 交付分支 | `qianmuyan001/web-phase3a-v4` |
| fetch 后的 `origin/main` / 基线 SHA | `a181e9ef706f5e254c1bd33c74f26f0be9f5bba5` |
| **最终源码及测试 SHA** | **`704a3b5fd5b812b38d975c7359029b7f3288b981`** |
| Web/Backend 实现及浏览器脚本 SHA | `692c2be9316c0a2167542bb20f239e82a2400049` |
| 数据库版本 | Schema **4**；未知 `>4` 版本拒绝启动 |
| 应用版本 | **2.1.0**，沿用主干，未修改版本号 |

开始时已获取远端引用；主干与用户提供的整合 SHA 相同，没有额外主干提交需要审计。原工作树仍在 `release/2.1`，未跟踪的 `.workbuddy/` 保留。并行开发分别使用新建的 Web 数据层、学习 API、UI 工作树，没有复用 Apple 或 Windows 工作树；提交由本分支串行整合。

最后一个源码提交只更新 `shared/tests/test_v2_contract.py` 中后端迁移目标的旧 v3 断言，Web/Backend 程序与浏览器验收时完全相同。此后交付提交只增加本报告和证据；本报告中的“最终 SHA”指可复现的最终源码/测试版本，避免把报告自己的提交 SHA 写进自身造成自引用。

## 2. 已完成的功能

- 新库直接初始化到 v4；保留 v1/v2 兼容迁移，并增量执行共享 v3→v4 迁移。
- 课程安排 CRUD、软删除/恢复、课程/星期/周/今日查询，重叠和夏令时缺失时间警告。
- 考试 CRUD、课程关联、三种状态、软删除/恢复、原子且幂等的复习任务创建。
- fixed / due_relative 提醒；截止日期、时区变化后更新相对提醒缓存；缺少截止日期或时间无效时提供禁用原因；完成/删除任务取消待投递提醒。
- 六个 Web 页面：任务、今日、日历、课程表、考试、设置。保留原有 Cover Flow、附件、课程、项目、标签和子任务。
- 全部/今日/本周/逾期/已完成筛选；月历显示任务与考试；今日页聚合课程、考试、到期/逾期任务并提供快速添加。
- 英文/简体中文持久化、系统/浅色/深色主题、简易/专业模式、版本及更新日志入口。
- 备份创建/下载、导入预检、单独明确确认、恢复事务回滚、附件一致性校验及中断恢复。
- 加载、空、错误与重试状态；删除确认；可见焦点、对话框焦点恢复、标签、ARIA、Cover Flow 键盘选择及 Reduce Motion。

进度条现在读取真实 `progress_percent`，移除了旧界面根据截止时间推算 82%、64% 等虚构进度的逻辑。模式切换共用原任务记录；编辑只 PATCH 改动字段，不清空隐藏值，标签加载未完成时不能误删关联。

## 3. 共享语义和 Apple 对照

规则来源为 `shared/schema_v3.py`、`shared/schema_v4.py`、`shared/feature-specs/learning-scenes-v4.md`、共享测试，以及 Apple Phase 3A 报告和 `SQLiteLearningRepository.swift` 中的规则。没有修改共享规则实现或 Apple/Windows 源码。

| 规则 | Apple / 共享规则 | 本次 Web / Backend |
|---|---|---|
| 标识与删除 | 数据库 lineage、稳定 UUID、软删除、索引及触发器 | 直接使用共享建表/迁移；启动同时校验继承的 v3 和新增 v4 约束 |
| 课程星期/生效期 | ISO 周一=1；结束日期含当天；禁止跨午夜 | 同一 `MeetingWindow` 和日期规则 |
| 时间重叠 | 有效日期交集上的 UTC 区间比较；相邻不重叠；仅警告 | 复用 `meetings_overlap`；保存成功、保留全部记录 |
| 夏令时 | 缺失墙上时间无 occurrence；重复时间取第一次 | 课程、考试和截止时间按相同规则解析，并显示缺失时间原因 |
| 考试 | upcoming / completed / cancelled；本地时间加 IANA 时区 | 同样的存储与校验；拒绝带 offset 的本地时间输入 |
| 复习任务 | `Review: <exam>`、高优先级、同课程/时区；考试前 86,400 秒 | 同一规则；写锁事务内建任务并关联；重复调用返回原任务，包括已软删除的任务 |
| 删除考试 | 不删除复习任务 | API 与浏览器均验证；已删除的复习任务可明确选择恢复 |
| fixed 提醒 | 原 trigger 为权威值，迁移不得重解释 | 保留旧 trigger 和 lead 原值；编辑任务截止时间不会移动 fixed |
| due_relative 提醒 | deadline − lead；缺少 deadline 禁用并说明 | 使用共享相对规则，缓存重新计算、原因返回、待投递列表过滤 |
| 今日与本周 | 今日/本周包含已完成任务；逾期排除已完成 | 筛选和概览保持一致；今日早些时候未完成任务可同时出现在今日与逾期 |
| 近期考试 | 查看者当天零点至第 14 天零点，含远端边界 | 比较已解析 UTC instant，并保留考试声明时区显示 |
| 今日课程 | 共享规则要求生效日期和真实时间；Apple 旧 planner 有仅按星期筛选的路径 | 使用完整生效期和查看者日期区间；纽约周日晚课能出现在上海周一的今日课程中 |
| 未写时区的旧任务 | 沿用运行设备的本地时区 | Backend 设备时区解析一次，通过新增只读 `due_at_utc` 给 Web；查看者时区只用于分组显示。新建 Web 任务写入浏览器 IANA 时区 |
| 输入长度与导入 | Apple 草稿地点/教师≤255，范围≤1000，备注≤4000 | 新建/编辑对齐限制；共享 schema 合法的已有较长文本可读取，未编辑字段原样保留 |

现有 `due_date` 字段格式和 `todo/done` ↔ `not_started/completed` 状态映射保留。`due_at_utc` 为兼容新增的只读字段，未引入第二份任务数据。

## 4. 迁移和恢复安全

### 数据迁移

沿用项目已有 advisory lock 和 SQLite Online Backup API。获取写事务锁后，使用独立只读连接生成唯一、可独立打开的备份；在备份完整性/逻辑指纹校验通过前不做任何 schema 或数据变更。之后在同一事务里调用共享迁移、校验全部原表的原列及扩展对象、执行 integrity/foreign-key 检查，再提交 v4。

这里保留了 Backend 原有“先 `BEGIN IMMEDIATE` 锁定，再 backup，再变更”的并发保护顺序，与共享文档“BEGIN 前 backup”的文字顺序不同；迁移前备份仍已完成并校验，目的是避免另一个写入者在备份与迁移之间使快照过期。

失败回滚后核对原逻辑指纹；如果已有其他有效写入使指纹不同，不覆盖实时数据库，而是保留备份并阻止启动。覆盖了 UUID/lineage、Unicode、BLOB、课程/项目/标签/子任务/附件/提醒、扩展列/表/索引/触发器的保留验证。

[迁移与故障回滚证据](web-phase3a-v4-evidence/migration-evidence.json)：v3→v4 成功；旧提醒 `2026-10-31T17:00:00Z`、lead 75 保持原值并标记 fixed；注入失败后原 v3 指纹一致。

### Web 备份与恢复

ZIP 包包含 Online Backup 生成的 SQLite 一致性快照、manifest 和附件。每个文件校验 SHA-256、大小及数据库附件元数据；拒绝损坏 ZIP、路径穿越、符号链接、重复/额外/缺失条目、未知 schema、错误外键及损坏附件。当前单包解压后上限 512 MiB。

预检只处理隔离快照，v3 导入快照先迁移至 v4，不改变实时数据库。确认 token 有效期 30 分钟；确认时重新校验预检后的数据库指纹与附件内容。恢复使用一个 SQLite 写事务替换 schema/数据，并交换附件目录；任何提交前错误会回滚两部分。恢复日志处理两次目录移动之间的中断。已测试新增自增扩展表后恢复旧备份的 SQLite 内部 `sqlite_sequence` 情况。

所有 Web worker 的请求及完整附件流共用维护锁；启动恢复和附件 reconciliation 同样持锁。维护锁测试包含独立进程，验证最终响应字节发送完成前不会发生恢复或附件变更。

[恢复证据](web-phase3a-v4-evidence/backup-recovery-evidence.json)：在附件目录交换后、SQLite 提交前注入失败，数据库前后指纹均为 `6e6db0a3ec818085810602f4f466f954f2afeec08817ac59f9dde33b0f1d19f9`，附件哈希相同；随后正常恢复指纹与预检快照一致，`integrity_check=ok`，外键错误 0。

## 5. API 列表

API 输入使用 Pydantic 验证；错误保留原 `detail`，并新增稳定 `error.code` / `error.message`。校验失败 422、缺失记录 404、冲突 409；备份预检失败使用 `backup_validation_failed`。现有任务/组织/附件路由继续可用。

| 路由 | 方法与用途 |
|---|---|
| `/course-meetings` | GET 列表/筛选；POST 新增 |
| `/course-meetings/{id}` | GET / PATCH / DELETE |
| `/course-meetings/{id}/restore` | POST 恢复 |
| `/exams` | GET 列表及 course_id/status 筛选；POST 新增 |
| `/exams/{id}` | GET / PATCH / DELETE |
| `/exams/{id}/restore` | POST 恢复 |
| `/exams/{id}/review-task` | POST 幂等创建或返回 `{exam, assignment, created}` |
| `/overview/today` | GET `timezone_id`、可选 `on_date`；返回 meetings、upcoming_exams、due_today、overdue、warnings |
| `/assignments/{id}/reminders` | GET / POST；fixed 或 due_relative |
| `/assignments/{id}/reminders/{reminder_id}` | PATCH / DELETE；schedule_kind、lead、trigger、启停及投递时间 |
| `/reminders/pending` | GET 待调度列表，并刷新相对缓存 |
| `/assignments/{id}` | 原 GET / PATCH / DELETE 保留；PATCH 截止时间/时区时重算相对提醒 |
| `/assignments/{id}/restore` | 原 POST 保留；任务恢复不会擅自启用已停用的提醒 |
| `/backups` | GET 列表；POST 创建一致性备份 |
| `/backups/{id}/download` | GET 下载 ZIP |
| `/backups/preflight` | POST 原始 `application/zip` 字节；返回 token、summary、warnings |
| `/backups/restore` | POST `{token, confirm:true}`，必须单独明确确认 |
| `/app-info` | GET 当前版本、schema、更新说明和提醒能力 |
| `/changelog` | GET 原有完整更新日志 |

课程表 GET 支持 `course_id`、ISO `weekday`、`week_start`、`current_week`、`on_date`、`timezone_id`、`include_deleted`；三个日期选择参数互斥。`week_start` 按存储的周循环日期查询；`on_date+timezone_id` 按查看者当天真实时间区间查询，与 Today 一致。GET 单条也可用 `include_deleted=true` 读取软删除记录。

## 6. 自动测试实际结果

环境：macOS 27.0 arm64，Python 3.14.6，FastAPI 0.139.0，SQLAlchemy 2.0.51，Pydantic 2.13.4。测试依赖位于 `/private/tmp/assignment-web-phase3a-env`。

| 检查 | 通过 | 失败 | 跳过 | 证据 |
|---|---:|---:|---:|---|
| 全部 Shared 测试 | 131 | 0 | 0 | [完整日志](web-phase3a-v4-evidence/shared-tests.log) |
| 全部 Backend 测试 | 140 | 0 | 0 | [完整日志](web-phase3a-v4-evidence/backend-tests.log) |
| Web 规则案例 | 21 | 0 | 0 | [Node 日志](web-phase3a-v4-evidence/web-rule-tests.log) |
| 真实浏览器操作组 | 18 | 0 | 0 | [操作日志](web-phase3a-v4-evidence/browser-tests.log)、[结构化记录](web-phase3a-v4-evidence/browser-acceptance.json) |
| Python 错误级 Pylint | 通过 | 0 错误 | — | [日志](web-phase3a-v4-evidence/pylint.log) |
| 版本同步 / diff 检查 / 冲突标记扫描 | 通过 | 0 | — | [检查记录](web-phase3a-v4-evidence/final-checks.json) |

Backend 的 140 项含一个运行全部 21 个 Node 案例的 CI 入口，避免现有 `unittest discover` 漏掉 Web 测试；因此两行不能简单相加作为独立用例总数。没有为了通过而跳过、删掉安全断言或仅检查 HTTP 200。

最终复跑曾发现 Shared 目录里的两个 Backend 迁移兼容测试仍硬编码 v3。只更新了目标版本/迁移链，并增加 v4 校验；原数据、WAL、备份和失败恢复断言保留。修改后 131 项全部通过。集成时发现的 Pydantic 计算字段冲突、日期输出精度断言、附件目录中断和下拉样式问题均已修正。

复现命令（仓库根目录；先安装 `requirements-dev.txt`，Node.js 18+）：

```sh
python -m unittest discover -s shared/tests -v
python -m unittest discover -s backend/tests -v
node --test backend/tests/web_ui.test.cjs
PYTHONPATH=. python -m pylint --errors-only $(git ls-files '*.py')
python scripts/check_version_sync.py
git diff --check a181e9ef706f5e254c1bd33c74f26f0be9f5bba5
```

浏览器脚本 `backend/tests/browser_phase3a.cjs` 自行创建临时目录和 loopback Uvicorn 服务，结束后停止服务，保留临时数据以便复查。可通过 `PLAYWRIGHT_MODULE` 和 `PYTHON_EXECUTABLE` 指定现有运行时；本次使用 bundled Playwright 和上述临时 Python 环境，没有依赖已运行的用户服务。

## 7. 真实浏览器和截图

浏览器：**Chromium 151.0.7922.34**，真实 headless 浏览器；时区 Asia/Shanghai。桌面 viewport **1440×1000**；窄屏 **390×844**；另外逐页验证 **320×740**。截图为 full-page，因此图片总高度可能高于 viewport。没有声称完成 Safari、Firefox 或真人屏幕阅读器验收。

18 组实际操作包括：空页面、课程/任务新增、表单错误、附件字节往返、任务删除确认、五种筛选及键盘选择、课程安排重叠/修改/删除/恢复、考试状态和幂等复习任务、日历/Today 聚合、相对提醒重算、无截止日期禁用、模式字段保留、主题/语言持久化、提醒实际投递、备份完整工作流、错误重试、桌面/窄屏布局及零未捕获脚本错误。

| 页面 | 桌面英文 | 桌面中文 | 窄屏中文 |
|---|---|---|---|
| 任务 | [截图](web-phase3a-v4-evidence/desktop-en-tasks.png) | [截图](web-phase3a-v4-evidence/desktop-zh-tasks.png) | [截图](web-phase3a-v4-evidence/narrow-zh-tasks.png) |
| 今日 | [截图](web-phase3a-v4-evidence/desktop-en-today.png) | [截图](web-phase3a-v4-evidence/desktop-zh-today.png) | [截图](web-phase3a-v4-evidence/narrow-zh-today.png) |
| 日历 | [截图](web-phase3a-v4-evidence/desktop-en-calendar.png) | [截图](web-phase3a-v4-evidence/desktop-zh-calendar.png) | [截图](web-phase3a-v4-evidence/narrow-zh-calendar.png) |
| 课程表 | [截图](web-phase3a-v4-evidence/desktop-en-timetable.png) | [截图](web-phase3a-v4-evidence/desktop-zh-timetable.png) | [截图](web-phase3a-v4-evidence/narrow-zh-timetable.png) |
| 考试 | [截图](web-phase3a-v4-evidence/desktop-en-exams.png) | [截图](web-phase3a-v4-evidence/desktop-zh-exams.png) | [截图](web-phase3a-v4-evidence/narrow-zh-exams.png) |
| 设置 | [截图](web-phase3a-v4-evidence/desktop-en-settings.png) | [截图](web-phase3a-v4-evidence/desktop-zh-settings.png) | [截图](web-phase3a-v4-evidence/narrow-zh-settings.png) |

另有 [桌面深色](web-phase3a-v4-evidence/desktop-en-settings-dark.png)、[窄屏深色](web-phase3a-v4-evidence/narrow-zh-settings-dark.png)、[简易模式](web-phase3a-v4-evidence/narrow-zh-simple-tasks.png)、[关于/更新日志](web-phase3a-v4-evidence/desktop-zh-about.png)、[空状态](web-phase3a-v4-evidence/empty-settings.png)，共 **23 张**。截图已实际打开复查；下拉框箭头、浅色文字对比度和真实进度均已修正。

## 8. 数据隔离与证据

实际保留的临时路径：

- 迁移成功数据库：`/private/tmp/assignment-phase3a-migration-evidence-26vlu9uf/populated-v3-to-v4.db`
- 迁移回滚数据库：`/private/tmp/assignment-phase3a-migration-evidence-26vlu9uf/rollback-v3.db`
- 对应唯一 `.bak` 的完整路径位于 [迁移 JSON](web-phase3a-v4-evidence/migration-evidence.json)。
- 最终浏览器/恢复数据库：`/var/folders/lf/58zg8mp53nz2fv6pwyt7sk5m0000gn/T/assignment-web-phase3a-browser-OpWLz4/assignments.db`
- 实际下载并重新导入的备份：同一目录的 `browser-backup.zip`。

其余自动测试使用 `TemporaryDirectory`，在退出时清理；包含 `assignment-api-tests-*`、`assignment-learning-api-*`、`assignment-backup-tests-*`、`assignment-backup-api-tests-*` 及迁移/提醒/维护锁测试的独立临时目录。所有应用测试启动前显式配置临时 `ASSIGNMENT_DB_PATH`，直接服务测试使用隔离 engine 或显式临时路径。

**真实用户数据库没有被测试打开或读取。** 本次不在原仓库启动 Backend。现有防护测试仅检查隔离工作树里默认数据库文件是否出现/变化，该工作树没有用户数据库；没有扫描原仓库数据库内容。

证据目录提供 [文件 SHA-256](web-phase3a-v4-evidence/sha256.json)，JSON/日志/截图已提交；临时 SQLite 数据库和 ZIP 没有提交进 Git。

## 9. 修改文件与范围

源码/测试共 **33 个文件**，精确列表：[changed-source-files.txt](web-phase3a-v4-evidence/changed-source-files.txt)。包括 Backend 数据库/模型/验证/路由/服务，`backend/app/static/` 六个文件，以及后端、Web 和浏览器测试。

两个位于常规 Backend 目录外的测试相关改动：

- `requirements-dev.txt`：新增 TestClient 使用的 `httpx` 测试依赖。
- `shared/tests/test_v2_contract.py`：仅更新其中 Backend 迁移测试的版本期望，保留共享规则及安全断言。

另外新增本报告及证据目录。`native/`、根 `README.md`、`VERSION`、`CHANGELOG.md`、共享 schema/规则实现均无改动，版本同步检查通过。

## 10. 限制与本阶段未做项目

本阶段要求的学习场景、迁移、模式、语言、主题及备份工作流已完成。提醒能力是**应用打开并可见期间的页面内提醒**：每 15 秒检查，保存 `last_scheduled_at`，遵守任务完成/删除及服务端禁用原因；已在真实浏览器观察到投递。关闭页面、浏览器退出或后台节流时不保证投递，不是系统后台推送，也没有伪装成该能力。

没有进行 Apple/Windows 真机验收、Safari/Firefox 验收或系统通知验收。普通 SQLite 扩展字段、表、索引、触发器和 BLOB 已测试；第三方虚拟表扩展不属于本次验收覆盖。

按明确范围未开发：MCP、AI 总结/自然语言创建接入、多设备同步、轮换课表、成绩追踪、番茄钟、完整看板/表格/图库多视图、桌宠。保留了已有功能入口和实现，没有扩展这些项目。
