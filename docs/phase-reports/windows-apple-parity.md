# Windows and Apple parity matrix

Date: 2026-09-01

Baseline scope: current Phase 2.5 source, version 1.1.0, Schema v3.

Overall result: **source, domain, build, and tested desktop interaction parity
are aligned; Windows Preview runtime parity is not declared because portable
notification cold activation is still open.**

| Capability | Apple Phase 2.5 | Windows 1.1 | Parity decision |
| --- | --- | --- | --- |
| Schema and migration | Schema v3 | Same v3 contract, backup, fail-closed migration | Aligned |
| Task CRUD and fields | Implemented | Implemented; actual add/edit/delete/complete passed | Aligned |
| Status and progress | todo/in_progress/done; child-derived progress | Same mapping; stale-editor reset fixed and retested | Aligned |
| Smart lists/search/filter/sort | Implemented | Implemented; desktop and Core evidence passed | Aligned |
| Simple/professional/theme | Hidden fields preserved | Same; professional and dark theme persist | Aligned |
| Courses/projects/tags | Implemented | CRUD passed in native manager and isolated SQLite | Aligned |
| Subtasks | CRUD and parent derivation | Add/edit/complete/delete and save persistence passed | Aligned |
| Attachments | Managed file lifecycle | Equivalent hash/open/export/delete/reconcile and reparse defense | Aligned |
| Reminder records | UTC one-shot trigger | Same Schema v3 semantics | Aligned |
| Notification delivery | Native Apple delivery | Visible Windows banner/card passed with High priority | Capability aligned |
| Notification activation | App routing | Warm activation passed; portable moved-path cold activation open | **Runtime evidence gap** |
| Navigation | Apple-native sidebar behavior | WinUI NavigationView compact/expanded/adaptive and persistent | Equivalent, platform-native |
| Search interaction | Expand/focus/clear/Escape | Equivalent WinUI behavior passed | Aligned |
| Accessibility | SwiftUI labels | Narrator runtime, named Tab order, Tooltip, 150% DPI passed | Aligned for tested flows |
| Reduce Motion | System preference | No custom animation overrides; system WinUI motion applies | Aligned |
| Build/package | Apple preview build | Debug/Release and clean self-contained x64 smoke passed | Equivalent preview posture |
| Phase 3A / Schema v4 | No trustworthy baseline found | Not implemented | Aligned absence |

## Shared rules

Both clients use the shared Phase 2.5 assignment and Schema v3 organization
contracts:

- title, course, description, source link, status, priority, due wall time, and
  timezone semantics;
- UUID and database-lineage rules;
- courses, projects, tags, task-tag links, subtasks, attachment metadata, and
  reminder records;
- soft deletion, hidden-field preservation, parent progress derivation, safe
  attachment paths, SHA-256 metadata, and canonical UTC reminder triggers.

`repeat_rule` remains preserved and validated, but native recurrence is not a
Phase 2.5 capability on either side of this matrix.

## Platform differences

- Apple uses SwiftUI, UserNotifications, QuickLook/share flows, and native
  Apple window/sidebar behavior.
- Windows uses WinUI 3 NavigationView, Windows file pickers and Launcher,
  native toast APIs, system materials, and Windows focus rules.
- Equivalent user capability is required; Windows does not imitate SwiftUI,
  Liquid Glass, or macOS window behavior pixel for pixel.

## Evidence

Windows final automated evidence:

- Shared: 57/57;
- Backend: 19/19;
- Windows Core: 50/50;
- version sync, Pylint errors-only, and dotnet format passed;
- Debug and Release x64: 0 warnings/errors;
- clean self-contained publish and isolated launch smoke passed at source
  `623fbb30b8f7400c8e88b37c497a10dc2915ef9e`.

Windows desktop evidence covers task/status/delete persistence, full
organization CRUD, subtask CRUD and derived progress, attachments, navigation,
search, settings/theme persistence, keyboard and named focus order, Narrator,
150% DPI, visible scheduled notification delivery, and warm activation.

The one remaining Windows runtime evidence gap is cold activation after a
portable executable moves between directories during the same Windows logon.
The current session retained the prior CLSID server path even after registry,
shortcut, and official toolkit uninstall/re-registration updates. A fresh-logon
or stable-install-path rerun is required.

## Decision

Do not start Phase 3A or Schema v4 implementation from planning text. There is
no trustworthy newer Apple implementation baseline to port.

Current wording:

> Windows 1.1 implements and passes the current Apple Phase 2.5 domain and
> tested desktop capability matrix. Windows Preview parity remains undeclared
> until portable notification cold activation is verified from a fresh session
> or stable installation directory.
