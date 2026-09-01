# Phase 2.5 Windows x64 acceptance

Date: 2026-09-01

Result: **Gate W0 passed. Gate W1 remains not accepted because portable
cross-directory notification cold activation is not closed.** All other W1
automated, build, launch, interaction, persistence, accessibility, attachment,
and visible-delivery checks completed in this run.

## Source identity

- Repository: `D:\Desktop\assignment-app-windows-parity`
- Branch: `release/1.1`
- Tested source revision: `623fbb30b8f7400c8e88b37c497a10dc2915ef9e`
- Remote: `https://github.com/qianmuyan001/assignment-app.git`
- Version: 1.1.0
- Database schema: v3
- Final package source tree: clean

The Phase 2.5 reports and the required Windows attachment, notification,
task-editor, and main-window implementations are present. No trustworthy Phase
3A report, Schema v4 specification, migration, model, or Apple implementation
was found. Phase 3A and Schema v4 work were not started.

## Source fixes

- Added subtask title editing to the WinUI editor.
- Kept parent task status and progress synchronized after child completion,
  deletion, and parent save. This fixes a desktop regression where saving a
  stale editor reset a completed child and its parent to todo/0%.
- Focused the notified task row instead of only the containing list.
- Added missing Automation Names to task actions, organization controls,
  browser controls, source login controls, and WebView content.
- Added task-row accessibility summaries for Narrator.
- Added isolated database/settings activation arguments and an explicit,
  acceptance-only toast registration reset path.
- Added root `tzdata` dependency so Windows backend tests pass in a fresh
  environment without a manual package install.

Schema v3 and shared field semantics were not changed.

## Automated verification

All checks used temporary or explicitly isolated data on Windows 11 x64
10.0.22631.

| Check | Result | Evidence |
| --- | --- | --- |
| Fresh dependency install | Passed, including `tzdata` from root manifest | `artifacts/windows/w1-acceptance-20260901T114347Z/logs/python-install-final.log` |
| Version synchronization | Passed, all platforms 1.1.0 | `version-sync-final.log` |
| Shared contract tests | **57/57 passed** | `shared-tests-final.log` |
| Backend tests | **19/19 passed** | `backend-tests-final.log` |
| Pylint errors-only | Passed | `pylint-errors-final.log` |
| Windows Core Release harness | **50/50 passed** | `core-tests-final.log` |
| `dotnet format --verify-no-changes` | Passed, 0 files changed | `dotnet-format-windows-rerun.log` |
| WinUI Debug x64 | Passed, 0 warnings/errors | `winui-debug-final.log` |
| WinUI Release x64 | Passed, 0 warnings/errors | `winui-release-final.log` |
| `git diff --check` | Passed | final Git inspection |

Evidence root:

```text
artifacts/windows/w1-acceptance-20260901T114347Z/
```

## Publish and launch

`native/windows/publish-x64.ps1 -RequireCleanTree` ran without
`-SkipSmokeTest`.

| Requirement | Result |
| --- | --- |
| Self-contained Release x64 publish | Passed |
| Core tests inside publish script | 50/50 passed |
| Isolated published-EXE startup | Passed |
| Process stayed alive | Passed |
| Startup readiness | 2169 ms |
| Isolated database schema / quick check | v3 / `ok` |
| File version | 1.1.0.0 |
| Authenticode | Not signed |

Artifact root:

```text
artifacts/windows/x64-w1-final-20260901T2102/
```

- EXE SHA-256: `DF8A4D51ADC6581B70071101862F00AFB0F22D05EE7720C98F8A8CE41FB8B485`
- ZIP SHA-256: `9D6A5C82C1FB77AA18B150BC28B1744D068B43EE2B6122610559753AC6A48B58`
- Authoritative package metadata: `build-info.txt`

This is an unsigned test package, not an installer, Store package, signed
release, or formal release.

## Desktop acceptance

The app ran in the logged-in Windows x64 desktop with an isolated database,
settings file, and attachment directory. No real user database or attachment
directory was opened or migrated.

