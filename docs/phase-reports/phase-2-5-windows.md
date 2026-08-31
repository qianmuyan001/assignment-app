# Phase 2.5 Windows x64 acceptance

Date: 2026-09-01

Result: **Gate W0 passed; Gate W1 partially passed and remains not accepted.**

Scope: Windows Phase 2.5 acceptance and Apple parity inspection only. Phase 3A,
Schema v4, timetable, and exam work were not started.

## Source identity

- Repository: `D:\Desktop\assignment-app-windows-parity`
- Branch: `qianmuyan001/windows-parity`
- Imported source candidate: `61205f63a41923b5d3926aec66baf04b47f09147`
- Local content-equivalent checkpoint: `21cad47624ef123c55fc060eca024b2377336ffb`
- Remote: `https://github.com/qianmuyan001/assignment-app.git`
- Version: 2.0.0
- Database schema: v3
- Final package source revision and tree state: recorded in the package
  `build-info.txt`; that file is authoritative for a produced artifact.

The remote candidate and local checkpoint were compared by Git object content:
all 43 imported paths matched. The two Phase 2.5 reports and the required
Windows attachment, notification, task-editor, and main-window files are
present. Gate W0 therefore passed; this acceptance did not use the stale
`origin/main` revision as its source baseline.

No Phase 3A report, Schema v4 specification, v4 migration, or v4 model was
found. **Windows 已追平当前 Apple Phase 2.5 的主要源码能力；Apple Phase 3A 尚未形成可移植基线。**
This is a source-scope statement, not a final Preview acceptance claim.

## Windows fixes in this branch

- Corrected WinUI startup resources and DPI manifest behavior so the unpackaged
  self-contained executable launches reliably.
- Added an isolated settings path override for desktop acceptance and tests.
- Added persistent compact/expanded navigation modes, narrow-window adaptation,
  and search expand/focus/clear/Escape/outside-click behavior.
- Added automation names and stable focus targets for navigation, search, task
  actions, settings, reminder controls, attachments, and organization UI.
- Replaced the self-contained-incompatible AppNotificationManager registration
  path with `CommunityToolkit.WinUI.Notifications` 7.1.2 for unpackaged toast
  registration and scheduling. The SQLite reminder contract remains unchanged.
- Preserved the existing Phase 2.5 attachment safety, rollback, reconciliation,
  organization, migration, and task-domain implementations.

Schema v3 was not changed. `repeat_rule` is still preserved and validated, but
native recurrence and deadline-relative reminders remain deferred.

## Automated verification

All commands ran on Windows 11 x64 (`10.0.22631`) using isolated temporary or
acceptance data.

| Check | Result | Evidence |
| --- | --- | --- |
| Version synchronization | Passed, all platforms 2.0.0 | `artifacts/windows/final-regression-20260901T0020Z/logs/version-sync.log` |
| Shared contract tests | **57/57 passed** | `artifacts/windows/final-regression-20260901T0020Z/logs/shared-tests-correct-env.log` |
| Backend tests | **19/19 passed** | `artifacts/windows/final-regression-20260901T0020Z/logs/backend-tests-correct-env.log` |
| Pylint CI errors-only command | Passed | `artifacts/windows/final-regression-20260901T0020Z/logs/pylint-errors-workflow.log` |
| Windows Core Release harness | **50/50 passed** | `artifacts/windows/final-regression-20260901T0020Z/logs/core-tests.log` |
| WinUI Debug x64 | Passed, 0 warnings/errors | `artifacts/windows/final-regression-20260901T0020Z/logs/winui-debug.log` |
| WinUI Release x64 | Passed, 0 warnings/errors | `artifacts/windows/final-regression-20260901T0020Z/logs/winui-release.log` |
| `git diff --check` | Passed | final Git inspection |

The first Python rerun used a bundled interpreter without project dependencies
and failed to import SQLAlchemy/Uvicorn. This was an environment-selection
error, not a product failure; the suites were rerun with the preflight virtual
environment and passed as recorded above.

## Publish and launch

`native/windows/publish-x64.ps1` was run without `-SkipSmokeTest`.

| Requirement | Result |
| --- | --- |
| Self-contained Release x64 publish | Passed |
| Published `AssignmentNative.exe` present | Passed |
| Core tests inside publish script | 50/50 passed |
| Isolated published-EXE startup | Passed |
| Process stayed alive | Passed |
| Isolated database schema | v3 |
| SQLite `quick_check` | `ok` |
| Complete Schema v3 contract | Passed |
| File version | 2.0.0.0 |
| Authenticode | Not signed |

The test package is not an installer, Store package, signed release, or formal
release. The publish directory, exact executable hash, environment inventory,
and launch readiness time are recorded in its `build-info.txt` and logs.

## Desktop interaction evidence

The release build was launched in the logged-in Windows desktop with:

- `ASSIGNMENT_DB_PATH` pointing to an isolated acceptance database;
- `ASSIGNMENT_SETTINGS_PATH` pointing to an isolated settings file;
- attachment payloads stored beside that isolated database.

