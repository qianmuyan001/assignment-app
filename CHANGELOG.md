# Changelog

All notable changes to this project will be documented in this file.

The project follows [Semantic Versioning](https://semver.org/). Release dates use the `YYYY-MM-DD` format.

## [Unreleased]

### Added

- Added the shared SQLite schema v3 contract and additive v1/v2-to-v3 migration
  for stable UUIDs, database lineage, courses, projects, tags, task-tag links,
  subtasks, attachment metadata, reminders, completion timestamps, real task
  progress, all-day dates, time zones, and soft deletion.
- Added Phase 1 repositories and API endpoints for Backend, iPadOS/Mac Catalyst,
  and Windows Core. User-facing native organization screens remain Phase 2.
- Added 57 shared contract tests, 46 Apple unit tests on Catalyst, 47 Windows
  Core tests, and cross-language schema validation fixtures.

### Fixed

- Hardened migration concurrency and recovery around SQLite Online Backup,
  `BEGIN IMMEDIATE`, cross-process locks, exact rollback verification, full
  logical fingerprints, integrity checks, foreign-key checks, and immutable
  database lineage. After SQLite releases its write lock, an unexpected live
  change is preserved and startup fails closed instead of overwriting a
  possible external commit with an older backup.
- Made active subtasks the authoritative source of parent task progress and
  status, with atomic parent commands and soft-delete/restore behavior.
- Preserved legacy local wall-time text through migrations, device/timezone-only
  edits, ambiguous times, and daylight-saving gaps; offset-bearing values are
  rejected rather than shifted.
- Unified the supported RFC 5545 recurrence subset across Python, Swift, and C#,
  including ASCII-only integer syntax, and reject untyped, explicit BLOB, or
  generated BLOB-affinity attachment columns.

### Changed

- Unified root, Apple, and Windows source versions at 2.0.0 while explicitly
  keeping the version untagged and unpublished.
- Replaced the single Python workflow with independent shared/backend, Apple,
  and real Windows x64 CI definitions. Package metadata now records source SHA,
  source cleanliness, toolchain, tests, launch smoke, architecture, and signing.
- Backend API tests now force a temporary database before importing the app and
  assert that the real local database plus existing WAL/SHM/backup sidecars
  retain their exact size, modification time, and SHA-256 content hash.
- Apple and Windows packaging now use unique timestamped output directories and
  refuse to overwrite an earlier artifact.
- Pinned the Windows Core SQLite native bundle to `2.1.12`, replacing the
  deprecated vulnerable `2.1.11` transitive resolution without changing the
  application database schema.
- Archived the retired Python CustomTkinter frontend under
  `legacy/desktop_gui/`. The root launchers now start the backend and open the
  web client instead of treating the Python GUI as an active frontend.

## [2.0.0] - 2026-08-09 (source baseline; not tagged or released)

This version identifies the repository source and application metadata. There
is currently no `v2.0.0` Git tag or GitHub Release.

### Added

- Shared Assignment App 2.0 task schema, status/priority definitions, local-time
  smart-list rules, fixtures, and common platform acceptance cases.
- Versioned SQLite schema v2 migration with WAL-safe online backups,
  transactional validation, automatic failure restoration, and migration tests.
- WinUI 3 task CRUD, overdue navigation, search, status/course/priority filters,
  due/priority sorting, loading/error/empty states, and delete confirmation.
- Persistent simple/professional task display modes and system/light/dark
  appearance settings for Windows.
- Windows x64 self-contained publish and launch-smoke-test script.
- Real SwiftUI iPadOS Xcode application target with Mac Catalyst enabled on the
  same target, preserving the legacy SwiftPM macOS client.
- Apple 2.0 task CRUD, completion/restoring, smart lists, search, filters,
  sorting, native editor and delete confirmation, responsive split navigation,
  keyboard commands, persistent simple/professional modes, and appearance.
- Apple SQLite v1-to-v2 online-backup migration, failure restoration, shared
  fixture coverage, Catalyst unit tests, and timestamped ad-hoc Debug packaging.
- Shared Apple scheme with repeatable iPad Simulator and Catalyst test actions,
  plus App Sandbox entitlements and clean non-instrumented package verification.

### Fixed

- The web client's `script.js` and `style.css` had their contents swapped, so
  the browser parsed the stylesheet as JavaScript and the script as CSS. The
  page loaded with no styling and threw a syntax error on every visit.

### Changed

- The web client is served by the real backend from `backend/app/static/` and
  reads the same SQLite database as the desktop GUI. The parallel FastAPI
  application under `assignment_app/`, which stored assignments in a JSON file
  and was not started by any script, has been removed.
- `PATCH /assignments/{id}` is accepted alongside `PUT`, matching the verb the
  desktop client already falls back to.
- The web client's status vocabulary follows the shared v2 contract. Its
  `ignored` status is gone, and it now reads and writes the backend's
  `priority` field instead of deriving a priority of its own.
- The Cover Flow carousel is driven by a velocity-carrying spring integrated
  against elapsed time. It previously advanced by a fixed fraction of the
  remaining distance per frame, which settled twice as fast on a 120Hz display,
  and it discarded gesture velocity on release so flicking did nothing.
- Card positions are written as a single transform per card per frame. The
  previous code ran a DOM query and eleven custom-property writes per card per
  frame, and animated `filter` and `backdrop-filter` while cards were moving.
- Filtering and searching patch the existing cards instead of clearing and
  rebuilding the shelf, search input is debounced, list loads are sequenced so
  a slow response cannot overwrite newer state, and `source_url` renders as a
  link only for `http`/`https`.
- Motion durations follow a shared token scale and stay under 300ms outside the
  dialog; reduced motion now drops movement while keeping the transitions that
  explain a change, and hover transforms are gated to fine pointers.
- 2.0 UI/API statuses are `todo`, `in_progress`, and `done`, while SQLite keeps
  the 1.0 physical values for backward compatibility.
- At the original schema-v2 baseline, Apple derived `completedAt` from
  `updated_at`; schema v3 now stores an independent `completed_at` value.

### Known limitations

- Apple Debug packages use ad-hoc signing. Public Mac distribution still needs
  a Developer ID Application identity, hardened runtime review, notarization,
  and stapling; physical iPad distribution needs an Apple development/team
  signing configuration.
- The optional Catalyst UI-automation target can hang before the runner connects
  under the current Xcode 27 beta host. It is excluded from the shared scheme's
  default Test action. Current source contains 46 stable unit tests (32 in the
  task contract suite and 14 in the schema-v3 repository suite); the separate iPad
  UI smoke target adds 3 tests and may be excluded. The older 2026-08-07 package
  contained 25 per platform and is not current-SHA evidence.
- WinUI source and Core tests are ready, but the self-contained x64 directory
  must be produced and launch-verified on Windows because the Windows App SDK
  XAML compiler has native Windows dependencies.

## [1.0.0] - 2026-08-06

### Added

- Desktop assignment workspace with search, course and status filters, due-date views, and progress summaries.
- Create, edit, complete, and delete workflows backed by the local FastAPI and SQLite service.
- Review-first HTML import with automatic, AI, and rule-based parser modes.
- Native macOS client and Windows client source, including secure website sign-in and local AI page scanning foundations.
- English and Simplified Chinese interfaces, with English as the default and a persistent language selector in Settings.
- Light, dark, and system appearance modes plus optional interface motion.

### Security

- Local-first storage and loopback local-model processing for native page scanning.
- OS credential-store integration for opt-in website credential filling.
- Personal filesystem paths removed from public documentation.

[Unreleased]: https://github.com/qianmuyan001/assignment-app/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/qianmuyan001/assignment-app/releases/tag/v1.0.0
