# Phase 2 — Task organization & reminder UI

Date: 2026-08-21
Author: WorkBuddy (高级工程师执行)
Scope: Phase 2 only. Implements the user-facing organization & reminder screens
(courses, projects, tags, subtasks, attachments, local system reminders) across
Apple (SwiftUI iPadOS + Mac Catalyst), Windows (WinUI 3), and Web (backend +
static client). Phase 2 is a **UI-consumer** phase over the already-merged Phase 1
schema-v3 data layer — no schema, migration, or contract change was required.

## 1. Current completed phase

Phase 2 — Task organization & reminder UI. The Phase 1 shared/native data layer
(schema v3, migration, fixtures, repositories, 57 shared + 18 backend tests) was
already merged on `main` and validated. This phase adds the screens Phase 1
deliberately deferred, on all three platforms, and reconciles them through the
existing repositories and link tables.

Design guidance from the installed skills (`ui-ux-pro-max`, `frontend-design`,
`apple-design`) was followed as structural principles: ≥44px touch targets and
clear sectioning on WinUI, a restrained token-based CSS treatment on Web, and
interruptible spring motion (`withAnimation(.spring(response:dampingFraction:))`)
on Apple. **Visual acceptance of Apple/Windows is pending compile** (see §3, §7, §9).

## 2. Actual files modified this phase

Apple (SwiftUI):
- `native/apple/AssignmentApp2/Models.swift` — `AssignmentDraft` now carries
  `courseID` / `projectID` / `tagIDs`; matching `init` overloads updated.
- `native/apple/AssignmentApp2/SQLiteAssignmentRepository.swift` — `create(_:)`
  now binds the `project_id` column (index 16) instead of hard-coding `NULL`.
- `native/apple/AssignmentApp2/OrganizationManagerView.swift` (new) — courses /
  projects / tags CRUD with spring-animated rows.
- `native/apple/AssignmentApp2/TaskEditorView.swift` — rewritten: pro-mode course /
  project / tag pickers (course selection cascades the project list and syncs
  `draft.courseName`) plus subtask / reminder / attachment sections gated to
  existing assignments + an org repository.
- `native/apple/AssignmentApp2/AssignmentViewModel.swift` — owns the org repository
  (shares the live SQLite DB), `reloadOrganization()`, and `applyOrganization(...)`
  which reconciles the assignment's `projectID` and tag links.
- `native/apple/AssignmentApp2/ContentView.swift` — `editor(for:)` passes org
  params and calls `applyOrganization` after add/edit.

Windows (WinUI 3):
- `native/windows/TaskEditorDialog.xaml` / `.xaml.cs` — extended with pro-mode
  course / project / tag pickers and subtask / reminder / attachment sections
  (child editing for existing assignments only), consuming `ITaskOrganizationRepository`.
- `native/windows/OrganizationManagerWindow.xaml` / `.xaml.cs` (new) — standalone
  courses / projects / tags CRUD.
- `native/windows/MainWindow.xaml` / `.xaml.cs` — "Courses & tags" button opens
  `OrganizationManagerWindow`; editor receives the org repo + owner handle, and tags
  are reconciled after save via `ApplyOrganizationTags`.

Web (backend + static client):
- `backend/app/static/index.html`, `script.js`, `style.css` — wired to the Phase 1
  organization REST surface and the assignment detail panel (courses, projects,
  tags, subtasks, attachments, reminders). (Authored in a prior Phase 2 session;
  re-verified this session.)

Docs:
- `docs/phase-reports/phase-2.md` (this report).
- `CHANGELOG.md` — `[Unreleased]` / Added entry for Phase 2.

No migration, backup, or write was performed against any user database in this
phase.

## 3. Apple / Windows / Web status at Phase 2

- **Web (backend + static client)**: implemented and **partially executed here**.
  The backend organization REST surface is Phase 1; the static client consumes it.
  Backend suite executed this session: **75 passed, 18 subtests passed**. Web client
  `script.js` passed `node --check` (syntax OK). Web is the only platform whose
  automation could run on this macOS host.
