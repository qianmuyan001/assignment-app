from __future__ import annotations

import hashlib
import multiprocessing
import os
import shutil
import sqlite3
import tempfile
import time
import unittest
from contextlib import closing
from pathlib import Path
from uuid import UUID


_MODULE_ROOT_ENV = "ASSIGNMENT_BACKEND_TEST_ROOT"
_is_spawn_worker = multiprocessing.current_process().name != "MainProcess"
if _is_spawn_worker:
    _inherited_module_root = os.environ.get(_MODULE_ROOT_ENV)
    if _inherited_module_root is None:
        raise RuntimeError("Spawned database tests require their parent temp root")
    _MODULE_ROOT = Path(_inherited_module_root).resolve()
    _temp_root = Path(tempfile.gettempdir()).resolve()
    if (
        _MODULE_ROOT.parent != _temp_root
        or not _MODULE_ROOT.name.startswith("assignment-database-v3-tests-")
    ):
        raise RuntimeError("Spawned database tests rejected a non-temporary root")
    _MODULE_OWNS_ROOT = False
else:
    # Ignore caller-provided paths in the primary test process. Every run owns
    # a newly-created system temporary directory; spawn workers inherit only
    # that validated path.
    _MODULE_ROOT = Path(tempfile.mkdtemp(prefix="assignment-database-v3-tests-")).resolve()
    _MODULE_OWNS_ROOT = True
os.environ[_MODULE_ROOT_ENV] = str(_MODULE_ROOT)
os.environ["ASSIGNMENT_DB_PATH"] = str(_MODULE_ROOT / "global.db")
_REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
_REAL_DATABASE = _REPOSITORY_ROOT / "backend" / "assignments.db"


def _database_family_sha(path: Path) -> dict[str, tuple[int, str]]:
    return {
        candidate.name: (candidate.stat().st_size, hashlib.sha256(candidate.read_bytes()).hexdigest())
        for candidate in sorted(path.parent.glob(f"{path.name}*"))
        if candidate.is_file()
    }


_REAL_DATABASE_BEFORE = _database_family_sha(_REAL_DATABASE)

from backend.app.database import (  # noqa: E402 - environment must be isolated first
    DATABASE_VERSION,
    DATABASE_PATH,
    DatabaseMigrationError,
    engine,
    ensure_assignment_schema,
    migrate_database,
)
from shared.schema_v3 import (  # noqa: E402
    deterministic_v3_uuid,
    validate_v3_schema,
)
from shared.schema_v4 import migrate_v3_to_v4  # noqa: E402


def _logical_dump(path: Path) -> tuple[str, ...]:
    with closing(sqlite3.connect(path)) as connection:
        return tuple(connection.iterdump())


