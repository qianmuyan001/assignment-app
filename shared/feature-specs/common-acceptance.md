# Common Apple, Windows, and Web acceptance cases

Run both clients against a disposable database populated from
`shared/fixtures/task-conformance-v2.json`. Never run migration or destructive
tests against the user's 1.0 database.

1. Add a task, restart, and verify every field remains.
2. Edit every field and verify the same row ID is retained.
3. Cancel deletion and verify the row remains; confirm deletion and verify it is
   gone.
4. Move a task through `todo`, `in_progress`, and `done`.
5. At fixture `now`, compare All, Today, Week, Overdue, and Completed IDs with
   `expected_views`.
6. Verify the null-due task stays out of Today, Week, and Overdue.
7. Verify the completed historical task stays out of Overdue.
8. Compare due and priority sorting with the fixture expected IDs.
9. Search Chinese, English, and special-character text; combine status, course,
   and priority filters.
10. Toggle simple/professional mode, restart to verify the setting, and confirm
    description, priority, and link were never cleared.
11. Copy a 1.0 fixture database, migrate the copy, and verify data, backup,
    `priority=medium`, legacy stored statuses, and `user_version=2`.
12. Inject a migration failure only in an automated disposable test and verify
    the source is restored byte-for-byte at the logical SQLite level.

## Schema v3 organization cases

Run all platforms against a disposable v2 database created from
`shared/fixtures/task-organization-v3.json` and compare the following outcomes:

13. Upgrade to v3 only after a verified SQLite Online Backup. Preserve the full
    ordered v2 payload, integer IDs, ambiguous DST wall time, null due date,
    Chinese, English, Emoji, and special characters.
14. Persist the fixture database instance UUID and produce every seeded UUID
    exactly. Link both `Physics` tasks to one course; do not merge a differently
    cased or spaced course name. Re-run the same local IDs under a different
    instance UUID and verify no migrated UUID collides.
15. Preserve an unknown v2 assignment column, index, and trigger during the
    additive migration. Confirm migrated `uuid` is logically required even
    though SQLite reports the added column as physically nullable.
16. Map migrated completed tasks to `progress_percent=100` and
    `completed_at=updated_at`; map other tasks to zero/null. Leave
    `timezone_id`, `project_id`, and `deleted_at` null and `all_day=false`.
17. Add, edit, archive, restore, and soft-delete a course, project, and tag.
    Restart and verify UUIDs do not change and task compatibility snapshots are
    not cleared.
18. Add, reorder, complete, restore, and soft-delete subtasks. Verify task
    progress uses only active subtasks and completion fields change atomically.
19. Attach a Unicode-named file, verify size and SHA-256, open it, soft-delete
    it, and run safe orphan cleanup. Store the original name only as metadata;
    require `attachments/<uuid>` as a lowercase, full-history-unique storage
    key. Reject absolute paths, traversal, NUL, empty segments, and path reuse;
    verify the database contains metadata but no payload BLOB.
20. Add, update, disable, and delete a reminder. Verify platform notification
    reconciliation uses the same active rows and UTC trigger instants.
21. Combine course, project, tag, status, and priority filters with the existing
    search and view rules. Simple/professional mode must remain a projection and
    retain all hidden organization data.
22. Inject failure after v3 DDL and before commit. Roll back, restore through the
    online backup, validate the original v2 logical snapshot, and stop startup.
23. Compare all fixture UUIDs, task/course relationships, derived progress, and
    attachment/reminder metadata on Apple, Windows, Web/backend, and the shared
    Python reference.
