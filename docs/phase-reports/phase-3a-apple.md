# Phase 3A — Apple Preview Closeout

This report covers the single-platform Apple Phase 3A Preview for Assignment App 2.0.
It was produced from the independent worktree branch
`qianmuyan001/apple-phase3a-preview`, not from the frozen Phase 2.5 branch.

## 1. Phase result

- **Apple Phase 3A Preview:** implemented and verified on iPadOS simulator.
- **Global Gate A:** still **not passed**.
- **Windows:** remains Phase 2.5 "未验证" — this report does **not** describe it as complete.
- **Web/Windows Phase 3A:** not implemented.
- **No push, merge, tag, PR, Release, Developer ID signing, notarization, or public
  distribution** has been performed.

## 2. Scope summary

**In scope for Apple Phase 3A Preview:**

- Schema v4 shared data contract (`course_meetings`, `exams`) and additive migration
  primitives, preserving v3 rows and fixed-trigger reminder semantics.
- Timetable: Mon–Sun week view, today view, CRUD, overlap warnings only, no auto-delete.
- Exam management: CRUD, course link, upcoming/completed/cancelled, idempotent review
  task creation, delete does not auto-delete tasks.
- Reminder refinement: fixed-time and due-relative presets/custom lead, recalculation on
  deadline/timezone change, disabled-with-reason when no due date.
- Today overview: classes today, exams soon, due today, overdue, quick add.

**Explicitly not in scope:** A/B or multi-week rotating schedules, grade tracking,
pomodoro, generic multi-views, AI, sync, desktop pet, Windows/Web Phase 3A, formal
signing/notarization/public release.

## 3. Key design decisions

- **Reuse first, no second system.** Course meetings, exams, and review tasks reuse the
  existing `courses`, `assignments`, and `reminders` tables. The single
  `AssignmentNotificationScheduler` is still the only notification scheduler.
- **Pure planner.** `LearningScenePlanner` contains all date/time/ordering/overlap logic
  and is tested without a database or SwiftUI.
- **Fixed vs. due-relative reminders.** `reminders.schedule_kind` distinguishes the two.
  Existing v3 reminders keep `schedule_kind = 'fixed'` and their `trigger_at_utc` is
  authoritative and never shifts. Due-relative reminders derive their trigger from
  `assignment.due_date - lead_minutes` and recalculate only when the due date or
  timezone changes.
- **DST semantics.** Missing wall time resolves to `nil` (no occurrence); ambiguous wall
  time resolves to the earlier offset. Start and end are resolved independently.
- **Overlap is a warning only.** `LearningRules.meetingsOverlap` reports pairs; the UI
  shows them but never auto-deletes or rejects a save.
- **Migration safety.** Migration uses SQLite Online Backup, `BEGIN IMMEDIATE`, a file
  lock, pre-commit integrity/FK/UUID verification, rollback + fingerprint verification,
  and a read-only fail-closed phase. **No real user database was migrated; all migration
  tests run on temporary databases.**

## 4. Implemented source

**New shared/schema files:**

- `shared/feature-specs/learning-scenes-v4.md`
- `shared/schema_v4.py`
- `shared/tests/test_v4_contract.py`
- `shared/tests/test_v4_learning_rules.py`

**New Apple feature files:**

- `native/apple/AssignmentApp2/LearningScenes.swift` — shared models/drafts/rules.
- `native/apple/AssignmentApp2/SQLiteSchemaV4.swift` — v4 schema creation.
- `native/apple/AssignmentApp2/SQLiteLearningRepository.swift` — repository for meetings/exams.
- `native/apple/AssignmentApp2/LearningSceneStore.swift` — store + pure planner.
- `native/apple/AssignmentApp2/TimetableView.swift`
- `native/apple/AssignmentApp2/ExamView.swift`
- `native/apple/AssignmentApp2/TodayOverviewView.swift`

**Modified Apple files (selection):**

- `ContentView.swift` — routes Timetable/Exams before task list; keeps Today overview
  visible even when the task list is empty.
- `AssignmentViewModel.swift` — wires `LearningSceneStore`, triggers relative-reminder
  recalculation before notification reconciliation.
- `TaskEditorView.swift` — fixed/relative reminder UI with disabled-reason.
- `Models.swift`, `NavigationChrome.swift`, `Views.swift`, `TaskRules.swift`,
  `SQLiteAssignmentRepository.swift`, `SQLiteOrganizationRepository.swift`,
  `SQLiteSchemaV3.swift`, `MigrationCoordinator.swift`, `OrganizationModels.swift`,
  `AssignmentRepository.swift`.

