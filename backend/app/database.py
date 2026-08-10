from __future__ import annotations

import os
import sqlite3
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Generator
from uuid import uuid4

from sqlalchemy import create_engine
from sqlalchemy.engine import URL
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker


DATABASE_VERSION = 2
_DEFAULT_DATABASE_PATH = Path(__file__).resolve().parents[1] / "assignments.db"


def _configured_database_path() -> Path:
    configured = os.environ.get("ASSIGNMENT_DB_PATH")
    if not configured:
        return _DEFAULT_DATABASE_PATH
    return Path(configured).expanduser().resolve()


DATABASE_PATH = _configured_database_path()
SQLALCHEMY_DATABASE_URL = URL.create("sqlite", database=str(DATABASE_PATH))

engine = create_engine(
    SQLALCHEMY_DATABASE_URL,
    connect_args={"check_same_thread": False},
)

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


class Base(DeclarativeBase):
    pass


class DatabaseMigrationError(RuntimeError):
    """Raised when the local database cannot be safely upgraded."""


@dataclass(frozen=True)
class MigrationResult:
    from_version: int
    to_version: int
    migrated: bool
    backup_path: Path | None = None
    strategy: str = "none"


def get_db() -> Generator[Session, None, None]:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def ensure_assignment_schema() -> MigrationResult:
    """Create or safely upgrade the configured local database to schema v2.

    Existing databases are backed up with SQLite's online backup API before any
    schema statement runs. This is safe when the source database uses WAL mode.
    A failed migration is restored from that backup and the error is re-raised,
    so application startup cannot continue against a partial schema.
    """

    return migrate_database(DATABASE_PATH)


def migrate_database(
    database_path: str | Path,
    *,
    migration_hook: Callable[[sqlite3.Connection], None] | None = None,
) -> MigrationResult:
    """Upgrade one SQLite database without touching any other database.

    ``migration_hook`` is an internal test seam used to prove rollback and
    backup restoration. Production callers must leave it unset.
    """

    path = Path(database_path).expanduser().resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    uses_global_engine = path == DATABASE_PATH
    if uses_global_engine:
        engine.dispose()

    try:
        connection = _connect(path)
        try:
            raw_version = _user_version(connection)
            table_exists = _table_exists(connection, "assignments")
        finally:
            connection.close()

        if raw_version > DATABASE_VERSION:
            raise DatabaseMigrationError(
                f"Database schema version {raw_version} is newer than supported "
                f"version {DATABASE_VERSION}."
            )

        if not table_exists:
            _create_new_database(path)
            return MigrationResult(
                from_version=raw_version,
                to_version=DATABASE_VERSION,
                migrated=True,
                strategy="create",
            )

        inferred_version = 1 if raw_version == 0 else raw_version
        if raw_version == DATABASE_VERSION:
            connection = _connect(path)
            try:
                _validate_v2_schema(connection)
            finally:
                connection.close()
            return MigrationResult(
                from_version=DATABASE_VERSION,
                to_version=DATABASE_VERSION,
                migrated=False,
            )

        backup_path = _backup_database(path, inferred_version)
        try:
            strategy = _upgrade_existing_database(
                path,
                migration_hook=migration_hook,
            )
        except Exception as exc:
            try:
                _restore_database(backup_path, path)
            except Exception as restore_exc:
                raise DatabaseMigrationError(
                    "Database migration failed and automatic restoration also failed. "
                    f"The consistent backup is preserved at {backup_path}."
                ) from restore_exc
            raise DatabaseMigrationError(
                "Database migration failed; the original database was restored from "
                f"{backup_path}."
            ) from exc

        return MigrationResult(
            from_version=inferred_version,
            to_version=DATABASE_VERSION,
            migrated=True,
            backup_path=backup_path,
            strategy=strategy,
        )
    finally:
        if uses_global_engine:
            engine.dispose()


def _connect(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(path, timeout=10)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA busy_timeout = 10000")
    return connection


def _user_version(connection: sqlite3.Connection) -> int:
    return int(connection.execute("PRAGMA user_version").fetchone()[0])


def _table_exists(connection: sqlite3.Connection, table_name: str) -> bool:
    row = connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        (table_name,),
    ).fetchone()
    return row is not None


