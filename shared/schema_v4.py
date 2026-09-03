"""Executable SQLite schema v4 primitives for Phase 3A learning scenes.

Platform repositories own online backups and transaction boundaries.  This
module only performs the additive v3 -> v4 schema change and validates the
result inside the caller's connection.
"""

from __future__ import annotations

import re
import sqlite3
from collections.abc import Callable
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

# `_uuid_check` is imported under an alias so the Phase 3A tables reuse the
# exact v3 UUID-v4 convention instead of inventing a second spelling of it.
from shared.schema_v3 import _uuid_check as _v3_uuid_check
from shared.schema_v3 import validate_v3_schema


DATABASE_VERSION = 4

_LOCAL_TIME = re.compile(r"^[0-9]{2}:[0-9]{2}:[0-9]{2}$")
_LOCAL_DATE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
_LOCAL_DATE_TIME = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$"
)
_IANA_TIME_ZONE = re.compile(r"^(?:UTC|[A-Za-z_+\-]+(?:/[A-Za-z0-9_+\-.]+)+)$")


class SchemaV4Error(RuntimeError):
    """Raised when a v4 operation would violate the shared contract."""


def _require_active_transaction(connection: sqlite3.Connection) -> None:
    if not connection.in_transaction:
        raise SchemaV4Error("v3 to v4 migration requires an active transaction")


def _require_foreign_keys(connection: sqlite3.Connection) -> None:
    if int(connection.execute("PRAGMA foreign_keys").fetchone()[0]) != 1:
        raise SchemaV4Error("SQLite foreign_keys must be enabled")


def parse_local_time(value: str) -> time:
    """Parse a strict `HH:mm:ss` wall-clock value without any date or offset."""

    if not isinstance(value, str) or _LOCAL_TIME.fullmatch(value) is None:
        raise SchemaV4Error("local time must use HH:mm:ss")
    try:
        return datetime.strptime(value, "%H:%M:%S").time()
    except ValueError as exc:
        raise SchemaV4Error("local time is not a real clock value") from exc


def parse_local_date(value: str) -> date:
    """Parse a strict `YYYY-MM-DD` local date without any time or offset."""

    if not isinstance(value, str) or _LOCAL_DATE.fullmatch(value) is None:
        raise SchemaV4Error("invalid local date")
    try:
        return date.fromisoformat(value)
    except ValueError as exc:
        raise SchemaV4Error("invalid local date") from exc


def meeting_times_overlap(
    first_start: str,
    first_end: str,
    second_start: str,
    second_end: str,
) -> bool:
    """Return whether two same-day half-open meeting intervals overlap."""

    first = (parse_local_time(first_start), parse_local_time(first_end))
    second = (parse_local_time(second_start), parse_local_time(second_end))
    if first[0] >= first[1] or second[0] >= second[1]:
        raise SchemaV4Error("course meeting start time must precede end time")
    return first[0] < second[1] and second[0] < first[1]


def relative_reminder_trigger(
    due_at_utc: datetime | None,
    lead_minutes: int,
) -> datetime:
    """Calculate the exact UTC trigger for a due-relative reminder."""

    if due_at_utc is None:
        raise SchemaV4Error("due-relative reminders require a due date")
    if due_at_utc.tzinfo is None or due_at_utc.utcoffset() is None:
        raise SchemaV4Error("due date must be timezone-aware")
    if lead_minutes < 0:
        raise SchemaV4Error("lead minutes must be non-negative")
    return due_at_utc - timedelta(minutes=lead_minutes)


# MARK: - Learning-scene rules


@dataclass(frozen=True)
class MeetingWindow:
    """A weekly course meeting interpreted in its own declared time zone."""

    weekday: int
    start_time_local: str
    end_time_local: str
    timezone_id: str
    effective_start_date: str
    effective_end_date: str | None = None

    def __post_init__(self) -> None:
        if not isinstance(self.weekday, int) or not 1 <= self.weekday <= 7:
            raise SchemaV4Error("course meeting weekday must use ISO values 1 to 7")
        meeting_times_overlap(
            self.start_time_local, self.end_time_local,
            self.start_time_local, self.end_time_local,
        )
        _validated_time_zone(self.timezone_id)
        start = parse_local_date(self.effective_start_date)
        if self.effective_end_date is not None:
            end = parse_local_date(self.effective_end_date)
            if end < start:
                raise SchemaV4Error("effective_end_date must not precede the start date")

    @property
    def start_date(self) -> date:
        return parse_local_date(self.effective_start_date)

    @property
    def end_date(self) -> date | None:
        if self.effective_end_date is None:
            return None
        return parse_local_date(self.effective_end_date)


