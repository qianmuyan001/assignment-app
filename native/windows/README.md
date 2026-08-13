# Windows native app

This is the independent Windows Assignment App 2.0 preview. It uses WinUI 3,
Windows App SDK, Microsoft.Data.Sqlite, and a UI-independent Core library.

## Included in the 2.0 preview

- Manual task add, edit, delete, and status changes.
- All, Today, This Week, Overdue, and Completed task views.
- Title/course/description search; status, course, and priority filters.
- Due-time and priority sorting.
- Loading, error, empty, validation, and delete-confirmation states.
- Persistent simple/professional display mode and system/light/dark theme.
- Existing signed-in WebView2 source browser and local-AI review flow.
- Versioned SQLite schema v3 migration with an online backup, transactional
  validation, rollback verification, and in-place online-backup recovery.
- Phase 1 Core repositories for courses, projects, tags, task-tag links,
  subtasks, attachment metadata, reminders, stable UUIDs, soft deletion, and
  subtask-derived task progress.

The simple and professional modes read and write the same task record. Hiding
description, priority, or source link never clears those fields.

## Architecture

```text
WinUI views -> Services shim -> AssignmentNative.Core -> SQLite
                                  |-> task rules
                                  |-> migration/backup
                                  `-> persisted UI settings
```

`AssignmentNative.Core` targets plain `net8.0`, so its data and rule tests run
without WinUI. The WinUI executable targets
`net8.0-windows10.0.19041.0` and is published separately for Windows x64.

## Database location and compatibility

Database resolution order is:

1. Absolute path in `ASSIGNMENT_DB_PATH`.
2. `backend/assignments.db` when running from a repository checkout.
3. `%LOCALAPPDATA%\AssignmentNative\assignments.db` for an installed or copied
   publish directory.

For a 1.0 database outside the repository, set the environment variable before
the first 2.0 launch:

```powershell
$env:ASSIGNMENT_DB_PATH = 'C:\absolute\path\to\assignments.db'
```

The first successful schema upgrade takes a bounded cross-process migration
lock, creates a sibling recovery backup through SQLite Online Backup, and then
runs an immediate transaction before setting `PRAGMA user_version=3`. Existing
v1/v2 rows, integer IDs, wall-clock due text, timestamps, and Unicode are
retained. Additive v2 extension columns are retained. The v1 compatibility
rebuild preserves the documented v1 task payload; unknown v1 extension columns
remain recoverable in the mandatory pre-migration backup but are not promised
in the upgraded live schema. A database-lineage UUID scopes deterministic UUID v5
values for migrated tasks and courses; all new records use UUID v4. Physical
SQLite statuses remain `not_started`, `in_progress`, and `completed`; the Core
layer exposes `todo`, `in_progress`, and `done`.

If migration fails, Core first verifies the transaction rollback. Any changed
live state that cannot be matched exactly to the fingerprint captured from this
specific failed migration attempt is preserved and automatic restore is refused,
including a concurrent valid v3 database or a healthy newer schema. Unknown
rollback evidence fails closed. Only a state proven to be this migration's failed
transaction is restored with SQLite Online Backup into the existing database
file, preserving the live inode. Recovery rechecks the destination while holding
an SQLite `EXCLUSIVE` lock that remains held through the backup overwrite. A
failed or unverifiable migration prevents normal database use.
Backups are published only after their own `quick_check` succeeds and are never
overwritten.

Schema v3 stores attachment metadata only. Payload files belong under the app
data directory using the immutable `attachments/<uuid>` relative key; no BLOB
or untyped payload column is permitted. Soft deletion uses canonical UTC audit
timestamps and does not erase hidden task fields.

Legacy due dates remain local wall-clock `YYYY-MM-DD HH:mm:ss` values without
an offset and are never silently shifted during migration. New audit,
completion, reminder, and deletion timestamps use canonical UTC ISO-8601 text.
Optional task `timezone_id` values use portable IANA syntax. Today and week
filters use the computer's current local timezone; a week starts Monday.
Offset-bearing legacy due dates are rejected instead of silently converted.

Phase 1 adds the data contracts and repositories only. Course/project/tag,
subtask, attachment, and reminder WinUI screens are intentionally deferred to
Phase 2; this README does not claim those native pages exist yet.

## Prerequisites

Use a Windows x64 machine with:

- Windows 10 1809 (build 17763) or newer;
- .NET 8 SDK;
- Visual Studio 2022 with **.NET desktop development**, **Desktop development
  with C++**, and Windows App SDK build tools.

The project is unpackaged (`WindowsPackageType=None`). MSIX remains a later
release task; it is not required for this self-contained test build.

## Test

From the repository root:

```powershell
dotnet run --project .\native\windows\AssignmentNative.Core.Tests\AssignmentNative.Core.Tests.csproj -c Release
```

The 30-test harness covers existing task CRUD/rules plus schema v3 migration,
shared UUID and Unicode-normalization vectors, organization CRUD, task tags,
derived subtask progress, safe attachment metadata, canonical recurrence,
soft-delete restore, immutable database identity, concurrent initialization,
and failure recovery. It creates temporary databases only.

## Build and run

```powershell
dotnet restore .\native\windows\AssignmentNative.Windows.csproj -r win-x64 -p:Platform=x64
dotnet build .\native\windows\AssignmentNative.Windows.csproj -c Debug -r win-x64 -p:Platform=x64 --no-restore
dotnet run --project .\native\windows\AssignmentNative.Windows.csproj -c Debug -r win-x64 -p:Platform=x64
```

## Create the x64 test publish directory

```powershell
.\native\windows\publish-x64.ps1
```

The script restores dependencies, runs the Core tests, publishes a
self-contained x64 directory, and starts `AssignmentNative.exe`. It waits up to
30 seconds for the isolated database to satisfy the complete current schema,
index, and `PRAGMA quick_check` contract before stopping the process. The launch
check restores the caller's `ASSIGNMENT_DB_PATH`; it never migrates the
repository or user database. Output is unique per run:

```text
artifacts\windows\x64-<UTC timestamp>\
  build-info.txt
  logs\
  publish\AssignmentNative.exe
```

The script refuses to overwrite an existing artifact directory. CI additionally
uses `-RequireCleanTree`, and `build-info.txt` records the Git SHA, dirty state,
Windows/.NET environment, architecture, tests, launch smoke, executable hash,
and Authenticode status.

To publish without the launch smoke test (for example in a headless runner):

```powershell
.\native\windows\publish-x64.ps1 -SkipSmokeTest
```

Copy the entire publish directory to the test computer and run
`AssignmentNative.exe`. Web source scanning still requires the Microsoft Edge
WebView2 Runtime on that computer.

## Continuous integration

`.github/workflows/windows.yml` runs the same script on a real GitHub-hosted
`windows-2025` x64 runner and uploads the timestamped artifact. The workflow has
not passed until its logs show the Core suite, WinUI publish, live process, and
isolated database verification; macOS builds are never accepted as WinUI proof.

## macOS host limitation

The Core library and its tests can run on macOS. A complete WinUI build cannot:
the Windows App SDK invokes a Windows XAML compiler executable/build task. Run
the build and publish commands above on Windows x64 to produce and launch-verify
the deliverable.
