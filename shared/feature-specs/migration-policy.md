# SQLite migration policy

## v2 to v3

- The platform migration runner acquires its cross-process migration lock,
  enables foreign keys on connection A, starts `BEGIN IMMEDIATE`, and rechecks
  the source version before any write or DDL.
- While connection A holds that write reservation but has not changed data,
  read-only connection B creates a uniquely named, standalone backup with
  SQLite Online Backup and verifies `integrity_check=ok`. The lock remains held
  through commit or restoration, so another process cannot restore a stale v2
  backup over a completed v3 migration.
- `shared.schema_v3.migrate_v2_to_v3` performs schema changes and validation on
  connection A but never begins, commits, rolls back, opens a file, or creates a
  backup.
- `assignments` is upgraded only through additive `ALTER TABLE` statements.
  Unknown columns, indexes, triggers, row IDs, and every v2 field value remain.
  Existing assignment triggers are captured, suspended during the derived-field
  backfill to avoid user-visible side effects, and recreated with their original
  SQL inside the same transaction.
- The transaction creates one production-random database instance UUID v4.
  Migrated UUIDs use it as their UUID v5 namespace and follow the seeded test
  vectors in `shared/fixtures/task-organization-v3.json`. Database copies retain
  that lineage value; independent databases must not share it. Courses merge
  only when their original stored `course_name` values are exactly equal.
- `due_date` and all v2 audit text are copied without parsing or conversion.
  Migrated rows use `timezone_id=NULL`.
- Before commit, compare the complete ordered v2 payload, verify derived v3
  fields, required objects, UUIDs, foreign keys, attachment metadata,
  progress/state invariants, `integrity_check`, and `user_version=3`.
- Any error rolls back the entire transaction. The platform runner then restores
  the original with SQLite Online Backup, validates that restoration, preserves
  the independent backup, raises a fatal migration error, and stops startup.
- Tests use a new temporary database or a private database copy. Never attach a
  test runner to the configured user or repository database.

## v1 to v2 compatibility step

- A database with an `assignments` table and `PRAGMA user_version = 0` is the
  historical 1.0 schema and is treated as version 1.
- Before any DDL, create a uniquely named sibling `.bak` file using the
  platform's SQLite online-backup API. This captures committed WAL content and
  produces a standalone, recoverable SQLite database.
- The current 1.0 shape (nullable `due_date` and legacy status constraint) uses
  an additive transaction: add missing source columns and `priority`, create
  missing indexes, then set `PRAGMA user_version = 2`.
- Rebuild only when an in-place change cannot establish the v2 contract, such as
  a non-null `due_date`, canonical status values stored directly, or incompatible
  constraints. Rebuild maps `todo` to `not_started` and `done` to `completed`.
- Record count and the complete ordered ID set must be identical before and after
  either strategy. Status, priority, schema, and SQLite integrity checks must
  also pass before commit.
- Any error rolls back, restores through the SQLite backup API, and raises
  `DatabaseMigrationError`. Application startup must stop on that exception.
- Never run migration tests against the configured user database. Tests create
  disposable SQLite files and may set `ASSIGNMENT_DB_PATH` to an isolated path.

The current v1-to-v2 executable runner is `backend/app/database.py`. A platform
moving directly from v1 to v3 first establishes and validates v2 inside the
same protected migration workflow, then invokes the v3 primitive. SQL files in
`shared/migrations` are reference DDL only.