def _create_new_database(path: Path) -> None:
    connection = _connect(path)
    try:
        connection.execute("BEGIN IMMEDIATE")
        _create_assignments_table(connection)
        _create_assignment_indexes(connection)
        connection.execute(f"PRAGMA user_version = {DATABASE_VERSION}")
        _validate_v2_schema(connection)
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


def _backup_database(path: Path, from_version: int) -> Path:
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    backup_path = path.with_name(
        f"{path.name}.v{from_version}-to-v{DATABASE_VERSION}."
        f"{timestamp}.{uuid4().hex[:8]}.bak"
    )

    source = _connect(path)
    destination = _connect(backup_path)
    try:
        source.backup(destination)
        destination.commit()
        if destination.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise DatabaseMigrationError("SQLite reported an invalid migration backup.")
    except Exception:
        destination.close()
        source.close()
        backup_path.unlink(missing_ok=True)
        raise
    else:
        destination.close()
        source.close()
    return backup_path


def _restore_database(backup_path: Path, database_path: Path) -> None:
    source = _connect(backup_path)
    destination = _connect(database_path)
    try:
        source.backup(destination)
        destination.commit()
        if destination.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise DatabaseMigrationError("SQLite reported an invalid restored database.")
    finally:
        destination.close()
        source.close()


def _upgrade_existing_database(
    path: Path,
    *,
    migration_hook: Callable[[sqlite3.Connection], None] | None,
) -> str:
    connection = _connect(path)
    try:
        connection.execute("PRAGMA foreign_keys = OFF")
        connection.execute("BEGIN IMMEDIATE")
        strategy = _migrate_assignments_to_v2(connection)
        if migration_hook is not None:
            migration_hook(connection)
        _validate_v2_schema(connection)
        connection.execute(f"PRAGMA user_version = {DATABASE_VERSION}")
        if connection.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise DatabaseMigrationError("SQLite integrity check failed after migration.")
        connection.commit()
        return strategy
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


def _migrate_assignments_to_v2(connection: sqlite3.Connection) -> str:
    if _table_exists(connection, "assignments_v1_migration"):
        raise DatabaseMigrationError(
            "Cannot migrate while assignments_v1_migration already exists."
        )

    old_columns = _assignment_columns(connection, "assignments")
    required = {"id", "course_name", "title"}
    missing_required = required.difference(old_columns)
    if missing_required:
        raise DatabaseMigrationError(
            "Legacy assignments table is missing required columns: "
            + ", ".join(sorted(missing_required))
        )

    if "status" in old_columns:
        unsupported_statuses = connection.execute(
            """
            SELECT DISTINCT status
            FROM assignments
            WHERE status IS NULL
               OR lower(trim(status)) NOT IN (
                    'not_started', 'todo', 'in_progress', 'completed', 'done'
               )
            """
        ).fetchall()
        if unsupported_statuses:
            values = ", ".join(repr(row[0]) for row in unsupported_statuses)
            raise DatabaseMigrationError(
                f"Unsupported assignment status values prevent migration: {values}"
            )

    if "priority" in old_columns:
        unsupported_priorities = connection.execute(
            """
            SELECT DISTINCT priority
            FROM assignments
            WHERE priority IS NOT NULL
              AND trim(priority) != ''
              AND lower(trim(priority)) NOT IN ('low', 'medium', 'high')
            """
        ).fetchall()
        if unsupported_priorities:
            values = ", ".join(repr(row[0]) for row in unsupported_priorities)
            raise DatabaseMigrationError(
                f"Unsupported assignment priority values prevent migration: {values}"
            )

    before_count = int(
        connection.execute("SELECT COUNT(*) FROM assignments").fetchone()[0]
    )
    before_ids = [
        row[0]
        for row in connection.execute(
            "SELECT id FROM assignments ORDER BY id"
        ).fetchall()
    ]

    if _requires_assignments_rebuild(connection, old_columns):
        _rebuild_assignments_to_v2(connection, old_columns)
        strategy = "rebuild"
    else:
        _add_v2_columns(connection, old_columns)
        _create_assignment_indexes(connection)
        strategy = "additive"

    after_count = int(
        connection.execute("SELECT COUNT(*) FROM assignments").fetchone()[0]
    )
    after_ids = [
        row[0]
        for row in connection.execute(
            "SELECT id FROM assignments ORDER BY id"
        ).fetchall()
    ]
    if after_count != before_count or after_ids != before_ids:
        raise DatabaseMigrationError(
            "Assignment identity validation failed during migration: "
            f"before={before_count}, after={after_count}."
        )
    return strategy


