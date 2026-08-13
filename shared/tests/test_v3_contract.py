from __future__ import annotations

import json
import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path
from uuid import UUID

from shared.schema_v3 import (
    DATABASE_VERSION,
    SchemaV3Error,
    attachment_storage_relative_path,
    canonical_name,
    canonical_repeat_rule,
    create_v3_schema,
    deterministic_v3_uuid,
    is_iana_timezone_id,
    is_safe_attachment_relative_path,
    is_utc_audit_timestamp,
    migrate_v2_to_v3,
    new_v3_uuid,
    validate_v3_schema,
)


ROOT = Path(__file__).resolve().parents[2]
FIXTURE_PATH = ROOT / "shared" / "fixtures" / "task-organization-v3.json"
DATABASE_SCHEMA_PATH = ROOT / "shared" / "schemas" / "database-v3.json"
TASK_SCHEMA_PATH = ROOT / "shared" / "schemas" / "task-v3.schema.json"
TEST_DATABASE_INSTANCE_UUID = "8c0f31e2-19a2-4c37-9b5d-4fc09f667c8d"

V2_COLUMNS = (
    "id",
    "course_name",
    "title",
    "due_date",
    "description",
    "link",
    "status",
    "priority",
    "source_name",
    "source_type",
    "source_file",
    "source_url",
    "created_at",
    "updated_at",
)


def _load_fixture() -> dict[str, object]:
    return json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))


def _connect(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(path)
    connection.execute("PRAGMA foreign_keys = ON")
    return connection


def _create_fixture_v2_database(
    path: Path,
    *,
    enforce_v2_checks: bool = True,
) -> None:
    fixture = _load_fixture()
    status_nullability = "NOT NULL" if enforce_v2_checks else ""
    priority_nullability = "NOT NULL" if enforce_v2_checks else ""
    check_constraints = """
                CHECK (status IN ('not_started', 'in_progress', 'completed')),
                CHECK (priority IN ('low', 'medium', 'high'))
    """ if enforce_v2_checks else ""
    with closing(_connect(path)) as connection, connection:
        connection.execute(
            f"""
            CREATE TABLE assignments (
                id INTEGER NOT NULL PRIMARY KEY,
                course_name VARCHAR(120) NOT NULL,
                title VARCHAR(255) NOT NULL,
                due_date DATETIME,
                description TEXT,
                link VARCHAR(1000),
                status VARCHAR(20) {status_nullability} DEFAULT 'not_started',
                priority VARCHAR(10) {priority_nullability} DEFAULT 'medium',
                source_name VARCHAR(255),
                source_type VARCHAR(80),
                source_file VARCHAR(1000),
                source_url VARCHAR(1000),
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
                custom_extension TEXT
                {',' if check_constraints else ''}
                {check_constraints}
            )
            """
        )
        connection.execute(
            "CREATE INDEX ix_assignments_custom_extension "
            "ON assignments(custom_extension)"
        )
        connection.execute(
            """
            CREATE TABLE extension_audit (
                assignment_id INTEGER NOT NULL,
                old_title TEXT NOT NULL,
                new_title TEXT NOT NULL
            )
            """
        )
        connection.execute(
            """
            CREATE TRIGGER assignment_extension_title_audit
            AFTER UPDATE ON assignments
            BEGIN
                INSERT INTO extension_audit (assignment_id, old_title, new_title)
                VALUES (NEW.id, OLD.title, NEW.title);
            END
            """
        )
        columns = ", ".join(V2_COLUMNS) + ", custom_extension"
        placeholders = ", ".join("?" for _ in range(len(V2_COLUMNS) + 1))
        for task in fixture["v2_tasks"]:
            values = tuple(task[column] for column in V2_COLUMNS) + (
                f"extension-{task['id']}",
            )
            connection.execute(
                f"INSERT INTO assignments ({columns}) VALUES ({placeholders})",
                values,
            )
        connection.execute("PRAGMA user_version = 2")


def _logical_v2_snapshot(connection: sqlite3.Connection) -> tuple[object, ...]:
    columns = ", ".join(V2_COLUMNS) + ", custom_extension"
    table_sql = connection.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='assignments'"
    ).fetchone()[0]
    rows = connection.execute(
        f"SELECT {columns} FROM assignments ORDER BY id"
    ).fetchall()
    objects = connection.execute(
        "SELECT type, name, tbl_name, sql FROM sqlite_master "
        "WHERE name IN ('ix_assignments_custom_extension', "
        "'assignment_extension_title_audit') ORDER BY type, name"
    ).fetchall()
    return (
        connection.execute("PRAGMA user_version").fetchone()[0],
        table_sql,
        tuple(rows),
        tuple(objects),
    )


class UUIDAndMetadataContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fixture = _load_fixture()

    def test_uuid_v5_vectors_are_exact_and_cross_platform(self) -> None:
        self.assertEqual(
            TEST_DATABASE_INSTANCE_UUID,
            self.fixture["uuid_contract"]["database_instance_uuid"],
        )
        for vector in self.fixture["uuid_contract"]["vectors"]:
            self.assertEqual(
                deterministic_v3_uuid(
                    TEST_DATABASE_INSTANCE_UUID,
                    vector["entity"],
                    vector["legacy_key"],
                ),
                vector["expected_uuid"],
            )

    def test_database_lineage_prevents_independent_database_collisions(self) -> None:
        other_instance = "26d55ac0-4dfc-4e37-a87b-3dca9d186d0f"
        for entity, legacy_key in (("task", 1), ("course", "Physics")):
            self.assertNotEqual(
                deterministic_v3_uuid(
                    TEST_DATABASE_INSTANCE_UUID,
                    entity,
                    legacy_key,
                ),
                deterministic_v3_uuid(other_instance, entity, legacy_key),
            )

    def test_course_identity_uses_exact_name_not_search_normalization(self) -> None:
        self.assertEqual(canonical_name(" Physics "), "physics")
        self.assertEqual(canonical_name("Ｐｈｙｓｉｃｓ"), "physics")
        self.assertNotEqual(
            deterministic_v3_uuid(
                TEST_DATABASE_INSTANCE_UUID, "course", "Physics"
            ),
            deterministic_v3_uuid(
                TEST_DATABASE_INSTANCE_UUID, "course", "physics"
            ),
        )

    def test_name_normalization_vectors_are_cross_platform_contract(self) -> None:
        for vector in self.fixture["name_normalization_contract"]["vectors"]:
            self.assertEqual(canonical_name(vector["input"]), vector["expected"])
        self.assertNotEqual(
            deterministic_v3_uuid(
                TEST_DATABASE_INSTANCE_UUID, "course", "Physics"
            ),
            deterministic_v3_uuid(
                TEST_DATABASE_INSTANCE_UUID, "course", " Physics "
            ),
        )

    def test_new_record_uuid_is_v4_and_canonical(self) -> None:
        value = new_v3_uuid()
        parsed = UUID(value)
        self.assertEqual(parsed.version, 4)
        self.assertEqual(str(parsed), value)

    def test_time_and_attachment_metadata_validators(self) -> None:
        self.assertTrue(is_utc_audit_timestamp("2026-08-11T12:34:56.123Z"))
        self.assertFalse(is_utc_audit_timestamp("2026-08-11 12:34:56"))
        self.assertFalse(is_utc_audit_timestamp("2026-99-99T99:99:99Z"))
        self.assertTrue(is_iana_timezone_id("America/Los_Angeles"))
        self.assertTrue(is_iana_timezone_id("UTC"))
        self.assertFalse(is_iana_timezone_id("local"))
        self.assertTrue(is_safe_attachment_relative_path("ab/cd/report 📚.pdf"))
        for unsafe in (
            "/absolute/file.pdf",
            "../escape.pdf",
            "task/../../escape.pdf",
            "C:/drive.pdf",
            "folder\\windows.pdf",
            "folder/./file.pdf",
        ):
            self.assertFalse(is_safe_attachment_relative_path(unsafe), unsafe)

    def test_repeat_rule_contract_is_strict_and_canonical(self) -> None:
        self.assertEqual(
            canonical_repeat_rule("freq=weekly;byday=mo,we;interval=2"),
            "FREQ=WEEKLY;BYDAY=MO,WE;INTERVAL=2",
        )
        self.assertIsNone(canonical_repeat_rule("  "))
        for invalid in (
            "DTSTART=20260812T090000Z;FREQ=DAILY",
            "FREQ=NOPE",
            "FREQ=DAILY;COUNT=2;UNTIL=20260814",
            "FREQ=MONTHLY;BYMONTHDAY=0",
            "FREQ=DAILY;COUNT=٢",
            "FREQ=YEARLY;BYMONTH=１",
        ):
            with self.assertRaises(ValueError, msg=invalid):
                canonical_repeat_rule(invalid)


