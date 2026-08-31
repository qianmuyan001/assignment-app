# Phase 2.5 Gate A — Windows acceptance and source closeout

Date: 2026-08-31

Result: **Windows Gate 未验证（未通过）**

Scope: Windows Phase 2.5 Gate A only. Phase 3A, Schema v4, timetable, and exam work were not started.

## Source identity

- Repository: `/Users/qianmuyan/Documents/GitHub/assignment-app`
- Branch: `main`
- HEAD: `e487dc21bc636906e717986844e5b4227e7f127a`
- `origin/main`: `079d779e11c2923cd2b03e1a7ea8b5d08ca622a1`
- Ahead/behind after `git fetch --prune origin`: ahead 4, behind 0
- Remote: `https://github.com/qianmuyan001/assignment-app.git`
- Version: 2.0.0; version synchronization passed
- Source state: dirty, with the complete Phase 2.5 work still uncommitted
- Pre-existing `.workbuddy/`: left untracked and untouched

The inspected worktree contains `AttachmentFileStore.cs`,
`WindowsNotificationScheduler.cs`, the current `TaskEditorDialog.xaml.cs` and
`MainWindow.xaml.cs`, and a 48-case Core harness. A clone of `origin/main` alone
does not contain this exact Phase 2.5 source and must not be used for acceptance.

Full source-state evidence:

```text
/private/tmp/assignment-app-evidence/phase2-5-windows-20260831-macos/git-state.txt
/private/tmp/assignment-app-evidence/phase2-5-windows-20260831-macos/git-diff-stat.txt
/private/tmp/assignment-app-evidence/phase2-5-windows-20260831-macos/untracked.txt
```

## Reuse decision

| Capability | Reused implementation | Decision |
| --- | --- | --- |
| WinUI UI | Existing WinUI 3, Windows App SDK, repository view/dialog code | No UI framework added |
| Attachment storage | `System.IO`, UUID storage keys, staging moves, `SHA256`, Windows pickers/launcher | No storage library added |
| Notifications | Windows App SDK `AppNotificationManager` and official scheduled-toast bridge | No daemon or third-party notification package added |
| Data/testing | Existing `AssignmentNative.Core`, Microsoft.Data.Sqlite, 48-case temporary-database harness | Schema v3 unchanged |
| Packaging | Existing `native/windows/publish-x64.ps1` | Must run unchanged, without `-SkipSmokeTest`, on an interactive Windows x64 host |

Installed skills and repository tooling were checked first. The `code-review`
workflow was used for independent specification and standards passes. No
installed tool can truthfully emulate a logged-in Windows desktop on this
Apple-silicon macOS host, and no new dependency was installed.

Microsoft's current documentation confirms that scheduled app notifications
use an `AppNotificationBuilder` payload with `ScheduledToastNotification`, and
that unpackaged .NET apps register through `AppNotificationManager.Register()`.
The self-contained deployment documentation also requires guarding optional app
notification support with `IsSupported()`. The source follows those platform
patterns.

References:

- <https://learn.microsoft.com/en-us/windows/apps/develop/notifications/app-notifications/app-notifications-scheduled>
- <https://learn.microsoft.com/en-us/windows/apps/develop/notifications/app-notifications-dotnet>
- <https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/self-contained-deploy/deploy-self-contained-apps>

## Source fixes completed

### Attachments

- Reconciliation now runs during application startup, not only when an existing
  professional-mode task editor is opened.
- Active reparse-point payloads are reported as missing/unsafe; open and export
  remain disabled for them.
- Imports use a UUID payload name, staging copy, real SHA-256, and database/file
  rollback. Deletes stage the payload and restore it if metadata deletion fails.
- Extensionless files export through a folder picker using the safe original
  filename. Existing destinations are not silently overwritten.
- Startup reconciliation restores interrupted deletes, removes partial staging
  files, reports missing payloads, and removes safe unreferenced UUID payloads.

### Notifications and reminders

- Added reminder-time editing using a Flyout, avoiding a nested `ContentDialog`
  inside the task editor.
- Date/time controls and dynamic edit, toggle, remove, open, export, and subtask
  controls have contextual automation names.
- Reminder add/edit/disable/delete immediately schedules or cancels its Windows
  request and reports adapter failure without rolling back valid task data.
- Task mutation, task completion/deletion, and subtask-derived parent completion
  run notification reconciliation.
- Notification registration failures are retryable; a transient exception no
  longer disables the adapter for the remainder of the process.
- Startup reconciliation removes stale requests and rebuilds future enabled
  requests for active tasks.

Schema v3 stores the reminder as an exact UTC trigger plus metadata. Therefore a
task title/deadline edit rebuilds notification content at the reminder's stored
trigger; it does not silently turn an independently chosen reminder into a
deadline-relative reminder. Deadline-relative lead-time behavior is Phase 3A
scope and was intentionally not added here.

### Usability

- Reminder date/time fields expose visible headers and accessibility names.
- Operational failures use the task editor's visible assertive validation text
  rather than attempting to show another modal dialog.
- Missing/unsafe attachments have a visible state and unavailable actions.
- No recurrence-rule editor or non-functional placeholder was added.

## Automated checks actually run