def meeting_occurs_on(meeting: MeetingWindow, on_date: str) -> bool:
    """Return whether the weekly meeting is scheduled on `on_date`."""

    day = parse_local_date(on_date)
    if day.isoweekday() != meeting.weekday:
        return False
    if day < meeting.start_date:
        return False
    end = meeting.end_date
    return end is None or day <= end


def resolve_meeting_interval(
    meeting: MeetingWindow,
    on_date: str,
) -> tuple[datetime, datetime] | None:
    """Resolve one occurrence to UTC.

    Returns `None` when the local wall time does not exist because a daylight
    saving transition skipped it. An ambiguous wall time uses its first
    (earlier-offset) occurrence. Both endpoints are resolved independently, so
    an occurrence that spans a fall-back boundary reports the real elapsed
    interval rather than the nominal wall-clock duration.
    """

    if not meeting_occurs_on(meeting, on_date):
        raise SchemaV4Error(
            f"course meeting weekday {meeting.weekday} does not occur on {on_date}"
        )
    day = parse_local_date(on_date)
    zone = _validated_time_zone(meeting.timezone_id)
    start = _resolve_local_wall_time(day, meeting.start_time_local, zone)
    end = _resolve_local_wall_time(day, meeting.end_time_local, zone)
    if start is None or end is None:
        return None
    return start.astimezone(timezone.utc), end.astimezone(timezone.utc)


def meetings_overlap(first: MeetingWindow, second: MeetingWindow) -> bool:
    """Return whether two weekly meetings can collide on a shared date.

    Overlap is a warning only. Meetings on different weekdays or with disjoint
    effective ranges never overlap. When both are scheduled on a common date
    the resolved UTC intervals decide; if that date has a daylight-saving gap
    the comparison falls back to the stored wall-clock intervals.
    """

    if first.weekday != second.weekday:
        return False
    earliest = max(first.start_date, second.start_date)
    latest = min(
        first.end_date or date.max,
        second.end_date or date.max,
    )
    if earliest > latest:
        return False
    offset = (first.weekday - earliest.isoweekday()) % 7
    shared = earliest + timedelta(days=offset)
    if shared > latest:
        return False

    first_interval = _interval_on(first, shared)
    second_interval = _interval_on(second, shared)
    if first_interval is None or second_interval is None:
        return meeting_times_overlap(
            first.start_time_local, first.end_time_local,
            second.start_time_local, second.end_time_local,
        )
    return first_interval[0] < second_interval[1] and second_interval[0] < first_interval[1]


EXAM_STATUS_ORDER = {"upcoming": 0, "completed": 1, "cancelled": 2}


def exam_sort_key(status: str, starts_at_utc: datetime) -> tuple[int, datetime]:
    """Order exams: upcoming first by start time, then completed, then cancelled."""

    if status not in EXAM_STATUS_ORDER:
        raise SchemaV4Error(f"unsupported exam status: {status}")
    if starts_at_utc.tzinfo is None or starts_at_utc.utcoffset() is None:
        raise SchemaV4Error("exam start time must be timezone-aware")
    return EXAM_STATUS_ORDER[status], starts_at_utc.astimezone(timezone.utc)


def _interval_on(
    meeting: MeetingWindow,
    day: date,
) -> tuple[datetime, datetime] | None:
    zone = _validated_time_zone(meeting.timezone_id)
    start = _resolve_local_wall_time(day, meeting.start_time_local, zone)
    end = _resolve_local_wall_time(day, meeting.end_time_local, zone)
    if start is None or end is None:
        return None
    return start, end


def _resolve_local_wall_time(
    day: date,
    clock: str,
    zone: ZoneInfo,
) -> datetime | None:
    naive = datetime.combine(day, parse_local_time(clock))
    aware = naive.replace(tzinfo=zone)
    round_trip = aware.astimezone(timezone.utc).astimezone(zone).replace(tzinfo=None)
    if round_trip != naive:
        return None
    return aware


