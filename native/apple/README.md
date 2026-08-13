# Assignment App 2.0 for iPad and Mac Catalyst

`native/apple/AssignmentApp2.xcodeproj` is the Apple 2.0 alternative requested
after the original iPadOS project could not be located. It is a real SwiftUI
iPadOS application target created with Xcode. The same `AssignmentApp2` target
has Mac Catalyst enabled; there is no separate AppKit target. The retired
SwiftPM 1.0 client is archived under `legacy/macos`.

## Initial 2.0 scope

- Create, edit, delete, complete, and restore tasks.
- All, Today, This Week, Overdue, Completed, and Settings destinations.
- Search title, course, and description; filter status, course, and priority;
  sort by due time or priority.
- Persistent simple/professional display mode and system/light/dark theme.
- Native split navigation, lists, forms, sheets, alerts, date pickers, empty,
  loading, and error states.
- iPad hardware-keyboard and Catalyst commands: Command-N, Command-F,
  Command-R, and context-sensitive Escape.

## Apple navigation and search refresh

The shared iPadOS/Catalyst UI has a desktop-friendly sidebar with two persisted
styles. **Expanded** shows the `Tasks` heading, SF Symbols, and full labels at
roughly 190–300 points. **Compact** is a 64–76 point icon rail; every 48-point
navigation target retains its full VoiceOver label, keyboard focus, selected
trait, and Help tooltip. The style is stored with `@AppStorage` under
`assignmentApp.sidebarDisplayStyle` and never changes the underlying task data.
Dynamic Type grows labels and symbols, while Compact symbols are capped to the
available rail width. Accessibility text sizes use a wrapping, scrollable empty
state instead of allowing the system placeholder to overlap itself.

On iPadOS 26 / Mac Catalyst 26 or newer, the selected item uses the formal
SwiftUI Liquid Glass APIs: `GlassEffectContainer`, an interactive
`glassEffect`, `glassEffectID`, and the matched-geometry glass transition. The
glass is applied directly to the selected content so its symbol and label remain
above the system compositing layer. Direct touch or pointer selection moves only
the capsule with a 220 ms custom timing curve. Keyboard, Switch Control, and
VoiceOver activation switch immediately, and Reduce Motion disables positional
motion. On iPadOS 17–25 the same selection falls back to a `regularMaterial`
capsule. Reduce Transparency or Increase Contrast uses a near-solid system
surface with an explicit accent edge. The native split view supplies the
sidebar material; the app does not stack another full-sidebar blur behind it.

Navigation no longer writes `.detailOnly` after choosing All, Today, This Week,
Overdue, Completed, or Settings. Command-F also leaves the split-view
visibility untouched; only the system sidebar command or unavoidable system
layout constraints can fully hide it.

Search is a controlled toolbar component rather than `.searchable(isPresented:)`.
`SearchPresentationState` reduces explicit present, clear-and-close, and
dismiss-preserving-query events. A focus-request token and `FocusState` make
repeated Command-F deterministic without lifecycle delays. The search button
opens and focuses the field. Its close button clears the query and closes. An
outside click or Escape closes while preserving an existing query, and the page
title is restored immediately. Search layout changes are intentionally
unanimated because they are high-frequency keyboard actions.

Commands use `FocusedSceneValue`, so only the focused window receives New,
Find, Reload, or Escape. Find is unavailable on Settings, and background
commands are disabled while an editor or alert is presented. Escape is only
claimed while search is open, leaving normal sheet and alert cancellation to
the system.

### App icon status

No user-provided Team Spirit source asset was found at
`native/apple/BrandAssets/team-spirit-logo.svg` or `.png`. The unrelated
`Team_Falcons_Logo.svg.webp` was not used. `AppIcon.appiconset` therefore remains
unchanged; no logo was downloaded, traced, or fabricated. To complete Default,
Dark, and Tinted icons, provide a licensed SVG or a transparent PNG of at least
1024×1024. Confirm Team Spirit brand/trademark permission before any public
release.

The UI is deliberately a stable native baseline. Source-site login, local AI,
account sync, projects, subtasks, alternative board/table/gallery views, and
other later features are not exposed as non-functional controls.

## Relationship to the 1.0 Apple client