**Test files:**

- `native/apple/AssignmentApp2Tests/LearningScenePlannerTests.swift`
- `native/apple/AssignmentApp2Tests/LearningSceneRepositoryTests.swift`
- `native/apple/AssignmentApp2Tests/LearningSceneRuleTests.swift`
- Updated `AssignmentApp2Tests.swift`, `SchemaV3RepositoryTests.swift`,
  `AssignmentApp2UITests.swift`.

**Packaging:**

- `native/apple/package-catalyst.sh` now validates v4 schema in the Catalyst launch
  smoke.

## 5. Tests and runtime evidence

All commands below set:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
```

All Xcode builds/tests also set `OTHER_SWIFT_FLAGS='-Xfrontend -disable-sandbox'`.

Every result in this section was produced at HEAD `0374f8d`. The iPad tests were
re-run after the final packager commit specifically so that the SHA recorded in
`build-info.txt` matches the SHA the tests actually ran against.

### Shared contract / rule tests

```bash
/Users/qianmuyan/.workbuddy/binaries/python/envs/default/bin/python -m pytest shared/tests -q
```

Result: **85 passed, 18 subtests passed**.

### iPadOS unit tests

```bash
xcodebuild -project native/apple/AssignmentApp2.xcodeproj \
  -scheme AssignmentApp2 -configuration Debug \
  -destination 'platform=iOS Simulator,id=55D6D2F6-FB7A-429C-ADFA-8BF9F8F2286F' \
  -derivedDataPath /private/tmp/assignment-app-xcode-derived-data \
  CODE_SIGNING_ALLOWED=NO \
  OTHER_SWIFT_FLAGS='-Xfrontend -disable-sandbox' \
  -skip-testing:AssignmentApp2UITests test
```

Result: **98 passed, 0 failed, 0 skipped** at HEAD `0374f8d` (verified via
`xcresulttool get test-results summary` on
`/private/tmp/assignment-app-xcode-derived-data/Logs/Test/Test-AssignmentApp2-2026.08.31_22-18-09-+0800.xcresult`:
`failedTests 0`, `passedTests 98`, `skippedTests 0`, `result "Passed"`).

Suite breakdown:

| Suite | Count |
|-------|-------|
| Schema v3 identity, migration, and organization repository | 15 |
| Apple navigation chrome state | 8 |
| Learning-scene rules | 22 |
| SQLite repository and migration | 10 |
| Learning scene planning | 14 |
| Shared task rules | 15 |
| Schema v4 migration and learning-scene repository | 14 |
| **Total** | **98** |

### iPad UI smoke tests

```bash
xcodebuild -project native/apple/AssignmentApp2.xcodeproj \
  -scheme AssignmentApp2UISmoke -configuration Debug \
  -destination 'platform=iOS Simulator,id=55D6D2F6-FB7A-429C-ADFA-8BF9F8F2286F' \
  -derivedDataPath /private/tmp/assignment-app-xcode-derived-data \
  CODE_SIGNING_ALLOWED=NO \
  OTHER_SWIFT_FLAGS='-Xfrontend -disable-sandbox' test
```

Result: **4 tests, 0 failures, 0 skipped** at HEAD `0374f8d`, `** TEST SUCCEEDED **`
in 92.745 s. Verified via `xcresulttool get test-results summary` on
`/private/tmp/assignment-app-xcode-derived-data/Logs/Test/Test-AssignmentApp2UISmoke-2026.08.31_22-19-27-+0800.xcresult`:
`result "Passed"`, `passedTests 4`, `failedTests 0`, `totalTestCount 4`, on iPad Pro
11-inch (M4) 18.5.

The smoke creates a throwaway database, exercises timetable CRUD, exam CRUD, the
idempotent "Add Review Task" flow, the Today overview, and landscape/portrait
orientations.

### Mac Catalyst unit tests

```bash
xcodebuild -project native/apple/AssignmentApp2.xcodeproj \
  -scheme AssignmentApp2 -configuration Debug \
  -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' \
  -derivedDataPath /private/tmp/assignment-app-xcode-derived-data \
  CODE_SIGNING_ALLOWED=NO \
  OTHER_SWIFT_FLAGS='-Xfrontend -disable-sandbox' \
  -skip-testing:AssignmentApp2UITests test
