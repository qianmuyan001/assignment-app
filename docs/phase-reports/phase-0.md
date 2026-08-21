# Phase 0 — 2.0 release-baseline closeout

Date: 2026-08-21
Author: WorkBuddy (高级工程师执行)
Scope: Phase 0 only. No application feature code was added or changed in this phase;
changes are limited to documentation accuracy and this report.

## 1. Current completed phase

Phase 0 — 2.0 release-baseline closeout. Source version metadata, CI definitions,
and package evidence scripts were already present on `main`; this pass re-verified
them against the live tree and corrected one stale test-count claim.

## 2. Actual files modified this phase

- `CHANGELOG.md` — corrected the contradictory "32 stable unit tests" claim in the
  [2.0.0] Known-limitations section to the real source count
  (46 unit: 32 task-contract + 14 schema-v3 repository; plus 3 iPad UI smoke).
- `docs/phase-reports/phase-0.md` — rewritten with the current, honest status
  (the previous version described a different branch/SHA and is superseded).

No source code, schema, migration, or application logic was changed.
No user data was read, modified, migrated, or deleted.

## 3. Apple / Windows / Web status at Phase 0

- **Web (backend + static client)**: fully present on `main`. Backend API + v3
  database layer and the web client (including the 3D Cover Flow) are implemented.
  Backend API/DB suite executed here: 18/18 passed.
- **Apple (SwiftUI iPadOS + Mac Catalyst)**: source present on `main`
  (`native/apple`). Task CRUD, smart lists, search/filter/sort, simple/professional
  modes, appearance, v1→v2→v3 migration, and organization repositories are
  implemented. Unit tests counted from source: 46 unit + 3 UI smoke. **Not executed
  in this environment** (no Xcode; only CommandLineTools installed).
- **Windows (WinUI 3, `native/windows`)**: source present on `main`
  (`AssignmentNative.Windows.csproj`, `<UseWinUI>true</UseWinUI>`,
  WindowsAppSDK 2.2.0). Task CRUD, filters, sorting, modes, secure browser,
  local-AI parser, and organization repositories are implemented. Core tests
  counted from source: 47. **Not executed in this environment** (macOS host, no
  .NET/Windows toolchain).

Web is the only platform whose automated suite could be executed on this macOS host.

## 4. Database version and migration result

- Schema `user_version` target for the 2.0 stack is **3** (assignments v2 + task
  organization v3). The v3 contract, migration SQL, fixtures, and cross-platform
  validators exist in `shared/` and are exercised by the 57 shared tests and 18
  backend tests (all passing).
- **No migration was run against any real database in Phase 0.** Phase 0 is a
  baseline closeout; migrations are a Phase 1/2 data-layer concern and were not
  triggered.
- Real `backend/assignments.db` does **not** exist in this checkout. The only
  related file is a read-only backup sidecar
  `backend/assignments.db.v1-to-v2.20260810T043113701465Z.64e0ec30.bak`, which was
  left untouched. Backend tests run against a temporary database and assert the real
  DB family is byte-for-byte unchanged; that assertion held (see §5).

## 5. Test commands, counts, and results (executed this session)

Environment: isolated venv
`/Users/qianmuyan/.workbuddy/binaries/python/envs/assignment-app`
(managed Python 3.13.12), macOS 14 (darwin), no Xcode, no .NET.

| # | Command | Result |
| --- | --- | --- |
| 1 | `python scripts/check_version_sync.py` | OK — root/README/CHANGELOG/Apple/Windows all = 2.0.0 |
| 2 | `python -m pylint --errors-only $(git ls-files '*.py')` | 0 findings (exit 0) |
| 3 | `python -m unittest discover -s shared/tests -v` | **57/57 passed** (0.574s) |
| 4 | `python -m unittest discover -s backend/tests -v` | **18/18 passed** (3.208s) |

Counts verified by source inspection (NOT executed here, no toolchain):

| Platform | Source test methods | Executed here? |
| --- | --- | --- |
| Apple unit (`AssignmentApp2Tests` + `SchemaV3RepositoryTests`) | 46 | No (no Xcode) |
| Apple UI smoke (`AssignmentApp2UITests`) | 3 | No (no Xcode) |
| Windows Core (`AssignmentNative.Core.Tests/Program.cs`) | 47 | No (no .NET/Windows) |

`git diff --check` on the working tree: **clean** (no trailing-whitespace /
newline-at-EOF issues introduced).

## 6. Generated artifacts (absolute path, arch, version, Git SHA, signing)