def _validated_time_zone(value: object) -> ZoneInfo:
    if not isinstance(value, str) or _IANA_TIME_ZONE.fullmatch(value) is None:
        raise SchemaV4Error(f"invalid IANA timezone id: {value!r}")
    try:
        return ZoneInfo(value)
    except (ZoneInfoNotFoundError, ValueError) as exc:
        raise SchemaV4Error(f"unresolvable IANA timezone id: {value!r}") from exc


def migrate_v3_to_v4(
    connection: sqlite3.Connection,
    *,
    migration_hook: Callable[[sqlite3.Connection], None] | None = None,
) -> None:
    """Add Phase 3A tables and reminder semantics without rebuilding v3."""

    _require_active_transaction(connection)
    _require_foreign_keys(connection)
    version = int(connection.execute("PRAGMA user_version").fetchone()[0])
    if version != 3:
        raise SchemaV4Error(f"v3 to v4 migration requires user_version 3, got {version}")
    validate_v3_schema(connection)

    reserved = {"course_meetings", "exams"}.intersection(
        str(row[0])
        for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        )
    )
    if reserved:
        raise SchemaV4Error(
            "partial v4 tables prevent deterministic migration: "
            + ", ".join(sorted(reserved))
        )
    reminder_columns = {
        str(row[1]) for row in connection.execute("PRAGMA table_info(reminders)")
    }
    if "schedule_kind" in reminder_columns:
        raise SchemaV4Error("partial v4 reminder column prevents deterministic migration")

    # Snapshot every v3 reminder column before the upgrade and compare it after.
    # An additive migration cannot move a fixed trigger, so any drift is a bug
    # in this function rather than a legal v4 change.
    reminders_before = _reminder_snapshot(connection)

    connection.execute(
        "ALTER TABLE reminders ADD COLUMN schedule_kind TEXT NOT NULL "
        "DEFAULT 'fixed' CHECK(schedule_kind IN ('fixed','due_relative'))"
    )
    _execute_script_in_caller_transaction(connection, _v4_schema_sql())

    if _reminder_snapshot(connection) != reminders_before:
        raise SchemaV4Error("v3 to v4 migration changed existing reminder rows")
    migrated_kinds = [
        str(row[0])
        for row in connection.execute("SELECT DISTINCT schedule_kind FROM reminders")
    ]
    if any(kind != "fixed" for kind in migrated_kinds):
        raise SchemaV4Error("migrated v3 reminders must keep fixed-trigger semantics")

    if migration_hook is not None:
        migration_hook(connection)

    connection.execute(f"PRAGMA user_version = {DATABASE_VERSION}")
    validate_v4_schema(connection)


def _reminder_snapshot(connection: sqlite3.Connection) -> list[tuple[object, ...]]:
    """Every v3 reminder column, ordered, so the upgrade can prove it moved nothing."""

    return list(
        connection.execute(
            "SELECT id,uuid,assignment_id,trigger_at_utc,lead_minutes,repeat_rule,"
            "is_enabled,last_scheduled_at,created_at,updated_at,deleted_at "
            "FROM reminders ORDER BY id"
        )
    )


def _execute_script_in_caller_transaction(
    connection: sqlite3.Connection,
    script: str,
) -> None:
    """Execute a DDL script without sqlite3.executescript's implicit commit."""

    statement = ""
    for line in script.splitlines(keepends=True):
        statement += line
        if sqlite3.complete_statement(statement):
            if statement.strip():
                connection.execute(statement)
            statement = ""
    if statement.strip():
        raise SchemaV4Error("v4 schema script contains an incomplete statement")


