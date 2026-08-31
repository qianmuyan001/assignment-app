# Phase 2.5 closeout acceptance

Date: 2026-08-31

Repository: `/Users/qianmuyan/Documents/GitHub/assignment-app`

Baseline revision: `e487dc21bc636906e717986844e5b4227e7f127a`

Scope: Gate A only; Phase 3A is conditional and was not started.

## Gate result

**Gate A is not accepted.** Apple source built and its automated tests passed;
the Web flow ran in a real Chrome browser; shared, backend, Apple, and Windows
Core suites passed. A real Windows x64 desktop was not available, so WinUI
build, self-contained publish, signed-in desktop launch, and interactive
acceptance remain unverified. Apple organization/attachment/notification source
also lacks a complete manual UI/delivered-notification acceptance recording.

Because Gate A did not pass, **Schema v4 and Phase 3A learning scenarios were
not created or modified**. No timetable, exam, or Phase 3 assignment-reminder UI
was added.

## Reuse choices

| Capability | Reused solution | New dependency decision |
| --- | --- | --- |
| Apple | SwiftUI, SQLite3, FileManager, CryptoKit, QuickLook, UniformTypeIdentifiers, UserNotifications; existing repository/view-model boundaries; Xcode 27 beta fallback because XcodeBuildMCP was unavailable | No product dependency added |
| Windows | Existing WinUI 3/Windows App SDK, Microsoft.Data.Sqlite, System.IO/SHA256, AppNotificationManager and scheduled toast APIs | No product dependency added |
| Web | Existing FastAPI, SQLAlchemy, vanilla JS and native browser file APIs | No product dependency added |
| System notifications | Apple UserNotifications and Windows App SDK app notifications | Native APIs are maintained with each OS and avoid a cross-platform daemon |
| Attachment storage | Platform filesystem APIs plus SQLite metadata; immutable `attachments/<UUID>` key | No BLOB library or file-management framework added |
| Dates/course schedule | Existing shared local-wall-time/IANA rules; future native DateComponents, DateOnly/TimeOnly, TimeZoneInfo and Python zoneinfo | Reviewed only; Gate B did not open |

UI work followed the installed `frontend-design` and `apple-design` guidance:
native controls, existing visual language, visible states, keyboard and
accessibility semantics, and restrained motion. `ios-debugger-agent` routing
was checked; repository XcodeBuildMCP was unavailable, so the user-approved
`/Applications/Xcode-beta.app` fallback was used. A real Chrome 151 session was
driven through its official DevTools Protocol; the only ephemeral helper was
`websocket-client 1.9.1` in `/private/tmp`, not a repository dependency.

## Implemented source

### Apple

- Fixed the real protocol/build mismatches: `fetchProjects(courseID:nil,
  includeDeleted:)`, `fetchTagLinks`, `UniformTypeIdentifiers`, and repository
  initialization.
- Added `AttachmentFileStore`: import from the system picker, immutable payload
  key, atomic staging, real SHA-256, QuickLook/open, share/export with the safe
  original filename, delete rollback, missing-file reporting, interrupted-delete
  recovery, and orphan/presentation-cache cleanup.
- Added `AssignmentNotificationScheduler`: authorization/status, settings link,
  one-shot schedule/reschedule, pending and delivered cancellation, disable,
  and startup reconciliation. Task completion/deletion/deadline/title changes
  are serialized through the view model so stale async snapshots cannot restore
  a canceled request. Notification errors do not block database work.
- Added reminder enable/disable UI. Removed the new recurrence text field because
  the native adapter does not yet implement recurring delivery. Existing valid
  `repeat_rule` data remains untouched and receives its first one-shot schedule.
- Fixed the Apple workflow's invalid job-level `${{ runner.temp }}` usage by
  writing the derived-data path to `$GITHUB_ENV` at runtime.

### Windows

- Added `AttachmentFileStore` to Core with import, SHA-256, safe UUID paths,
  staging, rollback, missing-file detection, interrupted-delete recovery, and
  orphan cleanup.
- Wired WinUI file selection, open, export, delete, warning states, and reminder
  time editing plus enable/disable actions. Extensionless exports preserve the
  original filename instead of inventing a `.file` suffix.
- Added `WindowsNotificationScheduler` using Windows App SDK notification status
  and scheduled toasts, including schedule/reschedule/cancel/reconcile behavior.
  Permission, registration, and service failures are caught and surfaced rather
  than escaping into startup or task CRUD; transient failures remain retryable.
