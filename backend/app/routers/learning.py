"""Phase 3A endpoints backed by the shared v4 tables and rules."""
from __future__ import annotations

from datetime import date, datetime, timedelta, timezone
from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Path, Query, Response
from fastapi.exceptions import RequestValidationError
from pydantic import BaseModel, ValidationError
from sqlalchemy import text
from sqlalchemy.orm import Session

from shared.schema_v3 import new_v3_uuid
from shared.schema_v4 import SchemaV4Error, _validated_time_zone, meeting_occurs_on, parse_local_date

from .. import learning_schemas as wire
from .. import models
from ..database import get_db
from ..services import learning
from ..services.task_state import canonical_utc_now

router = APIRouter(tags=["learning scenes"])
SceneID = Annotated[int, Path(ge=1)]


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _day(value: str | None) -> date | None:
    if value is None:
        return None
    try:
        return parse_local_date(value)
    except SchemaV4Error as exc:
        raise HTTPException(422, "Date must use a valid YYYY-MM-DD value") from exc


def _zone(value: str) -> str:
    try:
        _validated_time_zone(value)
    except SchemaV4Error as exc:
        raise HTTPException(422, "timezone_id must identify an installed IANA timezone") from exc
    return value


def _merged_values(row: dict[str, Any], patch: BaseModel, create_type: type[BaseModel]) -> dict[str, Any]:
    values = {name: row[name] for name in create_type.model_fields}
    values.update(patch.model_dump(exclude_unset=True))
    try:
        return create_type.model_validate(values).model_dump()
    except ValidationError as exc:
        errors = [{**error, "loc": ("body", *error["loc"])} for error in exc.errors()]
        raise RequestValidationError(errors) from exc


def _insert(db: Session, table: str, values: dict[str, Any]) -> int:
    # table and keys originate exclusively in this module and validated schemas.
    columns = ",".join(values)
    placeholders = ",".join(f":{name}" for name in values)
    result = db.execute(text(f"INSERT INTO {table} ({columns}) VALUES ({placeholders})"), values)
    return result.lastrowid


def _update(db: Session, table: str, scene_id: int, values: dict[str, Any]) -> None:
    columns = ",".join(f"{name}=:{name}" for name in values)
    db.execute(text(f"UPDATE {table} SET {columns} WHERE id=:scene_id"), {**values, "scene_id": scene_id})


def _one_meeting(db: Session, scene_id: int, *, include_deleted: bool = False) -> dict[str, Any]:
    row = learning.scene_or_404(db, "course_meetings", scene_id, include_deleted=include_deleted)
    return learning.meeting_responses(db, [row])[0]


@router.post("/course-meetings", response_model=wire.MeetingRead, status_code=201)
def create_meeting(payload: wire.MeetingCreate, db: Session = Depends(get_db)) -> dict[str, Any]:
    with learning.write_transaction(db):
        learning.course_or_404(db, payload.course_id)
        scene_id = _insert(db, "course_meetings", {**payload.model_dump(), "uuid": new_v3_uuid()})
    return _one_meeting(db, scene_id)


