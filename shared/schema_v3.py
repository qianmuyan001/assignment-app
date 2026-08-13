"""Executable, platform-neutral SQLite schema v3 migration primitives.

The functions in this module deliberately do not create backups, begin or end
transactions, or open database files. A platform repository must first create
an SQLite online-backup, then begin an immediate transaction on its own
connection before calling :func:`create_v3_schema` or
:func:`migrate_v2_to_v3`. This keeps backup and recovery policy at the platform
boundary while sharing the schema-changing and validation rules.
"""

from __future__ import annotations

import re
import sqlite3
import unicodedata
from collections.abc import Callable, Mapping
from datetime import datetime, timezone
from pathlib import PurePosixPath
from typing import Any
from uuid import UUID, uuid4, uuid5


DATABASE_VERSION = 3

_UTC_TIMESTAMP = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
    r"(?:\.[0-9]{1,6})?Z$"
)
_IANA_TIME_ZONE = re.compile(
    r"^(?:UTC|[A-Za-z_+\-]+(?:/[A-Za-z0-9_+\-.]+)+)$"
)
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_RRULE_UNTIL = re.compile(r"^(?:[0-9]{8}|[0-9]{8}T[0-9]{6}Z)$")
_RRULE_UNSIGNED_INTEGER = re.compile(r"^[0-9]+$")
_RRULE_SIGNED_INTEGER = re.compile(r"^-?[0-9]+$")
_RRULE_KEYS = {
    "FREQ",
    "INTERVAL",
    "COUNT",
    "UNTIL",
    "BYDAY",
    "BYMONTHDAY",
    "BYMONTH",
}
_WEEKDAYS = {"MO", "TU", "WE", "TH", "FR", "SA", "SU"}