The 2.0 implementation preserves and adapts the useful platform-neutral ideas
from `legacy/macos/Sources/AssignmentNative/Models.swift`,
`AssignmentDatabase.swift`, and the SwiftUI task list in `ContentView.swift`:
the assignment vocabulary, compatible stored status values, local SQLite
approach, Application Support storage, and native SwiftUI presentation. Those
concepts were reorganized into a model/rules/repository/view-model boundary and
updated to obey the shared schema-v3 contract and safe migration policy.

The 1.0 `BrowserSession`, Keychain credential flow, `LocalAIParser`, source
connector, AppKit-specific interactions, packaging script, and historical
`dist` products were deliberately not copied into this initial task-management
version. They are desktop-specific or outside the requested 2.0 scope. The
tracked source under `legacy/macos` remains available for historical reference;
its ignored build products are not a current 2.0 deliverable.

## Project layout

```text
native/apple/
  AssignmentApp2.xcodeproj/   Xcode project and AssignmentApp2 scheme
  AssignmentApp2/             app, SwiftUI, v3 migration, task and organization repositories
  AssignmentApp2Tests/        Swift Testing unit and migration tests
  AssignmentApp2UITests/      isolated launch and interaction smoke tests
```

The target requires iPadOS 17 or newer and supports Apple Silicon through Mac
Catalyst. Its display name is **Assignment App** and its bundle identifier is
`com.qianmuyan.assignmentapp`.

## Database and 1.0 compatibility

The app is offline-first and opens a SQLite database in its own application
container. iPadOS uses its normal app data container. The ad-hoc Catalyst test
package is signed with App Sandbox enabled and resolves to:

```text
~/Library/Containers/com.qianmuyan.assignmentapp/Data/Library/Application Support/AssignmentApp2/assignments.db
```

It never scans the repository for `backend/assignments.db` and never resets an
existing database. For an isolated development or migration test, point the app
at an explicit disposable file:

```bash
ASSIGNMENT_DB_PATH="$HOME/Library/Containers/com.qianmuyan.assignmentapp/Data/tmp/assignment-app-smoke/assignments.db" \
  "/path/to/Assignment App.app/Contents/MacOS/Assignment App"
```

That DEBUG-only override must remain inside the Catalyst sandbox container.
Tests that load the repository without launching the sandboxed package use
independent UUID-named directories under `/private/tmp`. Before the SwiftUI app
creates its test-host view model, DEBUG builds recognize XCTest injection and
route the implicit host repository to a process-unique `/private/tmp` path. A
fatal guard rejects XCTest access to `~/Library/Application Support` or
`~/Library/Containers`, and stderr records only the isolated path for auditing.

To use a 1.0 database, copy it first and run the app against the copy, or place
the copy at the app-container path before first launch. A database with an
`assignments` table and `PRAGMA user_version=0` is treated as 1.0. Initialization
uses an in-process lock plus a sibling `flock` file so separate repository
instances and processes cannot migrate the same file concurrently. Both lock
levels use a monotonic 30-second timeout instead of blocking startup forever.
The writer
starts `BEGIN IMMEDIATE`, performs a second version check, and only then asks a
separate read-only connection to create one uniquely named sibling backup with
SQLite Online Backup. The backup is written as `.partial`, validated, and only
then atomically renamed to its final `.backup` name. A 1.0 database is upgraded
through v2 and v3 in that same
transaction; a v2 database receives only the additive v3 upgrade.

Migration validates legacy payload, IDs, schema, indexes, triggers, foreign
keys, UUID lineage, status/progress invariants, and SQLite integrity before
commit. On failure it rolls back first, then verifies the original version,
`integrity_check`, `foreign_key_check`, and a logical fingerprint that includes
`WITHOUT ROWID` tables and `sqlite_sequence`. Once SQLite releases its write
lock, recovery is read-only: a healthy external change or a post-commit failure
is preserved and startup fails closed instead of restoring an older backup over
a possible concurrent write. Transaction validation and post-commit validation
are separate phases, so a post-commit error cannot roll back or close an already
released SQLite pointer. A failed or unverifiable migration is thrown to the
view model, no partially migrated database is opened for writes, and the
independent backup remains available for reviewed manual recovery.