def validate_v4_schema(connection: sqlite3.Connection) -> None:
    """Validate the additive v4 structure, data semantics, and integrity."""

    _require_foreign_keys(connection)
    version = int(connection.execute("PRAGMA user_version").fetchone()[0])
    if version != DATABASE_VERSION:
        raise SchemaV4Error(
            f"database user_version must be {DATABASE_VERSION}, got {version}"
        )

    required_columns = {
        "reminders": {"schedule_kind"},
        "course_meetings": {
            "id", "uuid", "course_id", "weekday", "start_time_local",
            "end_time_local", "location", "teacher_override", "timezone_id",
            "effective_start_date", "effective_end_date", "sort_order",
            "created_at", "updated_at", "deleted_at",
        },
        "exams": {
            "id", "uuid", "course_id", "name", "starts_at_local",
            "timezone_id", "location", "scope", "notes", "status",
            "linked_assignment_id", "created_at", "updated_at", "deleted_at",
        },
    }
    existing_tables = {
        str(row[0])
        for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        )
    }
    for table, expected in required_columns.items():
        if table not in existing_tables:
            raise SchemaV4Error(f"database v4 is missing table {table}")
        actual = {
            str(row[1]) for row in connection.execute(f"PRAGMA table_info({table})")
        }
        missing = expected.difference(actual)
        if missing:
            raise SchemaV4Error(
                f"database v4 table {table} is missing columns: "
                + ", ".join(sorted(missing))
            )

    required_objects = {
        "ux_course_meetings_uuid", "ix_course_meetings_week",
        "ix_course_meetings_deleted_at", "ux_exams_uuid",
        "ix_exams_course_start", "ix_exams_status_start",
        "ux_exams_linked_assignment", "ix_exams_deleted_at",
        "course_meetings_uuid_immutable", "exams_uuid_immutable",
    }
    actual_objects = {
        str(row[0])
        for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type IN ('index','trigger')"
        )
    }
    missing_objects = required_objects.difference(actual_objects)
    if missing_objects:
        raise SchemaV4Error(
            "database v4 is missing contract objects: "
            + ", ".join(sorted(missing_objects))
        )

    invalid = connection.execute(
        """
        SELECT 'reminder', id FROM reminders
        WHERE schedule_kind NOT IN ('fixed','due_relative')
           OR (schedule_kind='due_relative' AND lead_minutes < 0)
        UNION ALL
        SELECT 'meeting', id FROM course_meetings
        WHERE weekday NOT BETWEEN 1 AND 7
           OR start_time_local >= end_time_local
           OR sort_order < 0
           OR (effective_end_date IS NOT NULL
               AND effective_end_date < effective_start_date)
        UNION ALL
        SELECT 'exam', id FROM exams
        WHERE status NOT IN ('upcoming','completed','cancelled')
           OR length(trim(name)) = 0
        LIMIT 1
        """
    ).fetchone()
    if invalid is not None:
        raise SchemaV4Error(f"{invalid[0]} row {invalid[1]} violates v4 contract")

    for table in ("course_meetings", "exams"):
        for (value,) in connection.execute(f"SELECT uuid FROM {table}"):
            try:
                parsed = UUID(str(value))
            except ValueError as exc:
                raise SchemaV4Error(f"{table} contains invalid UUID") from exc
            if parsed.version != 4 or str(parsed) != str(value):
                raise SchemaV4Error(f"{table} UUID must be canonical version 4")

    for row in connection.execute(
        "SELECT start_time_local,end_time_local,timezone_id,effective_start_date,"
        "effective_end_date FROM course_meetings"
    ):
        meeting_times_overlap(row[0], row[1], row[0], row[1])
        _validate_timezone(row[2])
        _validate_local_date(row[3])
        if row[4] is not None:
            _validate_local_date(row[4])
    for starts_at, timezone_id in connection.execute(
        "SELECT starts_at_local,timezone_id FROM exams"
    ):
        _validate_local_datetime(starts_at)
        _validate_timezone(timezone_id)

    foreign_key_errors = connection.execute("PRAGMA foreign_key_check").fetchall()
    if foreign_key_errors:
        raise SchemaV4Error(f"database v4 foreign key check failed: {foreign_key_errors}")
    integrity = [str(row[0]) for row in connection.execute("PRAGMA integrity_check")]
    if integrity != ["ok"]:
        raise SchemaV4Error(f"database v4 integrity check failed: {integrity}")


def _validate_timezone(value: object) -> None:
    if not isinstance(value, str) or _IANA_TIME_ZONE.fullmatch(value) is None:
        raise SchemaV4Error(f"invalid IANA timezone id: {value!r}")


def _validate_local_date(value: object) -> None:
    if not isinstance(value, str) or _LOCAL_DATE.fullmatch(value) is None:
        raise SchemaV4Error(f"invalid local date: {value!r}")
    try:
        datetime.strptime(value, "%Y-%m-%d")
    except ValueError as exc:
        raise SchemaV4Error(f"invalid local date: {value!r}") from exc


