# Assignment App shared contract

This directory is the platform-neutral source of truth. Schema v3 adds task
organization while retaining the complete v2 compatibility contract.

- `schemas/`: canonical v2/v3 task fields, identities, relationships, statuses,
  priorities, and database versions.
- `migrations/`: reference DDL. SQL files are not safe standalone migration
  runners.
- `fixtures/`: common input and expected task-view/sort results.
- `feature-specs/`: date, filtering, display-mode, organization, migration, and
  acceptance behavior.
- `task_rules.py`: executable reference implementation used by the shared tests.
- `schema_v3.py`: executable v3 schema/migration/validation primitives. A
  platform caller must create a verified SQLite Online Backup, own the
  transaction, and restore on failure.

Run the contract and migration suite from the repository root:

```bash
python3 -m unittest discover -s shared/tests -v
```

These tests create temporary databases only. Do not point them at a user or
repository database.

The current suite contains 57 tests. Schema v3 validation includes database
lineage and UUID contracts, exact index/trigger/foreign-key shapes, active
subtask-derived parent state, course/project relationship invariants, canonical
recurrence rules, organization scalar semantics, and attachment metadata-only
affinity checks, including hidden/generated columns.

Phase 0 also provides isolated HTTP/API tests:

```bash
python3 -m unittest discover -s backend/tests -v
python3 scripts/check_version_sync.py
```

The API tests set `ASSIGNMENT_DB_PATH` to a new temporary file before importing
FastAPI and assert that `backend/assignments.db` is unchanged. The
`shared-backend.yml` workflow runs both suites; it does not use a repository or
user database as test input.