_V2_ASSIGNMENT_COLUMNS = (
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

_REQUIRED_COLUMNS: dict[str, set[str]] = {
    "database_identity": {"singleton", "instance_uuid", "created_at"},
    "assignments": set(_V2_ASSIGNMENT_COLUMNS)
    | {
        "uuid",
        "course_id",
        "project_id",
        "completed_at",
        "progress_percent",
        "all_day",
        "timezone_id",
        "deleted_at",
    },
    "courses": {
        "id",
        "uuid",
        "name",
        "normalized_name",
        "color_hex",
        "teacher",
        "semester",
        "is_archived",
        "created_at",
        "updated_at",
        "deleted_at",
    },
    "projects": {
        "id",
        "uuid",
        "course_id",
        "name",
        "description",
        "status",
        "created_at",
        "updated_at",
        "deleted_at",
    },
    "tags": {
        "id",
        "uuid",
        "name",
        "normalized_name",
        "color_hex",
        "created_at",
        "updated_at",
        "deleted_at",
    },
    "task_tags": {
        "id",
        "uuid",
        "assignment_id",
        "tag_id",
        "created_at",
        "updated_at",
        "deleted_at",
    },
    "subtasks": {
        "id",
        "uuid",
        "assignment_id",
        "title",
        "status",
        "sort_order",
        "completed_at",
        "created_at",
        "updated_at",
        "deleted_at",
    },
    "attachments": {
        "id",
        "uuid",
        "assignment_id",
        "file_name",
        "relative_path",
        "mime_type",
        "byte_size",
        "sha256",
        "created_at",
        "updated_at",
        "deleted_at",
    },
    "reminders": {
        "id",
        "uuid",
        "assignment_id",
        "trigger_at_utc",
        "lead_minutes",
        "repeat_rule",
        "is_enabled",
        "last_scheduled_at",
        "created_at",
        "updated_at",
        "deleted_at",
    },
}

_EXPECTED_INDEXES: dict[str, tuple[str, tuple[str, ...]]] = {
    "ux_assignments_uuid": ("assignments", ("uuid",)),
    "ix_assignments_course_id": ("assignments", ("course_id",)),
    "ix_assignments_project_id": ("assignments", ("project_id",)),
    "ix_assignments_due_date": ("assignments", ("due_date",)),
    "ix_assignments_status": ("assignments", ("status",)),
    "ix_assignments_priority": ("assignments", ("priority",)),
    "ix_assignments_deleted_at": ("assignments", ("deleted_at",)),
    "ux_courses_uuid": ("courses", ("uuid",)),
    "ix_courses_normalized_name": ("courses", ("normalized_name",)),
    "ix_courses_archived_name": ("courses", ("is_archived", "name")),
    "ux_projects_uuid": ("projects", ("uuid",)),
    "ix_projects_course_status": ("projects", ("course_id", "status")),
    "ix_projects_deleted_at": ("projects", ("deleted_at",)),
    "ux_tags_uuid": ("tags", ("uuid",)),
    "ux_tags_normalized_name": ("tags", ("normalized_name",)),
    "ix_tags_deleted_at": ("tags", ("deleted_at",)),
    "ux_task_tags_uuid": ("task_tags", ("uuid",)),
    "ux_task_tags_active_pair": ("task_tags", ("assignment_id", "tag_id")),
    "ix_task_tags_assignment": ("task_tags", ("assignment_id",)),
    "ix_task_tags_tag": ("task_tags", ("tag_id",)),
    "ux_subtasks_uuid": ("subtasks", ("uuid",)),
    "ix_subtasks_assignment_order": (
        "subtasks",
        ("assignment_id", "sort_order", "id"),
    ),
    "ix_subtasks_status": ("subtasks", ("status",)),
    "ux_attachments_uuid": ("attachments", ("uuid",)),
    "ux_attachments_relative_path": ("attachments", ("relative_path",)),
    "ix_attachments_assignment": ("attachments", ("assignment_id",)),
    "ix_attachments_sha256": ("attachments", ("sha256",)),
    "ux_reminders_uuid": ("reminders", ("uuid",)),
    "ix_reminders_assignment": ("reminders", ("assignment_id",)),
    "ix_reminders_enabled_trigger": (
        "reminders",
        ("is_enabled", "trigger_at_utc"),
    ),
}
_UNIQUE_INDEXES = {
    name for name in _EXPECTED_INDEXES if name.startswith("ux_")
}
_PARTIAL_INDEXES = {
    "ux_task_tags_active_pair",
}
_IMMUTABLE_UUID_TABLES = (
    "assignments",
    "courses",
    "projects",
    "tags",
    "task_tags",
    "subtasks",
    "attachments",
    "reminders",
)
_EXPECTED_TRIGGERS = {
    "assignments_v3_contract_insert",
    "assignments_v3_contract_update",
    "database_identity_immutable_update",
    "database_identity_immutable_delete",
} | {f"{table}_uuid_immutable" for table in _IMMUTABLE_UUID_TABLES}
_UUID_TABLES = set(_REQUIRED_COLUMNS).difference({"database_identity"})
_UUID_V5_ALLOWED_TABLES = {"assignments", "courses"}
_EXPECTED_FOREIGN_KEYS = {
    "assignments": {
        ("course_id", "courses", "id", "SET NULL"),
        ("project_id", "projects", "id", "SET NULL"),
    },
    "projects": {("course_id", "courses", "id", "SET NULL")},
    "task_tags": {
        ("assignment_id", "assignments", "id", "CASCADE"),
        ("tag_id", "tags", "id", "CASCADE"),
    },
    "subtasks": {("assignment_id", "assignments", "id", "CASCADE")},
    "attachments": {("assignment_id", "assignments", "id", "CASCADE")},
    "reminders": {("assignment_id", "assignments", "id", "CASCADE")},
}


class SchemaV3Error(RuntimeError):
    """Raised when a v3 contract operation is unsafe or invalid."""


def canonical_name(value: str) -> str:
    """Return the cross-platform identity key for named legacy entities.

    The algorithm is Unicode NFKC, Unicode whitespace collapse, trim, then
    locale-independent case-folding. Display strings are never rewritten.
    """

    normalized = unicodedata.normalize("NFKC", value)
    return " ".join(normalized.split()).casefold()


def deterministic_v3_uuid(
    database_instance_uuid: str | UUID,
    entity: str,
    legacy_key: str | int,
) -> str:
    """Return a migration UUID scoped to one persistent database lineage."""

    namespace = _canonical_v4_uuid(
        database_instance_uuid,
        field_name="database instance UUID",
    )

    cleaned_entity = entity.strip().lower()
    if cleaned_entity == "task":
        try:
            cleaned_key = str(int(legacy_key))
        except (TypeError, ValueError) as exc:
            raise ValueError("task legacy keys must be integer IDs") from exc
        if int(cleaned_key) < 1:
            raise ValueError("task legacy IDs must be positive")
    elif cleaned_entity == "course":
        # Course rows are merged only when the stored v2 course_name strings
        # are byte-for-byte equal. Normalization is a search aid, not identity.
        cleaned_key = str(legacy_key)
        if not cleaned_key:
            raise ValueError("course legacy names must not be empty")
    else:
        raise ValueError(f"unsupported deterministic UUID entity: {entity!r}")
    return str(uuid5(namespace, f"{cleaned_entity}:{cleaned_key}"))


def new_v3_uuid() -> str:
    """Return a canonical lowercase UUID v4 for a newly created record."""

    return str(uuid4())


def _canonical_v4_uuid(
    value: str | UUID,
    *,
    field_name: str,
) -> UUID:
    try:
        parsed = value if isinstance(value, UUID) else UUID(str(value))
    except (ValueError, AttributeError) as exc:
        raise ValueError(f"{field_name} must be a canonical UUID v4") from exc
    if parsed.version != 4 or str(parsed) != str(value):
        raise ValueError(f"{field_name} must be a canonical UUID v4")
    return parsed


def _resolve_database_instance_uuid(value: str | UUID | None) -> str:
    generated = new_v3_uuid() if value is None else value
    return str(
        _canonical_v4_uuid(
            generated,
            field_name="database instance UUID",
        )
    )


def is_utc_audit_timestamp(value: object) -> bool:
    """Return whether a new audit value uses canonical ISO-8601 UTC syntax."""

    if not isinstance(value, str) or _UTC_TIMESTAMP.fullmatch(value) is None:
        return False
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        return False
    return parsed.tzinfo == timezone.utc


def is_iana_timezone_id(value: object) -> bool:
    """Perform the portable syntax check used before a platform zone lookup."""

    return isinstance(value, str) and _IANA_TIME_ZONE.fullmatch(value) is not None


def is_safe_attachment_relative_path(value: object) -> bool:
    """Validate the canonical POSIX relative path stored for an attachment."""

    if not isinstance(value, str) or not value or "\x00" in value:
        return False
    if "\\" in value or ":" in value or value.startswith("/") or value.endswith("/"):
        return False
    raw_parts = value.split("/")
    if any(part in {"", ".", ".."} for part in raw_parts):
        return False
    path = PurePosixPath(value)
    return all(part not in {"", ".", ".."} for part in path.parts)


def canonical_repeat_rule(value: object) -> str | None:
    """Validate and canonicalize the supported single-line RFC 5545 subset."""

    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError("repeat_rule must be text or null")
    cleaned = value.strip()
    if not cleaned:
        return None
    if "\n" in cleaned or "\r" in cleaned or "DTSTART" in cleaned.upper():
        raise ValueError("repeat_rule must be a single RRULE without DTSTART")
    if any(character.isspace() for character in cleaned):
        raise ValueError("repeat_rule must not contain whitespace")

    parsed: dict[str, str] = {}
    ordered: list[tuple[str, str]] = []
    for component in cleaned.split(";"):
        if component.count("=") != 1:
            raise ValueError("repeat_rule components must use KEY=VALUE syntax")
        raw_key, raw_value = component.split("=", maxsplit=1)
        key = raw_key.upper()
        rule_value = raw_value.upper()
        if key not in _RRULE_KEYS:
            raise ValueError(f"repeat_rule key {key!r} is not supported")
        if key in parsed or not rule_value:
            raise ValueError("repeat_rule keys must be unique and non-empty")
        parsed[key] = rule_value
        ordered.append((key, rule_value))

    if parsed.get("FREQ") not in {"DAILY", "WEEKLY", "MONTHLY", "YEARLY"}:
        raise ValueError("repeat_rule requires a supported FREQ")
    if "COUNT" in parsed and "UNTIL" in parsed:
        raise ValueError("repeat_rule cannot combine COUNT and UNTIL")
    for key, maximum in (("INTERVAL", 999), ("COUNT", 9999)):
        if key in parsed and (
            _RRULE_UNSIGNED_INTEGER.fullmatch(parsed[key]) is None
            or not 1 <= int(parsed[key]) <= maximum
        ):
            raise ValueError(f"repeat_rule {key} is outside the allowed range")
    if "UNTIL" in parsed:
        until = parsed["UNTIL"]
        if _RRULE_UNTIL.fullmatch(until) is None:
            raise ValueError(
                "repeat_rule UNTIL must be YYYYMMDD or UTC YYYYMMDDTHHMMSSZ"
            )
        until_format = "%Y%m%d" if len(until) == 8 else "%Y%m%dT%H%M%SZ"
        try:
            datetime.strptime(until, until_format)
        except ValueError as exc:
            raise ValueError("repeat_rule UNTIL is not a real calendar value") from exc
    if "BYDAY" in parsed:
        days = parsed["BYDAY"].split(",")
        if len(days) != len(set(days)) or any(day not in _WEEKDAYS for day in days):
            raise ValueError("repeat_rule BYDAY contains an unsupported weekday")
    for key, minimum, maximum in (("BYMONTHDAY", -31, 31), ("BYMONTH", 1, 12)):
        if key not in parsed:
            continue
        raw_values = parsed[key].split(",")
        integer_pattern = (
            _RRULE_SIGNED_INTEGER if key == "BYMONTHDAY" else _RRULE_UNSIGNED_INTEGER
        )
        if any(integer_pattern.fullmatch(item) is None for item in raw_values):
            raise ValueError(f"repeat_rule {key} must contain ASCII integers")
        try:
            numbers = [int(item) for item in raw_values]
        except ValueError as exc:
            raise ValueError(f"repeat_rule {key} must contain integers") from exc
        if (
            len(numbers) != len(set(numbers))
            or any(number == 0 or not minimum <= number <= maximum for number in numbers)
        ):
            raise ValueError(f"repeat_rule {key} contains an invalid value")

    return ";".join(f"{key}={rule_value}" for key, rule_value in ordered)


def attachment_storage_relative_path(attachment_uuid: str) -> str:
    """Return the immutable, case-stable payload key for an attachment row."""

    try:
        parsed = UUID(attachment_uuid)
    except ValueError as exc:
        raise ValueError("attachment UUID must use canonical lowercase syntax") from exc
    if str(parsed) != attachment_uuid or parsed.version not in {4, 5}:
        raise ValueError("attachment UUID must use canonical lowercase syntax")
    return f"attachments/{attachment_uuid}"


def create_v3_schema(
    connection: sqlite3.Connection,
    *,
    database_instance_uuid: str | UUID | None = None,
) -> None:
    """Create an empty v3 schema inside the caller's active transaction."""

    _require_active_transaction(connection)
    _require_foreign_keys_enabled(connection)
    existing = set(_existing_tables(connection)).intersection(_REQUIRED_COLUMNS)
    if existing:
        raise SchemaV3Error(
            "v3 create requires an empty application schema; found: "
            + ", ".join(sorted(existing))
        )
    _ensure_reserved_trigger_names_available(connection)
    instance_uuid = _resolve_database_instance_uuid(database_instance_uuid)
    _create_database_identity(connection, instance_uuid)
    _create_primary_tables(connection)
    _create_v2_assignment_table(connection)
    _add_v3_assignment_columns(connection)
    _create_child_tables(connection)
    _create_indexes(connection)
    _create_contract_triggers(connection)
    connection.execute(f"PRAGMA user_version = {DATABASE_VERSION}")
    validate_v3_schema(connection)


def migrate_v2_to_v3(
    connection: sqlite3.Connection,
    *,
    database_instance_uuid: str | UUID | None = None,
    migration_hook: Callable[[sqlite3.Connection], None] | None = None,
) -> None:
    """Upgrade a v2 schema in-place without owning backup or transaction state.

    ``migration_hook`` is a test seam for platform recovery tests. Production
    callers leave it unset. Any exception must be handled by rolling back and
    restoring the caller-created online backup before application startup.
    """

    _require_active_transaction(connection)
    _require_foreign_keys_enabled(connection)
    version = int(connection.execute("PRAGMA user_version").fetchone()[0])
    if version != 2:
        raise SchemaV3Error(f"v2 to v3 migration requires user_version 2, got {version}")

    columns = _column_names(connection, "assignments")
    missing = set(_V2_ASSIGNMENT_COLUMNS).difference(columns)
    if missing:
        raise SchemaV3Error(
            "v2 assignments table is missing columns: "
            + ", ".join(sorted(missing))
        )
    reserved = {
        "uuid",
        "course_id",
        "project_id",
        "completed_at",
        "progress_percent",
        "all_day",
        "timezone_id",
        "deleted_at",
    }.intersection(columns)
    if reserved:
        raise SchemaV3Error(
            "user_version 2 contains reserved partial-v3 assignment columns: "
            + ", ".join(sorted(reserved))
        )

    conflicting = (
        set(_existing_tables(connection))
        .intersection(_REQUIRED_COLUMNS)
        .difference({"assignments"})
    )
    if conflicting:
        raise SchemaV3Error(
            "partial v3 tables prevent a deterministic migration: "
            + ", ".join(sorted(conflicting))
        )

    select_columns = ", ".join(_V2_ASSIGNMENT_COLUMNS)
    legacy_rows = _rows_as_dicts(
        connection.execute(f"SELECT {select_columns} FROM assignments ORDER BY id")
    )
    _validate_legacy_rows(legacy_rows)
    legacy_snapshot = _legacy_assignment_snapshot(connection)
    _ensure_reserved_trigger_names_available(connection)
    preserved_triggers = _assignment_triggers(connection)
    instance_uuid = _resolve_database_instance_uuid(database_instance_uuid)

    _create_database_identity(connection, instance_uuid)
    _create_primary_tables(connection)
    course_ids = _migrate_courses(connection, legacy_rows, instance_uuid)
    _add_v3_assignment_columns(connection)
    _drop_triggers(connection, preserved_triggers)
    _backfill_legacy_assignments(
        connection,
        legacy_rows,
        course_ids,
        instance_uuid,
    )
    _restore_triggers(connection, preserved_triggers)
    _create_child_tables(connection)
    _create_indexes(connection)
    _create_contract_triggers(connection)

    if migration_hook is not None:
        migration_hook(connection)

    connection.execute(f"PRAGMA user_version = {DATABASE_VERSION}")
    _verify_legacy_payload(
        connection,
        legacy_rows,
        instance_uuid,
        legacy_snapshot,
    )
    validate_v3_schema(connection)


def validate_v3_schema(connection: sqlite3.Connection) -> None:
    """Validate structure, referential integrity, UUIDs, and safe metadata."""

    _require_foreign_keys_enabled(connection)
    version = int(connection.execute("PRAGMA user_version").fetchone()[0])
    if version != DATABASE_VERSION:
        raise SchemaV3Error(
            f"database user_version must be {DATABASE_VERSION}, got {version}"
        )

    existing = set(_existing_tables(connection))
    missing_tables = set(_REQUIRED_COLUMNS).difference(existing)
    if missing_tables:
        raise SchemaV3Error(
            "database v3 is missing tables: " + ", ".join(sorted(missing_tables))
        )
    for table, expected_columns in _REQUIRED_COLUMNS.items():
        missing = expected_columns.difference(_column_names(connection, table))
        if missing:
            raise SchemaV3Error(
                f"database v3 table {table} is missing columns: "
                + ", ".join(sorted(missing))
            )

    actual_index_names = {
        str(row[0])
        for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type = 'index'"
        ).fetchall()
    }
    missing_indexes = set(_EXPECTED_INDEXES).difference(actual_index_names)
    if missing_indexes:
        raise SchemaV3Error(
            "database v3 is missing indexes: "
            + ", ".join(sorted(missing_indexes))
        )
    for name in _EXPECTED_INDEXES:
        _validate_index_contract(connection, name)

    actual_trigger_names = {
        str(row[0])
        for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type = 'trigger'"
        ).fetchall()
    }
    missing_triggers = _EXPECTED_TRIGGERS.difference(actual_trigger_names)
    if missing_triggers:
        raise SchemaV3Error(
            "database v3 is missing contract triggers: "
            + ", ".join(sorted(missing_triggers))
        )
    expected_triggers = _contract_trigger_statements()
    for name, (expected_table, expected_statement) in expected_triggers.items():
        row = connection.execute(
            "SELECT tbl_name, sql FROM sqlite_master "
            "WHERE type = 'trigger' AND name = ?",
            (name,),
        ).fetchone()
        if row is None or str(row[0]) != expected_table:
            raise SchemaV3Error(
                f"database v3 trigger {name} must belong to {expected_table}"
            )
        if _normalize_sql(str(row[1])) != _normalize_sql(expected_statement):
            raise SchemaV3Error(
                f"database v3 trigger {name} does not enforce the expected contract"
            )

    foreign_key_errors = connection.execute("PRAGMA foreign_key_check").fetchall()
    if foreign_key_errors:
        raise SchemaV3Error(f"database v3 foreign key check failed: {foreign_key_errors}")
    for table, expected_foreign_keys in _EXPECTED_FOREIGN_KEYS.items():
        actual_foreign_keys = {
            (str(row[3]), str(row[2]), str(row[4]), str(row[6]).upper())
            for row in connection.execute(f"PRAGMA foreign_key_list({table})").fetchall()
        }
        missing_foreign_keys = expected_foreign_keys.difference(actual_foreign_keys)
        if missing_foreign_keys:
            raise SchemaV3Error(
                f"database v3 table {table} is missing foreign keys: "
                + repr(sorted(missing_foreign_keys))
            )

    integrity = connection.execute("PRAGMA integrity_check").fetchall()
    if [str(row[0]) for row in integrity] != ["ok"]:
        raise SchemaV3Error(f"database v3 integrity check failed: {integrity}")

    identity_rows = connection.execute(
        "SELECT singleton, instance_uuid, created_at FROM database_identity"
    ).fetchall()
    if len(identity_rows) != 1 or int(identity_rows[0][0]) != 1:
        raise SchemaV3Error("database_identity must contain exactly the singleton row")
    instance_uuid = str(identity_rows[0][1])
    try:
        _canonical_v4_uuid(
            instance_uuid,
            field_name="database instance UUID",
        )
    except ValueError as exc:
        raise SchemaV3Error(str(exc)) from exc
    if not is_utc_audit_timestamp(identity_rows[0][2]):
        raise SchemaV3Error("database identity created_at is not canonical UTC")

    for table in _UUID_TABLES:
        for row in connection.execute(f"SELECT uuid FROM {table}").fetchall():
            value = str(row[0])
            try:
                parsed_uuid = UUID(value)
                canonical = str(parsed_uuid)
            except ValueError as exc:
                raise SchemaV3Error(f"{table} contains invalid UUID {value!r}") from exc
            if canonical != value:
                raise SchemaV3Error(f"{table} UUID must use canonical lowercase syntax")
            if parsed_uuid.version not in {4, 5}:
                raise SchemaV3Error(f"{table} UUID must be version 4 or 5")
            if table not in _UUID_V5_ALLOWED_TABLES and parsed_uuid.version != 4:
                raise SchemaV3Error(f"{table} UUID must be version 4")

    for task_id, task_uuid in connection.execute(
        "SELECT id, uuid FROM assignments"
    ).fetchall():
        if UUID(str(task_uuid)).version == 5 and str(task_uuid) != (
            deterministic_v3_uuid(instance_uuid, "task", int(task_id))
        ):
            raise SchemaV3Error(
                f"assignment {task_id} UUID v5 does not match database lineage"
            )

    _validate_audit_timestamps(connection)
    attachment_types = {
        str(row[2]).strip().upper()
        for row in connection.execute("PRAGMA table_xinfo(attachments)").fetchall()
    }
    # SQLite assigns BLOB affinity both to explicit BLOB declarations and to
    # columns with no declared type. Extension metadata is allowed, payload
    # storage is not.
    if any(not column_type or "BLOB" in column_type for column_type in attachment_types):
        raise SchemaV3Error("attachments must store metadata only, never BLOB columns")
    for attachment_uuid, file_name, relative_path, sha256 in connection.execute(
        "SELECT uuid, file_name, relative_path, sha256 FROM attachments"
    ).fetchall():
        if (
            not isinstance(file_name, str)
            or file_name in {"", ".", ".."}
            or len(file_name) > 255
            or any(character in file_name for character in ("\x00", "/", "\\"))
        ):
            raise SchemaV3Error(f"unsafe attachment file name: {file_name!r}")
        if not is_safe_attachment_relative_path(relative_path):
            raise SchemaV3Error(f"unsafe attachment relative path: {relative_path!r}")
        if relative_path != attachment_storage_relative_path(str(attachment_uuid)):
            raise SchemaV3Error(
                "attachment relative paths must use the immutable UUID storage key"
            )
        if _SHA256.fullmatch(str(sha256)) is None:
            raise SchemaV3Error("attachment sha256 must be 64 lowercase hex characters")

    for table in ("courses", "tags"):
        invalid_name = next(
            (
                (row[0], row[1], row[2])
                for row in connection.execute(
                    f"SELECT id, name, normalized_name FROM {table}"
                ).fetchall()
                if canonical_name(str(row[1])) != str(row[2])
            ),
            None,
        )
        if invalid_name is not None:
            raise SchemaV3Error(
                f"{table} row {invalid_name[0]} has an invalid normalized_name"
            )

    invalid_organization_row = connection.execute(
        """
        SELECT 'course', id FROM courses
        WHERE is_archived IS NULL OR is_archived NOT IN (0, 1)
        UNION ALL
        SELECT 'project', id FROM projects
        WHERE status IS NULL
           OR status NOT IN ('active', 'on_hold', 'completed', 'archived')
        UNION ALL
        SELECT 'subtask', id FROM subtasks
        WHERE status IS NULL
           OR status NOT IN ('not_started', 'in_progress', 'completed')
           OR sort_order IS NULL OR sort_order < 0
           OR (status = 'completed' AND completed_at IS NULL)
           OR (status != 'completed' AND completed_at IS NOT NULL)
        UNION ALL
        SELECT 'reminder', id FROM reminders
        WHERE lead_minutes IS NULL OR lead_minutes < 0
           OR is_enabled IS NULL OR is_enabled NOT IN (0, 1)
        UNION ALL
        SELECT 'attachment', id FROM attachments
        WHERE byte_size IS NULL OR byte_size < 0
        LIMIT 1
        """
    ).fetchone()
    if invalid_organization_row is not None:
        raise SchemaV3Error(
            f"{invalid_organization_row[0]} row {invalid_organization_row[1]} "
            "violates the v3 organization contract"
        )

    invalid_course_snapshot = connection.execute(
        """
        SELECT a.id FROM assignments AS a
        JOIN courses AS c ON c.id = a.course_id
        WHERE a.course_name IS NULL OR a.course_name != c.name
        LIMIT 1
        """
    ).fetchone()
    if invalid_course_snapshot is not None:
        raise SchemaV3Error(
            f"assignment {invalid_course_snapshot[0]} has a stale course snapshot"
        )

    invalid_project_course = connection.execute(
        """
        SELECT a.id FROM assignments AS a
        JOIN projects AS p ON p.id = a.project_id
        WHERE p.course_id IS NOT NULL
          AND (a.course_id IS NULL OR a.course_id != p.course_id)
        LIMIT 1
        """
    ).fetchone()
    if invalid_project_course is not None:
        raise SchemaV3Error(
            f"assignment {invalid_project_course[0]} and its project disagree on course"
        )

    for timezone_id in connection.execute(
        "SELECT timezone_id FROM assignments WHERE timezone_id IS NOT NULL"
    ).fetchall():
        if not is_iana_timezone_id(timezone_id[0]):
            raise SchemaV3Error(f"invalid IANA timezone identifier: {timezone_id[0]!r}")

    for reminder_id, trigger_at, last_scheduled_at, repeat_rule in connection.execute(
        "SELECT id, trigger_at_utc, last_scheduled_at, repeat_rule FROM reminders"
    ).fetchall():
        if not is_utc_audit_timestamp(trigger_at):
            raise SchemaV3Error(
                f"reminder {reminder_id} trigger_at_utc is not canonical UTC"
            )
        if last_scheduled_at is not None and not is_utc_audit_timestamp(
            last_scheduled_at
        ):
            raise SchemaV3Error(
                f"reminder {reminder_id} last_scheduled_at is not canonical UTC"
            )
        try:
            canonical_rule = canonical_repeat_rule(repeat_rule)
        except ValueError as exc:
            raise SchemaV3Error(f"reminder {reminder_id} has invalid repeat_rule") from exc
        if canonical_rule != repeat_rule:
            raise SchemaV3Error(
                f"reminder {reminder_id} repeat_rule is not stored canonically"
            )

    invalid_tasks = connection.execute(
        """
        SELECT id FROM assignments
        WHERE status IS NULL
           OR priority IS NULL
           OR status NOT IN ('not_started', 'in_progress', 'completed')
           OR priority NOT IN ('low', 'medium', 'high')
           OR progress_percent NOT BETWEEN 0 AND 100
           OR all_day NOT IN (0, 1)
           OR (all_day = 1 AND due_date IS NULL)
           OR (status = 'completed' AND
               (progress_percent != 100 OR completed_at IS NULL))
           OR (status != 'completed' AND
               (progress_percent = 100 OR completed_at IS NOT NULL))
        LIMIT 1
        """
    ).fetchone()
    if invalid_tasks is not None:
        raise SchemaV3Error(f"assignment {invalid_tasks[0]} violates progress semantics")

    for task_id, status, progress, total, completed, in_progress in connection.execute(
        """
        SELECT a.id, a.status, a.progress_percent,
               COUNT(s.id),
               SUM(CASE WHEN s.status = 'completed' THEN 1 ELSE 0 END),
               SUM(CASE WHEN s.status = 'in_progress' THEN 1 ELSE 0 END)
        FROM assignments AS a
        JOIN subtasks AS s
          ON s.assignment_id = a.id AND s.deleted_at IS NULL
        GROUP BY a.id, a.status, a.progress_percent
        """
    ).fetchall():
        total_count = int(total)
        completed_count = int(completed or 0)
        in_progress_count = int(in_progress or 0)
        expected_progress = completed_count * 100 // total_count
        if completed_count == total_count:
            expected_status = "completed"
        elif completed_count > 0 or in_progress_count > 0:
            expected_status = "in_progress"
        else:
            expected_status = "not_started"
        if str(status) != expected_status or int(progress) != expected_progress:
            raise SchemaV3Error(
                f"assignment {task_id} does not match its active subtask state"
            )