@router.get("/course-meetings", response_model=list[wire.MeetingRead])
def list_meetings(
    course_id: int | None = Query(default=None, ge=1),
    weekday: int | None = Query(default=None, ge=1, le=7),
    week_start: str | None = None,
    on_date: str | None = None,
    current_week: bool = False,
    timezone_id: str = "UTC",
    include_deleted: bool = False,
    db: Session = Depends(get_db),
) -> list[dict[str, Any]]:
    """on_date uses the viewer timezone; week_start uses stored ISO weekdays."""
    zone = _validated_time_zone(_zone(timezone_id))
    if sum((week_start is not None, on_date is not None, current_week)) > 1:
        raise HTTPException(422, "Choose only one of week_start, on_date, or current_week")
    days = None
    selected_day = _day(on_date)
    if week_start is not None or current_week:
        anchor = _day(week_start) if week_start is not None else _now().astimezone(zone).date()
        monday = anchor - timedelta(days=anchor.weekday())
        days = [monday + timedelta(days=offset) for offset in range(7)]
    clauses = []
    params = {}
    if not include_deleted:
        clauses.append("s.deleted_at IS NULL")
    if course_id is not None:
        clauses.append("s.course_id=:course_id")
        params["course_id"] = course_id
    if weekday is not None:
        clauses.append("s.weekday=:weekday")
        params["weekday"] = weekday
    where = " WHERE " + " AND ".join(clauses) if clauses else ""
    rows = [dict(row) for row in db.execute(text(
        "SELECT s.*,c.name AS course_name FROM course_meetings s JOIN courses c ON c.id=s.course_id"
        + where + " ORDER BY s.weekday,s.start_time_local,s.sort_order,s.id"
    ), params).mappings()]
    if selected_day is not None:
        return learning.meetings_for_viewer_day(db, rows, selected_day, timezone_id)
    if days is not None:
        rows = [row for row in rows if any(meeting_occurs_on(learning.meeting_window(row), day.isoformat()) for day in days)]
    return learning.meeting_responses(db, rows, days)


@router.get("/course-meetings/{scene_id}", response_model=wire.MeetingRead)
def get_meeting(scene_id: SceneID, include_deleted: bool = False, db: Session = Depends(get_db)) -> dict[str, Any]:
    return _one_meeting(db, scene_id, include_deleted=include_deleted)


@router.patch("/course-meetings/{scene_id}", response_model=wire.MeetingRead)
def update_meeting(scene_id: SceneID, payload: wire.MeetingUpdate, db: Session = Depends(get_db)) -> dict[str, Any]:
    with learning.write_transaction(db):
        row = learning.scene_or_404(db, "course_meetings", scene_id)
        values = _merged_values(row, payload, wire.MeetingCreate)
        learning.course_or_404(db, values["course_id"])
        _update(db, "course_meetings", scene_id, {**values, "updated_at": canonical_utc_now()})
    return _one_meeting(db, scene_id)


@router.delete("/course-meetings/{scene_id}", status_code=204)
def delete_meeting(scene_id: SceneID, db: Session = Depends(get_db)) -> Response:
    with learning.write_transaction(db):
        learning.scene_or_404(db, "course_meetings", scene_id)
        stamp = canonical_utc_now()
        _update(db, "course_meetings", scene_id, {"deleted_at": stamp, "updated_at": stamp})
    return Response(status_code=204)


@router.post("/course-meetings/{scene_id}/restore", response_model=wire.MeetingRead)
def restore_meeting(scene_id: SceneID, db: Session = Depends(get_db)) -> dict[str, Any]:
    with learning.write_transaction(db):
        row = learning.scene_or_404(db, "course_meetings", scene_id, include_deleted=True)
        learning.course_or_404(db, row["course_id"])
        _update(db, "course_meetings", scene_id, {"deleted_at": None, "updated_at": canonical_utc_now()})
    return _one_meeting(db, scene_id)


@router.post("/exams", response_model=wire.ExamRead, status_code=201)
def create_exam(payload: wire.ExamCreate, db: Session = Depends(get_db)) -> dict[str, Any]:
    with learning.write_transaction(db):
        learning.course_or_404(db, payload.course_id)
        scene_id = _insert(db, "exams", {**payload.model_dump(), "uuid": new_v3_uuid()})
    return learning.exam_response(learning.scene_or_404(db, "exams", scene_id))


@router.get("/exams", response_model=list[wire.ExamRead])
def list_exams(
    course_id: int | None = Query(default=None, ge=1),
    status: wire.ExamStatus | None = None,
    include_deleted: bool = False,
    db: Session = Depends(get_db),
) -> list[dict[str, Any]]:
    clauses = []
    params = {}
    if not include_deleted:
        clauses.append("e.deleted_at IS NULL")
    if course_id is not None:
        clauses.append("e.course_id=:course_id")
        params["course_id"] = course_id
    if status is not None:
        clauses.append("e.status=:status")
        params["status"] = status
    where = " WHERE " + " AND ".join(clauses) if clauses else ""
    rows = [dict(row) for row in db.execute(text(
        "SELECT e.*,c.name AS course_name FROM exams e JOIN courses c ON c.id=e.course_id" + where
    ), params).mappings()]
    return [learning.exam_response(row) for row in learning.sort_exams(rows)]