def _requires_assignments_rebuild(
    connection: sqlite3.Connection,
    old_columns: dict[str, sqlite3.Row],
) -> bool:
    table_sql_row = connection.execute(
        "SELECT sql FROM sqlite_master "
        "WHERE type = 'table' AND name = 'assignments'"
    ).fetchone()
    table_sql = str(table_sql_row[0] or "").lower()

    due_date = old_columns.get("due_date")
    if due_date is not None and int(due_date["notnull"]) == 1:
        return True

    if "created_at" not in old_columns or "updated_at" not in old_columns:
        return True

    status = old_columns.get("status")
    if status is not None:
        has_legacy_constraint_values = (
            "check" in table_sql
            and "not_started" in table_sql
            and "completed" in table_sql
        )
        noncanonical_storage = connection.execute(
            """
            SELECT 1 FROM assignments
            WHERE status != lower(trim(status))
               OR status IN ('todo', 'done')
            LIMIT 1
            """
        ).fetchone()
        if not has_legacy_constraint_values or noncanonical_storage is not None:
            return True

    priority = old_columns.get("priority")
    if priority is not None:
        default_value = str(priority["dflt_value"] or "").strip("'\"").lower()
        has_priority_constraint_values = (
            "check" in table_sql
            and "'low'" in table_sql
            and "'medium'" in table_sql
            and "'high'" in table_sql
        )
        if (
            int(priority["notnull"]) != 1
            or default_value != "medium"
            or not has_priority_constraint_values
        ):
            return True
        noncanonical_priority = connection.execute(
            """
            SELECT 1 FROM assignments
            WHERE priority IS NULL
               OR priority != lower(trim(priority))
               OR priority NOT IN ('low', 'medium', 'high')
            LIMIT 1
            """
        ).fetchone()
        if noncanonical_priority is not None:
            return True

    return False


def _add_v2_columns(
    connection: sqlite3.Connection,
    old_columns: dict[str, sqlite3.Row],
) -> None:
    additive_columns = {
        "due_date": "DATETIME",
        "description": "TEXT",
        "link": "VARCHAR(1000)",
        "status": (
            "VARCHAR(20) NOT NULL DEFAULT 'not_started' "
            "CHECK (status IN ('not_started', 'in_progress', 'completed'))"
        ),
        "priority": (
            "VARCHAR(10) NOT NULL DEFAULT 'medium' "
            "CHECK (priority IN ('low', 'medium', 'high'))"
        ),
        "source_name": "VARCHAR(255)",
        "source_type": "VARCHAR(80)",
        "source_file": "VARCHAR(1000)",
        "source_url": "VARCHAR(1000)",
    }
    for column_name, definition in additive_columns.items():
        if column_name not in old_columns:
            connection.execute(
                f"ALTER TABLE assignments ADD COLUMN {column_name} {definition}"
            )


def _rebuild_assignments_to_v2(
    connection: sqlite3.Connection,
    old_columns: dict[str, sqlite3.Row],
) -> None:
    connection.execute("ALTER TABLE assignments RENAME TO assignments_v1_migration")
    _create_assignments_table(connection)

    target_columns = [
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
    ]
    select_expressions = [
        _migration_expression(column_name, old_columns)
        for column_name in target_columns
    ]
    connection.execute(
        f"""
        INSERT INTO assignments ({", ".join(target_columns)})
        SELECT {", ".join(select_expressions)}
        FROM assignments_v1_migration
        """
    )
    connection.execute("DROP TABLE assignments_v1_migration")
    _create_assignment_indexes(connection)


def _assignment_columns(
    connection: sqlite3.Connection,
    table_name: str,
) -> dict[str, sqlite3.Row]:
    rows = connection.execute(f"PRAGMA table_info({table_name})").fetchall()
    return {str(row["name"]): row for row in rows}