def _validate_local_datetime(value: object) -> None:
    if not isinstance(value, str) or _LOCAL_DATE_TIME.fullmatch(value) is None:
        raise SchemaV4Error(f"invalid local date-time: {value!r}")
    try:
        datetime.strptime(value, "%Y-%m-%d %H:%M:%S")
    except ValueError as exc:
        raise SchemaV4Error(f"invalid local date-time: {value!r}") from exc


def _v4_schema_sql() -> str:
    """Phase 3A DDL. New entities reuse the v3 UUID-v4 and audit conventions."""

    uuid_check = _v3_uuid_check(allowed_versions=("4",))
    return f"""
CREATE TABLE course_meetings (
    id INTEGER NOT NULL PRIMARY KEY,
    uuid TEXT NOT NULL CHECK ({uuid_check}),
    course_id INTEGER NOT NULL REFERENCES courses(id) ON DELETE RESTRICT,
    weekday INTEGER NOT NULL CHECK(weekday BETWEEN 1 AND 7),
    start_time_local TEXT NOT NULL CHECK(
        length(start_time_local)=8 AND start_time_local GLOB '[0-2][0-9]:[0-5][0-9]:[0-5][0-9]'
    ),
    end_time_local TEXT NOT NULL CHECK(
        length(end_time_local)=8 AND end_time_local GLOB '[0-2][0-9]:[0-5][0-9]:[0-5][0-9]'
        AND start_time_local < end_time_local
    ),
    location TEXT,
    teacher_override TEXT,
    timezone_id TEXT NOT NULL CHECK(length(trim(timezone_id)) > 0),
    effective_start_date TEXT NOT NULL CHECK(length(effective_start_date)=10),
    effective_end_date TEXT CHECK(
        effective_end_date IS NULL OR
        (length(effective_end_date)=10 AND effective_end_date >= effective_start_date)
    ),
    sort_order INTEGER NOT NULL DEFAULT 0 CHECK(sort_order >= 0),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    deleted_at TEXT
);
CREATE UNIQUE INDEX ux_course_meetings_uuid ON course_meetings(uuid);
CREATE INDEX ix_course_meetings_week
    ON course_meetings(weekday,start_time_local,course_id);
CREATE INDEX ix_course_meetings_deleted_at ON course_meetings(deleted_at);

CREATE TABLE exams (
    id INTEGER NOT NULL PRIMARY KEY,
    uuid TEXT NOT NULL CHECK ({uuid_check}),
    course_id INTEGER NOT NULL REFERENCES courses(id) ON DELETE RESTRICT,
    name TEXT NOT NULL CHECK(length(trim(name)) > 0),
    starts_at_local TEXT NOT NULL CHECK(length(starts_at_local)=19),
    timezone_id TEXT NOT NULL CHECK(length(trim(timezone_id)) > 0),
    location TEXT,
    scope TEXT,
    notes TEXT,
    status TEXT NOT NULL DEFAULT 'upcoming'
        CHECK(status IN ('upcoming','completed','cancelled')),
    linked_assignment_id INTEGER REFERENCES assignments(id) ON DELETE SET NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    deleted_at TEXT
);
CREATE UNIQUE INDEX ux_exams_uuid ON exams(uuid);
CREATE INDEX ix_exams_course_start ON exams(course_id,starts_at_local);
CREATE INDEX ix_exams_status_start ON exams(status,starts_at_local);
CREATE UNIQUE INDEX ux_exams_linked_assignment ON exams(linked_assignment_id)
    WHERE linked_assignment_id IS NOT NULL;
CREATE INDEX ix_exams_deleted_at ON exams(deleted_at);

CREATE TRIGGER course_meetings_uuid_immutable
BEFORE UPDATE OF uuid ON course_meetings
WHEN NEW.uuid IS NOT OLD.uuid
BEGIN
    SELECT RAISE(ABORT, 'course meeting UUID is immutable');
END;
CREATE TRIGGER exams_uuid_immutable
BEFORE UPDATE OF uuid ON exams
WHEN NEW.uuid IS NOT OLD.uuid
BEGIN
    SELECT RAISE(ABORT, 'exam UUID is immutable');
END;
"""
