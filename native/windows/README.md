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
- Versioned SQLite v2 migration with an online backup and failure recovery.

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

The first successful 2.0 open creates a sibling recovery backup and then sets
`PRAGMA user_version=2`. Existing rows are retained and receive priority
`medium`. Physical SQLite statuses remain `not_started`, `in_progress`, and
`completed`; the Core layer exposes `todo`, `in_progress`, and `done`. Migration
failure restores the backup and prevents normal database use.

Dates are stored as local wall-clock `YYYY-MM-DD HH:mm:ss` values without an
offset. Today and week filters use the computer's current local timezone; a
week starts Monday. Offset-bearing due dates are rejected instead of being
silently converted.

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

The harness covers CRUD, state mapping, date views, sorting, search/filtering,
mode preservation, migration, failed-migration recovery, special characters,
and the shared cross-platform fixture. It creates temporary databases only.

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
self-contained x64 directory, starts `AssignmentNative.exe` for five seconds,
and stops it after confirming that it remained running. The launch check forces
an isolated temporary database, then restores the caller's
`ASSIGNMENT_DB_PATH`; it never migrates the repository or user database. Output:

```text
artifacts\windows-x64\
```

To publish without the launch smoke test (for example in a headless runner):

```powershell
.\native\windows\publish-x64.ps1 -SkipSmokeTest
```

Copy the entire publish directory to the test computer and run
`AssignmentNative.exe`. Web source scanning still requires the Microsoft Edge
WebView2 Runtime on that computer.

## macOS host limitation

The Core library and its tests can run on macOS. A complete WinUI build cannot:
the Windows App SDK invokes a Windows XAML compiler executable/build task. Run
the build and publish commands above on Windows x64 to produce and launch-verify
the deliverable.
