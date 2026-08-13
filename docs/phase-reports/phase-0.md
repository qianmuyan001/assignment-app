# Phase 0 — 2.0 release-baseline closeout

Date: 2026-08-11

## Status

Local source closeout is complete. Release acceptance is **not complete** because
the new workflows have not been committed/pushed or executed on GitHub-hosted
`xcode-27` and `windows-2025` runners. Windows WinUI restore, publish, launch,
and artifact upload remain **not accepted**.

Branch and inspected baseline:

- branch: `codex/ideal-through-phase4`
- HEAD: `3118bf830e4dfea0dc6427aa4c5af53b41ed051f`
- source tree: dirty with the documented Phase 0 implementation; no commit,
  push, tag, pull request, or release was created
- remote inspected: `https://github.com/qianmuyan001/assignment-app.git`
- published tags inspected: only `v1.0.0`

## Implemented

- Unified root, Apple, and Windows source metadata at `2.0.0` and added an
  executable version-consistency check.
- Replaced the old Python-only workflow with independent shared/backend,
  Apple, and real Windows x64 workflow definitions.
- Added isolated FastAPI HTTP/API/Web-asset tests. The test server is configured
  with a temporary database before application import and fingerprints the real
  database, WAL, SHM, and backup family before and after the suite.
- Added timestamped, non-overwriting Apple and Windows package scripts with
  clean-tree gates, source/environment provenance, bounded launch readiness,
  full v2 database smoke checks, and separate success/failure CI artifacts.
- Updated the Apple job to GitHub's arm64 `xcode-27` preview runner because the
  project is authored in Xcode 27 format.
- Pinned the Windows SQLite native bundle to `2.1.12` so the resolved native
  SQLite package no longer remains on the affected `2.1.11` release.
- Preserved an empty AppIcon catalog. No Team Spirit asset was supplied; the
  unrelated Team Falcons file was not used.

## Local verification

- version sync: passed
- Python errors-only lint: passed
- shared v2 contract/migration suite: 20/20 passed
- isolated backend HTTP suite: 4/4 passed with `ResourceWarning` promoted to an
  error
- iPad Simulator unit suite: 32/32 passed
- iPad Simulator UI smoke suite: 3/3 passed
- Mac Catalyst unit suite: 32/32 passed
- Mac Catalyst clean build, strict archive signature verification, sandbox
  launch, v2/14-column database check, and `PRAGMA quick_check`: passed
- Windows Core compatibility run in a disposable macOS-hosted .NET copy: 20/20
  passed; this is not WinUI or Windows acceptance
- Shell, PowerShell parser, workflow YAML parse, and `git diff --check`: passed

Apple test evidence:

```text
/Users/qianmuyan/Desktop/assignment-app/artifacts/phase0-20260811-073859Z
```

Latest local Catalyst development package:

```text
/Users/qianmuyan/Desktop/assignment-app/artifacts/apple/debug-20260811-080150Z
/Users/qianmuyan/Desktop/assignment-app/artifacts/apple/debug-20260811-080150Z/Assignment-App-2.0.0-Catalyst-Debug-arm64.zip
```

ZIP SHA-256:

```text
bf38f359449779d0192cfc7c42dcb218fe3315aa52e57e4e7d55218276f74534
```

The package is arm64 Mac Catalyst, ad-hoc signed, sandboxed, and not notarized.
It accurately records `source_tree_dirty=true`; therefore it is development
evidence, not a clean-SHA release artifact.

## Data-safety record

No migration was run against the real assignment database. Its main file stayed
at 32,768 bytes, mtime `1786355601`, and SHA-256
`0d6e2ae2f2c9f37ba15925bb5fbf396b4fbd1fbf5da514e099c4d0fbe9fcd4eb`.

During the initial read-only audit, opening the WAL database changed the existing
`backend/assignments.db-shm` modification time. Two sidecars for the tracked
v1-to-v2 backup also appeared during the audit. No main database or backup bytes
were changed, no sidecar was deleted or rewritten, and later tests use only
temporary databases. The sidecars are left in place and ignored rather than
being removed destructively.

## External acceptance debt

1. Commit/push is intentionally absent, so a clean source SHA cannot yet run the
   new CI definitions.
2. Run the Apple workflow and retain its clean-SHA XCResult/package manifest.
3. Run the Windows workflow on a real `windows-2025` x64 runner and retain the
   self-contained publish directory plus live launch evidence.
4. Supply an authorized Team Spirit SVG or transparent PNG of at least
   1024×1024 before replacing AppIcon; confirm trademark permission before any
   public release.
