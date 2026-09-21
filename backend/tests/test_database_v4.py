"""Backend migration safety: every fixture is a newly owned temporary database."""
from __future__ import annotations

import os
import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path
from unittest.mock import patch
from uuid import uuid4

# Database import constructs its engine lazily, but still give it an isolated
# path when this module runs by itself. Tests never import the live main app.
_IMPORT_ROOT = tempfile.TemporaryDirectory(prefix="assignment-v4-import-")
os.environ["ASSIGNMENT_DB_PATH"] = str(Path(_IMPORT_ROOT.name) / "unused.db")

from backend.app import database  # noqa: E402
from shared.schema_v3 import attachment_storage_relative_path, create_v3_schema  # noqa: E402
from shared.schema_v4 import validate_v4_schema  # noqa: E402


def connect(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(path)
    connection.execute("PRAGMA foreign_keys=ON")
    return connection


def create_populated_v3(path: Path) -> None:
    with closing(connect(path)) as connection:
        connection.execute("BEGIN IMMEDIATE")
        create_v3_schema(connection)
        connection.execute(
            "INSERT INTO courses(id,uuid,name,normalized_name,teacher,semester) "
            "VALUES(7,?,'物理','物理','Li','2026 秋')", (str(uuid4()),)
        )
        connection.execute(
            "INSERT INTO projects(id,uuid,course_id,name,description,status) "
            "VALUES(9,?,7,'实验','项目内容','on_hold')", (str(uuid4()),)
        )
        connection.execute(
            "INSERT INTO assignments(id,uuid,course_name,course_id,project_id,title,"
            "due_date,description,link,status,priority,created_at,updated_at,timezone_id) "
            "VALUES(41,?,'物理',7,9,'实验 🧪','2026-11-01 01:30:00.123',"
            "'保留专业字段','https://example.test/source','not_started','high',"
            "'2026-09-01T01:02:03.000Z','2026-09-01T01:02:03.000Z','America/New_York')",
            (str(uuid4()),),
        )
        connection.execute(
            "INSERT INTO tags(id,uuid,name,normalized_name) VALUES(3,?,'重要','重要')",
            (str(uuid4()),),
        )
        connection.execute(
            "INSERT INTO task_tags(uuid,assignment_id,tag_id) VALUES(?,41,3)",
            (str(uuid4()),),
        )
        connection.execute(
            "INSERT INTO subtasks(uuid,assignment_id,title,sort_order) "
            "VALUES(?,41,'准备仪器',4)", (str(uuid4()),)
        )
        attachment_uuid = str(uuid4())
        connection.execute(
            "INSERT INTO attachments(uuid,assignment_id,file_name,relative_path,"
            "mime_type,byte_size,sha256) VALUES(?,41,'研究.pdf',?,'application/pdf',7,?)",
            (attachment_uuid, attachment_storage_relative_path(attachment_uuid), 'a' * 64),
        )
        connection.execute(
            "INSERT INTO reminders(uuid,assignment_id,trigger_at_utc,lead_minutes,"
            "repeat_rule,is_enabled,last_scheduled_at) "
            "VALUES(?,41,'2026-10-31T17:00:00Z',75,'FREQ=DAILY;COUNT=2',1,"
            "'2026-09-01T01:02:03Z')", (str(uuid4()),)
        )
        connection.execute("ALTER TABLE assignments ADD COLUMN school_extension TEXT")
        connection.execute("UPDATE assignments SET school_extension='保留 ✅'")
        connection.execute("CREATE TABLE extension_notes(id INTEGER PRIMARY KEY, note BLOB)")
        connection.execute("INSERT INTO extension_notes VALUES(1,?)", (b'\x00\xffunchanged',))
        connection.execute("CREATE INDEX extension_task_index ON assignments(school_extension)")
        connection.execute(
            "CREATE TRIGGER extension_task_audit AFTER UPDATE OF title ON assignments "
            "BEGIN INSERT INTO extension_notes(note) VALUES(NEW.title); END"
        )
        connection.commit()


def preserved_rows(path: Path) -> dict[str, tuple[tuple[object, ...], ...]]:
    with closing(connect(path)) as connection:
        rows = {}
        for table in (
            "database_identity", "assignments", "courses", "projects", "tags",
            "task_tags", "subtasks", "attachments", "extension_notes",
        ):
            rows[table] = tuple(connection.execute(f'SELECT * FROM "{table}" ORDER BY 1'))
        rows["reminders"] = tuple(connection.execute(
            "SELECT id,uuid,assignment_id,trigger_at_utc,lead_minutes,repeat_rule,"
            "is_enabled,last_scheduled_at,created_at,updated_at,deleted_at FROM reminders"
        ))
        rows["extension_schema"] = tuple(connection.execute(
            "SELECT type,name,tbl_name,sql FROM sqlite_master "
            "WHERE name LIKE 'extension_%' ORDER BY name"
        ))
        return rows


def snapshot(path: Path) -> tuple[int, tuple[str, ...]]:
    with closing(connect(path)) as connection:
        return connection.execute("PRAGMA user_version").fetchone()[0], tuple(connection.iterdump())


class BackendDatabaseV4Tests(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory(prefix="assignment-v4-migration-")
        self.addCleanup(directory.cleanup)
        self.path = Path(directory.name) / "case.db"

    def test_v3_upgrade_preserves_every_child_extension_and_fixed_trigger(self) -> None:
        create_populated_v3(self.path)
        before = preserved_rows(self.path)
        result = database.migrate_database(self.path)
        self.assertEqual((result.from_version, result.to_version, result.strategy), (3, 4, "v3-v4-additive"))
        self.assertEqual(preserved_rows(self.path), before)
        self.assertEqual(preserved_rows(result.backup_path), before)
        with closing(connect(self.path)) as connection:
            validate_v4_schema(connection)
            self.assertEqual(connection.execute("SELECT schedule_kind FROM reminders").fetchall(), [('fixed',)])
        with closing(connect(result.backup_path)) as backup:
            self.assertEqual(backup.execute("PRAGMA user_version").fetchone()[0], 3)
            self.assertEqual(backup.execute("PRAGMA journal_mode").fetchone()[0], 'delete')
            self.assertEqual(backup.execute("PRAGMA integrity_check").fetchone()[0], 'ok')

    def test_valid_v4_reopens_without_migration_or_new_backup(self) -> None:
        create_populated_v3(self.path)
        database.migrate_database(self.path)
        before = snapshot(self.path)
        result = database.migrate_database(self.path)
        self.assertEqual((result.migrated, result.from_version, result.to_version), (False, 4, 4))
        self.assertIsNone(result.backup_path)
        self.assertEqual(snapshot(self.path), before)
        self.assertEqual(len(list(self.path.parent.glob('*.bak'))), 1)

    def test_v3_failure_rolls_back_all_ddl_payload_and_version(self) -> None:
        create_populated_v3(self.path)
        before = snapshot(self.path)
        def fail(connection: sqlite3.Connection) -> None:
            connection.execute("UPDATE assignments SET title='partial'")
            connection.execute("DELETE FROM reminders")
            raise RuntimeError('injected-v4-failure')
        with self.assertRaisesRegex(database.DatabaseMigrationError, 'verified unchanged'):
            database.migrate_database(self.path, migration_hook=fail)
        self.assertEqual(snapshot(self.path), before)
        backup = next(self.path.parent.glob('*.bak'))
        self.assertEqual(snapshot(backup), before)

    def test_silent_inherited_payload_change_is_detected_and_rolled_back(self) -> None:
        create_populated_v3(self.path)
        before = snapshot(self.path)
        def mutate(connection: sqlite3.Connection) -> None:
            connection.execute("UPDATE projects SET description='unintended rewrite'")
        with self.assertRaisesRegex(database.DatabaseMigrationError, 'verified unchanged'):
            database.migrate_database(self.path, migration_hook=mutate)
        self.assertEqual(snapshot(self.path), before)

    def test_silent_extension_schema_change_is_detected_and_rolled_back(self) -> None:
        create_populated_v3(self.path)
        before = snapshot(self.path)
        def mutate(connection: sqlite3.Connection) -> None:
            connection.execute("DROP INDEX extension_task_index")
        with self.assertRaisesRegex(database.DatabaseMigrationError, 'verified unchanged'):
            database.migrate_database(self.path, migration_hook=mutate)
        self.assertEqual(snapshot(self.path), before)

    def test_v3_wal_backup_includes_latest_committed_wal_rows(self) -> None:
        create_populated_v3(self.path)
        with closing(connect(self.path)) as writer:
            writer.execute("PRAGMA journal_mode=WAL")
            writer.execute("PRAGMA wal_autocheckpoint=0")
            writer.execute("INSERT INTO extension_notes VALUES(2,'committed in WAL')")
            writer.commit()
            self.assertTrue(Path(str(self.path) + '-wal').exists())
            result = database.migrate_database(self.path)
            with closing(connect(result.backup_path)) as backup:
                self.assertEqual(backup.execute("SELECT note FROM extension_notes WHERE id=2").fetchone()[0], 'committed in WAL')
            writer.execute("INSERT INTO extension_notes VALUES(3,'old connection remains usable')")
            writer.commit()

    def test_backup_failure_prevents_any_schema_mutation(self) -> None:
        create_populated_v3(self.path)
        before = snapshot(self.path)
        with patch.object(database, '_backup_database_while_locked', side_effect=OSError('disk full')):
            with self.assertRaises(database.DatabaseMigrationError):
                database.migrate_database(self.path)
        self.assertEqual(snapshot(self.path), before)

    def test_partial_v4_schema_fails_closed_and_preserves_v3(self) -> None:
        create_populated_v3(self.path)
        with closing(connect(self.path)) as connection:
            connection.execute("CREATE TABLE exams(custom_extension TEXT)")
            connection.commit()
        before = snapshot(self.path)
        with self.assertRaisesRegex(database.DatabaseMigrationError, 'verified unchanged'):
            database.migrate_database(self.path)
        self.assertEqual(snapshot(self.path), before)

    def test_fresh_failure_rolls_back_to_empty_database(self) -> None:
        def fail(_connection: sqlite3.Connection) -> None:
            raise RuntimeError('fresh-failure')
        with self.assertRaises(database.DatabaseMigrationError):
            database.migrate_database(self.path, migration_hook=fail)
        with closing(connect(self.path)) as connection:
            self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 0)
            self.assertEqual(connection.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall(), [])

    def test_v4_missing_inherited_index_is_rejected_unchanged(self) -> None:
        database.migrate_database(self.path)
        with closing(connect(self.path)) as connection:
            connection.execute("DROP INDEX ux_assignments_uuid")
            connection.commit()
        before = snapshot(self.path)
        with self.assertRaises(database.DatabaseMigrationError):
            database.migrate_database(self.path)
        self.assertEqual(snapshot(self.path), before)

    def test_v4_missing_lineage_is_rejected_unchanged(self) -> None:
        database.migrate_database(self.path)
        with closing(connect(self.path)) as connection:
            triggers = list(connection.execute("SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name='database_identity'"))
            for (name,) in triggers:
                connection.execute(f'DROP TRIGGER "{name}"')
            connection.execute("DELETE FROM database_identity")
            connection.commit()
        before = snapshot(self.path)
        with self.assertRaises(database.DatabaseMigrationError):
            database.migrate_database(self.path)
        self.assertEqual(snapshot(self.path), before)

    def test_unknown_version_preserves_file_bytes_and_makes_no_backup(self) -> None:
        database.migrate_database(self.path)
        with closing(connect(self.path)) as connection:
            connection.execute("PRAGMA user_version=99")
            connection.commit()
        before = self.path.read_bytes()
        with self.assertRaisesRegex(database.DatabaseMigrationError, 'newer than supported'):
            database.migrate_database(self.path)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(list(self.path.parent.glob('*.bak')), [])


if __name__ == '__main__':
    unittest.main()