def _validate_audit_timestamps(connection: sqlite3.Connection) -> None:
    for table in sorted(_UUID_TABLES):
        rows = connection.execute(
            f"SELECT id, uuid, created_at, updated_at, deleted_at FROM {table}"
        ).fetchall()
        for row_id, row_uuid, created_at, updated_at, deleted_at in rows:
            is_new_record = UUID(str(row_uuid)).version == 4
            if is_new_record and not is_utc_audit_timestamp(created_at):
                raise SchemaV3Error(
                    f"{table} row {row_id} created_at is not canonical UTC"
                )
            if is_new_record and not is_utc_audit_timestamp(updated_at):
                raise SchemaV3Error(
                    f"{table} row {row_id} updated_at is not canonical UTC"
                )
            if deleted_at is not None and not is_utc_audit_timestamp(deleted_at):
                raise SchemaV3Error(
                    f"{table} row {row_id} deleted_at is not canonical UTC"
                )

    for table in ("assignments", "subtasks"):
        for row_id, row_uuid, completed_at in connection.execute(
            f"SELECT id, uuid, completed_at FROM {table} "
            "WHERE completed_at IS NOT NULL"
        ).fetchall():
            if UUID(str(row_uuid)).version == 4 and not is_utc_audit_timestamp(
                completed_at
            ):
                raise SchemaV3Error(
                    f"{table} row {row_id} completed_at is not canonical UTC"
                )