**No build, package, or launch artifact was produced in this environment.**

- Apple Catalyst package: **not built** — `package-catalyst.sh` requires Xcode
  (`/Applications/Xcode-beta.app`); only CommandLineTools is installed. The script
  was reviewed and *does* write `build-info.txt` capturing
  `source_revision` (Git SHA), `architecture` (arm64), `version`,
  `ipad_tests`/`catalyst_tests`, `launch_smoke`, and `signing=ad-hoc`. No artifact
  exists to record yet.
- Windows x64 publish: **not built/published/launched** — requires a real Windows
  x64 host with VS 2022 + .NET 8 (rule #8: macOS cannot stand in for a WinUI build).
  `publish-x64.ps1` was reviewed and writes `build-info.txt` with
  `source_revision` (Git SHA), `architecture=x64`, `version`, test result, and
  signing state. No artifact exists to record yet.

No screenshot, launch log, or signed binary was fabricated.

## 7. Unfinished items and the real reasons

1. **Apple Catalyst package not built/verified** — Xcode is not installed on this
   macOS host. Requires the `xcode-27` runner (CI) or a local Xcode 27 install.
2. **Windows x64 build/publish/launch not verified** — no Windows host available;
   the Windows App SDK XAML compiler has native Windows dependencies. Must run on a
   real `windows-2025` runner or signed-in Windows x64 machine.
3. **Apple/Windows automated tests not re-run from current SHA** — no Xcode/.NET
   toolchain here. Counts above are from source inspection, not execution.
4. **AppIcon is an external blocker** — see §8.

## 8. AppIcon / trademark-asset status

- `native/apple/AssignmentApp2/Assets.xcassets/AppIcon.appiconset/Contents.json`
  is an **empty catalog** (slots present, no image assets). This is the correct
  "external blocker" state: no authorized Team Spirit artwork was supplied, so the
  icon is intentionally not filled.
- `native/apple/BrandAssets/Team_Falcons_Logo.svg.webp` exists but is **explicitly
  unused** (the Apple README states it was not used). Rule #10 (no Team Falcons
  asset substituting Team Spirit) is honored; rule #11 (no download/trace/fake of
  Team Spirit icons without authorization) is honored — no Team Spirit asset was
  created or forged.
- Public distribution still requires an authorized icon plus Developer ID /
  notarization (Apple) and a real Windows signing identity (Windows).

## 9. Real Windows environment used?

**No.** All work ran on macOS 14 (darwin). Windows build/launch acceptance remains
**未验收 (not accepted)** and must be performed on a real Windows x64 host or the
`windows-2025` CI runner.

## 10. Real user data modified?

**No.** No migration, backup, or write was performed against any user database.
The real `backend/assignments.db` is absent; the only related file is a read-only
`.bak` sidecar that was not touched. Backend tests prove the real DB family is
unchanged.

## 11. Branch, HEAD, and dirty state

- Branch: `main`
- HEAD at start of this phase:
  `079d779e11c2923cd2b03e1a7ea8b5d08ca622a1`
- Working tree before edits: clean (matches `origin/main`).
- After this phase's doc edits, a local commit was made (no push, no tag, no PR,
  no release). The new HEAD SHA is recorded by `git rev-parse HEAD` at commit time.
- Remote inspected: `https://github.com/qianmuyan001/assignment-app.git`
- Published tags: only `v1.0.0`. **No `v2.0.0` tag or GitHub Release was created**
  (per rule #6 / Phase 0 instruction).

## 12. Explicit non-fabrication statement

No engineering output, installer, code signature, test log, screenshot, or launch
result was fabricated. Every number above is either (a) produced by a command run
in this session (shared 57/57, backend 18/18, version-sync OK, pylint clean,
`git diff --check` clean) or (b) a source-inspection count explicitly marked
"not executed here". Apple and Windows builds are reported as **未验收**, not
"completed".

## Next single recommended action

Begin **Phase 2 — Task organization & reminder UI**. The Phase 1 shared/native
**data layer** (schema v3, migration, fixtures, repositories, 57 shared + 18 backend
+ 46/47 source-level tests) is already merged on `main` and validated here. Phase 2
should implement the user-facing screens that Phase 1 deliberately deferred: course
CRUD, projects, tags, subtasks, attachments, and local system reminders on Apple,
Windows, and Web — then run the full cross-platform regression and submit the Phase 2
report. Do **not** advance to Phase 5 (AI) or Phase 6 (sync) or Phase 7 (desktop pet)
until the data foundation and Phase 2 UI are fully accepted.
