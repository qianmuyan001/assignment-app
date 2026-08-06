# Common macOS and Windows acceptance cases

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