def _require_active_transaction(connection: sqlite3.Connection) -> None:
    if not connection.in_transaction:
        raise SchemaV3Error(
            "schema v3 primitives require a caller-owned active transaction"
        )


def _require_foreign_keys_enabled(connection: sqlite3.Connection) -> None:
    enabled = int(connection.execute("PRAGMA foreign_keys").fetchone()[0])
    if enabled != 1:
        raise SchemaV3Error(
            "schema v3 operations require PRAGMA foreign_keys=ON before transaction"
        )


def _existing_tables(connection: sqlite3.Connection) -> list[str]:
    return [
        str(row[0])
        for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        ).fetchall()
    ]


def _column_names(connection: sqlite3.Connection, table: str) -> set[str]:
    return {
        str(row[1])
        for row in connection.execute(f"PRAGMA table_info({table})").fetchall()
    }


def _rows_as_dicts(cursor: sqlite3.Cursor) -> list[dict[str, Any]]:
    names = [str(column[0]) for column in cursor.description or ()]
    return [dict(zip(names, row, strict=True)) for row in cursor.fetchall()]


def _legacy_assignment_snapshot(
    connection: sqlite3.Connection,
) -> tuple[tuple[str, ...], tuple[tuple[Any, ...], ...], tuple[tuple[Any, ...], ...]]:
    columns = tuple(
        str(row[1])
        for row in connection.execute("PRAGMA table_info(assignments)").fetchall()
    )
    quoted_columns = ", ".join(
        f'"{column.replace(chr(34), chr(34) * 2)}"' for column in columns
    )
    rows = tuple(
        tuple(row)
        for row in connection.execute(
            f"SELECT {quoted_columns} FROM assignments ORDER BY id"
        ).fetchall()
    )
    objects = tuple(
        tuple(row)
        for row in connection.execute(
            "SELECT type, name, tbl_name, sql FROM sqlite_master "
            "WHERE tbl_name = 'assignments' AND type IN ('index', 'trigger') "
            "AND sql IS NOT NULL ORDER BY type, name"
        ).fetchall()
    )
    return columns, rows, objects


