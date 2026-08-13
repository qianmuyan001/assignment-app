# Schema v3 task-organization contract

Schema v3 is the shared data boundary for task organization. It adds stable
identities and related entities without changing the meaning or stored value of
any v2 task field. Platform repositories own backup, transaction, file-system,
notification, and UI behavior; `shared/schema_v3.py` owns the executable schema
change and validation rules.

## Identity

- `assignments.id` remains the local integer primary key and is never
  renumbered. `assignments.uuid` is the stable identity reserved for future
  synchronization.
- Schema v3 creates exactly one `database_identity` row in the migration
  transaction. Its `instance_uuid` is a production-random UUID v4 and is the
  UUID v5 namespace for migrated entities. Database backups and copies retain
  it; independently created databases must receive different values.
- Migrated task UUIDs are RFC 4122 UUID v5 using that database instance UUID
  and UTF-8 name `task:<decimal-id>`.
- Migrated courses use UTF-8 name `course:<exact-v2-course_name>`. Only
  byte-for-byte equal stored course names merge. Case, whitespace, compatibility
  characters, and accents do not affect identity.
- `normalized_name` is a search key only. It is NFKC-normalized, Unicode
  whitespace-collapsed, trimmed, and case-folded; it is intentionally not unique
  for courses.
- New records on every platform use lowercase canonical UUID v4. UUID v5 is
  migration-only and appears only on migrated assignments and courses. The
  database identity and every entity UUID are immutable after insert. Fixed
  vectors are in
  `shared/fixtures/task-organization-v3.json`.

## Assignment compatibility and migration defaults

The v2 columns and values remain intact: `id`, `course_name`, `title`,
`due_date`, `description`, `link`, `status`, `priority`, source metadata, and
audit timestamps. Task status remains stored as `not_started`, `in_progress`, or
`completed`, with the existing UI mapping to `todo`, `in_progress`, and `done`.

The v3 migration adds columns without rebuilding `assignments`. This preserves
unknown extension columns, indexes, and triggers used by an existing client.
SQLite cannot add a unique, row-specific, non-null UUID column in one `ALTER`,
so `uuid` is physically nullable, backfilled, uniquely indexed, and then made
logically required by `BEFORE INSERT` and `BEFORE UPDATE` triggers. A fresh v3
database uses the same physical/logical shape.

For every v2 task:

| v3 field | migrated value |
| --- | --- |
| `uuid` | deterministic task UUID v5 |
| `course_id` | exact-name migrated course, or null for a blank legacy name |
| `project_id` | null |
| `completed_at` | exact `updated_at` when stored status is `completed`; otherwise null |
| `progress_percent` | 100 when stored status is `completed`; otherwise 0 |
| `all_day` | false |
| `timezone_id` | null |
| `deleted_at` | null |

`due_date` is copied byte-for-byte. An old time is never offset, normalized, or
moved during migration, including an ambiguous or nonexistent daylight-saving
wall time.

## Courses, projects, and tags

- A course contains a stable UUID, display name, non-unique normalized search
  name, optional color, teacher, semester, archive flag, and audit fields.
- A project optionally belongs to a course and has a name, description, and one
  of `active`, `on_hold`, `completed`, or `archived`.
- A tag has a stable UUID, unique normalized name for new editing, optional
  color, and audit fields. `task_tags` is an audited, soft-deletable relationship
  with at most one active row for a task/tag pair.
- `course_name` remains on `assignments` as a v2 compatibility snapshot.
  Repositories that edit a linked course must update the relationship and
  snapshot together in one transaction.

## Subtasks and real progress

Subtasks use the same stored statuses as tasks, a nonnegative `sort_order`, and
an independent `completed_at`. A completed subtask must have a completion time;
another status must not.

Task `progress_percent` is an integer from 0 through 100. A completed task is
exactly 100 and has `completed_at`; a noncompleted task is 0 through 99 and has
no `completed_at`. When subtasks exist, the repository calculates progress as
`floor(100 * completed-active-subtasks / active-subtasks)` and caps a
noncompleted task at 99. Marking the task completed sets all three fields
atomically. Soft-deleted subtasks do not participate.

## Attachments

- The database stores only original file name, an immutable POSIX storage key,
  MIME type, byte size, SHA-256, identity, and audit metadata.
- Attachment payloads are files in the platform application-data directory;
  no attachment column has BLOB affinity.
- `relative_path` is exactly `attachments/<attachment UUID>`. It is lowercase,
  ASCII, case-stable across Apple and Windows file systems, and globally unique
  across active and soft-deleted rows. The original file name never becomes a
  path component. Resolve and recheck that the final path remains under the
  attachment root before every file operation.
- Copy a selected file to a temporary sibling, calculate size and SHA-256,
  atomically rename it into place, and only then commit metadata. Deletion first
  soft-deletes metadata; purge removes the immutable UUID-keyed file only after
  a committed database state. Paths are never reused, so a later attachment
  cannot be deleted by an older row's purge. Orphan cleanup never follows
  symbolic links outside the attachment root.

## Reminders

Reminders belong to one task and store an exact UTC trigger instant,
nonnegative lead minutes, optional RFC 5545 RRULE text without `DTSTART`, and an
enabled flag. Platform notification identifiers are runtime state and do not
belong in the shared reminder row. Repositories reconcile local notification
state from active reminder rows after startup, edits, time-zone changes, and
permission changes.

## Time and audit rules

- `due_date` remains a local wall time. `timezone_id` is null for migrated rows;
  null means the device's current local zone under the v2 compatibility rule.
- A newly zoned deadline stores an IANA identifier such as
  `America/Los_Angeles`; platforms must confirm the identifier exists, not only
  match its syntax. Changing device zone does not rewrite the wall-time text.
- `all_day=true` requires a due date and uses the calendar date in the task's
  effective zone. It does not mean a UTC midnight instant.
- New `created_at`, `updated_at`, `completed_at`, `deleted_at`, reminder trigger,
  and scheduling audit values use ISO-8601 UTC with `Z`. Existing v2 audit text
  is retained exactly during migration. Validation parses real calendar values,
  rather than accepting strings that merely resemble a timestamp.

## Soft deletion and foreign keys

Rows with `deleted_at IS NULL` are active. Ordinary deletion is a soft delete;
hard deletion is an explicit purge after attachment reconciliation. Child
entities cascade on an explicit hard task purge. Course and project hard purge
sets task relationships to null so the v2 `course_name` snapshot remains.

Every connection enables `PRAGMA foreign_keys=ON`. Schema validation runs
`foreign_key_check`, verifies required indexes and triggers, rejects invalid
UUID/path/hash metadata, and enforces progress semantics before commit.