Host used for these checks:

```text
macOS 27.0 (26A5416b), arm64
.NET SDK 10.0.302
PowerShell 7.6.4
```

| Check | Result |
| --- | --- |
| `python3 scripts/check_version_sync.py` | Passed: all reported versions 2.0.0 |
| Windows Core Release harness, with .NET major roll-forward | **48/48 passed** |
| Restore exactly as the Windows command on macOS | Expected host rejection: `NETSDK1100` |
| Restore with `EnableWindowsTargeting=true` for source inspection only | Passed |
| Debug x64 WinUI build on macOS | Failed at Windows-only `XamlCompiler.exe`; not Windows build evidence |
| Release x64 WinUI build on macOS | Failed at Windows-only `XamlCompiler.exe`; not Windows build evidence |
| Isolated notification-adapter C# compilation, PRI generation disabled | Passed, 0 warnings and 0 errors; source-only evidence |
| `git diff --check` | Passed |

Logs:

```text
/private/tmp/assignment-app-evidence/phase2-5-windows-20260831-macos/version-sync.log
/private/tmp/assignment-app-evidence/phase2-5-windows-20260831-macos/core-tests.log
/private/tmp/assignment-app-evidence/phase2-5-windows-20260831-macos/restore.log
/private/tmp/assignment-app-evidence/phase2-5-windows-20260831-macos/restore-enable-windows-targeting.log
/private/tmp/assignment-app-evidence/phase2-5-windows-20260831-macos/build-debug.log
/private/tmp/assignment-app-evidence/phase2-5-windows-20260831-macos/build-release.log
/private/tmp/assignment-app-evidence/phase2-5-windows-20260831-macos/notification-adapter-compile-no-pri.log
/private/tmp/assignment-app-evidence/phase2-5-windows-20260831-macos/host.txt
```

The Core lifecycle test uses a disposable workspace and now also checks active
symbolic-link/reparse payload rejection when the host permits symbolic-link
creation. The test workspace is deleted by the harness. No repository or user
database was opened by the test.

## Required real-Windows acceptance matrix

| Requirement | Status |
| --- | --- |
| Windows x64 version/build, Visual Studio workloads, WebView2, notification/DND inventory | **未验证** |
| WinUI Debug and Release x64 compilation | **未验证** |
| Self-contained `publish-x64.ps1` without `-SkipSmokeTest` | **未验证** |
| `AssignmentNative.exe`, launch smoke, schema v3 and `quick_check=ok` | **未验证** |
| Logged-in desktop launch, restart persistence, resize, maximize, high DPI | **未验证** |
| Task CRUD, smart lists, search/filter/sort, modes, theme | **未验证** |
| Course/project/tag/subtask interactive CRUD and derived progress | **未验证** |
| File picker/import/open/export/delete/missing-file/restart UI flow | **未验证** |
| Notification status, schedule, actual delivery, edit, disable, cancel, restart reconciliation | **未验证** |
| Keyboard focus, Tab/Enter/Escape, screen-reader names, narrow/wide/error/empty states | **未验证** |

The host has no Windows VM, remote interactive Windows session, Visual Studio,
or Windows desktop automation path. Running the publish script here would stop
at Windows executable tooling and could not provide the required GUI or
notification evidence, so it was not misreported as an acceptance run. The
remote branch also lacks the dirty Phase 2.5 worktree, so an existing remote CI
run would test the wrong source.

## Artifacts

- Windows publish directory: **not generated**
- `AssignmentNative.exe`: **not generated**
- Executable SHA-256: **not available**
- Authenticode status: **not available**
- Launch smoke log: **not available**
- Main-window screenshots: **not available**
- Notification-delivery screenshot: **not available**

No package, signature, screenshot, notification delivery, or Windows launch was
fabricated.

## Data safety and scope

- Database schema remains v3; no migration or schema file changed in this
  Windows closeout.
- No real user database, backup, WAL, or SHM file was opened, migrated, reset,
  overwritten, or deleted.
- No push, tag, PR, Release, signing, or public publication was performed.
- Phase 3A and all later-phase features remain untouched.

## Gate decision and next action

Windows Gate A remains **未验证（未通过）** because all real Windows build,
publish, launch, interaction, attachment, accessibility, and notification
delivery evidence is absent. The only valid next action is to transport this
exact dirty worktree (not `origin/main`) to a logged-in Windows x64 environment,
run `native/windows/publish-x64.ps1` without `-SkipSmokeTest`, then complete and
record the interactive matrix above. Even after Windows passes, overall Gate A
still requires the outstanding Apple organization, attachment, and delivered
notification manual acceptance; Phase 3A must not start before that gate passes.

## Independent source-review summary

- Specification pass: the source-level gaps for reminder editing, startup
  attachment reconciliation, accessibility labels, subtask notification
  reconciliation, and stale README claims were fixed. The remaining blockers
  are real Windows evidence and the explicitly deferred deadline-relative rule.
- Standards pass: startup reconciliation, reparse-point handling, transient
  notification retry, extensionless export, and nested-dialog risks were fixed.
  `TaskEditorDialog` remains a large divergent-change area; splitting it before
  a real Windows compile would increase risk, so that refactor is deferred.