def _assignment_triggers(connection: sqlite3.Connection) -> list[tuple[str, str]]:
    return [
        (str(row[0]), str(row[1]))
        for row in connection.execute(
            """
            SELECT name, sql FROM sqlite_master
            WHERE type = 'trigger' AND tbl_name = 'assignments' AND sql IS NOT NULL
            ORDER BY name
            """
        ).fetchall()
    ]


def _ensure_reserved_trigger_names_available(
    connection: sqlite3.Connection,
) -> None:
    placeholders = ", ".join("?" for _ in _EXPECTED_TRIGGERS)
    conflicts = connection.execute(
        f"SELECT type, name, tbl_name FROM sqlite_master "
        f"WHERE name IN ({placeholders}) ORDER BY name",
        tuple(sorted(_EXPECTED_TRIGGERS)),
    ).fetchall()
    if conflicts:
        details = ", ".join(
            f"{row[1]} ({row[0]} on {row[2]})" for row in conflicts
        )
        raise SchemaV3Error(f"reserved v3 trigger names are already used: {details}")


def _drop_triggers(
    connection: sqlite3.Connection,
    triggers: list[tuple[str, str]],
) -> None:
    for name, _ in triggers:
        quoted_name = name.replace('"', '""')
        connection.execute(f'DROP TRIGGER "{quoted_name}"')


def _restore_triggers(
    connection: sqlite3.Connection,
    triggers: list[tuple[str, str]],
) -> None:
    for _, statement in triggers:
        connection.execute(statement)


def _validate_legacy_rows(rows: list[Mapping[str, Any]]) -> None:
    seen_ids: set[int] = set()
    for row in rows:
        task_id = int(row["id"])
        if task_id < 1 or task_id in seen_ids:
            raise SchemaV3Error("legacy assignment IDs must be unique positive integers")
        seen_ids.add(task_id)
        if row["status"] not in {"not_started", "in_progress", "completed"}:
            raise SchemaV3Error(f"unsupported legacy status: {row['status']!r}")
        if row["priority"] not in {"low", "medium", "high"}:
            raise SchemaV3Error(f"unsupported legacy priority: {row['priority']!r}")
        if row["course_name"] is None or row["title"] is None:
            raise SchemaV3Error("legacy course_name and title must be non-null")


