from __future__ import annotations

from datetime import date, datetime, timedelta
from typing import Any


STATUS_VALUES = ["todo", "in_progress", "done"]
STATUS_LABELS = {
    "not_started": "Not started",
    "in_progress": "In progress",
    "completed": "Completed",
    "todo": "To do",
    "done": "Done",
    "ignored": "Ignored",
}
STATUS_COLORS = {
    "not_started": "#6b7280",
    "in_progress": "#2563eb",
    "completed": "#15803d",
    "todo": "#6b7280",
    "done": "#15803d",
    "ignored": "#9ca3af",
}


def parse_due_datetime(value: Any) -> datetime | None:
    if value is None:
        return None

    if isinstance(value, datetime):
        return value

    text = str(value).strip()
    if not text:
        return None

    for date_format in (
        "%Y-%m-%d %H:%M",
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%dT%H:%M",
        "%Y-%m-%dT%H:%M:%S",
    ):
        try:
            return datetime.strptime(text, date_format)
        except ValueError:
            pass

    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None


def format_due_date(value: Any) -> str:
    due_at = parse_due_datetime(value)
    if due_at is None:
        return "No due date"
    return due_at.strftime("%Y-%m-%d %H:%M")


def due_date_text(value: Any) -> str:
    due_at = parse_due_datetime(value)
    if due_at is None:
        return "No due date"

    days_until_due = (due_at.date() - date.today()).days

    if days_until_due == 0:
        return "Due today"
    if days_until_due == 1:
        return "Due tomorrow"
    if days_until_due > 1:
        return f"Due in {days_until_due} days"
    if days_until_due == -1:
        return "Overdue by 1 day"
    return f"Overdue by {abs(days_until_due)} days"


def display_status(status: Any) -> str:
    return STATUS_LABELS.get(str(status), str(status).replace("_", " ").title())


def status_color(status: Any) -> str:
    return STATUS_COLORS.get(str(status), "#6b7280")


def source_text(assignment: dict[str, Any]) -> str:
    return (
        clean_text(assignment.get("source_name"))
        or clean_text(assignment.get("link"))
        or clean_text(assignment.get("source_file"))
        or clean_text(assignment.get("source_url"))
        or "None"
    )


def clean_text(value: Any) -> str:
    if value is None:
        return ""
    return str(value).strip()


def assignment_matches_search(assignment: dict[str, Any], search_text: str) -> bool:
    if not search_text:
        return True

    haystack = " ".join(
        clean_text(assignment.get(field_name))
        for field_name in (
            "course_name",
            "title",
            "description",
            "source_name",
            "source_type",
            "source_file",
            "link",
            "source_url",
        )
    ).lower()
    return search_text.lower() in haystack


def sort_assignments_by_due_date(assignments: list[dict[str, Any]]) -> list[dict[str, Any]]:
    def sort_key(assignment: dict[str, Any]) -> tuple[int, datetime]:
        due_at = parse_due_datetime(assignment.get("due_date"))
        if due_at is None:
            return (1, datetime.max)
        return (0, due_at.replace(tzinfo=None))

    return sorted(assignments, key=sort_key)


def build_summary(assignments: list[dict[str, Any]]) -> dict[str, int]:
    today = date.today()
    week_end = today + timedelta(days=7)

    completed = 0
    overdue = 0
    due_today = 0
    due_this_week = 0

    for assignment in assignments:
        status = clean_text(assignment.get("status"))
        is_completed = status in {"completed", "done"}
        due_at = parse_due_datetime(assignment.get("due_date"))

        if is_completed:
            completed += 1

        if due_at is None:
            continue

        due_day = due_at.date()
        if not is_completed and due_day < today:
            overdue += 1
        if due_day == today:
            due_today += 1
        if not is_completed and today <= due_day <= week_end:
            due_this_week += 1

    total = len(assignments)
    return {
        "total": total,
        "incomplete": total - completed,
        "completed": completed,
        "overdue": overdue,
        "due_today": due_today,
        "due_this_week": due_this_week,
    }
