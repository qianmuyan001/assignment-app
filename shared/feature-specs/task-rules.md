# Assignment App 2.0 shared task rules

This document is the behavior contract for the macOS and Windows clients.

## Fields and persistence

- The shared field names are `id`, `course_name`, `title`, `due_date`,
  `description`, `link`, `status`, and `priority`. `course` is the UI label for
  `course_name`; `source link` is the UI label for `link`.
- UI and API statuses are `todo`, `in_progress`, and `done`.
- SQLite retains the 1.0 values `not_started`, `in_progress`, and `completed`.
  Map them as `todo <-> not_started`, `in_progress <-> in_progress`, and
  `done <-> completed` at the data-access boundary.
- Priorities are `low`, `medium`, and `high`; a missing 1.0 value migrates to
  `medium`.
- `PRAGMA user_version` is `2` after a successful migration.
- Attachments, model assets, and caches must not be stored in `assignments`.

## Local date and time

- `due_date` is an optional local wall time with no UTC offset. Persist it as
  `YYYY-MM-DD HH:mm:ss`; interpret it using the device's current local calendar
  and timezone. Offset-bearing values are rejected rather than silently shifted.
- All ranges are half-open: the start is included and the end is excluded.
- Today is `[local day 00:00, next local day 00:00)`.
- The week is the natural Monday-based week `[Monday 00:00, next Monday 00:00)`.
- Today and week are date smart lists and may contain completed tasks.
- Overdue means `due_date < now` and status is not `done`.
- A task without a due date is never today, this week, or overdue. It remains in
  All, and appears in Completed when its status is `done`.

## Search, filters, and sorting

- Search trims the query and performs a case-insensitive substring match across
  title, course name, and description. An empty query applies no search filter.
- Status, course, and priority filters combine with logical AND. Course matching
  is trimmed, case-insensitive equality.
- Due-date sort is ascending with tasks that have no due date last.
- Priority sort is `high`, then `medium`, then `low`; ties use due-date order.

## Display modes

- Simple mode displays title, course, due date/time, and status.
- Professional mode additionally displays description, priority, and link.
- Mode changes are projections over the same task record. Hidden fields must not
  be written as null or empty, and the selected mode is persisted as a setting.

The executable reference for these rules is `shared/task_rules.py`; the canonical
cross-platform input and expected IDs are in
`shared/fixtures/task-conformance-v2.json`.
