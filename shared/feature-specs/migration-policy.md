# SQLite v1 to v2 migration policy

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

The executable runner is `backend/app/database.py`; the SQL file in
`shared/migrations` is reference DDL only.