```

Result: **blocked** — `Assignment App encountered an error (The test runner hung before
establishing connection.)`, exit 65, after ~6 minutes. This is an XPC/test-host
environment issue, not a source failure. Handed back per user instruction
"做不了的验证交给我".

### `git diff --check`

Result: clean.

### Version sync

```bash
/Users/qianmuyan/.workbuddy/binaries/python/envs/default/bin/python scripts/check_version_sync.py
```

Result: **OK** — root, README, CHANGELOG, Apple, Windows all at 2.0.0.

## 6. Database and migration safety

- Schema v4 is additive; v3 tables/columns/indexes/triggers are preserved.
- All migration tests use temporary databases; **no real user database was migrated**.
- Migration primitives implement backup, lock, integrity/FK/UUID verification, rollback,
  and fingerprint checks.
- Windows and Web do **not** yet support Schema v4; the shared contract is documented
  for future implementation.

## 7. UI/UX screenshots

iPad UI screenshots were captured by the `AssignmentApp2UISmoke` suite:

```text
/Users/qianmuyan/Documents/GitHub/assignment-app-apple-phase3a/artifacts/apple/phase3a-ipad-ui/
```

Files include empty states, timetable week/today, meeting/exam editors, review-task
alert, Today overview, landscape/portrait, and sidebar/search states.

All 18 files were regenerated at HEAD `0374f8d` by the run in Section 5. They come from
`XCUIApplication.screenshot()` inside the simulator, which needs no extra macOS
permission.

Catalyst UI screenshots were **not** captured. The app does launch in this environment
in local-runnable mode (Section 8), so the blocker is capture, not launch. Two
independent routes were attempted and both are blocked by permissions on the
automation process:

- `screencapture -x` fails with `could not create image from display` — no Screen
  Recording permission for the automating process.
- `System Events` AppleScript window queries hang on the Accessibility permission
  prompt.

A third route, driving the Catalyst app with an XCUITest bundle, is unavailable
without a project change: `AssignmentApp2.xcodeproj` declares
`SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"` and `SDKROOT = iphoneos`, so no
test target in this project can build against the macOS SDK. Adding a macOS UI test
target is out of scope for this phase.

Catalyst screenshots therefore have to be taken by a person, or by an automation
process that has Screen Recording permission.

## 8. Artifacts

Two Catalyst Debug packages were produced from the same source revision
`0374f8de745533ba89e91b5cf74e7a8662292fe4`. They differ only in the App Sandbox
entitlement.

### 8.1 Sandboxed package (canonical, launch blocked)

```text
/Users/qianmuyan/Documents/GitHub/assignment-app-apple-phase3a/artifacts/apple/debug-20260831-140756Z/Assignment App.app
/Users/qianmuyan/Documents/GitHub/assignment-app-apple-phase3a/artifacts/apple/debug-20260831-140756Z/Assignment-App-2.0.0-Catalyst-Debug-arm64.zip
```

- **Build / ad-hoc sign / deep verify / ZIP verification:** all succeeded
- **Launch smoke:** **failed** — `Trace/BPT trap: 5` during dyld initialization
- `app_sandbox=true`
- Crash report: `logs/catalyst-launch-crash.ips`
  - `EXC_BREAKPOINT` / `SIGTRAP`, termination `SIGNAL 5`
  - triggering frames: `_libsecinit_appsandbox.cold.9` → `_libsecinit_appsandbox` →
    `_libsecinit_initializer` → `libSystem_initializer`, all inside
    `dyld4::Loader::findAndRunAllInitializers`
  - i.e. it dies in libSystem before any application code runs
- `build-info.txt` **was** written, with `launch_smoke=failed` (the packager was
  changed to record blocked launches instead of aborting without a record)

### 8.2 Local-runnable package (App Sandbox removed, launch verified)

```text
/Users/qianmuyan/Documents/GitHub/assignment-app-apple-phase3a/artifacts/apple/debug-local-20260831-140857Z/Assignment App.app
/Users/qianmuyan/Documents/GitHub/assignment-app-apple-phase3a/artifacts/apple/debug-local-20260831-140857Z/Assignment-App-2.0.0-Catalyst-Debug-arm64.zip
```

- **Launch smoke: passed.** The packaged app started, created a throwaway database, and
  was still alive after schema validation.
