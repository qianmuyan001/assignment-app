"""Shared-rule adapters for course meetings, exams, and the Today overview."""
from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import fields
from datetime import date, datetime, time, timedelta, timezone
from typing import Any
from zoneinfo import ZoneInfo

from fastapi import HTTPException
from sqlalchemy import select, text
from sqlalchemy.exc import IntegrityError, OperationalError
from sqlalchemy.orm import Session

from shared.schema_v4 import (
    MeetingWindow,
    _resolve_local_wall_time,
    exam_sort_key,
    meeting_occurs_on,
    meetings_overlap,
    resolve_meeting_interval,
)

from .. import models, schemas
from .reminder_schedule import resolved_deadline


@contextmanager
def write_transaction(db: Session) -> Iterator[None]:
    """Serialize the read/modify/write transaction, including review-task creation."""
    try:
        db.execute(text("BEGIN IMMEDIATE"))
        yield
        db.commit()
    except IntegrityError as exc:
        db.rollback()
        raise HTTPException(409, "Learning scene conflicts with the stored data") from exc
    except OperationalError as exc:
        db.rollback()
        if "locked" in str(exc.orig).lower() or "busy" in str(exc.orig).lower():
            raise HTTPException(409, "Database is busy; retry this operation") from exc
        raise
    except Exception:
        db.rollback()
        raise


