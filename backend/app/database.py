from pathlib import Path
from typing import Generator

from sqlalchemy import create_engine
from sqlalchemy.engine import Connection
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker


DATABASE_PATH = Path(__file__).resolve().parents[1] / "assignments.db"
SQLALCHEMY_DATABASE_URL = f"sqlite:///{DATABASE_PATH}"

engine = create_engine(
    SQLALCHEMY_DATABASE_URL,
    connect_args={"check_same_thread": False},
)

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


class Base(DeclarativeBase):
    pass


def get_db() -> Generator[Session, None, None]:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def ensure_assignment_schema() -> None:
    """Keep older local SQLite databases compatible with the current model."""
    with engine.begin() as connection:
        table_exists = connection.exec_driver_sql(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='assignments'"
        ).scalar()
        if not table_exists:
            return

        columns = _assignment_columns(connection)
        due_date_column = columns.get("due_date", {})

        if due_date_column.get("notnull") == 1:
            _rebuild_assignments_table(connection, columns)
            return

        _add_missing_source_columns(connection, columns)


def _assignment_columns(connection: Connection) -> dict[str, dict[str, object]]:
    rows = connection.exec_driver_sql("PRAGMA table_info(assignments)").mappings().all()
    return {str(row["name"]): dict(row) for row in rows}


def _add_missing_source_columns(
    connection: Connection,
    columns: dict[str, dict[str, object]],
) -> None:
    source_columns = {
        "source_name": "VARCHAR(255)",
        "source_type": "VARCHAR(80)",
        "source_file": "VARCHAR(1000)",
        "source_url": "VARCHAR(1000)",
    }

    for column_name, column_type in source_columns.items():
        if column_name not in columns:
            connection.exec_driver_sql(
                f"ALTER TABLE assignments ADD COLUMN {column_name} {column_type}"
            )


def _rebuild_assignments_table(
    connection: Connection,
    old_columns: dict[str, dict[str, object]],
) -> None:
    connection.exec_driver_sql("ALTER TABLE assignments RENAME TO assignments_old")
    connection.exec_driver_sql(
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
            CONSTRAINT assignment_status_check
                CHECK (status IN ('not_started', 'in_progress', 'completed'))
        )
        """
    )

    target_columns = [
        "id",
        "course_name",
        "title",
        "due_date",
        "description",
        "link",
        "status",
        "source_name",
        "source_type",
        "source_file",
        "source_url",
        "created_at",
        "updated_at",
    ]
    select_columns = [
        column_name if column_name in old_columns else _default_select_value(column_name)
        for column_name in target_columns
    ]

    connection.exec_driver_sql(
        f"""
        INSERT INTO assignments ({", ".join(target_columns)})
        SELECT {", ".join(select_columns)}
        FROM assignments_old
        """
    )
    connection.exec_driver_sql("DROP TABLE assignments_old")
    _create_assignment_indexes(connection)


def _default_select_value(column_name: str) -> str:
    defaults = {
        "status": "'not_started'",
        "created_at": "CURRENT_TIMESTAMP",
        "updated_at": "CURRENT_TIMESTAMP",
    }
    return f"{defaults.get(column_name, 'NULL')} AS {column_name}"


def _create_assignment_indexes(connection: Connection) -> None:
    indexes = {
        "ix_assignments_course_name": "course_name",
        "ix_assignments_due_date": "due_date",
        "ix_assignments_id": "id",
        "ix_assignments_status": "status",
        "ix_assignments_title": "title",
    }

    for index_name, column_name in indexes.items():
        connection.exec_driver_sql(
            f"CREATE INDEX IF NOT EXISTS {index_name} ON assignments ({column_name})"
        )