- Attachment staging/orphan reconciliation now runs at application startup.
  Active reparse-point payloads are reported as missing/unsafe, and subtask-driven
  parent completion triggers notification reconciliation.
- Fixed project picker selection to read the project control rather than the
  course control.

The Windows Core code ran on macOS. WinUI source could not be compiled past the
Windows-only XAML compiler and therefore is **not accepted as compiled source**.

### Web/backend

- Added streamed attachment upload and managed payload storage beside the
  selected database, with a 100 MiB limit, atomic rename, real SHA-256, safe UUID
  path resolution, delete rollback, interrupted-operation recovery, missing-file
  response, and orphan cleanup.
- Added inline/open and download/export endpoints while retaining the metadata
  endpoint for compatibility.
- Restricted inline types to a small safe allowlist. Other content downloads
  with `Content-Security-Policy: sandbox; default-src 'none'` and
  `X-Content-Type-Options: nosniff`, preventing active attachment content from
  executing in the application origin.
- Made organization-loading failures visible instead of silently suppressing
  them.

## Actual changed files

```text
.github/workflows/apple.yml
README.md
CHANGELOG.md
docs/phase-reports/phase-2.md
docs/phase-reports/phase-2-5.md
docs/phase-reports/phase-2-5-windows.md
backend/app/main.py
backend/app/routers/organization.py
backend/app/schemas.py
backend/app/services/attachment_store.py
backend/app/static/script.js
backend/tests/test_api.py
native/apple/README.md
native/apple/AssignmentApp2/AssignmentNotificationScheduler.swift
native/apple/AssignmentApp2/AssignmentViewModel.swift
native/apple/AssignmentApp2/AttachmentFileStore.swift
native/apple/AssignmentApp2/ContentView.swift
native/apple/AssignmentApp2/OrganizationManagerView.swift
native/apple/AssignmentApp2/OrganizationModels.swift
native/apple/AssignmentApp2/OrganizationRepository.swift
native/apple/AssignmentApp2/SQLiteOrganizationRepository.swift
native/apple/AssignmentApp2/TaskEditorView.swift
native/apple/AssignmentApp2/Views.swift
native/apple/AssignmentApp2Tests/SchemaV3RepositoryTests.swift
native/windows/README.md
native/windows/App.xaml.cs
native/windows/AssignmentNative.Core.Tests/Program.cs
native/windows/AssignmentNative.Core/AttachmentFileStore.cs
native/windows/AssignmentNative.Core/TaskOrganizationModels.cs
native/windows/AssignmentNative.Core/TaskOrganizationRepository.cs
native/windows/MainWindow.xaml
native/windows/MainWindow.xaml.cs
native/windows/Services/WindowsNotificationScheduler.cs
native/windows/TaskEditorDialog.xaml
native/windows/TaskEditorDialog.xaml.cs
```

`.workbuddy/` was pre-existing and remains untracked and untouched.

## Tests and runtime evidence

| Command/scope | Result |
| --- | --- |
| `python3 -m unittest discover -s shared/tests -v` | 57/57 passed |
| `python3 -m unittest discover -s backend/tests -v` | 19/19 passed |
| `python -m pylint --errors-only $(git ls-files '*.py')` in an isolated requirements environment | passed, no errors |
| `python3 scripts/check_version_sync.py` | passed; root/README/CHANGELOG/Apple/Windows all 2.0.0 |
| `git diff --check` | passed |
| `DOTNET_ROLL_FORWARD=Major dotnet run --project native/windows/AssignmentNative.Core.Tests/AssignmentNative.Core.Tests.csproj -c Release` | 48/48 passed; Core only |
| iPad `AssignmentApp2` unit test, fixed iPadOS 18.5 simulator | 47/47 passed |
| Apple Silicon Mac Catalyst `AssignmentApp2` unit test | 47/47 passed |
| iPad `AssignmentApp2UISmoke` | 3/3 passed |
| Current-source iPad Simulator build | passed |
| Current-source Catalyst clean package build | passed |
| Packaged Catalyst process/schema smoke | passed; process alive, schema v3, 22 assignment columns, 30 contract indexes, 12 contract triggers |
| Chrome 151 Phase 2 flow | `all_passed=true`: empty/error/recovery, organization CRUD, Unicode task persistence, tag link, subtask CRUD, attachment open/export/delete, reminder CRUD, refresh, keyboard search, accessibility names, 390 px responsive layout |
| macOS WinUI restore | passed |
| macOS WinUI build | failed as expected: Windows `XamlCompiler.exe` cannot execute; this is not Windows evidence |
| Isolated Windows notification-adapter C# compilation on macOS | passed with 0 warnings/errors after disabling Windows PRI generation; source-only evidence |
| Real Windows x64 build/publish/desktop launch | **未验证** |