def utc_text(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def resolve_wall_instant(value: str | datetime, zone_name: str) -> datetime | None:
    """Use the v4 gap/first-fold resolver, retaining legacy subsecond precision."""
    wall = datetime.fromisoformat(value) if isinstance(value, str) else value
    resolved = _resolve_local_wall_time(wall.date(), wall.strftime("%H:%M:%S"), ZoneInfo(zone_name))
    if resolved is None:
        return None
    return resolved.replace(microsecond=wall.microsecond).astimezone(timezone.utc)


def meeting_window(row: dict[str, Any]) -> MeetingWindow:
    return MeetingWindow(**{field.name: row[field.name] for field in fields(MeetingWindow)})


def course_or_404(db: Session, course_id: int) -> models.Course:
    course = db.scalar(select(models.Course).where(
        models.Course.id == course_id, models.Course.deleted_at.is_(None),
    ))
    if course is None:
        raise HTTPException(404, "Course not found")
    return course


def scene_or_404(db: Session, table: str, scene_id: int, *, include_deleted: bool = False) -> dict[str, Any]:
    if table not in {"course_meetings", "exams"}:
        raise ValueError("Unsupported learning table")
    suffix = "" if include_deleted else " AND s.deleted_at IS NULL"
    row = db.execute(text(
        f"SELECT s.*,c.name AS course_name FROM {table} s "
        f"JOIN courses c ON c.id=s.course_id WHERE s.id=:id{suffix}"
    ), {"id": scene_id}).mappings().first()
    if row is None:
        raise HTTPException(404, "Course meeting not found" if table == "course_meetings" else "Exam not found")
    return dict(row)


def meeting_responses(db: Session, rows: list[dict[str, Any]], days: list[date] | None = None) -> list[dict[str, Any]]:
    """Warnings inspect every active meeting, even when the response is filtered."""
    active = [dict(row) for row in db.execute(text(
        "SELECT * FROM course_meetings WHERE deleted_at IS NULL"
    )).mappings()]
    windows = [(row["id"], meeting_window(row)) for row in active]
    result = []
    for row in rows:
        window = meeting_window(row)
        warnings = []
        occurrences = []
        if row["deleted_at"] is None:
            for other_id, other_window in windows:
                if other_id != row["id"] and meetings_overlap(window, other_window):
                    warnings.append({"code": "overlap", "message": "This meeting overlaps another course meeting.", "related_id": other_id})
        for day in days or []:
            if not meeting_occurs_on(window, day.isoformat()):
                continue
            interval = resolve_meeting_interval(window, day.isoformat())
            occurrences.append({
                "date": day.isoformat(),
                "starts_at_utc": utc_text(interval[0]) if interval else None,
                "ends_at_utc": utc_text(interval[1]) if interval else None,
            })
            if interval is None:
                warnings.append({"code": "nonexistent_local_time", "message": "A daylight-saving change skips this meeting's local time; no occurrence is scheduled.", "on_date": day.isoformat()})
        result.append({**row, "warnings": warnings, "occurrences": occurrences})
    return result


def exam_response(row: dict[str, Any]) -> dict[str, Any]:
    instant = resolve_wall_instant(row["starts_at_local"], row["timezone_id"])
    warnings = [] if instant else [{"code": "nonexistent_local_time", "message": "A daylight-saving change skips this exam's local time. Edit the time before creating a review task."}]
    return {**row, "starts_at_utc": utc_text(instant) if instant else None, "warnings": warnings}


def sort_exams(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(rows, key=lambda row: (
        *exam_sort_key(row["status"], resolve_wall_instant(row["starts_at_local"], row["timezone_id"]) or datetime.max.replace(tzinfo=timezone.utc)), row["id"],
    ))


def task_response(assignment: models.Assignment) -> dict[str, Any]:
    return {
        **schemas.AssignmentRead.model_validate(assignment).model_dump(mode="json"),
        "deleted_at": assignment.deleted_at,
    }


def meetings_for_viewer_day(
    db: Session, meetings: list[dict[str, Any]], day: date, zone_name: str,
) -> list[dict[str, Any]]:
    """Resolve recurrence dates into the viewer's half-open calendar day.

    Returned occurrence.date remains the stored meeting timezone's date. Week
    views continue to use stored ISO weekdays and their declared local dates.
    """
    zone = ZoneInfo(zone_name)
    start = datetime.combine(day, time.min, zone).astimezone(timezone.utc)
    end = datetime.combine(day + timedelta(days=1), time.min, zone).astimezone(timezone.utc)
    # Meeting dates belong to their declared timezone, while the selected Today
    # interval belongs to the viewer. Inspect adjacent local dates across zones.
    occurring = []
    for meeting in meetings:
        window = meeting_window(meeting)
        meeting_zone = ZoneInfo(meeting["timezone_id"])
        local_first = start.astimezone(meeting_zone).date()
        local_last = (end - timedelta(microseconds=1)).astimezone(meeting_zone).date()
        days = [local_first + timedelta(days=offset) for offset in range((local_last - local_first).days + 1)]
        response = meeting_responses(db, [meeting], days)[0]
        relevant = []
        for occurrence in response["occurrences"]:
            if occurrence["starts_at_utc"] is None:
                # A nonexistent wall time remains visible with its warning.
                relevant.append(occurrence)
            elif start <= datetime.fromisoformat(occurrence["starts_at_utc"]) < end:
                relevant.append(occurrence)
        if relevant:
            response["occurrences"] = relevant
            occurring.append(response)
    occurring.sort(key=lambda row: (row["occurrences"][0]["starts_at_utc"] or "~", row["id"]))
    return occurring


def today_overview(db: Session, zone_name: str, *, now: datetime, selected_date: date | None = None) -> dict[str, Any]:
    zone = ZoneInfo(zone_name)
    day = selected_date or now.astimezone(zone).date()
    start = datetime.combine(day, time.min, zone).astimezone(timezone.utc)
    end = datetime.combine(day + timedelta(days=1), time.min, zone).astimezone(timezone.utc)
    horizon = datetime.combine(day + timedelta(days=14), time.min, zone).astimezone(timezone.utc)
    meetings = [dict(row) for row in db.execute(text(
        "SELECT s.*,c.name AS course_name FROM course_meetings s "
        "JOIN courses c ON c.id=s.course_id WHERE s.deleted_at IS NULL "
        "ORDER BY s.start_time_local,s.sort_order,s.id"
    )).mappings()]
    occurring = meetings_for_viewer_day(db, meetings, day, zone_name)
    warnings = [warning for meeting in occurring for warning in meeting["warnings"]
                if warning["code"] == "nonexistent_local_time"]
    exams = []
    exam_rows = [dict(row) for row in db.execute(text(
        "SELECT e.*,c.name AS course_name FROM exams e JOIN courses c ON c.id=e.course_id "
        "WHERE e.deleted_at IS NULL AND e.status='upcoming'"
    )).mappings()]
    for exam in sort_exams(exam_rows):
        instant = resolve_wall_instant(exam["starts_at_local"], exam["timezone_id"])
        if instant is None:
            warnings.extend(exam_response(exam)["warnings"])
        elif start <= instant <= horizon:
            exams.append(exam_response(exam))
    due_today = []
    overdue = []
    tasks = db.scalars(select(models.Assignment).where(
        models.Assignment.deleted_at.is_(None), models.Assignment.due_date.is_not(None),
    )).all()
    resolved_tasks = []
    for assignment in tasks:
        instant = resolved_deadline(assignment)
        if instant is None:
            warnings.append({"code": "unresolvable_task_deadline", "message": "A daylight-saving change skips a task deadline; edit its local time.", "related_id": assignment.id})
        else:
            resolved_tasks.append((instant, assignment))
    for instant, assignment in sorted(resolved_tasks, key=lambda item: (item[0], item[1].id)):
        values = {**task_response(assignment), "due_at_utc": utc_text(instant)}
        if start <= instant < end:
            due_today.append(values)
        if assignment.status != "done" and instant < now:
            overdue.append(values)
    return {"date": day.isoformat(), "timezone_id": zone_name, "meetings": occurring, "upcoming_exams": exams, "due_today": due_today, "overdue": overdue, "warnings": warnings}
