# Changelog

All notable changes to this project will be documented in this file.

The project follows [Semantic Versioning](https://semver.org/). Release dates use the `YYYY-MM-DD` format.

## [Unreleased]

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
