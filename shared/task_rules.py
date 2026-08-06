from __future__ import annotations

from copy import deepcopy
from datetime import datetime, time, timedelta
from typing import Any, Iterable, Literal, Mapping


TaskStatus = Literal["todo", "in_progress", "done"]
TaskPriority = Literal["low", "medium", "high"]
TaskView = Literal["all", "today", "week", "overdue", "completed"]
DisplayMode = Literal["simple", "professional"]

STATUSES: tuple[TaskStatus, ...] = ("todo", "in_progress", "done")
PRIORITIES: tuple[TaskPriority, ...] = ("low", "medium", "high")
STATUS_TO_DATABASE = {
    "todo": "not_started",
    "in_progress": "in_progress",
    "done": "completed",
}
STATUS_FROM_DATABASE = {
    "not_started": "todo",
    "todo": "todo",
    "in_progress": "in_progress",
    "completed": "done",
    "done": "done",
}
PRIORITY_ORDER = {"high": 0, "medium": 1, "low": 2}

SIMPLE_FIELDS = ("title", "course_name", "due_date", "status")
PROFESSIONAL_FIELDS = SIMPLE_FIELDS + ("description", "priority", "link")


def normalize_status(value: object) -> TaskStatus:
    if not isinstance(value, str):
        raise ValueError("status must be a string")
    try:
        return STATUS_FROM_DATABASE[value.strip().lower()]  # type: ignore[return-value]
    except KeyError as exc:
        raise ValueError(f"unsupported status: {value!r}") from exc


def database_status(value: object) -> str:
    return STATUS_TO_DATABASE[normalize_status(value)]


def normalize_priority(value: object) -> TaskPriority:
    if not isinstance(value, str):
        raise ValueError("priority must be a string")
    cleaned = value.strip().lower()
    if cleaned not in PRIORITIES:
        raise ValueError(f"unsupported priority: {value!r}")
    return cleaned  # type: ignore[return-value]


def parse_local_wall_time(value: object) -> datetime | None:
    """Parse a timezone-free local wall time used by both desktop clients."""

    if value is None or value == "":
        return None
    if isinstance(value, datetime):
        parsed = value
    elif isinstance(value, str):
        parsed = datetime.fromisoformat(value.strip().replace(" ", "T"))
    else:
        raise ValueError("due_date must be a datetime, ISO local string, or null")

    if parsed.tzinfo is not None and parsed.utcoffset() is not None:
        raise ValueError("due_date must not contain a timezone or UTC offset")
    return parsed


def day_bounds(now: datetime) -> tuple[datetime, datetime]:
    local_now = _require_local_wall_time(now)
    start = datetime.combine(local_now.date(), time.min)
    return start, start + timedelta(days=1)


def week_bounds(now: datetime) -> tuple[datetime, datetime]:
    """Return the Monday-based natural week as a half-open interval."""

    day_start, _ = day_bounds(now)
    start = day_start - timedelta(days=day_start.weekday())
    return start, start + timedelta(days=7)


def matches_view(
    task: Mapping[str, Any],
    view: TaskView,
    *,
    now: datetime,
) -> bool:
    status = normalize_status(task.get("status", "todo"))
    if view == "all":
        return True
    if view == "completed":
        return status == "done"

    due = parse_local_wall_time(task.get("due_date"))
    if due is None:
        return False
    if view == "today":
        start, end = day_bounds(now)
        return start <= due < end
    if view == "week":
        start, end = week_bounds(now)
        return start <= due < end
    if view == "overdue":
        return status != "done" and due < _require_local_wall_time(now)
    raise ValueError(f"unsupported view: {view!r}")


def search_tasks(
    tasks: Iterable[Mapping[str, Any]],
    query: str,
) -> list[Mapping[str, Any]]:
    needle = query.strip().casefold()
    if not needle:
        return list(tasks)
    fields = ("title", "course_name", "description")
    return [
        task
        for task in tasks
        if any(needle in str(task.get(field) or "").casefold() for field in fields)
    ]


def filter_tasks(
    tasks: Iterable[Mapping[str, Any]],
    *,
    status: str | None = None,
    course_name: str | None = None,
    priority: str | None = None,
) -> list[Mapping[str, Any]]:
    expected_status = normalize_status(status) if status is not None else None
    expected_course = course_name.strip().casefold() if course_name else None
    expected_priority = normalize_priority(priority) if priority is not None else None

    result: list[Mapping[str, Any]] = []
    for task in tasks:
        if (
            expected_status is not None
            and normalize_status(task.get("status", "todo")) != expected_status
        ):
            continue
        if (
            expected_course is not None
            and str(task.get("course_name") or "").strip().casefold()
            != expected_course
        ):
            continue
        if (
            expected_priority is not None
            and normalize_priority(task.get("priority", "medium"))
            != expected_priority
        ):
            continue
        result.append(task)
    return result


def sort_tasks(
    tasks: Iterable[Mapping[str, Any]],
    *,
    by: Literal["due_date", "priority"],
) -> list[Mapping[str, Any]]:
    def due_key(task: Mapping[str, Any]) -> tuple[bool, datetime, str]:
        due = parse_local_wall_time(task.get("due_date"))
        return (
            due is None,
            due or datetime.max,
            str(task.get("title") or "").casefold(),
        )

    if by == "due_date":
        return sorted(tasks, key=due_key)
    if by == "priority":
        return sorted(
            tasks,
            key=lambda task: (
                PRIORITY_ORDER[normalize_priority(task.get("priority", "medium"))],
                *due_key(task),
            ),
        )
    raise ValueError(f"unsupported sort: {by!r}")


def project_for_mode(
    task: Mapping[str, Any],
    mode: DisplayMode,
) -> dict[str, Any]:
    """Create a display projection without mutating or clearing hidden fields."""

    if mode == "simple":
        fields = SIMPLE_FIELDS
    elif mode == "professional":
        fields = PROFESSIONAL_FIELDS
    else:
        raise ValueError(f"unsupported display mode: {mode!r}")
    return {field: deepcopy(task.get(field)) for field in fields}


def _require_local_wall_time(value: datetime) -> datetime:
    if value.tzinfo is not None and value.utcoffset() is not None:
        raise ValueError("now must be a local wall time without a timezone")
    return value

