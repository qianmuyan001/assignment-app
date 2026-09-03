from __future__ import annotations

import sqlite3
import tempfile
import unittest
import json
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

from shared.schema_v3 import create_v3_schema
from shared.schema_v4 import (
    DATABASE_VERSION,
    SchemaV4Error,
    meeting_times_overlap,
    migrate_v3_to_v4,
    relative_reminder_trigger,
    validate_v4_schema,
)


def _connect(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(path)
    connection.execute("PRAGMA foreign_keys = ON")
    return connection


def _create_v3(path: Path) -> tuple[str, str]:
    course_uuid = str(uuid4())
    task_uuid = str(uuid4())
    reminder_uuid = str(uuid4())
    with closing(_connect(path)) as connection:
        connection.execute("BEGIN IMMEDIATE")
        create_v3_schema(connection, database_instance_uuid=str(uuid4()))
        connection.execute(
            "INSERT INTO courses "
            "(uuid,name,normalized_name,color_hex,teacher,semester) "
            "VALUES (?, 'Physics 物理', 'physics 物理', '#3366CC', 'Dr. Li', 'Fall')",
            (course_uuid,),
        )
        course_id = connection.execute("SELECT id FROM courses").fetchone()[0]
        connection.execute(
            "INSERT INTO assignments "
            "(uuid,course_name,title,due_date,status,priority,created_at,updated_at,"
            "course_id,progress_percent,all_day) "
            "VALUES (?, 'Physics 物理', 'Lab 🧪', '2026-11-01 01:30:00',"
            "'not_started','high','2026-08-31T02:00:00Z','2026-08-31T02:00:00Z',?,0,0)",
            (task_uuid, course_id),
        )
        task_id = connection.execute("SELECT id FROM assignments").fetchone()[0]
        trigger = "2026-10-31T17:00:00Z"
        connection.execute(
            "INSERT INTO reminders "
            "(uuid,assignment_id,trigger_at_utc,lead_minutes,is_enabled) "
            "VALUES (?,?,?,?,1)",
            (reminder_uuid, task_id, trigger, 60),
        )
        connection.execute("ALTER TABLE assignments ADD COLUMN school_extension TEXT")
        connection.execute(
            "UPDATE assignments SET school_extension='保留 ✅' WHERE id=?", (task_id,)
        )
        connection.execute(
            "CREATE INDEX ix_assignments_school_extension "
            "ON assignments(school_extension)"
        )
        connection.execute(
            "CREATE TABLE extension_notes (id INTEGER PRIMARY KEY, note TEXT NOT NULL)"
        )
        connection.execute("INSERT INTO extension_notes(note) VALUES ('扩展数据')")
        connection.execute("COMMIT")
    return trigger, task_uuid


def _preserved_snapshot(connection: sqlite3.Connection) -> tuple[object, ...]:
    return (
        tuple(connection.execute("SELECT * FROM assignments ORDER BY id")),
        tuple(connection.execute("SELECT * FROM courses ORDER BY id")),
        tuple(
            connection.execute(
                "SELECT id,uuid,assignment_id,trigger_at_utc,lead_minutes,repeat_rule,"
                "is_enabled,last_scheduled_at,created_at,updated_at,deleted_at "
                "FROM reminders ORDER BY id"
            )
        ),
        tuple(connection.execute("SELECT * FROM extension_notes ORDER BY id")),
    )


class SchemaV4MigrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.path = Path(self.temp_dir.name) / "phase3a.db"
        self.fixed_trigger, self.task_uuid = _create_v3(self.path)

    def test_v3_to_v4_is_additive_and_fixed_reminder_does_not_move(self) -> None:
        with closing(_connect(self.path)) as connection:
            before = _preserved_snapshot(connection)
            connection.execute("BEGIN IMMEDIATE")
            migrate_v3_to_v4(connection)
            connection.execute("COMMIT")
            validate_v4_schema(connection)
            self.assertEqual(DATABASE_VERSION, connection.execute(
                "PRAGMA user_version"
            ).fetchone()[0])
            self.assertEqual(before, _preserved_snapshot(connection))
            self.assertEqual(
                (self.fixed_trigger, 60, "fixed"),
                connection.execute(
                    "SELECT trigger_at_utc,lead_minutes,schedule_kind FROM reminders"
                ).fetchone(),
            )
            self.assertEqual("保留 ✅", connection.execute(
                "SELECT school_extension FROM assignments"
            ).fetchone()[0])

    def test_failure_rolls_back_to_exact_v3_shape_and_payload(self) -> None:
        with closing(_connect(self.path)) as connection:
            before = _preserved_snapshot(connection)
            connection.execute("BEGIN IMMEDIATE")
            with self.assertRaisesRegex(RuntimeError, "injected"):
                migrate_v3_to_v4(
                    connection,
                    migration_hook=lambda _: (_ for _ in ()).throw(
                        RuntimeError("injected")
                    ),
                )
            connection.execute("ROLLBACK")
            self.assertEqual(3, connection.execute("PRAGMA user_version").fetchone()[0])
            self.assertEqual(before, _preserved_snapshot(connection))
            self.assertNotIn(
                "schedule_kind",
                {row[1] for row in connection.execute("PRAGMA table_info(reminders)")},
            )
            self.assertIsNone(connection.execute(
                "SELECT name FROM sqlite_master WHERE name='course_meetings'"
            ).fetchone())

    def test_validator_rejects_invalid_learning_rows(self) -> None:
        with closing(_connect(self.path)) as connection:
            connection.execute("BEGIN IMMEDIATE")
            migrate_v3_to_v4(connection)
            course_id = connection.execute("SELECT id FROM courses").fetchone()[0]
            with self.assertRaises(sqlite3.IntegrityError):
                connection.execute(
                    "INSERT INTO course_meetings "
                    "(uuid,course_id,weekday,start_time_local,end_time_local,timezone_id,"
                    "effective_start_date,sort_order) VALUES (?,?,1,'10:00:00','09:00:00',"
                    "'Asia/Shanghai','2026-09-01',0)",
                    (str(uuid4()), course_id),
                )
            with self.assertRaises(sqlite3.IntegrityError):
                connection.execute(
                    "UPDATE reminders SET schedule_kind='relative'"
                )
            connection.execute("ROLLBACK")


class LearningRuleTests(unittest.TestCase):
    def test_meeting_boundaries_and_overlap(self) -> None:
        self.assertFalse(meeting_times_overlap("09:00:00", "10:00:00", "10:00:00", "11:00:00"))
        self.assertTrue(meeting_times_overlap("09:00:00", "10:01:00", "10:00:00", "11:00:00"))
        with self.assertRaises(SchemaV4Error):
            meeting_times_overlap("10:00:00", "09:00:00", "08:00:00", "09:00:00")

    def test_relative_trigger_uses_exact_utc_instant(self) -> None:
        due = datetime(2026, 11, 1, 6, 30, tzinfo=timezone.utc)
        self.assertEqual(
            datetime(2026, 11, 1, 5, 30, tzinfo=timezone.utc),
            relative_reminder_trigger(due, 60),
        )
        with self.assertRaises(SchemaV4Error):
            relative_reminder_trigger(None, 10)


class V4ArtifactTests(unittest.TestCase):
    def test_reference_artifacts_are_well_formed(self) -> None:
        root = Path(__file__).resolve().parents[1]
        schema = json.loads((root / "schemas/database-v4.json").read_text())
        fixture = json.loads((root / "fixtures/learning-scenes-v4.json").read_text())
        migration = (root / "migrations/004_learning_scenes_v4.sql").read_text()
        self.assertEqual(4, schema["properties"]["databaseVersion"]["const"])
        self.assertEqual("due_relative", fixture["relativeReminder"]["scheduleKind"])
        self.assertIn("ALTER TABLE reminders", migration)
        self.assertIn("PRAGMA user_version = 4", migration)


if __name__ == "__main__":
    unittest.main()