def _migration_expression(
    column_name: str,
    old_columns: dict[str, sqlite3.Row],
) -> str:
    if column_name == "status":
        if "status" not in old_columns:
            return "'not_started' AS status"
        return """
            CASE lower(trim(status))
                WHEN 'todo' THEN 'not_started'
                WHEN 'done' THEN 'completed'
                ELSE lower(trim(status))
            END AS status
        """.strip()

    if column_name == "priority":
        if "priority" not in old_columns:
            return "'medium' AS priority"
        return """
            CASE
                WHEN priority IS NULL OR trim(priority) = '' THEN 'medium'
                ELSE lower(trim(priority))
            END AS priority
        """.strip()

    if column_name in old_columns:
        return column_name

    defaults = {
        "created_at": "CURRENT_TIMESTAMP",
        "updated_at": "CURRENT_TIMESTAMP",
    }
    return f"{defaults.get(column_name, 'NULL')} AS {column_name}"


def _create_assignments_table(connection: sqlite3.Connection) -> None:
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
            priority VARCHAR(10) NOT NULL DEFAULT 'medium',
            source_name VARCHAR(255),
            source_type VARCHAR(80),
            source_file VARCHAR(1000),
            source_url VARCHAR(1000),
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
            PRIMARY KEY (id),
            CONSTRAINT assignment_status_check
                CHECK (status IN ('not_started', 'in_progress', 'completed')),
            CONSTRAINT assignment_priority_check
                CHECK (priority IN ('low', 'medium', 'high'))
        )
        """
    )


def _create_assignment_indexes(connection: sqlite3.Connection) -> None:
    indexes = {
        "ix_assignments_course_name": "course_name",
        "ix_assignments_due_date": "due_date",
        "ix_assignments_id": "id",
        "ix_assignments_priority": "priority",
        "ix_assignments_status": "status",
        "ix_assignments_title": "title",
    }
    for index_name, column_name in indexes.items():
        connection.execute(
            f"CREATE INDEX IF NOT EXISTS {index_name} "
            f"ON assignments ({column_name})"
        )


def _validate_v2_schema(connection: sqlite3.Connection) -> None:
    columns = _assignment_columns(connection, "assignments")
    expected = {
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
    }
    missing = expected.difference(columns)
    if missing:
        raise DatabaseMigrationError(
            "Database v2 schema is missing columns: " + ", ".join(sorted(missing))
        )
    if int(columns["due_date"]["notnull"]) != 0:
        raise DatabaseMigrationError("Database v2 requires a nullable due_date column.")
    if int(columns["status"]["notnull"]) != 1:
        raise DatabaseMigrationError("Database v2 requires a non-null status column.")
    if int(columns["priority"]["notnull"]) != 1:
        raise DatabaseMigrationError("Database v2 requires a non-null priority column.")

    priority_default = str(columns["priority"]["dflt_value"] or "").strip()
    if priority_default.strip("'\"").lower() != "medium":
        raise DatabaseMigrationError(
            "Database v2 requires priority to default to medium."
        )

    status_default = str(columns["status"]["dflt_value"] or "").strip()
    if status_default.strip("'\"").lower() != "not_started":
        raise DatabaseMigrationError(
            "Database v2 requires status to default to not_started."
        )

    table_sql_row = connection.execute(
        "SELECT sql FROM sqlite_master "
        "WHERE type = 'table' AND name = 'assignments'"
    ).fetchone()
    table_sql = str(table_sql_row[0] or "").lower()
    if (
        "check" not in table_sql
        or "not_started" not in table_sql
        or "completed" not in table_sql
    ):
        raise DatabaseMigrationError(
            "Database v2 must retain legacy status storage constraints."
        )
    if not all(value in table_sql for value in ("'low'", "'medium'", "'high'")):
        raise DatabaseMigrationError(
            "Database v2 must constrain priority to low, medium, and high."
        )

    invalid_status = connection.execute(
        """
        SELECT 1 FROM assignments
        WHERE status NOT IN ('not_started', 'in_progress', 'completed')
        LIMIT 1
        """
    ).fetchone()
    if invalid_status is not None:
        raise DatabaseMigrationError("Database v2 contains an invalid status value.")

    invalid_priority = connection.execute(
        """
        SELECT 1 FROM assignments
        WHERE priority NOT IN ('low', 'medium', 'high')
        LIMIT 1
        """
    ).fetchone()
    if invalid_priority is not None:
        raise DatabaseMigrationError("Database v2 contains an invalid priority value.")