- **Apple (SwiftUI iPadOS + Mac Catalyst)**: source written and reviewed this phase
  (and earlier Phase 2 sessions). **Not compiled in this environment** (no Xcode;
  only CommandLineTools). Reported as **未验收 (not accepted)** — must be built and
  run on the user's Xcode runner.
- **Windows (WinUI 3)**: source written this phase. **Not compiled in this
  environment** (macOS host, no .NET / Windows App SDK toolchain). Reported as
  **未验收 (not accepted)** — must be built on a real Windows x64 host or the
  `windows-2025` runner.

## 4. Database version and migration result

- Schema target remains **v3** (unchanged from Phase 1). Phase 2 added **no schema,
  migration, or contract change** — it is purely a UI layer over the existing
  repositories.
- **No migration was run against any real database in Phase 2.** The real
  `backend/assignments.db` is still absent from this checkout; the only related file
  is the read-only backup sidecar `backend/assignments.db.v1-to-v2.…bak`, which was
  not touched.
- Invariants preserved from Phase 1 and exercised by Phase 2 UI:
  - **Status mapping**: UI `todo`/`in_progress`/`done` ⇄ DB `not_started` /
    `in_progress` / `completed` (Apple `TaskStatuses`, Windows `TaskStatuses`,
    Python `schema_v3`).
  - **Derived progress**: when an assignment has subtasks, its progress/status is
    derived from active subtasks (Windows `TaskStatePersistence.RecalculateParent`;
    Apple `recalculate_assignment_from_active_subtasks`); Phase 2 never sets
    progress directly when subtasks exist.
  - **Tag semantics**: tags are reconciled through the `task_tags` link table so
    shared tag definitions stay consistent across platforms (rule #5 — shared-data
    semantics consistency).

## 5. Test commands, counts, and results (executed this session)

Environment: isolated venv
`/Users/qianmuyan/.workbuddy/binaries/python/envs/default`
(managed Python 3.13.12) + managed Node 22.22.2, macOS 14 (darwin), no Xcode,
no .NET.

| # | Command | Result |
| --- | --- | --- |
| 1 | `python -m pytest -q` (backend) | **75 passed, 18 subtests passed** (8.06s) |
| 2 | `node --check backend/app/static/script.js` | syntax OK |

Counts verified by source inspection (NOT executed here, no toolchain):

| Platform | Source test methods | Executed here? |
| --- | --- | --- |
| Apple unit (`AssignmentApp2Tests` + `SchemaV3RepositoryTests`) | 46 | No (no Xcode) |
| Apple UI smoke (`AssignmentApp2UITests`) | 3 | No (no Xcode) |
| Windows Core (`AssignmentNative.Core.Tests/Program.cs`) | 47 | No (no .NET/Windows) |

`git diff --check` on the working tree (pre-report): no trailing-whitespace /
newline-at-EOF issues introduced by the committed files.

## 6. Generated artifacts (absolute path, arch, version, Git SHA, signing)

**No build, package, or launch artifact was produced in this environment.**

- Apple Catalyst package: **not built** — requires Xcode (`package-catalyst.sh`).
  The script remains the source of truth for `build-info.txt` (Git SHA, arch
  arm64, version, test counts, `launch_smoke`, `signing=ad-hoc`). No artifact exists.
- Windows x64 publish: **not built/published/launched** — requires a real Windows
  x64 host with VS 2022 + .NET 8 (rule #8: macOS cannot stand in for a WinUI
  build). `publish-x64.ps1` remains the source of truth for `build-info.txt`. No
  artifact exists.
- Web: the static client is source (`backend/app/static/*`) served by the FastAPI
  app; it produces no separate binary and was not packaged.

No screenshot, launch log, or signed binary was fabricated.

## 7. Unfinished items and the real reasons

1. **Apple build/run not verified** — Xcode is not installed on this macOS host.
   Must run on the user's Xcode runner (the `xcode acp agent` the user added) or a
   local Xcode install. This is the verification the user explicitly asked to take
   back ("做不了的验证交给我").
