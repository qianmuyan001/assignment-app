# Changelog

All notable changes to this project will be documented in this file.

The project follows [Semantic Versioning](https://semver.org/). Release dates use the `YYYY-MM-DD` format.

## [Unreleased]

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

### Changed

- 2.0 UI/API statuses are `todo`, `in_progress`, and `done`, while SQLite keeps
  the 1.0 physical values for backward compatibility.

### Known limitations

- The Mac Catalyst port is paused because the repository does not contain the
  required iPadOS Xcode project or workspace. The existing native SwiftPM macOS
  client remains unchanged as a 1.0 baseline.
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