| Area | Source implemented | Automated | Actual desktop | Result / evidence |
| --- | --- | --- | --- | --- |
| Add/edit/delete/complete | Yes | Yes | Yes | Passed, including delete confirmation and restart persistence |
| todo/in_progress/done | Yes | Yes | Yes | Passed |
| Due/course/description/link/priority | Yes | Yes | Yes | Passed |
| Today/week/overdue/completed | Yes | Yes | Yes | Passed through Core and desktop navigation |
| Search/filter/sort | Yes | Yes | Yes | Passed |
| Simple/professional/theme | Yes | Yes | Yes | Professional and dark theme persisted after restart; `settings-dark.png` |
| Courses/projects/tags | Yes | Yes | Yes | Create/update/delete passed; SQLite soft deletion verified |
| Subtask CRUD/progress | Yes | Yes | Yes | Add/edit/complete/delete passed; save no longer resets derived state |
| Attachments | Yes | Yes | Yes | Import/SHA/open/export/delete passed in prior matching Phase 2.5 desktop evidence |
| Attachment defenses | Yes | Yes | Targeted | Missing/orphan/rollback/path/reparse cases covered by Core lifecycle tests |
| Notification schedule/delivery | Yes | Indirect | Yes | Visible banner and notification-center card passed; `cold-start-new-clsid-banner-final.png` |
| Notification warm activation | Yes | No | Yes | Existing running app foreground activation passed |
| Notification cold activation | Yes | No | **Blocked** | See notification finding below |
| Navigation/search behavior | Yes | Partial | Yes | Compact/expanded/narrow and search focus/clear/Escape/outside click passed |
| Keyboard/Tab/Tooltip | Yes | Partial | Yes | Main, settings, editor, and organization focus sequences passed |
| Narrator | Yes | No | Yes | Narrator process ran; 12 consecutive named focus targets in `narrator-tab-final.log` |
| High DPI | Yes | No | Yes | 150% / 144 DPI, DPI-aware process, no overlap |
| Reduce Motion | Yes | N/A | Yes | No custom Storyboard/Composition animation; system WinUI behavior remains authoritative |

Representative screenshots are in
`artifacts/windows/w1-acceptance-20260901T114347Z/screenshots/`, including
dark-theme persistence, notification delivery, notification-center expansion,
and Narrator runtime evidence. Earlier Phase 2.5 evidence retains task editor,
attachment, organization, search, compact sidebar, and notification settings
screenshots.

## Notification finding

Visible scheduled delivery is fixed and passed. Windows settings show the
stable `Assignment App` sender with banners, notification center, sound, and
important delivery enabled; notification-center priority is High and global Do
Not Disturb is off.

Cold activation remains blocked for a portable executable moved between build
directories in the same Windows logon session:

1. The stable CLSID registry value and Start menu shortcut were rewritten to
   the current Debug executable and isolated arguments.
2. Clicking the explicit `Open Assignment App` action still caused the Windows
   COM service to use a previously cached portable artifact path.
3. `ToastNotificationManagerCompat.Uninstall()` plus re-registration did not
   flush that session cache.
4. A new test CLSID was visible under HKCU/HKCR but cold `CoCreateInstance`
   returned `REGDB_E_CLASSNOTREG`; manually starting the same EXE as a COM server
   registered its class factory successfully.
5. The experimental CLSID and registry key were removed, and source retained
   the stable production CLSID.

This must not be reported as a cold-start pass. The next acceptance run should
use a fresh Windows logon after the current package registration, or install
and update the app in one stable directory before repeating action-button cold
activation and target-row focus verification. No reboot or logoff was forced
during this interactive Codex session.

## Final status

- Source implemented: **Yes**, for the current Phase 2.5 scope.
- Automated tests passed: **Yes**, 57 shared + 19 backend + 50 Windows Core.
- Windows builds passed: **Yes**, Debug and Release x64 with 0 warnings/errors.
- Desktop launch passed: **Yes**, including clean self-contained smoke.
- Manual interaction passed: **Yes**, for task, organization, subtask,
  persistence, navigation, search, keyboard, accessibility, theme, and DPI.
- Notification actual delivery passed: **Yes**.
- Notification cold activation passed: **No; blocked by portable
  cross-directory COM activation cache in the current logon session.**
- Remaining Apple difference: no current Phase 2.5 feature gap was found in
  source/domain behavior; runtime Preview parity cannot be declared until the
  cold-start evidence is closed.

Therefore Gate W1 remains **not passed**, and this report does not claim:

> Windows Preview 已追平当前 Apple 版本。

Current accurate statement:

> Windows 1.1 source, automated behavior, desktop interaction, accessibility,
> packaging, and notification delivery match the current Apple Phase 2.5 scope;
> portable notification cold activation still requires a fresh-session or
> stable-install-path acceptance rerun. Apple Phase 3A has not formed a portable
> implementation baseline.
