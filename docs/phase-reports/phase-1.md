# Phase 1 — Schema v3 and task organization

Date: 2026-08-12

## Status

Phase 1 source and local data-layer implementation are complete. Shared,
Backend, Apple, and Windows Core use schema v3 and the same task-organization
semantics. Phase 2 user interfaces were intentionally not started.

Release acceptance is not complete: this host is macOS, so the WinUI 3 app has
not been built, published, or launched on real Windows x64. No Phase 1 Catalyst
package was generated from a clean Git SHA either. These are external delivery
gates, not substitutes for the local Core and Simulator results below.

Inspected source state:

- branch: `codex/ideal-through-phase4`
- HEAD: `6bbf0091017ce5fe8305bc339bb3d91d8dc2a3fe`
- source version: `2.0.0`
- source tree: dirty with the uncommitted Phase 1 closeout
- remote: `https://github.com/qianmuyan001/assignment-app.git`
- published local tags: only `v1.0.0`
- no commit, push, tag, pull request, or release was created

## Implemented

### Shared contract and database

- Raised `PRAGMA user_version` to 3 while retaining every v2 assignment field
  and integer ID.
- Added database-scoped lineage, stable migrated UUID v5 identities, new-record
  UUID v4 identities, courses, projects, tags, task-tag links, subtasks,
  attachment metadata, reminders, `completed_at`, real `progress_percent`,
  `all_day`, `timezone_id`, and soft-delete timestamps.
- Made the migration additive for `assignments`; unknown assignment columns,
  values, indexes, and triggers are preserved.
- Defined one strict recurrence subset, local-wall-time behavior, active-subtask
  progress derivation, attachment path/affinity rules, and cross-platform fixture
  vectors. Recurrence integers are ASCII-only. Attachment validation uses
  `table_xinfo`, so untyped, explicit BLOB, and hidden/generated BLOB columns
  are rejected.

### Backend and Web API

- Added explicit v0/v1/v2/v3 dispatch, a bounded cross-process lock, lock-held
  version recheck, verified SQLite Online Backup, `BEGIN IMMEDIATE`, integrity
  and foreign-key checks, and exact transaction-rollback verification. If the
  live database changes after SQLite releases the write lock, startup fails
  closed while preserving both live data and the standalone backup; it never
  overwrites a possible external commit with an older snapshot.
- Added repositories and HTTP endpoints for task organization, soft delete and
  restore, relationship invariants, reminder rules, IANA timezones, and
  subtask-derived parent state.
- Existing Web task CRUD remains available. Phase 2 organization screens were
  not added to the Web client.

### Apple

- Added the same schema-v3 migration, lineage, repositories, organization
  models, soft delete/restore, relationship validation, reminder validation,
  and subtask-derived task state to the shared iPadOS/Mac Catalyst target.
- Migration uses a bounded `flock`, a verified partial backup published
  atomically, separate transaction/post-commit phases, complete logical
  fingerprints including `WITHOUT ROWID` and `sqlite_sequence`, and read-only
  post-lock recovery classification that cannot overwrite a concurrent writer.
- Preserved accepted legacy due text byte-for-byte until the due value is
  actually edited, including timezone-only edits, ambiguous times, and spring
  daylight-saving gaps.
- Organization UI was not added; it belongs to Phase 2.

### Windows

- Added the same v3 migration and repositories to `AssignmentNative.Core`, with
  Windows cross-process locking, Online Backup, transactional validation,
  rollback fingerprinting, and fail-closed concurrent-write protection.
- Added courses, projects, tags, task tags, subtasks, attachment metadata,
  reminders, UUID lineage, soft delete/restore, and derived progress.
- Updated the existing WinUI model/service shim for the expanded task fields.
  Organization screens were not added; they belong to Phase 2.

## Major files

- Shared: `shared/schema_v3.py`, `shared/migrations/003_task_organization_v3.sql`,
  `shared/schemas/database-v3.json`, `shared/schemas/task-v3.schema.json`,
  `shared/fixtures/task-organization-v3.json`,
  `shared/feature-specs/task-organization-v3.md`, and
  `shared/tests/test_v3_contract.py`.
- Backend: `backend/app/database.py`, `models.py`, `schemas.py`,
  `repositories.py`, `routers/assignments.py`, `routers/organization.py`,
  `services/task_state.py`, `backend/tests/test_database_v3.py`, and
  `backend/tests/test_api.py`.
- Apple: `Models.swift`, `OrganizationModels.swift`,
  `SQLiteAssignmentRepository.swift`, `SQLiteOrganizationRepository.swift`,
  `SQLiteSchemaV3.swift`, `MigrationCoordinator.swift`,
  `DatabaseMigrationLock.swift`, `DatabaseLogicalFingerprint.swift`,
  `SQLiteSupport.swift`, and `SchemaV3RepositoryTests.swift`.
- Windows: `AssignmentDatabase.cs`, `DatabaseMigrationLock.cs`,
  `DatabaseLogicalFingerprint.cs`, `SchemaV3Contract.cs`,
  `TaskOrganizationModels.cs`, `TaskOrganizationRepository.cs`,
  `TaskStatePersistence.cs`, Core `Models.cs`, Core test `Program.cs`, and the
  WinUI model/service shim.

