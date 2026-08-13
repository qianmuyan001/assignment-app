from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from contextlib import closing
from copy import deepcopy
from datetime import datetime
from pathlib import Path

from backend.app.database import (
    DatabaseMigrationError,
    migrate_database,
)
from backend.app.models import Assignment
from backend.app.schemas import AssignmentCreate
from shared.schema_v3 import DATABASE_VERSION, new_v3_uuid
from shared.task_rules import (
    STATUS_FROM_DATABASE,
    STATUS_TO_DATABASE,
    database_status,
    filter_tasks,
    matches_view,
    normalize_status,
    parse_local_wall_time,
    project_for_mode,
    search_tasks,
    sort_tasks,
    week_bounds,
)


ROOT = Path(__file__).resolve().parents[2]
FIXTURE_PATH = ROOT / "shared" / "fixtures" / "task-conformance-v2.json"


def _load_fixture() -> tuple[datetime, list[dict[str, object]], dict[str, object]]:
    fixture = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
    return (
        datetime.fromisoformat(fixture["now"]),
        fixture["tasks"],
        fixture,
    )


def _create_v1_database(path: Path, *, status: str = "not_started") -> None:
    connection = sqlite3.connect(path)
    try:
        connection.execute("PRAGMA journal_mode = WAL")
        connection.execute(
            """
            CREATE TABLE assignments (
                id INTEGER NOT NULL PRIMARY KEY,
                course_name VARCHAR(120) NOT NULL,
                title VARCHAR(255) NOT NULL,
                due_date DATETIME NOT NULL,
                description TEXT,
                link VARCHAR(1000),
                status VARCHAR(20) NOT NULL DEFAULT 'not_started',
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
                CHECK (status IN (
                    'not_started', 'todo', 'in_progress', 'completed', 'done'
                ))
            )
            """
        )
        connection.execute(
            """
            INSERT INTO assignments (
                id, course_name, title, due_date, description, link, status
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                41,
                "语文 / English",
                "Legacy's \"special\" task 📚",
                "2026-08-05 18:30:00",
                "保留 <>& and emoji 🧪",
                "https://example.test/?a=1&b=二",
                status,
            ),
        )
        connection.execute("PRAGMA user_version = 0")
        connection.commit()
    finally:
        connection.close()


def _create_current_v1_database(path: Path) -> None:
    connection = sqlite3.connect(path)
    try:
        connection.execute(
            """
            CREATE TABLE assignments (
                id INTEGER NOT NULL,
                course_name VARCHAR(120) NOT NULL,
                title VARCHAR(255) NOT NULL,
                due_date DATETIME,
                description TEXT,
                link VARCHAR(1000),
                status VARCHAR(20) NOT NULL DEFAULT 'not_started',
                source_name VARCHAR(255),
                source_type VARCHAR(80),
                source_file VARCHAR(1000),
                source_url VARCHAR(1000),
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
                PRIMARY KEY (id),
                CHECK (status IN ('not_started', 'in_progress', 'completed'))
            )
            """
        )
        connection.executemany(
            """
            INSERT INTO assignments (
                id, course_name, title, due_date, status, source_url
            ) VALUES (?, ?, ?, ?, ?, ?)
            """,
            [
                (1, "Math", "No due date", None, "not_started", None),
                (
                    9,
                    "计算机",
                    "保留 ID 和来源",
                    "2026-08-07 12:00:00",
                    "in_progress",
                    "https://例子.测试/source",
                ),
            ],
        )
        connection.execute("PRAGMA user_version = 0")
        connection.commit()
    finally:
        connection.close()


def _logical_snapshot(path: Path) -> tuple[int, str, list[tuple[object, ...]]]:
    connection = sqlite3.connect(path)
    try:
        version = int(connection.execute("PRAGMA user_version").fetchone()[0])
        schema = str(
            connection.execute(
                "SELECT sql FROM sqlite_master "
                "WHERE type = 'table' AND name = 'assignments'"
            ).fetchone()[0]
        )
        rows = connection.execute("SELECT * FROM assignments ORDER BY id").fetchall()
        return version, schema, rows
    finally:
        connection.close()


class TaskCrudContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.database_path = Path(self.temp_dir.name) / "contract.db"
        migrate_database(self.database_path)

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.database_path)
        connection.row_factory = sqlite3.Row
        return connection

    def _insert_task(self) -> int:
        with closing(self._connect()) as connection, connection:
            audit_time = "2026-08-05T17:00:00Z"
            cursor = connection.execute(
                """
                INSERT INTO assignments (
                    uuid, course_name, title, due_date, description, link,
                    status, priority, completed_at, progress_percent, all_day,
                    created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, 0, 0, ?, ?)
                """,
                (
                    new_v3_uuid(),
                    "Physics",
                    "Wave lab",
                    "2026-08-05 18:00:00",
                    "Initial notes",
                    "https://example.test/lab",
                    database_status("todo"),
                    "medium",
                    audit_time,
                    audit_time,
                ),
            )
            return int(cursor.lastrowid)

    def test_01_add_task(self) -> None:
        task_id = self._insert_task()
        with closing(self._connect()) as connection, connection:
            row = connection.execute(
                "SELECT * FROM assignments WHERE id = ?", (task_id,)
            ).fetchone()
        self.assertEqual(row["title"], "Wave lab")
        self.assertEqual(row["status"], "not_started")
        self.assertEqual(row["priority"], "medium")

    def test_02_edit_task_preserves_row_identity(self) -> None:
        task_id = self._insert_task()
        with closing(self._connect()) as connection, connection:
            connection.execute(
                """
                UPDATE assignments
                SET title = ?, description = ?, priority = ?,
                    updated_at = '2026-08-05T17:30:00Z'
                WHERE id = ?
                """,
                ("Updated 波形", "Edited <>& 📈", "high", task_id),
            )
            row = connection.execute(
                "SELECT id, title, description, priority FROM assignments WHERE id = ?",
                (task_id,),
            ).fetchone()
        self.assertEqual(tuple(row), (task_id, "Updated 波形", "Edited <>& 📈", "high"))

    def test_03_soft_delete_task(self) -> None:
        task_id = self._insert_task()
        with closing(self._connect()) as connection, connection:
            connection.execute(
                "UPDATE assignments SET deleted_at='2026-08-05T18:00:00Z' "
                "WHERE id = ?",
                (task_id,),
            )
            active_count = connection.execute(
                "SELECT COUNT(*) FROM assignments "
                "WHERE id = ? AND deleted_at IS NULL",
                (task_id,),
            ).fetchone()[0]
            retained_count = connection.execute(
                "SELECT COUNT(*) FROM assignments WHERE id = ?", (task_id,)
            ).fetchone()[0]
        self.assertEqual(active_count, 0)
        self.assertEqual(retained_count, 1)

    def test_04_change_status_uses_legacy_storage_values(self) -> None:
        task_id = self._insert_task()
        with closing(self._connect()) as connection, connection:
            observed = []
            for canonical in ("todo", "in_progress", "done"):
                is_done = canonical == "done"
                connection.execute(
                    """
                    UPDATE assignments
                    SET status = ?, completed_at = ?, progress_percent = ?,
                        updated_at = '2026-08-05T19:00:00Z'
                    WHERE id = ?
                    """,
                    (
                        database_status(canonical),
                        "2026-08-05T19:00:00Z" if is_done else None,
                        100 if is_done else 0,
                        task_id,
                    ),
                )
                stored = connection.execute(
                    "SELECT status FROM assignments WHERE id = ?", (task_id,)
                ).fetchone()[0]
                observed.append((stored, normalize_status(stored)))
        self.assertEqual(
            observed,
            [
                ("not_started", "todo"),
                ("in_progress", "in_progress"),
                ("completed", "done"),
            ],
        )


class SmartListAndFilterContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.now, cls.tasks, cls.fixture = _load_fixture()

    def _view_ids(self, view: str) -> list[int]:
        return [
            int(task["id"])
            for task in self.tasks
            if matches_view(task, view, now=self.now)  # type: ignore[arg-type]
        ]

    def test_05_today_uses_half_open_local_day(self) -> None:
        self.assertEqual(
            self._view_ids("today"),
            self.fixture["expected_views"]["today"],
        )
        boundary_task = {"status": "todo", "due_date": "2026-08-06 00:00:00"}
        self.assertFalse(matches_view(boundary_task, "today", now=self.now))

    def test_06_week_is_monday_based_and_half_open(self) -> None:
        self.assertEqual(week_bounds(self.now)[0], datetime(2026, 8, 3))
        self.assertEqual(
            self._view_ids("week"),
            self.fixture["expected_views"]["week"],
        )

    def test_07_overdue_compares_full_deadline_to_now(self) -> None:
        self.assertEqual(
            self._view_ids("overdue"),
            self.fixture["expected_views"]["overdue"],
        )

    def test_08_completed_task_is_never_overdue(self) -> None:
        completed = next(task for task in self.tasks if task["id"] == 7)
        self.assertLess(parse_local_wall_time(completed["due_date"]), self.now)
        self.assertFalse(matches_view(completed, "overdue", now=self.now))

    def test_09_task_without_due_date(self) -> None:
        no_due = next(task for task in self.tasks if task["id"] == 6)
        for view in ("today", "week", "overdue"):
            self.assertFalse(
                matches_view(no_due, view, now=self.now)  # type: ignore[arg-type]
            )
        self.assertTrue(matches_view(no_due, "all", now=self.now))

    def test_10_priority_and_due_date_sorting(self) -> None:
        priority_ids = [task["id"] for task in sort_tasks(self.tasks, by="priority")]
        due_ids = [task["id"] for task in sort_tasks(self.tasks, by="due_date")]
        self.assertEqual(priority_ids, self.fixture["expected_sorts"]["priority"])
        self.assertEqual(due_ids, self.fixture["expected_sorts"]["due_date"])

    def test_11_search_and_filters_combine_predictably(self) -> None:
        self.assertEqual(
            [task["id"] for task in search_tasks(self.tasks, "整理实验")],
            [2],
        )
        self.assertEqual(
            [
                task["id"]
                for task in filter_tasks(
                    self.tasks,
                    status="todo",
                    course_name=" mathematics ",
                    priority="high",
                )
            ],
            [1],
        )

    def test_12_display_mode_projection_never_mutates_task(self) -> None:
        task = deepcopy(self.tasks[0])
        original = deepcopy(task)
        simple = project_for_mode(task, "simple")
        professional = project_for_mode(task, "professional")
        self.assertNotIn("description", simple)
        self.assertEqual(professional["description"], original["description"])
        self.assertEqual(task, original)


class MigrationAndCompatibilityContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.database_path = Path(self.temp_dir.name) / "legacy.db"

    def test_13_v1_database_migrates_with_backup_and_data(self) -> None:
        _create_v1_database(self.database_path, status="completed")
        wal_keeper = sqlite3.connect(self.database_path)
        try:
            wal_keeper.execute("PRAGMA journal_mode = WAL")
            wal_keeper.execute(
                """
                INSERT INTO assignments (
                    id, course_name, title, due_date, status
                ) VALUES (42, 'Physics', 'Committed in WAL',
                          '2026-08-06 19:00:00', 'not_started')
                """
            )
            wal_keeper.commit()
            self.assertTrue(Path(f"{self.database_path}-wal").exists())
            result = migrate_database(self.database_path)
        finally:
            wal_keeper.close()

        self.assertTrue(result.migrated)
        self.assertEqual((result.from_version, result.to_version), (1, DATABASE_VERSION))
        self.assertEqual(result.strategy, "v1-v2-rebuild+v2-v3-additive")
        self.assertIsNotNone(result.backup_path)
        self.assertTrue(result.backup_path.is_file())

        with closing(sqlite3.connect(self.database_path)) as connection, connection:
            connection.row_factory = sqlite3.Row
            self.assertEqual(
                connection.execute("PRAGMA user_version").fetchone()[0],
                DATABASE_VERSION,
            )
            row = connection.execute(
                "SELECT * FROM assignments WHERE id = 41"
            ).fetchone()
            self.assertEqual(row["status"], "completed")
            self.assertEqual(row["priority"], "medium")
            self.assertEqual(row["title"], "Legacy's \"special\" task 📚")
            self.assertEqual(
                connection.execute(
                    "SELECT priority FROM assignments WHERE id = 42"
                ).fetchone()[0],
                "medium",
            )

        with closing(sqlite3.connect(result.backup_path)) as backup, backup:
            columns = {
                row[1] for row in backup.execute("PRAGMA table_info(assignments)")
            }
            self.assertNotIn("priority", columns)
            self.assertEqual(backup.execute("PRAGMA user_version").fetchone()[0], 0)
            self.assertEqual(
                backup.execute(
                    "SELECT title FROM assignments WHERE id = 42"
                ).fetchone()[0],
                "Committed in WAL",
            )

    def test_current_v1_schema_uses_additive_migration(self) -> None:
        _create_current_v1_database(self.database_path)
        before_ids = [1, 9]

        result = migrate_database(self.database_path)

        self.assertEqual(result.strategy, "v1-v2-additive+v2-v3-additive")
        with closing(sqlite3.connect(self.database_path)) as connection, connection:
            after_ids = [
                row[0]
                for row in connection.execute(
                    "SELECT id FROM assignments ORDER BY id"
                ).fetchall()
            ]
            priorities = connection.execute(
                "SELECT DISTINCT priority FROM assignments"
            ).fetchall()
            version = connection.execute("PRAGMA user_version").fetchone()[0]
        self.assertEqual(after_ids, before_ids)
        self.assertEqual(priorities, [("medium",)])
        self.assertEqual(version, DATABASE_VERSION)

    def test_14_failed_migration_restores_original_and_stops(self) -> None:
        _create_current_v1_database(self.database_path)
        before = _logical_snapshot(self.database_path)

        def fail_after_schema_change(_: sqlite3.Connection) -> None:
            raise RuntimeError("injected migration failure")

        with self.assertRaises(DatabaseMigrationError) as raised:
            migrate_database(
                self.database_path,
                migration_hook=fail_after_schema_change,
            )

        self.assertIn("restored", str(raised.exception))
        self.assertEqual(_logical_snapshot(self.database_path), before)
        self.assertTrue(list(self.database_path.parent.glob("*.bak")))

    def test_15_chinese_and_special_characters_survive_migration(self) -> None:
        _create_v1_database(self.database_path)
        migrate_database(self.database_path)
        with closing(sqlite3.connect(self.database_path)) as connection, connection:
            row = connection.execute(
                "SELECT course_name, title, description, link FROM assignments"
            ).fetchone()
        self.assertEqual(row[0], "语文 / English")
        self.assertEqual(row[1], "Legacy's \"special\" task 📚")
        self.assertEqual(row[2], "保留 <>& and emoji 🧪")
        self.assertEqual(row[3], "https://example.test/?a=1&b=二")

    def test_16_platform_adapters_produce_identical_fixture_views(self) -> None:
        now, canonical_tasks, fixture = _load_fixture()
        stored_tasks = [
            {**task, "status": STATUS_TO_DATABASE[str(task["status"])]}
            for task in canonical_tasks
        ]
        macos_tasks = [
            {**task, "status": STATUS_FROM_DATABASE[str(task["status"])]}
            for task in stored_tasks
        ]
        windows_tasks = deepcopy(canonical_tasks)

        for view, expected_ids in fixture["expected_views"].items():
            macos_ids = [
                task["id"]
                for task in macos_tasks
                if matches_view(task, view, now=now)
            ]
            windows_ids = [
                task["id"]
                for task in windows_tasks
                if matches_view(task, view, now=now)
            ]
            self.assertEqual(macos_ids, expected_ids)
            self.assertEqual(windows_ids, expected_ids)

    def test_backend_model_and_schema_map_ui_and_storage_statuses(self) -> None:
        model = Assignment(
            course_name="Biology",
            title="Cell worksheet",
            status="done",
            priority="high",
        )
        self.assertEqual(model.status, "done")
        self.assertEqual(model._status, "completed")
        payload = AssignmentCreate(
            course_name=" Biology ",
            title=" Worksheet ",
            status="not_started",
        )
        self.assertEqual(payload.status, "todo")
        self.assertEqual(payload.priority, "medium")

    def test_due_dates_reject_offsets_instead_of_shifting(self) -> None:
        with self.assertRaises(ValueError):
            parse_local_wall_time("2026-08-05T12:00:00+08:00")
        with self.assertRaises(ValueError):
            AssignmentCreate(
                course_name="Biology",
                title="Worksheet",
                due_date="2026-08-05T12:00:00Z",
            )

    def test_assignment_db_path_environment_override(self) -> None:
        configured = Path(self.temp_dir.name) / "override.db"
        environment = os.environ.copy()
        environment["ASSIGNMENT_DB_PATH"] = str(configured)
        completed = subprocess.run(
            [
                sys.executable,
                "-c",
                (
                    "from backend.app.database import DATABASE_PATH; "
                    "print(DATABASE_PATH)"
                ),
            ],
            cwd=ROOT,
            env=environment,
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertEqual(Path(completed.stdout.strip()), configured.resolve())
        self.assertFalse(configured.exists())


if __name__ == "__main__":
    unittest.main()