The final frozen Phase 1 source passed 46/46 unit tests on Mac Catalyst and 3/3
iPad UI smoke tests. The iPad unit runner was attempted on iPadOS 18.5 and 26.1,
including one explicit serial run, but CoreSimulator stopped before workers
materialized and zero tests executed. That current-source iPad unit result is
therefore **not accepted**; the earlier 44/44 iPad result predates the final
recovery hardening. Test databases used isolated `/private/tmp` paths:

```text
/private/tmp/assignment-app-phase1-safe-recovery-full-final-20260812.xcresult
/private/tmp/assignment-app-phase1-safe-recovery-ipad26-ui-smoke-final-20260812.xcresult
/private/tmp/assignment-app-phase1-safe-recovery-ipad26-serial-final-20260812.xcresult
```

The final local Phase 1 Catalyst package is under
`/private/tmp/assignment-app-phase1-final-artifacts/apple/` and is described in
its own `build-info.txt`. It is ad-hoc signed and not notarized. Repository
packages still predate schema v3 and remain Phase 0 evidence only.

The shared 2.0 contract is in `shared/`:

- UI statuses `todo`, `in_progress`, and `done` are stored as the compatible
  1.0 values `not_started`, `in_progress`, and `completed`.
- Priority is `low`, `medium`, or `high`; migrated 1.0 rows default to `medium`.
- `due_date` is local wall time without an offset. New or edited values use
  `YYYY-MM-DD HH:mm:ss` in the effective IANA timezone; accepted legacy text is
  retained byte-for-byte until that due date is edited. Offset-bearing input is
  rejected rather than silently shifted.
- Schema v3 retains the legacy integer task ID and adds a stable UUID. Migrated
  task and course UUIDs are deterministic UUID v5 values scoped to the
  database's immutable UUID v4 identity; newly created entities use UUID v4.
- `completed_at`, `progress_percent`, `all_day`, `timezone_id`, and
  `deleted_at` are physical task fields. Active subtasks atomically derive the
  parent status and progress, and parent status commands cascade to them.
  Delete is soft; restore preserves ID/UUID. Deleting a task disables active
  reminders, and restoring it never re-enables them.
- `timezone_id`, when present, is a resolvable IANA identifier. Existing naive
  due-date wall times are preserved byte-for-byte during migration and are not
  silently moved into a timezone.
- Courses, projects, tags, task-tag links, subtasks, attachment metadata, and
  reminders have separate repositories and audit/soft-delete fields. Phase 1
  stores attachment metadata only at `attachments/<uuid>` and performs no file
  copying or notification scheduling; those user-facing operations belong to
  Phase 2.
- Course identity uses the exact display name; normalized names are search
  helpers, so `Math` and `math` are not silently merged. Project/course and
  active-parent child invariants are checked transactionally. Reminder repeats
  accept only the documented strict RRULE subset.

The iPadOS and Catalyst app containers are intentionally independent from the
legacy unsandboxed SwiftPM client's `Application Support/AssignmentNative`
location. No legacy file is moved or deleted automatically.

The migration lock coordinates Assignment App 2.0 processes; unrelated legacy
clients do not participate in it, so close old clients or database tools before
testing a copied 1.0 database. The additive v2-to-v3 path preserves all legacy
fields, row IDs, extension columns, assignment indexes, assignment triggers,
and their values. A structurally incompatible v1 table may still require the
validated v1 rebuild path, so use the retained backup and a reviewed manual
migration for unsupported custom v1 schemas. Fresh and migrated databases share
the canonical v3 objects and rules, but migrated files may retain compatible
legacy or application extension objects; their full physical `sqlite_master`
listings therefore need not be identical.

## Required Xcode

The delivery was built with **Xcode 27.0 beta (build 27A5228h)**. All repository
commands use that installed full Xcode explicitly:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
export ASSIGNMENT_DERIVED_DATA=/private/tmp/assignment-app-xcode-derived-data
```

Inspect the project and installed destinations:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -version
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project native/apple/AssignmentApp2.xcodeproj \
  -scheme AssignmentApp2 -showdestinations
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcrun simctl list devices available
```

## Build and test

Use an actual installed iPad simulator UUID. The machine used for the initial
2.0 build has these suitable devices:

- iPad Pro 11-inch (M4), iOS 18.5: `55D6D2F6-FB7A-429C-ADFA-8BF9F8F2286F`
- iPad Air 11-inch (M3), iOS 26.1: `F0BB9838-B33F-417E-852C-26BE36AD75CF`

Build for iPad Simulator:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project native/apple/AssignmentApp2.xcodeproj \
  -scheme AssignmentApp2 -configuration Debug \
  -destination 'platform=iOS Simulator,id=55D6D2F6-FB7A-429C-ADFA-8BF9F8F2286F' \
  -derivedDataPath "$ASSIGNMENT_DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO build
```

Run the current Apple unit suite on that iPad Simulator:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project native/apple/AssignmentApp2.xcodeproj \
  -scheme AssignmentApp2 -configuration Debug \
  -destination 'platform=iOS Simulator,id=55D6D2F6-FB7A-429C-ADFA-8BF9F8F2286F' \
  -derivedDataPath "$ASSIGNMENT_DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO test
```

Build and test Mac Catalyst:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project native/apple/AssignmentApp2.xcodeproj \
  -scheme AssignmentApp2 -configuration Debug \
  -destination 'platform=macOS,arch=arm64,variant=Mac Catalyst' \
  -derivedDataPath "$ASSIGNMENT_DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO build

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project native/apple/AssignmentApp2.xcodeproj \
  -scheme AssignmentApp2 -configuration Debug \
  -destination 'platform=macOS,arch=arm64,variant=Mac Catalyst' \
  -derivedDataPath "$ASSIGNMENT_DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO test
```

The shared `AssignmentApp2` scheme intentionally makes the stable domain,
task/organization repository, v1/v2-to-v3 migration, identity/contract, and
navigation-state tests its default Test action. `AssignmentApp2UISmoke` is a
separate shared scheme for the opt-in UI flow:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project native/apple/AssignmentApp2.xcodeproj \
  -scheme AssignmentApp2UISmoke \
  -destination 'platform=iOS Simulator,id=F0BB9838-B33F-417E-852C-26BE36AD75CF' \
  -derivedDataPath "$ASSIGNMENT_DERIVED_DATA" \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:AssignmentApp2UITests/AssignmentApp2UITests/testSidebarAndSearchStateSmoke \
  -only-testing:AssignmentApp2UITests/AssignmentApp2UITests/testCompactSidebarAccessibilityAtLargestTextAndRapidRetarget \
  test
```

That flow verifies navigation does not hide the sidebar, toggles Compact mode,
checks all six full accessibility names and 44-point targets, rapidly retargets
selection, opens search with focus, types a query, closes with the clear button,
restores the title, and checks portrait/landscape layout. The second test uses a
Debug-only launch override to force SwiftUI Accessibility 5 while the Simulator
itself remains at its normal text size; production builds do not include that
branch. The Catalyst UI runner can still hang waiting for workers to materialize
under Xcode 27 beta. The 2026-08-10 attempt was interrupted after 139.6 seconds
without reaching a test assertion; Catalyst build and all 32 unit tests passed.
Packaged-app startup is
additionally verified against a disposable sandbox-contained database; this
checks that the process remains alive and creates the exact schema-v3 table,
22-column assignment, 30-index, and 12-trigger shape, with one canonical
database identity, no foreign-key errors, and `PRAGMA quick_check=ok`.

The unsigned Catalyst build is produced at:

```text
/private/tmp/assignment-app-xcode-derived-data/Build/Products/Debug-maccatalyst/Assignment App.app
```

After tests pass, create an ad-hoc-signed local package without overwriting an
earlier run:

```bash
./native/apple/package-catalyst.sh
```

The script writes a timestamped directory under `artifacts/apple/` containing
`Assignment App.app`, a ZIP, the Catalyst build/signature/launch/database logs,
and `build-info.txt`. This is a local Debug test package, not a formal release.
Packaging performs a clean build with coverage instrumentation disabled,
rejects stale LLVM profile symbols, adds the App Sandbox entitlement, strips
File Provider metadata from the ZIP, and verifies the extracted archive.
Public distribution still requires an Apple Developer ID Application
certificate, hardened runtime configuration as appropriate, notarization, and
stapling.