2. **Windows build/run not verified** — no Windows host / .NET available. Must run
   on a real `windows-2025` runner or a signed-in Windows x64 machine. Same hand-back.
3. **Apple/Windows automated suites not re-run from current SHA** — no Xcode/.NET
   toolchain here. Counts in §5 are from source inspection, not execution.
4. **Apple/Windows UI visual acceptance pending** — even after a successful
   compile, the org pickers, child-record sections, and `OrganizationManagerWindow`
   need a human/runner pass for layout, motion, and accessibility (contrast, touch
   targets). Design-skill principles were applied structurally but not pixel-verified.

## 8. AppIcon / trademark-asset status

Unchanged from Phase 0/1 — the correct "external blocker" state:
- `native/apple/AssignmentApp2/Assets.xcassets/AppIcon.appiconset/Contents.json`
  remains an **empty catalog** (no image assets filled). No authorized Team Spirit
  artwork was supplied, so the icon is intentionally not filled.
- `native/apple/BrandAssets/Team_Falcons_Logo.svg.webp` exists but is **explicitly
  unused**. Rule #10 (no Team Falcons asset substituting Team Spirit) and rule #11
  (no forged Team Spirit icon) are honored — no Team Spirit asset was created or
  forged in Phase 2.
- Public distribution still requires an authorized icon plus Developer ID /
  notarization (Apple) and a real Windows signing identity (Windows).

## 9. Real Windows environment used?

**No.** All work ran on macOS 14 (darwin). Windows build/launch acceptance remains
**未验收 (not accepted)** and must be performed on a real Windows x64 host or the
`windows-2025` CI runner.

## 10. Real user data modified?

**No.** No migration, backup, or write was performed against any user database.
The real `backend/assignments.db` is absent; the only related file is a read-only
`.bak` sidecar that was not touched. Backend tests run against a temporary database
and assert the real DB family is unchanged.

## 11. Branch, HEAD, and dirty state

- Branch: `main`
- HEAD at start of this phase: `3283d33` (Phase 0 report closeout).
- Working tree before edits: contained the uncommitted Phase 2 Web (static) + Apple
  changes from earlier sessions, plus this session's new Windows files.
- This phase made **local commits only** (no push, no tag, no PR, no release —
  rule #6):
  - Implementation + CHANGELOG: `759370dfd5cb9ec941574079bbb00be1360848de`
  - This report: committed on top as the current HEAD (a local commit; SHA shown
    by `git rev-parse HEAD`).
- Remote inspected: `https://github.com/qianmuyan001/assignment-app.git`
- Published tags: only `v1.0.0`. **No `v2.0.0` tag or GitHub Release was created.**
- The internal `.workbuddy/` directory is intentionally **not** committed.

## 12. Explicit non-fabrication statement

No engineering output, installer, code signature, test log, screenshot, or launch
result was fabricated. Every number above is either (a) produced by a command run
in this session (backend **75 passed / 18 subtests**, `node --check` OK) or
(b) a source-inspection count explicitly marked "not executed here". Apple and
Windows builds are reported as **未验收**, not "completed". The Phase 2 implementation
exists as committed source on `main`; its acceptance depends on the user's Xcode and
Windows runners, which was the explicit division of labor requested.

## Next single recommended action

**Hand Phase 2 verification to the user's runners.** Concretely:
1. On the Xcode runner: build `native/apple` (Catalyst + iPadOS), run
   `AssignmentApp2Tests` + `AssignmentApp2UITests`, and smoke-test the new
   `OrganizationManagerView` and `TaskEditorView` org pickers / child sections.
2. On a Windows x64 host: `dotnet build` `AssignmentNative.Windows.csproj`, run
   `AssignmentNative.Core.Tests`, and smoke-test `TaskEditorDialog` (pro mode) and
   `OrganizationManagerWindow`.
3. Web is already green (75/75 backend, JS syntax OK) and can be demoed immediately.

Only after Apple + Windows are accepted should the project advance toward later
phases (AI, sync, desktop pet). Do **not** tag or release `v2.0.0` until both
native platforms pass their runners.