def _migrate_courses(
    connection: sqlite3.Connection,
    rows: list[Mapping[str, Any]],
    database_instance_uuid: str,
) -> dict[str, int]:
    grouped: dict[str, dict[str, Any]] = {}
    for row in rows:
        display_name = str(row["course_name"])
        if not canonical_name(display_name):
            continue
        current = grouped.get(display_name)
        if current is None or int(row["id"]) < int(current["id"]):
            grouped[display_name] = {
                "id": int(row["id"]),
                "name": display_name,
                "normalized_name": canonical_name(display_name),
                "created_at": row["created_at"],
                "updated_at": row["updated_at"],
            }

    result: dict[str, int] = {}
    for display_name in sorted(grouped, key=lambda value: value.encode("utf-8")):
        values = grouped[display_name]
        cursor = connection.execute(
            """
            INSERT INTO courses (
                uuid, name, normalized_name, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?)
            """,
            (
                deterministic_v3_uuid(
                    database_instance_uuid,
                    "course",
                    display_name,
                ),
                values["name"],
                values["normalized_name"],
                values["created_at"],
                values["updated_at"],
            ),
        )
        result[display_name] = int(cursor.lastrowid)
    return result


def _backfill_legacy_assignments(
    connection: sqlite3.Connection,
    rows: list[Mapping[str, Any]],
    course_ids: Mapping[str, int],
    database_instance_uuid: str,
) -> None:
    for row in rows:
        status = str(row["status"])
        completed = status == "completed"
        connection.execute(
            """
            UPDATE assignments
            SET uuid = ?, course_id = ?, project_id = NULL,
                completed_at = ?, progress_percent = ?, all_day = 0,
                timezone_id = NULL, deleted_at = NULL
            WHERE id = ?
            """,
            (
                deterministic_v3_uuid(
                    database_instance_uuid,
                    "task",
                    int(row["id"]),
                ),
                course_ids.get(str(row["course_name"])),
                row["updated_at"] if completed else None,
                100 if completed else 0,
                row["id"],
            ),
        )


def _verify_legacy_payload(
    connection: sqlite3.Connection,
    before: list[Mapping[str, Any]],
    database_instance_uuid: str,
    legacy_snapshot: tuple[
        tuple[str, ...],
        tuple[tuple[Any, ...], ...],
        tuple[tuple[Any, ...], ...],
    ],
) -> None:
    select_columns = ", ".join(_V2_ASSIGNMENT_COLUMNS)
    after = _rows_as_dicts(
        connection.execute(f"SELECT {select_columns} FROM assignments ORDER BY id")
    )
    if after != before:
        raise SchemaV3Error("v2 assignment payload changed during v3 migration")

    original_columns, original_rows, original_objects = legacy_snapshot
    quoted_columns = ", ".join(
        f'"{column.replace(chr(34), chr(34) * 2)}"'
        for column in original_columns
    )
    current_rows = tuple(
        tuple(row)
        for row in connection.execute(
            f"SELECT {quoted_columns} FROM assignments ORDER BY id"
        ).fetchall()
    )
    if current_rows != original_rows:
        raise SchemaV3Error(
            "existing assignment extension values changed during v3 migration"
        )
    original_names = tuple(str(row[1]) for row in original_objects)
    if original_names:
        placeholders = ", ".join("?" for _ in original_names)
        current_objects = tuple(
            tuple(row)
            for row in connection.execute(
                "SELECT type, name, tbl_name, sql FROM sqlite_master "
                f"WHERE name IN ({placeholders}) ORDER BY type, name",
                original_names,
            ).fetchall()
        )
        if current_objects != original_objects:
            raise SchemaV3Error(
                "existing assignment indexes or triggers changed during v3 migration"
            )

    derived = {
        int(row[0]): tuple(row[1:])
        for row in connection.execute(
            """
            SELECT id, uuid, course_id, project_id, completed_at,
                   progress_percent, all_day, timezone_id, deleted_at
            FROM assignments ORDER BY id
            """
        ).fetchall()
    }
    migrated_course_ids = {
        str(row[0]): int(row[1])
        for row in connection.execute("SELECT name, id FROM courses").fetchall()
    }
    for row in before:
        task_id = int(row["id"])
        expected_completed_at = (
            row["updated_at"] if row["status"] == "completed" else None
        )
        expected = (
            deterministic_v3_uuid(database_instance_uuid, "task", task_id),
            migrated_course_ids.get(str(row["course_name"])),
            None,
            expected_completed_at,
            100 if row["status"] == "completed" else 0,
            0,
            None,
            None,
        )
        if derived[task_id] != expected:
            raise SchemaV3Error(f"assignment {task_id} has invalid migrated v3 fields")

    expected_courses = {
        str(row["course_name"]): deterministic_v3_uuid(
            database_instance_uuid,
            "course",
            str(row["course_name"]),
        )
        for row in before
        if canonical_name(str(row["course_name"]))
    }
    actual_courses = {
        str(row[0]): str(row[1])
        for row in connection.execute(
            "SELECT name, uuid FROM courses"
        ).fetchall()
    }
    if actual_courses != expected_courses:
        raise SchemaV3Error("migrated course UUIDs do not match database lineage")

    for table in (
        "projects",
        "tags",
        "task_tags",
        "subtasks",
        "attachments",
        "reminders",
    ):
        count = int(connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0])
        if count != 0:
            raise SchemaV3Error(
                f"v2 to v3 migration must not synthesize rows in {table}"
            )


def _uuid_check(
    column: str = "uuid",
    *,
    allowed_versions: tuple[str, ...] = ("4", "5"),
) -> str:
    if not allowed_versions or any(value not in {"4", "5"} for value in allowed_versions):
        raise ValueError("UUID checks only support version 4 and 5")
    version_values = ", ".join(f"'{value}'" for value in allowed_versions)
    return f"""
        length({column}) = 36
        AND length(replace({column}, '-', '')) = 32
        AND {column} = lower({column})
        AND substr({column}, 9, 1) = '-'
        AND substr({column}, 14, 1) = '-'
        AND substr({column}, 19, 1) = '-'
        AND substr({column}, 24, 1) = '-'
        AND substr({column}, 15, 1) IN ({version_values})
        AND substr({column}, 20, 1) IN ('8', '9', 'a', 'b')
        AND replace({column}, '-', '') NOT GLOB '*[^0-9a-f]*'
    """.strip()


def _audit_columns() -> str:
    return """
        created_at TEXT NOT NULL
            DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
        updated_at TEXT NOT NULL
            DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
        deleted_at TEXT
    """.strip()


def _create_database_identity(
    connection: sqlite3.Connection,
    instance_uuid: str,
) -> None:
    uuid_check = _uuid_check("instance_uuid", allowed_versions=("4",))
    connection.execute(
        f"""
        CREATE TABLE database_identity (
            singleton INTEGER NOT NULL PRIMARY KEY CHECK (singleton = 1),
            instance_uuid TEXT NOT NULL CHECK (
                ({uuid_check})
            ),
            created_at TEXT NOT NULL
                DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
        )
        """
    )
    connection.execute(
        "INSERT INTO database_identity (singleton, instance_uuid) VALUES (1, ?)",
        (instance_uuid,),
    )


