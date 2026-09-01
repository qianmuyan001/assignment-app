# Windows and Apple parity matrix

Date: 2026-09-01

Baseline scope: current Phase 2.5 source, version 2.0.0, Schema v3.

Overall result: **source and automated-domain parity are substantially aligned;
runtime acceptance parity is not yet closed.**

| Capability | Apple | Windows | Current parity | Remaining evidence |
| --- | --- | --- | --- | --- |
| Schema and migrations | Schema v3 repository and migration tests | Same Schema v3 contract and fail-closed migration behavior | Aligned | None for current schema; do not invent v4 |
| Basic task CRUD | SwiftUI task flows | Native WinUI task flows | Source/test aligned | Finish Windows done/delete manual matrix |
| Status and progress | todo/in_progress/done plus subtask-derived progress | Same storage/UI mapping and derivation | Aligned | Final manual cross-view confirmation |
| Due date/course/description/link/priority | Implemented | Implemented and desktop editor exercised | Aligned | None material |
| Smart lists/search/filter/sort | Implemented | Implemented; sidebar/search desktop evidence captured | Aligned | Complete keyboard/Tab-order pass |
| Simple/professional modes | Hidden fields preserved | Hidden fields preserved; setting persisted | Aligned | Repeat dark-theme manual pass |
| Courses/projects/tags | Native organization repository/UI | Native Core repository and WinUI manager | Source/test aligned | Full Windows project/tag CRUD desktop pass |
| Subtasks | CRUD and derived parent progress | CRUD and derived parent progress | Aligned | Windows add exercised; finish edit/delete manual pass |
| Attachments | Managed file store, hashing, open/share/delete/reconcile | Managed file store, hashing, open/export/delete/reconcile and reparse defense | Aligned | Apple full manual package pass remains historical blocker |
| Reminder records | Exact UTC trigger; one-shot scheduling | Same Schema v3 semantics | Aligned | Recurrence intentionally deferred |
| Notification permission/status | UserNotifications status | Stable `Assignment App` sender is enabled; banners, center, sound, and important delivery verified | Aligned in capability | None material |
| Schedule/cancel/reconcile | Implemented | Scheduled Reminder banner and running-app activation verified; cancel/reconcile implemented | Mostly aligned | Cold-start routing not repeated against an isolated desktop environment |
| Navigation behavior | Apple compact/expanded patterns | Native NavigationView compact/expanded, persistent and adaptive | Equivalent, platform-native | Narrator/high-DPI manual pass |
| Search interaction | Expand/focus/clear/Escape | Equivalent WinUI interaction exercised | Aligned | None material |
| Accessibility | SwiftUI labels and prior UI smoke evidence | WinUI automation names/tooltips and keyboard checks | Partial evidence parity | VoiceOver/Narrator and Reduce Motion dedicated passes |
| Build | Apple iPad/Catalyst source and tests reported passing at baseline | Windows Debug/Release x64 pass with 0 warnings/errors | Platform evidence present | Reports bind to different host runs by design |
| Packaging | Local Catalyst debug artifact, not formal release | Self-contained x64 test package, not signed or installed | Equivalent preview posture | Signing/installer/Store require separate authorization |
| Desktop launch/persistence | Catalyst package smoke reported | Published EXE and isolated DB smoke passed; settings restart exercised | Aligned for tested paths | Exhaustive persistence matrix remains |
| Phase 3A / Schema v4 | No trustworthy implementation baseline found | No implementation started | Aligned absence | End Phase 2.5 here |

## Field and rule mapping

Both clients use the shared Phase 2.5 assignment shape and Schema v3
organization tables. They share:

- title, course, description, source link, status, priority, due wall time, and
  timezone semantics;
- UUID and database-lineage rules;
- courses, projects, tags, task-tag links, subtasks, attachment metadata, and
  reminder records;
- soft deletion, hidden-field preservation, parent progress derivation, safe
  attachment paths, SHA-256 metadata, and canonical UTC reminder triggers.

Neither platform may claim recurring native delivery merely because
`repeat_rule` is retained in Schema v3. Only the one-shot trigger is in the
accepted Phase 2.5 behavior.

## Platform differences

- Apple uses SwiftUI, UserNotifications, QuickLook/share flows, and Apple-native
  sidebar/window behavior.
- Windows uses WinUI 3 NavigationView, Windows file pickers/launcher, native
  toast APIs, Mica/Acrylic-compatible system materials, and Windows focus rules.
- Equivalent capability is required; pixel-level SwiftUI or Liquid Glass
  imitation is not.

## Evidence summary

Windows automated evidence:

- shared 57/57;
- backend 19/19;
- Windows Core 50/50;
- Pylint errors-only and version sync passed;
- Debug and Release x64 passed with no warnings or errors;
- self-contained publish and isolated launch smoke passed.

Windows desktop evidence covers navigation, adaptive layout, search, settings
persistence, task editing, one subtask, attachment import/export/delete with
matching SHA-256, organization manager launch, notification status, scheduled
visible delivery, and running-app activation.

The remaining Windows gaps are cold-start notification routing and the complete
manual organization/status/delete/accessibility/high-DPI matrix. The Apple Phase
2.5 report also retains manual organization/attachment/notification and
accessibility gaps. Consequently no cross-platform Preview parity claim is made.

## Decision

Do not start Phase 3A or Schema v4 migration work from planning text alone.
There is no trustworthy newer Apple implementation baseline to port.

Current wording:

> Windows source and automated-domain behavior match the current Apple Phase
> 2.5 baseline. Runtime acceptance is partially open on both platform evidence
> sets, so Windows Preview parity is not yet declared.