No real user database, WAL/SHM file, backup, or attachment directory was opened
or migrated.

| Area | Implemented | Automated | Actual desktop | Evidence / remaining work |
| --- | --- | --- | --- | --- |
| Add/edit task and fields | Yes | Yes | Passed | `task-editor-add.png`; SQLite row verified |
| todo/in_progress/done rules | Yes | Yes | Partial | in-progress task exercised; full done/delete matrix not repeated manually |
| Search/filter/sort and smart lists | Yes | Yes | Passed for search/sidebar/layout | `search-expanded.png`, `main-wide.png`, `main-narrow.png` |
| Simple/professional and theme persistence | Yes | Yes | Partial | professional and navigation modes persisted across restart; dark theme not manually repeated |
| Compact/expanded/narrow navigation | Yes | Yes | Passed | `main-wide.png`, `main-compact.png`, `main-narrow.png` |
| Search focus/clear/Escape/outside click | Yes | Core/UIA checks | Passed | live UI Automation acceptance |
| Course/project/tag/subtask | Yes | Yes | Partial | subtask created and verified; manager launched in `organization-manager.png`; full manual project/tag CRUD not repeated |
| Attachment import/SHA/open/export/delete | Yes | Yes | Passed | real picker; stored/exported SHA-256 matched; UI delete removed payload and soft-deleted metadata |
| Missing/orphan/reparse/rollback handling | Yes | Yes | Not all forced manually | covered by Core lifecycle tests |
| Reminder add/edit/disable/remove | Yes | Yes | Partial | add and edit exercised through WinUI; records verified in SQLite |
| Notification registration/status | Yes | Indirect | Passed | settings showed `Allowed` after custom probe registrations were removed |
| Notification scheduling/system delivery | Yes | Indirect | Passed at platform level | event 3052 at 00:01:59 and 00:10:00; notification history contained tag `r3` |
| Visible notification banner/card | Yes | No | **Not verified** | screenshots did not capture the Assignment notification card despite platform delivery/history evidence |
| Keyboard, focus, automation names | Yes | Partial | Passed for inspected flows | UI Automation tree and keyboard search checks |
| Narrator, full Tab order, high DPI | Intended | No | **Not fully verified** | requires dedicated manual accessibility pass |

Desktop evidence root:

```text
artifacts/windows/desktop-acceptance-20260831T1530Z/
```

Important evidence includes `main-wide.png`, `main-compact.png`,
`search-expanded.png`, `main-narrow.png`, `settings-professional.png`,
`task-editor-add.png`, `task-editor-subtask.png`,
`task-editor-attachment.png`, `organization-manager.png`,
`notification-delivery.log`, `notification-delivery-background.log`, and the
notification-center screenshots.

## Notification finding

The unpackaged self-contained AppNotificationManager path failed on this host
because it depends on Windows App SDK singleton registration that is not part of
the portable publish directory. The compatibility notifier now reports
`Allowed`, accepts schedule/cancel/reconcile operations, and survives application
exit. Windows PushNotification-Platform event 3052 twice recorded delivery to
session 1 for the current executable; an independent history read returned the
scheduled `r3` notification.

However, neither the real-time screenshot nor the subsequently opened
notification center showed the Assignment card. Do Not Disturb was inspected
and restored to its original off state. Because the user's acceptance criterion
requires actual visible receipt, this report does not promote platform-delivery
evidence to a visible-notification pass.

References used during diagnosis:

- <https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/self-contained-deploy/deploy-self-contained-apps>
- <https://learn.microsoft.com/en-us/windows/apps/develop/notifications/app-notifications/app-notifications-scheduled>
- <https://learn.microsoft.com/en-us/windows/win32/shell/appids>
- <https://github.com/CommunityToolkit/WindowsCommunityToolkit/blob/main/Microsoft.Toolkit.Uwp.Notifications/Toasts/Compat/ToastNotificationManagerCompat.cs>

## Data and scope safety

- Schema remains v3; no v4 migration or parallel model was introduced.
- All automated and desktop tests used disposable or explicitly isolated data.
- User databases, side files, attachments, and `.workbuddy/` were preserved.
- No push, merge, tag, PR, Store submission, signing, installer, or formal
  Release was performed.

## Gate decision

Automated tests, Windows Debug/Release builds, self-contained publish, isolated
published-EXE startup, core task/editor flows, attachment lifecycle, navigation,
search, and notification platform delivery passed.

Gate W1 remains **not passed** because visible notification receipt, the complete
organization CRUD matrix, full task completion/deletion interaction, Narrator,
high-DPI, and exhaustive keyboard/Tab-order acceptance are not all closed with
matching evidence. Therefore this report does **not** claim:

> Windows Preview 已追平当前 Apple 版本。

The correct current statement is:

> Windows source and automated behavior are aligned with the current Apple
> Phase 2.5 baseline; Windows desktop acceptance remains partially open, and
> Apple Phase 3A has not formed a portable baseline.