def _create_primary_tables(connection: sqlite3.Connection) -> None:
    migrated_uuid_check = _uuid_check()
    new_uuid_check = _uuid_check(allowed_versions=("4",))
    audit = _audit_columns()
    connection.execute(
        f"""
        CREATE TABLE courses (
            id INTEGER NOT NULL PRIMARY KEY,
            uuid TEXT NOT NULL CHECK ({migrated_uuid_check}),
            name TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 120),
            normalized_name TEXT NOT NULL CHECK (length(normalized_name) >= 1),
            color_hex TEXT CHECK (
                color_hex IS NULL OR
                (length(color_hex) = 7 AND substr(color_hex, 1, 1) = '#'
                 AND substr(color_hex, 2) NOT GLOB '*[^0-9A-Fa-f]*')
            ),
            teacher TEXT,
            semester TEXT,
            is_archived INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1)),
            {audit}
        )
        """
    )
    connection.execute(
        f"""
        CREATE TABLE projects (
            id INTEGER NOT NULL PRIMARY KEY,
            uuid TEXT NOT NULL CHECK ({new_uuid_check}),
            course_id INTEGER REFERENCES courses(id) ON DELETE SET NULL,
            name TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 255),
            description TEXT,
            status TEXT NOT NULL DEFAULT 'active'
                CHECK (status IN ('active', 'on_hold', 'completed', 'archived')),
            {audit}
        )
        """
    )
    connection.execute(
        f"""
        CREATE TABLE tags (
            id INTEGER NOT NULL PRIMARY KEY,
            uuid TEXT NOT NULL CHECK ({new_uuid_check}),
            name TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 80),
            normalized_name TEXT NOT NULL CHECK (length(normalized_name) >= 1),
            color_hex TEXT CHECK (
                color_hex IS NULL OR
                (length(color_hex) = 7 AND substr(color_hex, 1, 1) = '#'
                 AND substr(color_hex, 2) NOT GLOB '*[^0-9A-Fa-f]*')
            ),
            {audit}
        )
        """
    )


def _create_v2_assignment_table(connection: sqlite3.Connection) -> None:
    connection.execute(
        """
        CREATE TABLE assignments (
            id INTEGER NOT NULL PRIMARY KEY,
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
            CONSTRAINT assignment_status_check
                CHECK (status IN ('not_started', 'in_progress', 'completed')),
            CONSTRAINT assignment_priority_check
                CHECK (priority IN ('low', 'medium', 'high'))
        )
        """
    )


def _add_v3_assignment_columns(connection: sqlite3.Connection) -> None:
    existing = _column_names(connection, "assignments")
    definitions = {
        # UUID is physically nullable because SQLite cannot add a NOT NULL
        # column without a non-unique constant default. Triggers below enforce
        # logical non-null and canonical syntax after migration backfill.
        "uuid": "TEXT",
        "course_id": "INTEGER REFERENCES courses(id) ON DELETE SET NULL",
        "project_id": "INTEGER REFERENCES projects(id) ON DELETE SET NULL",
        "completed_at": "TEXT",
        "progress_percent": (
            "INTEGER NOT NULL DEFAULT 0 CHECK (progress_percent BETWEEN 0 AND 100)"
        ),
        "all_day": "INTEGER NOT NULL DEFAULT 0 CHECK (all_day IN (0, 1))",
        "timezone_id": "TEXT",
        "deleted_at": "TEXT",
    }
    for name, definition in definitions.items():
        if name not in existing:
            connection.execute(f"ALTER TABLE assignments ADD COLUMN {name} {definition}")


def _create_child_tables(connection: sqlite3.Connection) -> None:
    uuid_check = _uuid_check(allowed_versions=("4",))
    audit = _audit_columns()
    connection.execute(
        f"""
        CREATE TABLE task_tags (
            id INTEGER NOT NULL PRIMARY KEY,
            uuid TEXT NOT NULL CHECK ({uuid_check}),
            assignment_id INTEGER NOT NULL
                REFERENCES assignments(id) ON DELETE CASCADE,
            tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
            {audit}
        )
        """
    )
    connection.execute(
        f"""
        CREATE TABLE subtasks (
            id INTEGER NOT NULL PRIMARY KEY,
            uuid TEXT NOT NULL CHECK ({uuid_check}),
            assignment_id INTEGER NOT NULL
                REFERENCES assignments(id) ON DELETE CASCADE,
            title TEXT NOT NULL CHECK (length(trim(title)) BETWEEN 1 AND 255),
            status TEXT NOT NULL DEFAULT 'not_started'
                CHECK (status IN ('not_started', 'in_progress', 'completed')),
            sort_order INTEGER NOT NULL DEFAULT 0 CHECK (sort_order >= 0),
            completed_at TEXT,
            {audit},
            CHECK (
                (status = 'completed' AND completed_at IS NOT NULL)
                OR (status != 'completed' AND completed_at IS NULL)
            )
        )
        """
    )
    connection.execute(
        f"""
        CREATE TABLE attachments (
            id INTEGER NOT NULL PRIMARY KEY,
            uuid TEXT NOT NULL CHECK ({uuid_check}),
            assignment_id INTEGER NOT NULL
                REFERENCES assignments(id) ON DELETE CASCADE,
            file_name TEXT NOT NULL CHECK (
                length(file_name) BETWEEN 1 AND 255
                AND file_name NOT IN ('.', '..')
                AND instr(file_name, char(0)) = 0
                AND instr(file_name, '/') = 0
                AND instr(file_name, char(92)) = 0
            ),
            relative_path TEXT NOT NULL CHECK (
                length(relative_path) BETWEEN 1 AND 1000
                AND relative_path = 'attachments/' || uuid
                AND substr(relative_path, 1, 1) != '/'
                AND substr(relative_path, -1, 1) != '/'
                AND instr(relative_path, char(0)) = 0
                AND instr(relative_path, '//') = 0
                AND instr(relative_path, char(92)) = 0
                AND instr(relative_path, ':') = 0
                AND relative_path != '..'
                AND relative_path NOT LIKE '../%'
                AND relative_path NOT LIKE '%/../%'
                AND relative_path != '.'
                AND relative_path NOT LIKE './%'
                AND relative_path NOT LIKE '%/./%'
                AND ('/' || relative_path || '/') NOT LIKE '%/./%'
                AND ('/' || relative_path || '/') NOT LIKE '%/../%'
            ),
            mime_type TEXT,
            byte_size INTEGER NOT NULL CHECK (byte_size >= 0),
            sha256 TEXT NOT NULL CHECK (
                length(sha256) = 64
                AND sha256 = lower(sha256)
                AND sha256 NOT GLOB '*[^0-9a-f]*'
            ),
            {audit}
        )
        """
    )
    connection.execute(
        f"""
        CREATE TABLE reminders (
            id INTEGER NOT NULL PRIMARY KEY,
            uuid TEXT NOT NULL CHECK ({uuid_check}),
            assignment_id INTEGER NOT NULL
                REFERENCES assignments(id) ON DELETE CASCADE,
            trigger_at_utc TEXT NOT NULL,
            lead_minutes INTEGER NOT NULL DEFAULT 0 CHECK (lead_minutes >= 0),
            repeat_rule TEXT,
            is_enabled INTEGER NOT NULL DEFAULT 1 CHECK (is_enabled IN (0, 1)),
            last_scheduled_at TEXT,
            {audit}
        )
        """
    )