For a baseline artifact whose Git SHA uniquely identifies its source, require a
clean tree:

```bash
ASSIGNMENT_REQUIRE_CLEAN_TREE=1 ./native/apple/package-catalyst.sh
```

The Phase 0 Apple CI uses this clean-tree gate and records iPad unit/UI and
Catalyst unit results in `build-info.txt`. A normal local dirty-tree package is
allowed for development but is explicitly marked `source_tree_dirty=true` and
cannot be used as same-SHA release evidence.

The frozen Phase 1 local development package is:

```text
/private/tmp/assignment-app-phase1-final-artifacts/apple/debug-safe-recovery-final-20260812/
```

Its canonical `Assignment-App-2.0.0-Catalyst-Debug-arm64.zip` is an ad-hoc
signed, sandboxed arm64 Catalyst Debug build from revision `7f55ef7` with a
dirty-source disclosure. The extracted ZIP passed strict signature checks; the
real process stayed alive and created a disposable schema-v3 database with 22
assignment columns, 30 contract indexes, 12 contract triggers,
`quick_check=ok`, and no foreign-key errors. ZIP SHA-256:
`9cb4ad79c476237200c59d7307960acfc0ab585d6f0a9184c24dd5965368ec5f`.
This is current local Phase 1 evidence, not a notarized or clean-SHA release.

The latest local Phase 0 development verification package is:

```text
artifacts/apple/debug-20260811-080150Z/
```

Its canonical ZIP is an ad-hoc-signed arm64 Catalyst Debug build. The extracted
ZIP passed strict signature verification, sandbox launch, the complete 14-column
v2 schema check, and `PRAGMA quick_check=ok`. It records the current HEAD but
also records `source_tree_dirty=true`, so it is development evidence only and
does not replace the still-unrun clean-tree CI gate. It predates schema v3 and
is not a Phase 1 data-layer artifact.

The verified package from the initial Apple 2.0 delivery is:

```text
artifacts/apple/debug-20260807-021853Z/
```

Its clean ZIP was extracted outside the Desktop file-provider tree, passed
strict recursive code-signature verification, launched as a real sandboxed
process, and created a disposable v2 SQLite database with 14 expected assignment
columns and `PRAGMA quick_check=ok`. The package rejects coverage-instrumented
binaries and AppleDouble metadata. The directory includes the Catalyst app and
ZIP, iPad and Catalyst test result bundles, and build, shared-contract,
signature, archive, and launch-smoke logs. Because Finder/File Provider can add
metadata to the visible `.app` directory after packaging, the ZIP is the
canonical transferable payload.

The packaged 2026-08-07 snapshot independently passed 25 Apple unit and
migration tests on both iPad Simulator and Mac Catalyst. The shared
cross-platform contract suite additionally passed 20 tests. It was built from a
dirty source tree at revision `9556916…`, so it is retained only as historical
evidence and does not validate the current source revision.

The before/after UI evidence and logs for the navigation/search refresh are in:

```text
artifacts/apple/ui-refresh-20260807/before/
artifacts/apple/ui-refresh-20260807/after/
artifacts/apple/ui-refresh-20260807/logs/
artifacts/apple/ui-refresh-20260807/ipad-ui-glass-final.xcresult
```

The skills-based accessibility, motion, command-routing, and Dynamic Type
polish completed on 2026-08-10 is verified in:

```text
artifacts/apple/skill-polish-20260810/
```

That directory contains the final Catalyst and iPad 32/32 result bundles, the
iOS 18.5 fallback build result, the 2/2 iPad UI result bundle, and screenshots
for Expanded, Compact, search expanded/restored, landscape, and self-contained
Accessibility 5 layouts.

## Continuous integration

`.github/workflows/apple.yml` runs on GitHub's arm64 `xcode-27` public-preview
image because this project was authored with Xcode 27 and the general
`macos-26` image currently selects Xcode 26.x. It creates an iPad simulator from
the installed iOS runtime, runs the shared unit suite and all iPad UI smoke
tests, runs Catalyst unit tests, then builds and launch-smokes a clean-tree
ad-hoc Catalyst ZIP. A workflow definition is not a pass result; use its
uploaded XCResult bundles and `build-info.txt` for evidence.