class V3MigrationContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.database_path = Path(self.temp_dir.name) / "fixture-v2.db"
        _create_fixture_v2_database(self.database_path)
        self.fixture = _load_fixture()

    def test_v2_to_v3_preserves_payload_and_unknown_extensions(self) -> None:
        with closing(_connect(self.database_path)) as connection:
            before_rows = connection.execute(
                f"SELECT {', '.join(V2_COLUMNS)} FROM assignments ORDER BY id"
            ).fetchall()
            before_trigger_sql = connection.execute(
                "SELECT sql FROM sqlite_master WHERE type='trigger' "
                "AND name='assignment_extension_title_audit'"
            ).fetchone()[0]
            before_rootpage = connection.execute(
                "SELECT rootpage FROM sqlite_master "
                "WHERE type='table' AND name='assignments'"
            ).fetchone()[0]
            connection.execute("BEGIN IMMEDIATE")
            migrate_v2_to_v3(
                connection,
                database_instance_uuid=TEST_DATABASE_INSTANCE_UUID,
            )
            self.assertTrue(connection.in_transaction)
            connection.commit()

            after_rows = connection.execute(
                f"SELECT {', '.join(V2_COLUMNS)} FROM assignments ORDER BY id"
            ).fetchall()
            self.assertEqual(after_rows, before_rows)
            self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 3)
            after_rootpage = connection.execute(
                "SELECT rootpage FROM sqlite_master "
                "WHERE type='table' AND name='assignments'"
            ).fetchone()[0]
            self.assertEqual(after_rootpage, before_rootpage)

            extension_values = connection.execute(
                "SELECT custom_extension FROM assignments ORDER BY id"
            ).fetchall()
            self.assertEqual(
                extension_values,
                [("extension-1",), ("extension-9",), ("extension-41",), ("extension-73",)],
            )
            extension_objects = {
                row[0]
                for row in connection.execute(
                    "SELECT name FROM sqlite_master "
                    "WHERE name IN ('ix_assignments_custom_extension', "
                    "'assignment_extension_title_audit')"
                ).fetchall()
            }
            self.assertEqual(
                extension_objects,
                {"ix_assignments_custom_extension", "assignment_extension_title_audit"},
            )
            after_trigger_sql = connection.execute(
                "SELECT sql FROM sqlite_master WHERE type='trigger' "
                "AND name='assignment_extension_title_audit'"
            ).fetchone()[0]
            self.assertEqual(after_trigger_sql, before_trigger_sql)
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM extension_audit").fetchone()[0], 0)
            connection.execute(
                "UPDATE assignments SET title = 'Wave lab revised' WHERE id = 1"
            )
            self.assertEqual(
                connection.execute(
                    "SELECT assignment_id, old_title, new_title "
                    "FROM extension_audit"
                ).fetchall(),
                [(1, "Wave lab", "Wave lab revised")],
            )

    def test_migrated_identifiers_course_links_and_derived_values(self) -> None:
        with closing(_connect(self.database_path)) as connection:
            connection.execute("BEGIN IMMEDIATE")
            migrate_v2_to_v3(
                connection,
                database_instance_uuid=TEST_DATABASE_INSTANCE_UUID,
            )
            connection.commit()

            expected_uuids = self.fixture["expected"]["task_uuids"]
            for task_id, task_uuid, completed_at, progress, all_day, timezone_id in connection.execute(
                """
                SELECT id, uuid, completed_at, progress_percent, all_day, timezone_id
                FROM assignments ORDER BY id
                """
            ):
                self.assertEqual(task_uuid, expected_uuids[str(task_id)])
                if task_id == 9:
                    self.assertEqual(completed_at, "2026-08-05 15:45:30")
                    self.assertEqual(progress, 100)
                else:
                    self.assertIsNone(completed_at)
                    self.assertEqual(progress, 0)
                self.assertEqual(all_day, 0)
                self.assertIsNone(timezone_id)

            course_links = connection.execute(
                """
                SELECT c.name, c.uuid, group_concat(a.id, ',')
                FROM courses c JOIN assignments a ON a.course_id = c.id
                GROUP BY c.id ORDER BY c.name
                """
            ).fetchall()
            expected = {
                course["name"]: (course["uuid"], ",".join(str(value) for value in course["task_ids"]))
                for course in self.fixture["expected"]["courses"]
            }
            self.assertEqual(
                {name: (uuid, ids) for name, uuid, ids in course_links},
                expected,
            )
            self.assertEqual(
                connection.execute("SELECT due_date FROM assignments WHERE id=1").fetchone()[0],
                "2026-11-01 01:30:00",
            )
            self.assertIsNone(
                connection.execute("SELECT due_date FROM assignments WHERE id=41").fetchone()[0]
            )

    def test_course_migration_merges_only_exact_stored_names(self) -> None:
        with closing(_connect(self.database_path)) as connection:
            source = self.fixture["v2_tasks"][0]
            values = tuple(
                74 if column == "id" else "physics" if column == "course_name" else source[column]
                for column in V2_COLUMNS
            )
            connection.execute(
                f"INSERT INTO assignments ({', '.join(V2_COLUMNS)}) "
                f"VALUES ({', '.join('?' for _ in V2_COLUMNS)})",
                values,
            )
            connection.commit()
            connection.execute("BEGIN IMMEDIATE")
            migrate_v2_to_v3(
                connection,
                database_instance_uuid=TEST_DATABASE_INSTANCE_UUID,
            )
            connection.commit()

            rows = connection.execute(
                """
                SELECT a.id, c.name, c.uuid
                FROM assignments a JOIN courses c ON c.id = a.course_id
                WHERE a.id IN (1, 9, 74) ORDER BY a.id
                """
            ).fetchall()
            self.assertEqual(
                rows,
                [
                    (
                        1,
                        "Physics",
                        deterministic_v3_uuid(
                            TEST_DATABASE_INSTANCE_UUID, "course", "Physics"
                        ),
                    ),
                    (
                        9,
                        "Physics",
                        deterministic_v3_uuid(
                            TEST_DATABASE_INSTANCE_UUID, "course", "Physics"
                        ),
                    ),
                    (
                        74,
                        "physics",
                        deterministic_v3_uuid(
                            TEST_DATABASE_INSTANCE_UUID, "course", "physics"
                        ),
                    ),
                ],
            )

    def test_required_tables_indexes_foreign_keys_and_no_attachment_blob(self) -> None:
        with closing(_connect(self.database_path)) as connection:
            connection.execute("BEGIN IMMEDIATE")
            migrate_v2_to_v3(
                connection,
                database_instance_uuid=TEST_DATABASE_INSTANCE_UUID,
            )
            connection.commit()
            validate_v3_schema(connection)

            tables = {
                row[0]
                for row in connection.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                ).fetchall()
            }
            self.assertTrue(
                {
                    "assignments",
                    "courses",
                    "projects",
                    "tags",
                    "task_tags",
                    "subtasks",
                    "attachments",
                    "reminders",
                }.issubset(tables)
            )
            attachment_types = {
                str(row[2]).upper()
                for row in connection.execute("PRAGMA table_info(attachments)")
            }
            self.assertFalse(any("BLOB" in value for value in attachment_types))
            with self.assertRaises(sqlite3.IntegrityError):
                connection.execute(
                    """
                    INSERT INTO subtasks (
                        uuid, assignment_id, title, status, sort_order
                    ) VALUES (?, 999999, 'orphan', 'not_started', 0)
                    """,
                    (new_v3_uuid(),),
                )

    def test_validator_rejects_wrong_reserved_index_column(self) -> None:
        with closing(_connect(self.database_path)) as connection:
            connection.execute("BEGIN IMMEDIATE")
            migrate_v2_to_v3(
                connection,
                database_instance_uuid=TEST_DATABASE_INSTANCE_UUID,
            )
            connection.commit()
            connection.execute("DROP INDEX ix_assignments_status")
            connection.execute(
                "CREATE INDEX ix_assignments_status ON assignments(title)"
            )
            with self.assertRaisesRegex(SchemaV3Error, "has columns"):
                validate_v3_schema(connection)

    def test_validator_rejects_broadened_partial_index_predicate(self) -> None:
        with closing(_connect(self.database_path)) as connection:
            connection.execute("BEGIN IMMEDIATE")
            migrate_v2_to_v3(
                connection,
                database_instance_uuid=TEST_DATABASE_INSTANCE_UUID,
            )
            connection.commit()
            connection.execute("DROP INDEX ux_task_tags_active_pair")
            connection.execute(
                "CREATE UNIQUE INDEX ux_task_tags_active_pair "
                "ON task_tags(assignment_id, tag_id) "
                "WHERE deleted_at IS NULL OR 1=1"
            )
            with self.assertRaisesRegex(SchemaV3Error, "filter exactly"):
                validate_v3_schema(connection)

    def test_reserved_trigger_name_on_extension_table_blocks_migration(self) -> None:
        with closing(_connect(self.database_path)) as connection:
            connection.execute(
                """
                CREATE TRIGGER assignments_v3_contract_insert
                BEFORE INSERT ON extension_audit
                BEGIN
                    SELECT 1;
                END
                """
            )
            connection.commit()
            connection.execute("BEGIN IMMEDIATE")
            with self.assertRaisesRegex(SchemaV3Error, "reserved v3 trigger"):
                migrate_v2_to_v3(
                    connection,
                    database_instance_uuid=TEST_DATABASE_INSTANCE_UUID,
                )
            connection.rollback()
            self.assertEqual(
                connection.execute("PRAGMA user_version").fetchone()[0],
                2,
            )
            self.assertIsNone(
                connection.execute(
                    "SELECT 1 FROM sqlite_master WHERE name='database_identity'"
                ).fetchone()
            )

    def test_validator_rejects_inert_assignment_contract_trigger(self) -> None:
        with closing(_connect(self.database_path)) as connection:
            connection.execute("BEGIN IMMEDIATE")
            migrate_v2_to_v3(
                connection,
                database_instance_uuid=TEST_DATABASE_INSTANCE_UUID,
            )
            connection.commit()
            connection.execute("DROP TRIGGER assignments_v3_contract_insert")
            connection.execute(
                """
                CREATE TRIGGER assignments_v3_contract_insert
                AFTER INSERT ON assignments
                BEGIN
                    SELECT 1;
                END
                """
            )
            with self.assertRaisesRegex(SchemaV3Error, "expected contract"):
                validate_v3_schema(connection)

    def test_trigger_validation_preserves_string_literal_case(self) -> None:
        with closing(_connect(self.database_path)) as connection:
            connection.execute("BEGIN IMMEDIATE")
            migrate_v2_to_v3(
                connection,
                database_instance_uuid=TEST_DATABASE_INSTANCE_UUID,
            )
            connection.commit()
            original_sql = connection.execute(
                "SELECT sql FROM sqlite_master WHERE type='trigger' "
                "AND name='assignments_v3_contract_update'"
            ).fetchone()[0]
            connection.execute("DROP TRIGGER assignments_v3_contract_update")
            connection.execute(str(original_sql).replace("'completed'", "'COMPLETED'"))
            with self.assertRaisesRegex(SchemaV3Error, "expected contract"):
                validate_v3_schema(connection)

    def test_database_identity_and_entity_uuids_are_immutable(self) -> None:
        with closing(_connect(self.database_path)) as connection:
            connection.execute("BEGIN IMMEDIATE")
            migrate_v2_to_v3(
                connection,
                database_instance_uuid=TEST_DATABASE_INSTANCE_UUID,
            )
            connection.commit()
            with self.assertRaises(sqlite3.IntegrityError):
                connection.execute(
                    "UPDATE database_identity SET instance_uuid = ? WHERE singleton = 1",
                    (new_v3_uuid(),),
                )
            with self.assertRaises(sqlite3.IntegrityError):
                connection.execute("DELETE FROM database_identity WHERE singleton = 1")
            with self.assertRaises(sqlite3.IntegrityError):
                connection.execute(
                    "UPDATE assignments SET uuid = ? WHERE id = 1",
                    (new_v3_uuid(),),
                )
            validate_v3_schema(connection)

    def test_migrated_course_can_be_renamed_without_changing_identity(self) -> None:
        with closing(_connect(self.database_path)) as connection:
            connection.execute("BEGIN IMMEDIATE")
            migrate_v2_to_v3(
                connection,
                database_instance_uuid=TEST_DATABASE_INSTANCE_UUID,
            )
            connection.commit()
            course_id, original_uuid = connection.execute(
                "SELECT id, uuid FROM courses WHERE name = 'Physics'"
            ).fetchone()
            connection.execute(
                "UPDATE courses SET name='Applied Physics', "
                "normalized_name='applied physics' WHERE id=?",
                (course_id,),
            )
            connection.execute(
                "UPDATE assignments SET course_name='Applied Physics' "
                "WHERE course_id=?",
                (course_id,),
            )
            validate_v3_schema(connection)
            self.assertEqual(
                connection.execute(
                    "SELECT uuid FROM courses WHERE id=?",
                    (course_id,),
                ).fetchone()[0],
                original_uuid,
            )

    def test_validator_rejects_invalid_new_entity_audit_timestamp(self) -> None:
        with closing(_connect(self.database_path)) as connection:
            connection.execute("BEGIN IMMEDIATE")
            migrate_v2_to_v3(
                connection,
                database_instance_uuid=TEST_DATABASE_INSTANCE_UUID,
            )
            connection.commit()
            connection.execute(
                """
                INSERT INTO projects (
                    uuid, name, created_at, updated_at
                ) VALUES (?, 'Invalid audit', '2026-99-99T99:99:99Z', 'bad')
                """,
                (new_v3_uuid(),),
            )
            with self.assertRaisesRegex(SchemaV3Error, "created_at"):
                validate_v3_schema(connection)

    def test_non_migrated_entities_reject_uuid_v5(self) -> None:
        with closing(_connect(self.database_path)) as connection:
            connection.execute("BEGIN IMMEDIATE")
            migrate_v2_to_v3(
                connection,
                database_instance_uuid=TEST_DATABASE_INSTANCE_UUID,
            )
            connection.commit()
            v5_value = deterministic_v3_uuid(
                TEST_DATABASE_INSTANCE_UUID,
                "task",
                999,
            )
            with self.assertRaises(sqlite3.IntegrityError):
                connection.execute(
                    "INSERT INTO projects (uuid, name) VALUES (?, 'Not migrated')",
                    (v5_value,),
                )

    def test_v3_contract_protects_unconstrained_legacy_status_and_priority(self) -> None:
        malformed_path = Path(self.temp_dir.name) / "unconstrained-v2.db"
        _create_fixture_v2_database(
            malformed_path,
            enforce_v2_checks=False,
        )
        with closing(_connect(malformed_path)) as connection:
            connection.execute("BEGIN IMMEDIATE")
            migrate_v2_to_v3(
                connection,
                database_instance_uuid=TEST_DATABASE_INSTANCE_UUID,
            )
            connection.commit()
            for column, invalid_value in (
                ("status", "bogus"),
                ("status", None),
                ("priority", "urgent"),
                ("priority", None),
            ):
                with self.subTest(column=column):
                    with self.assertRaises(sqlite3.IntegrityError):
                        connection.execute(
                            f"UPDATE assignments SET {column} = ? WHERE id = 1",
                            (invalid_value,),
                        )
            validate_v3_schema(connection)

    def test_database_checks_reject_malformed_uuid_shapes(self) -> None:
        with closing(_connect(self.database_path)) as connection:
            connection.execute("BEGIN IMMEDIATE")
            migrate_v2_to_v3(
                connection,
                database_instance_uuid=TEST_DATABASE_INSTANCE_UUID,
            )
            connection.commit()
            malformed = (
                "00000000-0000-4000-8000-00000000000-",
                "00000000-0000-1000-8000-000000000000",
                "00000000-0000-4000-7000-000000000000",
            )
            for index, value in enumerate(malformed):
                with self.subTest(value=value):
                    with self.assertRaises(sqlite3.IntegrityError):
                        connection.execute(
                            """
                            INSERT INTO courses (
                                uuid, name, normalized_name
                            ) VALUES (?, ?, ?)
                            """,
                            (value, f"Invalid {index}", f"invalid {index}"),
                        )

    def test_attachment_metadata_accepts_safe_path_and_rejects_escape(self) -> None:
        with closing(_connect(self.database_path)) as connection:
            connection.execute("BEGIN IMMEDIATE")
            migrate_v2_to_v3(
                connection,
                database_instance_uuid=TEST_DATABASE_INSTANCE_UUID,
            )
            connection.commit()
            attachment_uuid = new_v3_uuid()
            connection.execute(
                """
                INSERT INTO attachments (
                    uuid, assignment_id, file_name, relative_path,
                    mime_type, byte_size, sha256
                ) VALUES (?, 1, ?, ?, 'application/pdf', 1024, ?)
                """,
                (
                    attachment_uuid,
                    "report 📚.pdf",
                    attachment_storage_relative_path(attachment_uuid),
                    "a" * 64,
                ),
            )
            connection.execute(
                "UPDATE attachments SET deleted_at='2026-08-11T13:00:00Z' "
                "WHERE uuid=?",
                (attachment_uuid,),
            )
            replacement_uuid = new_v3_uuid()
            with self.assertRaises(sqlite3.IntegrityError):
                connection.execute(
                    """
                    INSERT INTO attachments (
                        uuid, assignment_id, file_name, relative_path,
                        byte_size, sha256
                    ) VALUES (?, 1, 'replacement.pdf', ?, 1, ?)
                    """,
                    (
                        replacement_uuid,
                        attachment_storage_relative_path(attachment_uuid),
                        "d" * 64,
                    ),
                )
            invalid_paths = (
                "../escape.pdf",
                "attachments//escape",
                "attachments/a/.",
                "attachments/a/..",
                "attachments/a\x00b",
                "Attachments/" + new_v3_uuid(),
            )
            for invalid_path in invalid_paths:
                with self.subTest(invalid_path=invalid_path):
                    with self.assertRaises(sqlite3.IntegrityError):
                        connection.execute(
                            """
                            INSERT INTO attachments (
                                uuid, assignment_id, file_name, relative_path,
                                byte_size, sha256
                            ) VALUES (?, 1, 'escape.pdf', ?, 1, ?)
                            """,
                            (new_v3_uuid(), invalid_path, "b" * 64),
                        )
            for invalid_file_name in (".", "..", "bad\x00name.pdf"):
                with self.subTest(invalid_file_name=invalid_file_name):
                    invalid_uuid = new_v3_uuid()
                    with self.assertRaises(sqlite3.IntegrityError):
                        connection.execute(
                            """
                            INSERT INTO attachments (
                                uuid, assignment_id, file_name, relative_path,
                                byte_size, sha256
                            ) VALUES (?, 1, ?, ?, 1, ?)
                            """,
                            (
                                invalid_uuid,
                                invalid_file_name,
                                attachment_storage_relative_path(invalid_uuid),
                                "c" * 64,
                            ),
                        )
            validate_v3_schema(connection)

    def test_transaction_failure_rolls_back_schema_and_payload(self) -> None:
        with closing(_connect(self.database_path)) as connection:
            before = _logical_v2_snapshot(connection)

            def fail_after_changes(_: sqlite3.Connection) -> None:
                raise RuntimeError("injected migration failure")

            connection.execute("BEGIN IMMEDIATE")
            with self.assertRaisesRegex(RuntimeError, "injected migration failure"):
                migrate_v2_to_v3(
                    connection,
                    database_instance_uuid=TEST_DATABASE_INSTANCE_UUID,
                    migration_hook=fail_after_changes,
                )
            self.assertTrue(connection.in_transaction)
            connection.rollback()
            self.assertEqual(_logical_v2_snapshot(connection), before)
            self.assertNotIn("courses", {
                row[0]
                for row in connection.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                )
            })

    def test_migration_verifier_rejects_wrong_course_relationship(self) -> None:
        with closing(_connect(self.database_path)) as connection:
            def corrupt_course_link(database: sqlite3.Connection) -> None:
                wrong_course_id = database.execute(
                    "SELECT id FROM courses WHERE name = '高等数学'"
                ).fetchone()[0]
                database.execute(
                    "UPDATE assignments SET course_id=? WHERE id=1",
                    (wrong_course_id,),
                )

            connection.execute("BEGIN IMMEDIATE")
            with self.assertRaisesRegex(SchemaV3Error, "invalid migrated v3 fields"):
                migrate_v2_to_v3(
                    connection,
                    database_instance_uuid=TEST_DATABASE_INSTANCE_UUID,
                    migration_hook=corrupt_course_link,
                )
            connection.rollback()
            self.assertEqual(
                connection.execute("PRAGMA user_version").fetchone()[0],
                2,
            )

    def test_migration_verifier_rejects_synthesized_organization_rows(self) -> None:
        with closing(_connect(self.database_path)) as connection:
            def synthesize_project(database: sqlite3.Connection) -> None:
                database.execute(
                    "INSERT INTO projects (uuid, name) VALUES (?, 'Injected')",
                    (new_v3_uuid(),),
                )

            connection.execute("BEGIN IMMEDIATE")
            with self.assertRaisesRegex(SchemaV3Error, "must not synthesize rows"):
                migrate_v2_to_v3(
                    connection,
                    database_instance_uuid=TEST_DATABASE_INSTANCE_UUID,
                    migration_hook=synthesize_project,
                )
            connection.rollback()

    def test_primitive_refuses_to_own_or_commit_transaction(self) -> None:
        with closing(_connect(self.database_path)) as connection:
            with self.assertRaisesRegex(SchemaV3Error, "caller-owned"):
                migrate_v2_to_v3(
                    connection,
                    database_instance_uuid=TEST_DATABASE_INSTANCE_UUID,
                )

    def test_primitive_requires_foreign_keys_before_transaction(self) -> None:
        with closing(sqlite3.connect(self.database_path)) as connection:
            connection.execute("BEGIN IMMEDIATE")
            with self.assertRaisesRegex(SchemaV3Error, "foreign_keys=ON"):
                migrate_v2_to_v3(
                    connection,
                    database_instance_uuid=TEST_DATABASE_INSTANCE_UUID,
                )
            connection.rollback()