## Verification

All database tests used newly created temporary databases.

```text
python3 -m unittest discover -s shared/tests -v
57/57 passed

PYTHONWARNINGS='error::ResourceWarning' .venv/bin/python \
  -m unittest backend.tests.test_database_v3 -v
8/8 passed

PYTHONWARNINGS='error::ResourceWarning' .venv/bin/python \
  -m unittest backend.tests.test_api -v
9/9 passed

dotnet build native/windows/AssignmentNative.Core.Tests/\
  AssignmentNative.Core.Tests.csproj -c Release --no-restore
0 warnings, 0 errors

DOTNET_ROLL_FORWARD=Major dotnet run --project \
  native/windows/AssignmentNative.Core.Tests/AssignmentNative.Core.Tests.csproj \
  -c Release --no-build
30/30 passed

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project native/apple/AssignmentApp2.xcodeproj -scheme AssignmentApp2 \
  -destination 'platform=macOS,arch=arm64,variant=Mac Catalyst' \
  -derivedDataPath /private/tmp/assignment-app-xcode-derived-data \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
44/44 passed

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project native/apple/AssignmentApp2.xcodeproj -scheme AssignmentApp2 \
  -destination 'platform=iOS Simulator,id=F0BB9838-B33F-417E-852C-26BE36AD75CF' \
  -derivedDataPath /private/tmp/assignment-app-xcode-derived-data \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
44/44 passed

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project native/apple/AssignmentApp2.xcodeproj -scheme AssignmentApp2UISmoke \
  -destination 'platform=iOS Simulator,id=F0BB9838-B33F-417E-852C-26BE36AD75CF' \
  -derivedDataPath /private/tmp/assignment-app-xcode-derived-data \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
3/3 passed
```

Additional gates passed: version synchronization, Python compile/lint
errors-only, C# formatting verification for Core and Core.Tests, cross-language
validation of a Windows-created v3 database with `shared.schema_v3`, JSON
parsing, Swift parsing, and `git diff --check`.

The WinUI restore succeeded with Windows targeting enabled. Its macOS build then
failed at the expected native boundary because `XamlCompiler.exe` cannot execute
on macOS. That result is not a Windows build failure or a Windows acceptance
result; the app remains unverified until run on Windows x64.

## Evidence and artifacts

```text
/private/tmp/assignment-app-phase1-catalyst-final6-20260812.xcresult
/private/tmp/assignment-app-phase1-ipad-final6-20260812.xcresult
/private/tmp/assignment-app-phase1-ui-smoke-final4-20260812.xcresult
/private/tmp/assignment-app-phase1-artifacts/apple/debug-phase1-local-20260812-r2/
/private/tmp/assignment-windows-contract.1xxuUS/windows-v3.db
```

The Apple result bundles are arm64 local test evidence built with Xcode 27 beta
and code signing disabled. The isolated Phase 1 artifact directory contains an
ad-hoc-signed, sandboxed arm64 Catalyst Debug app and canonical ZIP. Its launch
smoke created only a disposable container-temp database and verified schema v3,
22 assignment columns, 30 contract indexes, 12 contract triggers, integrity,
and foreign keys. The ZIP SHA-256 is
`89657e0d9272f864eaf14a5e709ce094160e8c2f8b38862eff16fe5f98cbea2c`.
Because the source tree was dirty, this is a local test package rather than a
clean-SHA release artifact. No Windows x64 publish directory was generated on
this Mac.

The existing Catalyst ZIP under
`artifacts/apple/debug-20260811-080150Z/` is an ad-hoc arm64 Phase 0/schema-v2
artifact; it must not be described or distributed as Phase 1 evidence.

## Data-safety record

- The repository Backend main database remained 32,768 bytes with mtime
  `1786355601` and SHA-256
  `0d6e2ae2f2c9f37ba15925bb5fbf396b4fbd1fbf5da514e099c4d0fbe9fcd4eb`.
- An early read-only audit opened its WAL family and changed the existing
  `backend/assignments.db-shm` modification time. No sidecar was deleted or
  rewritten to hide that event.
- Before Apple XCTest isolation was added, one test-host launch migrated
  `/Users/qianmuyan/Library/Application Support/AssignmentApp2/assignments.db`
  from v2 to v3 and created its normal sibling backup. That path may be a prior
  unsandboxed test-host database, but it is outside the approved temporary
  scope. It was not inspected, deleted, restored, or touched again. All final
  Apple tests explicitly used `/private/tmp`.
- No other repository or user SQLite database was opened for migration, reset,
  or overwritten during the final Phase 1 verification.

## Remaining external gates

1. Run the Windows workflow or `publish-x64.ps1` on real Windows x64 and retain
   the Core, WinUI publish, launch, database-smoke, architecture, hash, and
   Authenticode evidence.
2. After authorization to commit/push, run the clean-SHA Apple workflow and
   generate a new schema-v3 Catalyst package.
3. Team Spirit AppIcon remains blocked on an authorized SVG or transparent
   1024×1024-or-larger PNG and trademark clearance.

No project, test, package, signature, screenshot, Windows result, or launch was
fabricated.
