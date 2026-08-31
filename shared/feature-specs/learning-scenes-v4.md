# Assignment App Phase 3A learning-scenes contract (Schema v4)

## Scope and ownership

Schema v4 adds course meetings, exams, and an explicit reminder schedule kind.
It reuses `courses`, `assignments`, `reminders`, the database lineage UUID,
UTC audit timestamps, and soft deletion. It does not create another course,
task, or notification model.

Apple Phase 3A is the first v4 client. Windows and Web remain v3-only until
their own incremental adapters are implemented; they must fail closed when
opening a v4 database instead of writing with a v3 contract.

## Course Meeting

- `weekday` uses ISO values `1...7`, Monday through Sunday.
- `start_time_local` and `end_time_local` use `HH:mm:ss`; start is strictly
  earlier than end. Overnight meetings are outside Phase 3A.
- `timezone_id` is a resolvable IANA identifier.
- `effective_start_date` and optional `effective_end_date` use `YYYY-MM-DD` in
  the meeting time zone; the end is inclusive and cannot precede the start.
- A course can have multiple meetings on the same weekday.
- Overlaps are warnings, not destructive validation. Two active meetings
  overlap when their effective date ranges intersect and their resolved time
  intervals overlap. Adjacency (`end == start`) is not overlap.
- A missing daylight-saving wall time has no occurrence and is shown as a
  scheduling warning. For a repeated wall time, the first (earlier-offset)
  occurrence is used.
- Start and end are resolved independently. An occurrence spanning a fall-back
  boundary therefore reports the real elapsed interval instead of the nominal
  wall-clock duration; this is an accepted, disclosed edge case because Phase 3A
  meetings are ordinary daytime classes.
- Overlap is evaluated on the earliest date both meetings are effective for
  their shared weekday, comparing resolved UTC intervals. If that date has a
  daylight-saving gap for either meeting, the comparison falls back to stored
  wall-clock intervals. Overlap never mutates, merges, or deletes a meeting.

## Exam

- `starts_at_local` is local wall time `YYYY-MM-DD HH:mm:ss` interpreted in the
  declared IANA `timezone_id`; offset-bearing text is rejected.
- Status is `upcoming`, `completed`, or `cancelled`.
- Today and upcoming calculations compare resolved instants while presenting
  the exam in its declared time zone.
- An exam may link one Review Task through `linked_assignment_id`. Creating a
  Review Task is idempotent and returns the stored task identity when invoked
  again.
- Soft-deleting an exam never deletes or soft-deletes its Review Task.

## Reminder schedule kinds

- `schedule_kind='fixed'`: `trigger_at_utc` is authoritative. Every migrated
  v3 reminder receives this value and its trigger and lead metadata remain
  byte-for-byte unchanged.
- `schedule_kind='due_relative'`: `lead_minutes` is subtracted from the task's
  resolved deadline and the computed UTC result is stored in
  `trigger_at_utc` as a scheduling cache.
- Only due-relative reminders move when a deadline or task time zone changes.
- A task without a deadline cannot create or enable a due-relative reminder.
- Completing or deleting a task cancels its pending notifications without
  deleting reminder records.

## Migration safety

The v3-to-v4 migration is additive. Before `BEGIN IMMEDIATE`, the platform
runner creates and verifies a unique SQLite Online Backup. Within the same
transaction it validates v3, adds `reminders.schedule_kind`, creates v4 tables,
indexes, and triggers, validates payload/integrity/foreign keys, and sets
`PRAGMA user_version=4`. Any failure rolls back, verifies the original logical
fingerprint, keeps the backup, and stops startup writes.

Existing integer IDs, UUIDs, assignment wall-time text, extension columns,
extension tables, indexes, triggers, Unicode, reminders, and all v3 child data
remain unchanged.