class FreshV3ContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.database_path = Path(self.temp_dir.name) / "fresh-v3.db"

    @staticmethod
    def _create_schema(connection: sqlite3.Connection) -> None:
        connection.execute("BEGIN IMMEDIATE")
        create_v3_schema(
            connection,
            database_instance_uuid=TEST_DATABASE_INSTANCE_UUID,
        )
        connection.commit()

    def test_fresh_schema_has_same_additive_assignment_shape_and_triggers(self) -> None:
        with closing(_connect(self.database_path)) as connection:
            connection.execute("BEGIN IMMEDIATE")
            create_v3_schema(
                connection,
                database_instance_uuid=TEST_DATABASE_INSTANCE_UUID,
            )
            self.assertTrue(connection.in_transaction)
            connection.commit()
            validate_v3_schema(connection)

            columns = {
                row[1]: row
                for row in connection.execute("PRAGMA table_info(assignments)")
            }
            self.assertEqual(columns["uuid"][3], 0)
            self.assertEqual(columns["progress_percent"][3], 1)
            self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], DATABASE_VERSION)
            with self.assertRaises(sqlite3.IntegrityError):
                connection.execute(
                    """
                    INSERT INTO assignments (
                        course_name, title, status, priority
                    ) VALUES ('Math', 'Missing UUID', 'not_started', 'medium')
                    """
                )

    def test_fresh_task_contract_enforces_progress_and_uuid(self) -> None:
        with closing(_connect(self.database_path)) as connection:
            connection.execute("BEGIN IMMEDIATE")
            create_v3_schema(
                connection,
                database_instance_uuid=TEST_DATABASE_INSTANCE_UUID,
            )
            connection.commit()
            task_uuid = new_v3_uuid()
            connection.execute(
                """
                INSERT INTO assignments (
                    uuid, course_name, title, status, priority,
                    progress_percent, all_day, created_at, updated_at
                ) VALUES (
                    ?, 'Math', 'New task', 'not_started', 'high', 25, 0,
                    '2026-08-11T12:00:00Z', '2026-08-11T12:00:00Z'
                )
                """,
                (task_uuid,),
            )
            with self.assertRaises(sqlite3.IntegrityError):
                connection.execute(
                    "UPDATE assignments SET progress_percent=100 WHERE uuid=?",
                    (task_uuid,),
                )
            connection.execute(
                """
                UPDATE assignments
                SET status='completed', progress_percent=100,
                    completed_at='2026-08-11T12:00:00Z'
                WHERE uuid=?
                """,
                (task_uuid,),
            )
            validate_v3_schema(connection)

    def test_validator_rejects_parent_state_that_disagrees_with_subtasks(self) -> None:
        with closing(_connect(self.database_path)) as connection:
            self._create_schema(connection)
            task_uuid = new_v3_uuid()
            connection.execute(
                """
                INSERT INTO assignments (
                    uuid, course_name, title, status, priority,
                    progress_percent, all_day, created_at, updated_at
                ) VALUES (?, 'Math', 'Parent', 'not_started', 'medium',
                          0, 0, ?, ?)
                """,
                (task_uuid, "2026-08-12T12:00:00Z", "2026-08-12T12:00:00Z"),
            )
            task_id = int(connection.execute("SELECT last_insert_rowid()").fetchone()[0])
            connection.execute(
                """
                INSERT INTO subtasks (
                    uuid, assignment_id, title, status, sort_order,
                    completed_at, created_at, updated_at
                ) VALUES (?, ?, 'Finished child', 'completed', 0, ?, ?, ?)
                """,
                (
                    new_v3_uuid(),
                    task_id,
                    "2026-08-12T12:10:00Z",
                    "2026-08-12T12:00:00Z",
                    "2026-08-12T12:10:00Z",
                ),
            )
            with self.assertRaisesRegex(SchemaV3Error, "active subtask state"):
                validate_v3_schema(connection)

    def test_validator_rejects_noncanonical_or_invalid_repeat_rule(self) -> None:
        with closing(_connect(self.database_path)) as connection:
            self._create_schema(connection)
            task_uuid = new_v3_uuid()
            connection.execute(
                """
                INSERT INTO assignments (
                    uuid, course_name, title, status, priority,
                    progress_percent, all_day, created_at, updated_at
                ) VALUES (?, 'Math', 'Reminder parent', 'not_started', 'medium',
                          0, 0, ?, ?)
                """,
                (task_uuid, "2026-08-12T12:00:00Z", "2026-08-12T12:00:00Z"),
            )
            task_id = int(connection.execute("SELECT last_insert_rowid()").fetchone()[0])
            connection.execute(
                """
                INSERT INTO reminders (
                    uuid, assignment_id, trigger_at_utc, lead_minutes,
                    repeat_rule, is_enabled, created_at, updated_at
                ) VALUES (?, ?, ?, 0, ?, 1, ?, ?)
                """,
                (
                    new_v3_uuid(),
                    task_id,
                    "2026-08-13T12:00:00Z",
                    "DTSTART=bad\nFREQ=NOPE",
                    "2026-08-12T12:00:00Z",
                    "2026-08-12T12:00:00Z",
                ),
            )
            with self.assertRaisesRegex(SchemaV3Error, "invalid repeat_rule"):
                validate_v3_schema(connection)

    def test_validator_rejects_untyped_attachment_payload_column(self) -> None:
        with closing(_connect(self.database_path)) as connection:
            self._create_schema(connection)
            connection.execute("ALTER TABLE attachments ADD COLUMN payload")
            with self.assertRaisesRegex(SchemaV3Error, "metadata only"):
                validate_v3_schema(connection)

    def test_validator_rejects_generated_blob_attachment_payload_column(self) -> None:
        with closing(_connect(self.database_path)) as connection:
            self._create_schema(connection)
            connection.execute(
                "ALTER TABLE attachments ADD COLUMN payload BLOB "
                "GENERATED ALWAYS AS (x'00') VIRTUAL"
            )
            with self.assertRaisesRegex(SchemaV3Error, "metadata only"):
                validate_v3_schema(connection)

    def test_validator_rejects_forged_organization_rows_and_relationships(self) -> None:
        corruptions = (
            (
                "project status",
                "INSERT INTO projects (uuid, name, status, created_at, updated_at) "
                "VALUES (?, 'Bad', 'bogus', ?, ?)",
                (new_v3_uuid(), "2026-08-12T12:00:00Z", "2026-08-12T12:00:00Z"),
                "integrity check failed|organization contract",
            ),
            (
                "course archive flag",
                "INSERT INTO courses (uuid, name, normalized_name, is_archived, "
                "created_at, updated_at) VALUES (?, 'Math', 'math', 2, ?, ?)",
                (new_v3_uuid(), "2026-08-12T12:00:00Z", "2026-08-12T12:00:00Z"),
                "integrity check failed|organization contract",
            ),
        )
        for name, sql, parameters, message in corruptions:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "forged.db"
                with closing(_connect(path)) as connection:
                    self._create_schema(connection)
                    connection.execute("PRAGMA ignore_check_constraints = ON")
                    connection.execute(sql, parameters)
                    connection.execute("PRAGMA ignore_check_constraints = OFF")
                    with self.assertRaisesRegex(SchemaV3Error, message):
                        validate_v3_schema(connection)

    def test_validator_rejects_stale_course_and_project_relationships(self) -> None:
        with closing(_connect(self.database_path)) as connection:
            self._create_schema(connection)
            timestamp = "2026-08-12T12:00:00Z"
            connection.execute(
                "INSERT INTO courses (uuid, name, normalized_name, created_at, updated_at) "
                "VALUES (?, 'Math', 'math', ?, ?)",
                (new_v3_uuid(), timestamp, timestamp),
            )
            course_id = int(connection.execute("SELECT last_insert_rowid()").fetchone()[0])
            connection.execute(
                """
                INSERT INTO assignments (
                    uuid, course_id, course_name, title, status, priority,
                    progress_percent, all_day, created_at, updated_at
                ) VALUES (?, ?, 'Old Math', 'Task', 'not_started', 'medium',
                          0, 0, ?, ?)
                """,
                (new_v3_uuid(), course_id, timestamp, timestamp),
            )
            with self.assertRaisesRegex(SchemaV3Error, "stale course snapshot"):
                validate_v3_schema(connection)

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "project-course.db"
            with closing(_connect(path)) as connection:
                self._create_schema(connection)
                timestamp = "2026-08-12T12:00:00Z"
                for name in ("Math", "Physics"):
                    connection.execute(
                        "INSERT INTO courses (uuid, name, normalized_name, "
                        "created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                        (new_v3_uuid(), name, name.lower(), timestamp, timestamp),
                    )
                math_id, physics_id = (
                    int(row[0])
                    for row in connection.execute(
                        "SELECT id FROM courses ORDER BY id"
                    ).fetchall()
                )
                connection.execute(
                    "INSERT INTO projects (uuid, course_id, name, status, "
                    "created_at, updated_at) VALUES (?, ?, 'Lab', 'active', ?, ?)",
                    (new_v3_uuid(), physics_id, timestamp, timestamp),
                )
                project_id = int(
                    connection.execute("SELECT last_insert_rowid()").fetchone()[0]
                )
                connection.execute(
                    """
                    INSERT INTO assignments (
                        uuid, course_id, project_id, course_name, title, status,
                        priority, progress_percent, all_day, created_at, updated_at
                    ) VALUES (?, ?, ?, 'Math', 'Task', 'not_started', 'medium',
                              0, 0, ?, ?)
                    """,
                    (new_v3_uuid(), math_id, project_id, timestamp, timestamp),
                )
                with self.assertRaisesRegex(SchemaV3Error, "disagree on course"):
                    validate_v3_schema(connection)


class V3ArtifactContractTests(unittest.TestCase):
    def test_json_contracts_and_fixture_are_well_formed(self) -> None:
        database_schema = json.loads(DATABASE_SCHEMA_PATH.read_text(encoding="utf-8"))
        task_schema = json.loads(TASK_SCHEMA_PATH.read_text(encoding="utf-8"))
        fixture = _load_fixture()
        self.assertEqual(database_schema["database_version"], 3)
        self.assertEqual(database_schema["sqlite_user_version"], 3)
        self.assertEqual(task_schema["x-sqlite-storage"]["databaseVersion"], 3)
        self.assertEqual(fixture["target_schema_version"], 3)
        self.assertFalse(
            database_schema["tables"]["attachments"]["file_payload_in_database"]
        )


if __name__ == "__main__":
    unittest.main()