def _index_statements() -> dict[str, str]:
    statements = (
        "CREATE UNIQUE INDEX ux_assignments_uuid ON assignments(uuid)",
        "CREATE INDEX ix_assignments_course_id ON assignments(course_id)",
        "CREATE INDEX ix_assignments_project_id ON assignments(project_id)",
        "CREATE INDEX ix_assignments_due_date ON assignments(due_date)",
        "CREATE INDEX ix_assignments_status ON assignments(status)",
        "CREATE INDEX ix_assignments_priority ON assignments(priority)",
        "CREATE INDEX ix_assignments_deleted_at ON assignments(deleted_at)",
        "CREATE UNIQUE INDEX ux_courses_uuid ON courses(uuid)",
        "CREATE INDEX ix_courses_normalized_name ON courses(normalized_name)",
        "CREATE INDEX ix_courses_archived_name ON courses(is_archived, name)",
        "CREATE UNIQUE INDEX ux_projects_uuid ON projects(uuid)",
        "CREATE INDEX ix_projects_course_status ON projects(course_id, status)",
        "CREATE INDEX ix_projects_deleted_at ON projects(deleted_at)",
        "CREATE UNIQUE INDEX ux_tags_uuid ON tags(uuid)",
        "CREATE UNIQUE INDEX ux_tags_normalized_name ON tags(normalized_name)",
        "CREATE INDEX ix_tags_deleted_at ON tags(deleted_at)",
        "CREATE UNIQUE INDEX ux_task_tags_uuid ON task_tags(uuid)",
        "CREATE UNIQUE INDEX ux_task_tags_active_pair "
        "ON task_tags(assignment_id, tag_id) WHERE deleted_at IS NULL",
        "CREATE INDEX ix_task_tags_assignment ON task_tags(assignment_id)",
        "CREATE INDEX ix_task_tags_tag ON task_tags(tag_id)",
        "CREATE UNIQUE INDEX ux_subtasks_uuid ON subtasks(uuid)",
        "CREATE INDEX ix_subtasks_assignment_order "
        "ON subtasks(assignment_id, sort_order, id)",
        "CREATE INDEX ix_subtasks_status ON subtasks(status)",
        "CREATE UNIQUE INDEX ux_attachments_uuid ON attachments(uuid)",
        "CREATE UNIQUE INDEX ux_attachments_relative_path "
        "ON attachments(relative_path)",
        "CREATE INDEX ix_attachments_assignment ON attachments(assignment_id)",
        "CREATE INDEX ix_attachments_sha256 ON attachments(sha256)",
        "CREATE UNIQUE INDEX ux_reminders_uuid ON reminders(uuid)",
        "CREATE INDEX ix_reminders_assignment ON reminders(assignment_id)",
        "CREATE INDEX ix_reminders_enabled_trigger "
        "ON reminders(is_enabled, trigger_at_utc)",
    )
    return {
        statement.split(" ON ", maxsplit=1)[0].split()[-1]: statement
        for statement in statements
    }


def _normalize_sql(statement: str) -> str:
    return " ".join(statement.strip().rstrip(";").split())


def _validate_index_contract(connection: sqlite3.Connection, name: str) -> None:
    expected_table, expected_columns = _EXPECTED_INDEXES[name]
    row = connection.execute(
        "SELECT type, tbl_name, sql FROM sqlite_master WHERE name = ?",
        (name,),
    ).fetchone()
    if row is None or str(row[0]) != "index":
        raise SchemaV3Error(f"database v3 is missing index {name}")
    actual_table = str(row[1])
    statement = None if row[2] is None else str(row[2])
    if actual_table != expected_table:
        raise SchemaV3Error(
            f"database v3 index {name} belongs to {actual_table}, "
            f"expected {expected_table}"
        )
    quoted_name = name.replace('"', '""')
    columns = tuple(
        str(index_row[2])
        for index_row in connection.execute(
            f'PRAGMA index_info("{quoted_name}")'
        ).fetchall()
    )
    if columns != expected_columns:
        raise SchemaV3Error(
            f"database v3 index {name} has columns {columns!r}, "
            f"expected {expected_columns!r}"
        )
    quoted_table = expected_table.replace('"', '""')
    index_list = {
        str(index_row[1]): (bool(index_row[2]), bool(index_row[4]))
        for index_row in connection.execute(
            f'PRAGMA index_list("{quoted_table}")'
        ).fetchall()
    }
    if name not in index_list:
        raise SchemaV3Error(f"database v3 index {name} is not attached to its table")
    is_unique, is_partial = index_list[name]
    if is_unique != (name in _UNIQUE_INDEXES):
        raise SchemaV3Error(
            f"database v3 index {name} has the wrong uniqueness contract"
        )
    if is_partial != (name in _PARTIAL_INDEXES):
        raise SchemaV3Error(
            f"database v3 index {name} has the wrong partial-index contract"
        )
    if name in _PARTIAL_INDEXES:
        normalized_statement = _normalize_sql(statement or "").lower()
        match = re.search(r"\bwhere\b\s+(.+)$", normalized_statement)
        if match is None or match.group(1).strip() != "deleted_at is null":
            raise SchemaV3Error(
                f"database v3 partial index {name} must filter exactly "
                "deleted_at IS NULL"
            )


def _create_indexes(connection: sqlite3.Connection) -> None:
    for name, statement in _index_statements().items():
        existing = connection.execute(
            "SELECT type FROM sqlite_master WHERE name = ?",
            (name,),
        ).fetchone()
        if existing is None:
            connection.execute(statement)
        else:
            _validate_index_contract(connection, name)


def _contract_trigger_statements() -> dict[str, tuple[str, str]]:
    uuid_valid = _uuid_check("NEW.uuid")
    invalid_progress = """
        NEW.status IS NULL
        OR NEW.priority IS NULL
        OR NEW.status NOT IN ('not_started', 'in_progress', 'completed')
        OR NEW.priority NOT IN ('low', 'medium', 'high')
        OR NEW.progress_percent NOT BETWEEN 0 AND 100
        OR NEW.all_day NOT IN (0, 1)
        OR (NEW.all_day = 1 AND NEW.due_date IS NULL)
        OR (NEW.status = 'completed' AND
            (NEW.progress_percent != 100 OR NEW.completed_at IS NULL))
        OR (NEW.status != 'completed' AND
            (NEW.progress_percent = 100 OR NEW.completed_at IS NOT NULL))
    """.strip()
    statements: dict[str, tuple[str, str]] = {
        "assignments_v3_contract_insert": ("assignments", f"""
        CREATE TRIGGER assignments_v3_contract_insert
        BEFORE INSERT ON assignments
        WHEN NEW.uuid IS NULL OR NOT ({uuid_valid}) OR ({invalid_progress})
        BEGIN
            SELECT RAISE(ABORT, 'assignment violates schema v3 contract');
        END
        """.strip()),
        "assignments_v3_contract_update": ("assignments", f"""
        CREATE TRIGGER assignments_v3_contract_update
        BEFORE UPDATE ON assignments
        WHEN NEW.uuid IS NULL OR NOT ({uuid_valid}) OR ({invalid_progress})
        BEGIN
            SELECT RAISE(ABORT, 'assignment violates schema v3 contract');
        END
        """.strip()),
        "database_identity_immutable_update": ("database_identity", """
        CREATE TRIGGER database_identity_immutable_update
        BEFORE UPDATE ON database_identity
        BEGIN
            SELECT RAISE(ABORT, 'database identity is immutable');
        END
        """.strip()),
        "database_identity_immutable_delete": ("database_identity", """
        CREATE TRIGGER database_identity_immutable_delete
        BEFORE DELETE ON database_identity
        BEGIN
            SELECT RAISE(ABORT, 'database identity is immutable');
        END
        """.strip()),
    }
    for table in _IMMUTABLE_UUID_TABLES:
        name = f"{table}_uuid_immutable"
        statements[name] = (table, f"""
        CREATE TRIGGER {name}
        BEFORE UPDATE OF uuid ON {table}
        WHEN NEW.uuid IS NOT OLD.uuid
        BEGIN
            SELECT RAISE(ABORT, '{table} UUID is immutable');
        END
        """.strip())
    return statements


def _create_contract_triggers(connection: sqlite3.Connection) -> None:
    _ensure_reserved_trigger_names_available(connection)
    for _, statement in _contract_trigger_statements().values():
        connection.execute(statement)