Final Apple result bundles:

```text
/private/tmp/assignment-app-ipad-unit-final3.xcresult
/private/tmp/assignment-app-catalyst-unit-final2.xcresult
/private/tmp/assignment-app-ipad-ui-final2.xcresult
```

Web and Windows-host-limit evidence:

```text
/private/tmp/assignment-app-evidence/phase2-5-20260831/web-browser-report.json
/private/tmp/assignment-app-evidence/phase2-5-20260831/windows/restore-macos.log
/private/tmp/assignment-app-evidence/phase2-5-20260831/windows/build-macos.log
/private/tmp/assignment-app-evidence/phase2-5-windows-20260831-macos/
```

## Database and user-data safety

- Database target remains **schema v3**. Phase 2.5 adds no table, column,
  trigger, migration, or version change.
- Schema v1/v2-to-v3 online-backup, transactional migration, integrity,
  fingerprint, rollback, and fail-closed tests remain green in shared, Apple,
  backend, and Windows Core suites.
- Attachment bytes are never written into `assignments` or an SQLite BLOB.
- All tests, browser sessions, and package launch smoke used temporary or
  explicitly isolated databases. No real user database was opened for writing,
  migrated, reset, or deleted.

## Artifacts and screenshots

Final local Apple test package:

```text
/private/tmp/assignment-app-artifacts/apple/debug-20260831-060127Z/Assignment App.app
/private/tmp/assignment-app-artifacts/apple/debug-20260831-060127Z/Assignment-App-2.0.0-Catalyst-Debug-arm64.zip
/private/tmp/assignment-app-artifacts/apple/debug-20260831-060127Z/build-info.txt
/private/tmp/assignment-app-artifacts/apple/debug-20260831-060127Z/logs/
```

- Architecture: arm64 Mac Catalyst
- Version: 2.0.0
- Baseline Git SHA: `e487dc21bc636906e717986844e5b4227e7f127a`
- Source state: dirty, fully disclosed in `build-info.txt`
- Signing: local ad-hoc; App Sandbox enabled; not notarized
- ZIP SHA-256:
  `03b936f75bf01bc17193f6ec2f7e6d6c8f9a35293b3b1a5131945568575ce7b9`

No Windows publish directory or installer was generated.

Screenshots and UI attachments:

```text
/private/tmp/assignment-app-evidence/phase2-5-20260831/ipad-ui-final2-attachments/
/private/tmp/assignment-app-evidence/phase2-5-20260831/catalyst-wide.png
/private/tmp/assignment-app-evidence/phase2-5-20260831/catalyst-narrow.png
/private/tmp/assignment-app-evidence/phase2-5-20260831/web-empty-wide.png
/private/tmp/assignment-app-evidence/phase2-5-20260831/web-phase2-wide.png
/private/tmp/assignment-app-evidence/phase2-5-20260831/web-phase2-narrow.png
/private/tmp/assignment-app-evidence/phase2-5-20260831/web-error-state.png
```

The iPad UI bundle/attachments cover expanded and compact sidebar, largest text,
search expanded/restored, portrait, and landscape. Catalyst screenshots verify
wide and narrow main-window layouts. They do not constitute a full manual
organization/attachment/notification UI acceptance pass.

## Remaining blockers

1. Run restore, build, 48 Core tests, self-contained x64 publish, process/schema
   smoke, and interactive WinUI CRUD/notification acceptance in a signed-in
   real Windows x64 desktop session.
2. Manually accept Apple course/project/tag/subtask/attachment/reminder CRUD,
   file import/open/export/delete, notification authorization/delivery/cancel,
   VoiceOver, and Reduce Motion on the final package or matching build.
3. Recurring native notifications are intentionally not implemented. Schema v3
   retains validated rules, but only the first occurrence is scheduled.

## Repository state and non-fabrication

- Branch: `main`
- Baseline HEAD: `e487dc21bc636906e717986844e5b4227e7f127a`
- `origin/main`: `079d779e11c2923cd2b03e1a7ea8b5d08ca622a1`
- Divergence at inspection: local ahead 4, behind 0
- Published tags: `v1.0.0` only
- No push, tag, PR, Release, formal signing, notarization, or public publish was
  performed.

No project, test, screenshot, startup, package, signature, Windows environment,
or result was fabricated. Unexecuted work is marked **未验证**. The only next
recommended action is the real Windows x64 acceptance run; Gate B must remain
closed until Gate A is accepted.
