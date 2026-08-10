# Changelog

All notable changes to this project will be documented in this file.

The project follows [Semantic Versioning](https://semver.org/). Release dates use the `YYYY-MM-DD` format.

## [Unreleased]

## [2.0.0] - 2026-08-09

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
- Apple `completedAt` is derived from `updated_at` while a task is done because
  shared schema v2 intentionally has no independent completion timestamp.

### Known limitations

- Apple Debug packages use ad-hoc signing. Public Mac distribution still needs
  a Developer ID Application identity, hardened runtime review, notarization,
  and stapling; physical iPad distribution needs an Apple development/team
  signing configuration.
- The optional Catalyst UI-automation target can hang before the runner connects
  under the current Xcode 27 beta host. It is excluded from the shared scheme's
  default Test action; the default 25-test suite and package launch/database
  smoke checks are repeatable and pass.
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

[Unreleased]: https://github.com/qianmuyan001/assignment-app/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/qianmuyan001/assignment-app/compare/v1.0.0...v2.0.0
[1.0.0]: https://github.com/qianmuyan001/assignment-app/releases/tag/v1.0.0
