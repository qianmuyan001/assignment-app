# Assignment App 2.0 shared contract

This directory is the platform-neutral source of truth for the 2.0 task model.

- `schemas/`: canonical task fields, status mapping, priorities, and database
  version.
- `migrations/`: reference v2 DDL. Executable migration code must use a SQLite
  backup API and platform-specific transaction handling.
- `fixtures/`: common input and expected task-view/sort results.
- `feature-specs/`: date, filtering, display-mode, migration, and acceptance
  behavior.
- `task_rules.py`: executable reference implementation used by the shared tests.

Run the contract and migration suite from the repository root:

```bash
python3 -m unittest discover -s shared/tests -v
```

These tests create temporary databases only. Do not point them at a user or
repository 1.0 database.
