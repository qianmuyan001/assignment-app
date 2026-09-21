"""The v4 reminder cache, using the shared due-relative rule."""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Protocol
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from sqlalchemy import select
from sqlalchemy.orm import Session

from shared.schema_v4 import SchemaV4Error, relative_reminder_trigger

from .. import models


class DeadlineFields(Protocol):
    """Fields shared by database tasks and read-only API projections."""
    due_date: datetime | None
    timezone_id: str | None


def resolved_deadline(assignment: DeadlineFields) -> datetime | None:
    """Resolve stored local wall time with the task zone or server device zone.

    A repeated wall time uses its first occurrence; missing daylight-saving
    wall times have no instant. The null-zone fallback follows the OS zone at
    the deadline's date, rather than reusing today's UTC offset.
    """
    wall = assignment.due_date
    if wall is None:
        return None
    try:
        if assignment.timezone_id:
            aware = wall.replace(tzinfo=ZoneInfo(assignment.timezone_id), fold=0)
            round_trip = aware.astimezone(timezone.utc).astimezone(aware.tzinfo)
        else:
            aware = wall.replace(fold=0).astimezone()
            round_trip = aware.astimezone(timezone.utc).astimezone()
        if round_trip.replace(tzinfo=None) != wall:
            return None
        return aware.astimezone(timezone.utc)
    except (OverflowError, ValueError, ZoneInfoNotFoundError) as exc:
        raise SchemaV4Error("due date cannot be resolved in its time zone within supported dates") from exc


def relative_trigger(assignment: models.Assignment, lead_minutes: int) -> str:
    if assignment.due_date is None:
        raise SchemaV4Error("due-relative reminders require a due date")
    deadline = resolved_deadline(assignment)
    if deadline is None:
        raise SchemaV4Error("due date is a missing daylight-saving wall time")
    try:
        trigger = relative_reminder_trigger(deadline, lead_minutes)
    except OverflowError as exc:
        raise SchemaV4Error("lead_minutes places the reminder outside supported dates") from exc
    return trigger.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def disabled_reason(
    reminder: models.Reminder,
    assignment: models.Assignment,
) -> str | None:
    if reminder.schedule_kind == "due_relative":
        if assignment.due_date is None:
            return "missing_due_date"
        try:
            if resolved_deadline(assignment) is None:
                return "nonexistent_due_time"
        except SchemaV4Error:
            return "unresolvable_due_time"
    if assignment.deleted_at is not None:
        return "task_deleted"
    if assignment.status == "done":
        return "task_completed"
    if not reminder.is_enabled:
        return "disabled_by_user"
    return None


def decorate_reminder(
    reminder: models.Reminder,
    assignment: models.Assignment,
) -> models.Reminder:
    # Response-only annotation: the schema does not invent another persisted
    # field that would diverge from Apple or the shared SQLite contract.
    reminder.disabled_reason = disabled_reason(reminder, assignment)
    return reminder


def refresh_relative_reminders(db: Session, assignment: models.Assignment) -> None:
    """Recompute active relative caches, retaining disabled user preferences."""
    reminders = db.scalars(
        select(models.Reminder).where(
            models.Reminder.assignment_id == assignment.id,
            models.Reminder.schedule_kind == "due_relative",
            models.Reminder.deleted_at.is_(None),
        )
    ).all()
    now = datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    deadline = resolved_deadline(assignment)
    for reminder in reminders:
        changed = False
        if deadline is None:
            changed = reminder.is_enabled or reminder.last_scheduled_at is not None
            reminder.is_enabled = False
            reminder.last_scheduled_at = None
        else:
            trigger = relative_trigger(assignment, reminder.lead_minutes)
            if trigger != reminder.trigger_at_utc:
                reminder.trigger_at_utc = trigger
                reminder.last_scheduled_at = None
                changed = True
        if changed:
            reminder.updated_at = now