@router.get("/exams/{scene_id}", response_model=wire.ExamRead)
def get_exam(scene_id: SceneID, include_deleted: bool = False, db: Session = Depends(get_db)) -> dict[str, Any]:
    return learning.exam_response(learning.scene_or_404(db, "exams", scene_id, include_deleted=include_deleted))


@router.patch("/exams/{scene_id}", response_model=wire.ExamRead)
def update_exam(scene_id: SceneID, payload: wire.ExamUpdate, db: Session = Depends(get_db)) -> dict[str, Any]:
    with learning.write_transaction(db):
        row = learning.scene_or_404(db, "exams", scene_id)
        values = _merged_values(row, payload, wire.ExamCreate)
        learning.course_or_404(db, values["course_id"])
        _update(db, "exams", scene_id, {**values, "updated_at": canonical_utc_now()})
    return learning.exam_response(learning.scene_or_404(db, "exams", scene_id))


@router.delete("/exams/{scene_id}", status_code=204)
def delete_exam(scene_id: SceneID, db: Session = Depends(get_db)) -> Response:
    with learning.write_transaction(db):
        learning.scene_or_404(db, "exams", scene_id)
        stamp = canonical_utc_now()
        _update(db, "exams", scene_id, {"deleted_at": stamp, "updated_at": stamp})
    return Response(status_code=204)


@router.post("/exams/{scene_id}/restore", response_model=wire.ExamRead)
def restore_exam(scene_id: SceneID, db: Session = Depends(get_db)) -> dict[str, Any]:
    with learning.write_transaction(db):
        row = learning.scene_or_404(db, "exams", scene_id, include_deleted=True)
        learning.course_or_404(db, row["course_id"])
        _update(db, "exams", scene_id, {"deleted_at": None, "updated_at": canonical_utc_now()})
    return learning.exam_response(learning.scene_or_404(db, "exams", scene_id))


@router.post("/exams/{scene_id}/review-task", response_model=wire.ReviewTaskRead)
def create_review_task(scene_id: SceneID, db: Session = Depends(get_db)) -> dict[str, Any]:
    with learning.write_transaction(db):
        exam = learning.scene_or_404(db, "exams", scene_id)
        created = exam["linked_assignment_id"] is None
        if created:
            course = learning.course_or_404(db, exam["course_id"])
            instant = learning.resolve_wall_instant(exam["starts_at_local"], exam["timezone_id"])
            if instant is None:
                raise HTTPException(422, "Exam local time does not exist because of daylight saving; edit it before creating a review task")
            due = (instant - timedelta(days=1)).astimezone(_validated_time_zone(exam["timezone_id"])).replace(tzinfo=None)
            assignment = models.Assignment(
                course_id=course.id, course_name=course.name,
                title=("Review: " + exam["name"])[:255],
                description="Linked to an exam.", due_date=due,
                status="todo", priority="high", timezone_id=exam["timezone_id"],
            )
            db.add(assignment)
            db.flush()
            _update(db, "exams", scene_id, {"linked_assignment_id": assignment.id, "updated_at": canonical_utc_now()})
        else:
            assignment = db.get(models.Assignment, exam["linked_assignment_id"])
            if assignment is None:
                raise HTTPException(409, "The linked review task is unavailable")
        assignment_values = learning.task_response(assignment)
        exam_values = learning.exam_response(learning.scene_or_404(db, "exams", scene_id))
    return {"exam": exam_values, "assignment": assignment_values, "created": created}


@router.get("/overview/today", response_model=wire.TodayRead)
def today_overview(
    timezone_id: str = "UTC",
    on_date: str | None = None,
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    return learning.today_overview(db, _zone(timezone_id), now=_now(), selected_date=_day(on_date))
