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

Result: **98 passed, 0 failed, 0 skipped** (verified via `xcresulttool` summary on
`/private/tmp/assignment-app-xcode-derived-data/Logs/Test/Test-AssignmentApp2-2026.08.31_21-44-20-+0800.xcresult`).

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

Result: **4 tests, 0 failures**.

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

Catalyst UI screenshots were **not** produced because the packaged Catalyst app crashes
on launch in this environment (see Section 9).

## 8. Artifacts

Catalyst Debug test package (build, code-sign, ZIP verification succeeded; launch smoke
failed):

```text
/Users/qianmuyan/Documents/GitHub/assignment-app-apple-phase3a/artifacts/apple/debug-20260831-133026Z/Assignment App.app
/Users/qianmuyan/Documents/GitHub/assignment-app-apple-phase3a/artifacts/apple/debug-20260831-133026Z/Assignment-App-2.0.0-Catalyst-Debug-arm64.zip
```

- **Version:** 2.0.0
- **Architecture:** arm64 Mac Catalyst
- **Git SHA:** `b4acb5574eaff8f0ca90db099355fdb126f4f928`
- **Source tree:** mostly clean; only untracked `CONTEXT.md` remains
- **Signing:** local ad-hoc; App Sandbox entitlement embedded; not notarized
- **ZIP SHA-256:** `410bff16431af40fb537741c375f016265c626217a42f8dc3a4b16f1ee80a05e`
- **ZIP verification:** no AppleDouble / `__MACOSX` entries (script verified)
- **Binary profile check:** no LLVM coverage instrumentation

Build log and crash log:

```text
/Users/qianmuyan/Documents/GitHub/assignment-app-apple-phase3a/artifacts/apple/debug-20260831-133026Z/logs/catalyst-build.log
/Users/qianmuyan/Documents/GitHub/assignment-app-apple-phase3a/artifacts/apple/debug-20260831-133026Z/logs/catalyst-launch-crash.ips
```

Note: `build-info.txt` was **not** written because `package-catalyst.sh` aborted at the
launch-smoke step. The artifact directory still contains the signed `.app`, `.zip`, and
all intermediate logs.

## 9. Remaining blockers / unfinished

1. **Mac Catalyst unit tests** — blocked by test-runner hang (Section 5).
2. **Real Catalyst launch smoke / acceptance** — the packaged app crashes during
   `_libsecinit_appsandbox` initialization on this macOS 27.0 beta machine. The crash
   signature is `SYSCALL_SET_USERLAND_PROFILE` / `EXC_BREAKPOINT`. The unsigned
   derived-data build of the same binary launches successfully, so the crash is tied to
   the ad-hoc signed + App Sandbox packaged app in this environment, not to app code.
3. **Real notification delivery on device** — not independently verified. The existing
  `AssignmentNotificationScheduler` is reused; relative reminder recalculation is unit
   tested.
4. **Windows and Web Phase 3A** — not implemented.
5. **Global Gate A** — cannot be claimed until Windows Phase 2.5 is verified and the
   cross-platform contract is implemented on all platforms.

## 10. Repository state and non-fabrication

- **Main worktree:** `/Users/qianmuyan/Documents/GitHub/assignment-app`
  - branch `qianmuyan001/phase2-5-checkpoint`
  - HEAD `61205f6`
- **Phase 3A worktree:** `/Users/qianmuyan/Documents/GitHub/assignment-app-apple-phase3a`
  - branch `qianmuyan001/apple-phase3a-preview`
  - HEAD `b4acb5574eaff8f0ca90db099355fdb126f4f928`
- **Local commit:** `b4acb55` on `qianmuyan001/apple-phase3a-preview`.
- **No push / merge / tag / PR / Release.**
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
| Mac Catalyst unit tests | blocked (test-runner hang) |
| Mac Catalyst launch smoke | blocked (App Sandbox init crash) |
| Real notification delivery | not independently verified |
| Windows Phase 2.5 | still unverified |
| Windows/Web Phase 3A | not implemented |

## 12. Deliverables checklist

Per the Apple Phase 3A Preview spec, §十三:

- [x] Schema v4 spec & migration explanation (Section 3 and shared docs)
- [x] Actual test commands, counts, and results (Section 5)
- [x] Catalyst `.app` path
  - `/Users/qianmuyan/Documents/GitHub/assignment-app-apple-phase3a/artifacts/apple/debug-20260831-133026Z/Assignment App.app`
- [x] Catalyst ZIP path
  - `/Users/qianmuyan/Documents/GitHub/assignment-app-apple-phase3a/artifacts/apple/debug-20260831-133026Z/Assignment-App-2.0.0-Catalyst-Debug-arm64.zip`
- [x] Version / architecture / Git SHA / signing status (Section 8)
- [x] iPad screenshot directory (Section 7)
- [x] Notification evidence: not independently verified; disclosed in Section 9
- [x] Data came from temporary databases: yes, UI tests and launch smoke both use
  throwaway DBs; unit tests use temp/in-memory DBs
- [x] Unfinished/unverified content listed (Section 9)
- [x] Branch / HEAD / worktree / local-commit status (Section 10)
- [x] Explicit statement: Gate A incomplete, Windows Phase 2.5 unverified, Windows/Web
  Phase 3A not implemented, not a formal release

---

Generated from worktree `/Users/qianmuyan/Documents/GitHub/assignment-app-apple-phase3a`
on 2026-08-31.