- `app_sandbox=false`; signed ad-hoc with `com.apple.security.get-task-allow` only
- **ZIP SHA-256:**
  `9175b474eb58c547c50c1cb34c51592e195bd6e3501fc20f401ea5ad48c82c75`
- Launch-smoke fingerprint (from `logs/catalyst-launch-smoke.log`):

| Check | Value |
|-------|-------|
| `user_version` | 4 |
| `quick_check` | ok |
| `foreign_key_errors` | 0 |
| `database_identity_rows` | 1 |
| tables | 11, exactly the expected v4 set |
| `assignments` columns | 22, exact match |
| indexes | 38, exact match |
| triggers | 14, exact match |
| `process_alive_after_schema_validation` | true |

**This package is a local acceptance aid only.** It is not the canonical deliverable:
the shipping configuration has App Sandbox enabled, and this variant exists solely so
a real launch can be demonstrated on this machine.

### 8.3 Shared properties

- **Version:** 2.0.0
- **Architecture:** arm64 Mac Catalyst
- **Git SHA:** `0374f8de745533ba89e91b5cf74e7a8662292fe4`
- **Source tree:** tracked files clean; the only entry in
  `logs/source-status.log` is the untracked `CONTEXT.md`, which was deliberately left
  untouched and unstaged
- **Signing:** local ad-hoc, not notarized, no Developer ID
- **ZIP verification:** no AppleDouble / `__MACOSX` entries (script verified)
- **Binary profile check:** no LLVM coverage instrumentation

### 8.4 Why the second packaging attempt previously failed

The first local-runnable attempt failed with
`Disallowed xattr com.apple.FinderInfo found`. Root cause: the artifact root sits under
a file-provider-managed tree, which re-attaches `com.apple.FinderInfo` and
`com.apple.fileprovider.fpfs#P` to any newly created directory within about two
seconds. `codesign` rejects a bundle carrying that metadata, and stripping it is a
losing race — the earlier run only succeeded because signing happened to finish before
the metadata reappeared.

Measured: `xattr -cr` removes the keys, and they return within 2 s.

`package-catalyst.sh` now copies, signs, and packages inside `/private/tmp`, then
publishes the finished deliverable into the artifact directory. Nothing is signed or
verified after that final copy, so metadata attached there is harmless.

## 9. Remaining blockers / unfinished

1. **Mac Catalyst unit tests** — blocked by test-runner hang (Section 5). The suite has
   never run to completion on this machine, so Catalyst has no automated test coverage
   at all.
2. **Catalyst launch with App Sandbox enabled** — the sandboxed package crashes during
   `_libsecinit_appsandbox` initialization on this macOS 27.0 beta machine, before any
   app code runs (Section 8.1). Evidence that this is environmental, not a source
   defect: the unsigned derived-data build of the same binary launches, and the same
   package re-signed without App Sandbox launches and initializes a v4 database. The
   canonical sandboxed configuration therefore remains unverified here.
3. **Catalyst manual acceptance** — not performed. Requires a person at the keyboard:
   wide/narrow window resizing, timetable and exam CRUD, linked task creation, real
   notification delivery/modification/cancellation, restart recovery, keyboard
   navigation, VoiceOver, and simple/professional mode switching. The local-runnable
   package in Section 8.2 is the artifact to use.
4. **Catalyst screenshots** — not captured (Section 7). Blocked by Screen Recording and
   Accessibility permissions on the automation process; no macOS test target exists to
   capture them in-process.
5. **Real notification delivery** — not independently verified. The existing
   `AssignmentNotificationScheduler` is reused; relative reminder recalculation,
   cancellation on completion/deletion, and the "disabled with reason when there is no
   due date" rule are unit tested, but no notification has been observed actually
   firing.
6. **Windows and Web Phase 3A** — not implemented.
7. **Global Gate A** — cannot be claimed until Windows Phase 2.5 is verified and the
   cross-platform contract is implemented on all platforms.

## 10. Repository state and non-fabrication

- **Main worktree:** `/Users/qianmuyan/Documents/GitHub/assignment-app`
  - branch `qianmuyan001/phase2-5-checkpoint`
  - HEAD `61205f6`
- **Phase 3A worktree:** `/Users/qianmuyan/Documents/GitHub/assignment-app-apple-phase3a`
  - branch `qianmuyan001/apple-phase3a-preview`
  - HEAD `0374f8de745533ba89e91b5cf74e7a8662292fe4`