def _create_v2_database(path: Path) -> None:
    with closing(sqlite3.connect(path)) as connection:
        connection.executescript(
            """
            CREATE TABLE assignments (
                id INTEGER NOT NULL PRIMARY KEY,
                course_name VARCHAR(120) NOT NULL,
                title VARCHAR(255) NOT NULL,
                due_date DATETIME,
                description TEXT,
                link VARCHAR(1000),
                status VARCHAR(20) NOT NULL DEFAULT 'not_started'
                    CHECK (status IN ('not_started', 'in_progress', 'completed')),
                priority VARCHAR(10) NOT NULL DEFAULT 'medium'
                    CHECK (priority IN ('low', 'medium', 'high')),
                source_name VARCHAR(255),
                source_type VARCHAR(80),
                source_file VARCHAR(1000),
                source_url VARCHAR(1000),
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL
            );
            CREATE INDEX ix_assignments_course_name ON assignments(course_name);
            CREATE INDEX ix_assignments_due_date ON assignments(due_date);
            CREATE INDEX ix_assignments_id ON assignments(id);
            CREATE INDEX ix_assignments_priority ON assignments(priority);
            CREATE INDEX ix_assignments_status ON assignments(status);
            CREATE INDEX ix_assignments_title ON assignments(title);
            CREATE TABLE extension_data (
                id INTEGER PRIMARY KEY,
                note TEXT NOT NULL
            );
            INSERT INTO extension_data (id, note) VALUES (1, '保留 extension 🧪');
            PRAGMA user_version = 2;
            """
        )
        connection.executemany(
            """
            INSERT INTO assignments (
                id, course_name, title, due_date, description, link, status,
                priority, source_name, source_type, source_file, source_url,
                created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                (
                    1,
                    "Physics",
                    "Wave lab",
                    "2026-11-01 01:30:00",
                    "DST wall time",
                    "https://example.test/?a=1&b=2",
                    "not_started",
                    "high",
                    "LMS",
                    "html",
                    None,
                    "https://example.test/source",
                    "2026-08-01 09:00:00",
                    "2026-08-02 10:00:00",
                ),
                (
                    9,
                    "语文 / English",
                    "完成 ✅ <>&",
                    None,
                    "换行\nEmoji 🧪",
                    None,
                    "completed",
                    "medium",
                    None,
                    None,
                    "资料/作业.txt",
                    None,
                    "2026-08-03 11:00:00",
                    "2026-08-05 15:45:30",
                ),
            ],
        )
        connection.commit()


def _create_v1_database(path: Path) -> None:
    with closing(sqlite3.connect(path)) as connection:
        connection.executescript(
            """
            CREATE TABLE assignments (
                id INTEGER PRIMARY KEY,
                course_name TEXT NOT NULL,
                title TEXT NOT NULL,
                status TEXT,
                due_date TEXT NOT NULL
            );
            INSERT INTO assignments (
                id, course_name, title, status, due_date
            ) VALUES (
                41, '历史 / Legacy', '原始任务 🧪', 'todo', '2026-11-01 01:30:00'
            );
            PRAGMA user_version = 1;
            """
        )
        connection.commit()


def _concurrent_migration_worker(
    database_path: str,
    hold_event: multiprocessing.synchronize.Event | None,
    result_queue: multiprocessing.queues.Queue,
) -> None:
    def hold_after_schema(_connection: sqlite3.Connection) -> None:
        if hold_event is not None:
            hold_event.set()
            time.sleep(0.4)

    try:
        result = migrate_database(
            database_path,
            migration_hook=hold_after_schema if hold_event is not None else None,
        )
        result_queue.put(("ok", result.migrated, result.strategy))
    except Exception as exc:  # pragma: no cover - only returned to parent process
        result_queue.put(("error", type(exc).__name__, str(exc)))


class BackendDatabaseV3Tests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="assignment-database-v3-case-"
        )
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)
        self.assertNotEqual(DATABASE_PATH.resolve(), _REAL_DATABASE.resolve())

    def test_fresh_database_is_created_directly_as_v3(self) -> None:
        path = self.root / "fresh.db"
        result = migrate_database(path)
        self.assertEqual(result.from_version, 0)
        self.assertEqual(result.to_version, DATABASE_VERSION)
        self.assertEqual(result.strategy, "create-v3")
        self.assertIsNone(result.backup_path)

        with closing(sqlite3.connect(path)) as connection:
            connection.execute("PRAGMA foreign_keys = ON")
            validate_v3_schema(connection)
            identity = connection.execute(
                "SELECT instance_uuid FROM database_identity"
            ).fetchone()[0]
        self.assertEqual(UUID(identity).version, 4)

    def test_v4_database_fails_closed_instead_of_being_written_as_v3(self) -> None:
        """A Schema v4 database must be rejected, never rewritten with v3 rules.

        `shared/feature-specs/learning-scenes-v4.md` makes this normative for
        Windows and Web: Apple Phase 3A is the first v4 client, and a v3-only
        platform that silently opened a v4 database would drop course meetings,
        exams, and the reminder schedule kind on the next write.
        """
        path = self.root / "v4.db"
        migrate_database(path)
        with closing(sqlite3.connect(path)) as connection:
            connection.execute("PRAGMA foreign_keys = ON")
            connection.execute("BEGIN IMMEDIATE")
            migrate_v3_to_v4(connection)
            connection.commit()

        with self.assertRaises(DatabaseMigrationError) as caught:
            migrate_database(path)
        self.assertIn("newer than supported", str(caught.exception))

        # Fail closed also means no rewrite: the v4 payload is still intact.
        with closing(sqlite3.connect(path)) as connection:
            self.assertEqual(
                connection.execute("PRAGMA user_version").fetchone()[0], 4
            )
            tables = {
                row[0]
                for row in connection.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                )
            }
        self.assertTrue({"course_meetings", "exams"}.issubset(tables))
        self.assertEqual(DATABASE_VERSION, 3)

    def test_v2_migration_preserves_payload_and_creates_standalone_backup(self) -> None:
        path = self.root / "v2.db"
        _create_v2_database(path)
        with closing(sqlite3.connect(path)) as connection:
            before = connection.execute(
                "SELECT * FROM assignments ORDER BY id"
            ).fetchall()

        result = migrate_database(path)
        self.assertTrue(result.migrated)
        self.assertEqual(result.from_version, 2)
        self.assertEqual(result.strategy, "v2-v3-additive")
        self.assertIsNotNone(result.backup_path)
        backup_path = result.backup_path
        assert backup_path is not None
        self.assertTrue(backup_path.is_file())
        self.assertFalse(Path(str(backup_path) + "-wal").exists())
        self.assertFalse(Path(str(backup_path) + "-shm").exists())

        with closing(sqlite3.connect(backup_path)) as backup:
            self.assertEqual(backup.execute("PRAGMA journal_mode").fetchone()[0], "delete")
            self.assertEqual(backup.execute("PRAGMA user_version").fetchone()[0], 2)
            self.assertEqual(backup.execute("PRAGMA integrity_check").fetchone()[0], "ok")
        with closing(sqlite3.connect(path)) as connection:
            connection.execute("PRAGMA foreign_keys = ON")
            validate_v3_schema(connection)
            after = connection.execute(
                """
                SELECT id, course_name, title, due_date, description, link,
                       status, priority, source_name, source_type, source_file,
                       source_url, created_at, updated_at
                FROM assignments ORDER BY id
                """
            ).fetchall()
            identity = connection.execute(
                "SELECT instance_uuid FROM database_identity"
            ).fetchone()[0]
            derived = connection.execute(
                "SELECT id, uuid, completed_at, progress_percent FROM assignments "
                "ORDER BY id"
            ).fetchall()
            extension = connection.execute(
                "SELECT note FROM extension_data"
            ).fetchone()[0]
        self.assertEqual(after, before)
        self.assertEqual(extension, "保留 extension 🧪")
        self.assertEqual(derived[0][1], deterministic_v3_uuid(identity, "task", 1))
        self.assertEqual((derived[0][2], derived[0][3]), (None, 0))
        self.assertEqual(derived[1][1], deterministic_v3_uuid(identity, "task", 9))
        self.assertEqual((derived[1][2], derived[1][3]), (before[1][-1], 100))

    def test_v1_dispatches_through_v2_and_v3_in_one_protected_flow(self) -> None:
        path = self.root / "v1.db"
        _create_v1_database(path)
        result = migrate_database(path)
        self.assertEqual(result.from_version, 1)
        self.assertTrue(result.strategy.startswith("v1-v2-"))
        self.assertTrue(result.strategy.endswith("+v2-v3-additive"))
        with closing(sqlite3.connect(path)) as connection:
            connection.execute("PRAGMA foreign_keys = ON")
            validate_v3_schema(connection)
            row = connection.execute(
                "SELECT id, title, due_date, status FROM assignments"
            ).fetchone()
        self.assertEqual(row, (41, "原始任务 🧪", "2026-11-01 01:30:00", "not_started"))

    def test_failed_migration_restores_version_and_complete_payload(self) -> None:
        path = self.root / "failure.db"
        _create_v2_database(path)
        original_dump = _logical_dump(path)

        def fail_after_v3(connection: sqlite3.Connection) -> None:
            connection.execute(
                "UPDATE extension_data SET note = 'partial write' WHERE id = 1"
            )
            raise RuntimeError("injected migration failure")

        with self.assertRaises(DatabaseMigrationError) as raised:
            migrate_database(path, migration_hook=fail_after_v3)
        self.assertIn("verified unchanged after transaction rollback", str(raised.exception))
        self.assertEqual(_logical_dump(path), original_dump)
        with closing(sqlite3.connect(path)) as connection:
            self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 2)
            self.assertEqual(connection.execute("PRAGMA integrity_check").fetchone()[0], "ok")
        self.assertEqual(len(list(self.root.glob("failure.db.v2-to-v3.*.bak"))), 1)

    def test_failed_wal_migration_keeps_inode_and_old_connection_usable(self) -> None:
        path = self.root / "wal-failure.db"
        _create_v2_database(path)
        with closing(sqlite3.connect(path)) as old_connection:
            self.assertEqual(
                old_connection.execute("PRAGMA journal_mode = WAL").fetchone()[0],
                "wal",
            )
            old_connection.execute("PRAGMA wal_autocheckpoint = 0")
            old_connection.execute(
                "INSERT INTO extension_data (id, note) VALUES (2, 'before failure')"
            )
            old_connection.commit()
            inode_before = path.stat().st_ino
            self.assertTrue(Path(str(path) + "-wal").exists())

            def fail_after_v3(_connection: sqlite3.Connection) -> None:
                raise RuntimeError("rollback must be enough")

            with self.assertRaises(DatabaseMigrationError) as raised:
                migrate_database(path, migration_hook=fail_after_v3)
            self.assertIn(
                "verified unchanged after transaction rollback",
                str(raised.exception),
            )
            self.assertEqual(path.stat().st_ino, inode_before)
            old_connection.execute(
                "INSERT INTO extension_data (id, note) VALUES (3, 'after recovery')"
            )
            old_connection.commit()
            with closing(sqlite3.connect(path)) as new_connection:
                notes = new_connection.execute(
                    "SELECT id, note FROM extension_data ORDER BY id"
                ).fetchall()
                version = new_connection.execute("PRAGMA user_version").fetchone()[0]
            self.assertEqual(version, 2)
            self.assertEqual(notes[-1], (3, "after recovery"))

    def test_rollback_preserves_a_healthy_concurrent_write_without_overwrite(self) -> None:
        path = self.root / "concurrent-write.db"
        _create_v2_database(path)
        original_dump = _logical_dump(path)
        inode_before = path.stat().st_ino

        def fail_after_v3(connection: sqlite3.Connection) -> None:
            connection.execute(
                "UPDATE extension_data SET note = 'rolled back' WHERE id = 1"
            )
            raise RuntimeError("force rollback before external write")

        def write_after_rollback(database_path: Path) -> None:
            with closing(sqlite3.connect(database_path)) as writer:
                writer.execute(
                    "INSERT INTO extension_data (id, note) VALUES (2, 'newer valid write')"
                )
                writer.commit()

        with self.assertRaises(DatabaseMigrationError) as raised:
            migrate_database(
                path,
                migration_hook=fail_after_v3,
                after_rollback_hook=write_after_rollback,
            )
        self.assertIn("preserved without overwrite", str(raised.exception))
        self.assertEqual(path.stat().st_ino, inode_before)
        with closing(sqlite3.connect(path)) as connection:
            self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 2)
            self.assertEqual(
                connection.execute(
                    "SELECT note FROM extension_data WHERE id = 2"
                ).fetchone()[0],
                "newer valid write",
            )
        backups = list(self.root.glob("concurrent-write.db.v2-to-v3.*.bak"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(_logical_dump(backups[0]), original_dump)

    def test_unsafe_external_commit_blocks_startup_without_overwrite(self) -> None:
        path = self.root / "unsafe-commit.db"
        _create_v2_database(path)
        original_dump = _logical_dump(path)
        inode_before = path.stat().st_ino

        def commit_partial_schema(connection: sqlite3.Connection) -> None:
            connection.commit()
            raise RuntimeError("simulate failure after an unsafe external commit")

        with self.assertRaises(DatabaseMigrationError) as raised:
            migrate_database(path, migration_hook=commit_partial_schema)
        self.assertIn("preserved without overwrite", str(raised.exception))
        self.assertEqual(path.stat().st_ino, inode_before)
        self.assertNotEqual(_logical_dump(path), original_dump)
        backups = list(self.root.glob("unsafe-commit.db.v2-to-v3.*.bak"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(_logical_dump(backups[0]), original_dump)

    def test_cross_process_lock_rechecks_version_before_second_backup(self) -> None:
        path = self.root / "concurrent.db"
        _create_v2_database(path)
        context = multiprocessing.get_context("spawn")
        hold_event = context.Event()
        result_queue = context.Queue()
        first = context.Process(
            target=_concurrent_migration_worker,
            args=(str(path), hold_event, result_queue),
        )
        first.start()
        self.assertTrue(hold_event.wait(timeout=10))
        second = context.Process(
            target=_concurrent_migration_worker,
            args=(str(path), None, result_queue),
        )
        second.start()
        first.join(timeout=15)
        second.join(timeout=15)
        self.assertEqual((first.exitcode, second.exitcode), (0, 0))
        results = [result_queue.get(timeout=2), result_queue.get(timeout=2)]
        result_queue.close()
        result_queue.join_thread()
        first.close()
        second.close()
        self.assertEqual([item[0] for item in results], ["ok", "ok"])
        self.assertEqual(sorted(item[1] for item in results), [False, True])
        self.assertEqual(len(list(self.root.glob("concurrent.db.v2-to-v3.*.bak"))), 1)
        with closing(sqlite3.connect(path)) as connection:
            connection.execute("PRAGMA foreign_keys = ON")
            validate_v3_schema(connection)

    def test_sqlalchemy_connections_enable_foreign_keys_and_busy_timeout(self) -> None:
        result = ensure_assignment_schema()
        self.assertEqual(result.to_version, 3)
        with engine.connect() as connection:
            self.assertEqual(connection.exec_driver_sql("PRAGMA foreign_keys").scalar(), 1)
            self.assertEqual(connection.exec_driver_sql("PRAGMA busy_timeout").scalar(), 10000)


def tearDownModule() -> None:  # noqa: N802 - unittest lifecycle name
    engine.dispose()
    real_database_after = _database_family_sha(_REAL_DATABASE)
    if real_database_after != _REAL_DATABASE_BEFORE:
        raise AssertionError(
            "Backend database tests modified the repository database family: "
            f"before={_REAL_DATABASE_BEFORE!r}, after={real_database_after!r}"
        )
    if _MODULE_OWNS_ROOT:
        shutil.rmtree(_MODULE_ROOT, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