- **Local commits** on `qianmuyan001/apple-phase3a-preview`, all created from explicit
  file lists (`git add .` was never used):
  - `b4acb55` — Schema v4, timetable, exams, relative reminders, Today overview
  - `7124953` — packager: `ASSIGNMENT_LOCAL_RUNNABLE` mode + this report
  - `0374f8d` — packager: sign outside the file-provider tree, record blocked launches
- **No push / merge / tag / PR / Release.**
- **Verification evidence is SHA-traceable.** Both Catalyst packages embed
  `source_revision` and their own `logs/source-status.log`, and `build-info.txt` records
  the iPad test results they were built against.
- **Excluded from commit:** `.workbuddy/`, databases, WAL/SHM, backups, temp evidence,
  user files, and `artifacts/` (git-ignored).
- **No untracked user modifications were overwritten.** The only untracked file is
  `CONTEXT.md`, which was left unstaged.

## 11. Verification status

| Check | Result |
|-------|--------|
| Shared Python contract/rule tests | 85 passed, 18 subtests passed |
| iPadOS unit tests | 98/98 passed |
| iPad UI smoke tests | 4/4 passed |
| `git diff --check` | clean |
| Version sync | 2.0.0 everywhere |
| Catalyst build / ad-hoc sign / deep verify | passed |
| Catalyst ZIP integrity (no AppleDouble) | passed |
| Catalyst launch smoke, sandboxed | **blocked** (App Sandbox init crash) |
| Catalyst launch smoke, no App Sandbox | passed, `user_version=4`, schema fingerprint exact |
| Catalyst Schema v4 fingerprint | 11 tables / 22 columns / 38 indexes / 14 triggers, exact |
| Mac Catalyst unit tests | **blocked** (test-runner hang) |
| Catalyst UI screenshots | **not captured** (permission + no macOS test target) |
| Catalyst manual acceptance | **not performed** (needs a person) |
| Real notification delivery | not independently verified |
| Windows Phase 2.5 | still unverified |
| Windows/Web Phase 3A | not implemented |

## 12. Deliverables checklist

Per the Apple Phase 3A Preview spec, §十三:

- [x] Schema v4 spec & migration explanation (Section 3 and shared docs)
- [x] Actual test commands, counts, and results (Section 5)
- [x] Catalyst `.app` paths — sandboxed (blocked) and local-runnable (verified)
  - `/Users/qianmuyan/Documents/GitHub/assignment-app-apple-phase3a/artifacts/apple/debug-20260831-140756Z/Assignment App.app`
  - `/Users/qianmuyan/Documents/GitHub/assignment-app-apple-phase3a/artifacts/apple/debug-local-20260831-140857Z/Assignment App.app`
- [x] Catalyst ZIP paths
  - `/Users/qianmuyan/Documents/GitHub/assignment-app-apple-phase3a/artifacts/apple/debug-20260831-140756Z/Assignment-App-2.0.0-Catalyst-Debug-arm64.zip`
  - `/Users/qianmuyan/Documents/GitHub/assignment-app-apple-phase3a/artifacts/apple/debug-local-20260831-140857Z/Assignment-App-2.0.0-Catalyst-Debug-arm64.zip`
    (SHA-256 `9175b474eb58c547c50c1cb34c51592e195bd6e3501fc20f401ea5ad48c82c75`)
- [x] Version / architecture / Git SHA / signing status (Section 8)
- [x] iPad screenshot directory (Section 7)
- [ ] **Catalyst screenshot directory** — not captured (Section 7). This is the one
  §十三 item that is genuinely missing.
- [x] Notification evidence: not independently verified; disclosed in Section 9
- [x] Data came from temporary databases: yes. UI tests and both launch smokes use
  throwaway DBs; unit tests use temp/in-memory DBs. The demo content seeded for the
  Catalyst launch attempt also lived in a temporary database and was discarded.
  **No real user database was migrated or modified.**
- [x] Unfinished/unverified content listed (Section 9)
- [x] Branch / HEAD / worktree / local-commit status (Section 10)
- [x] Explicit statement: Gate A incomplete, Windows Phase 2.5 unverified, Windows/Web
  Phase 3A not implemented, not a formal release

---

Generated from worktree `/Users/qianmuyan/Documents/GitHub/assignment-app-apple-phase3a`
on 2026-08-31.
