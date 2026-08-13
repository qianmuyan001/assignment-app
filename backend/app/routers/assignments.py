from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy import or_, select, update
from sqlalchemy.orm import Session

from shared.schema_v3 import canonical_name, new_v3_uuid

from .. import models, repositories, schemas
from ..database import get_db
from ..services.task_state import (
    TaskStateConflict,
    canonical_utc_now,
    update_assignment_state,
)


router = APIRouter(prefix="/assignments", tags=["assignments"])


def utc_now() -> str:
    return canonical_utc_now()


def get_assignment_or_404(db: Session, assignment_id: int) -> models.Assignment:
    assignment = repositories.get_active_assignment(db, assignment_id)
    if assignment is None:
        raise HTTPException(status_code=404, detail="Assignment not found")
    return assignment


def _active_course_or_404(db: Session, course_id: int) -> models.Course:
    course = repositories.get_active_course(db, course_id)
    if course is None:
        raise HTTPException(status_code=404, detail="Course not found")
    return course


def _active_project_or_404(db: Session, project_id: int) -> models.Project:
    project = repositories.get_active_project(db, project_id)
    if project is None:
        raise HTTPException(status_code=404, detail="Project not found")
    return project


def _find_or_create_course(db: Session, name: str) -> models.Course:
    course = db.scalar(
        select(models.Course)
        .where(
            models.Course.name == name,
            models.Course.deleted_at.is_(None),
        )
        .order_by(models.Course.id)
    )
    if course is not None:
        return course
    course = models.Course(
        uuid=new_v3_uuid(),
        name=name,
        normalized_name=canonical_name(name),
    )
    db.add(course)
    db.flush()
    return course


def _resolve_organization(
    db: Session,
    values: dict[str, object],
    *,
    current: models.Assignment | None = None,
) -> None:
    course_id_present = "course_id" in values
    course_name_present = "course_name" in values

    if course_id_present and values["course_id"] is not None:
        course = _active_course_or_404(db, int(values["course_id"]))
        values["course_name"] = course.name
    elif course_name_present:
        course = _find_or_create_course(db, str(values["course_name"]))
        values["course_id"] = course.id

    project_id_present = "project_id" in values
    organization_changed = course_id_present or course_name_present
    if project_id_present:
        project_id = values["project_id"]
    elif organization_changed and current is not None:
        project_id = current.project_id
    else:
        return
    if project_id is not None:
        project = _active_project_or_404(db, int(project_id))
        if course_id_present:
            effective_course_id = (
                int(values["course_id"])
                if values["course_id"] is not None
                else None
            )
        elif course_name_present:
            effective_course_id = int(values["course_id"])
        else:
            effective_course_id = current.course_id if current is not None else None
        if project.course_id is not None and project.course_id != effective_course_id:
            raise HTTPException(
                status_code=422,
                detail="Project belongs to a different course",
            )


def _update_state_or_422(
    db: Session,
    assignment: models.Assignment,
    *,
    requested_status: str | None,
    requested_progress: int | None,
) -> None:
    try:
        update_assignment_state(
            db,
            assignment,
            requested_status=requested_status,
            requested_progress=requested_progress,
        )
    except TaskStateConflict as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


def _validate_deadline_state(assignment: models.Assignment) -> None:
    if assignment.all_day and assignment.due_date is None:
        raise HTTPException(status_code=422, detail="all_day tasks require due_date")


@router.post(
    "",
    response_model=schemas.AssignmentRead,
    status_code=status.HTTP_201_CREATED,
)
def create_assignment(
    assignment_in: schemas.AssignmentCreate,
    db: Session = Depends(get_db),
) -> models.Assignment:
    values = assignment_in.model_dump(exclude={"status", "progress_percent"})
    _resolve_organization(db, values)
    assignment = models.Assignment(
        uuid=new_v3_uuid(),
        **values,
    )
    assignment.progress_percent = 0
    _update_state_or_422(
        db,
        assignment,
        requested_status=assignment_in.status,
        requested_progress=assignment_in.progress_percent,
    )
    _validate_deadline_state(assignment)
    db.add(assignment)
    db.commit()
    db.refresh(assignment)
    return assignment


@router.get("", response_model=list[schemas.AssignmentRead])
def list_assignments(db: Session = Depends(get_db)) -> list[models.Assignment]:
    statement = (
        select(models.Assignment)
        .where(models.Assignment.deleted_at.is_(None))
        .order_by(
            models.Assignment.due_date.is_(None),
            models.Assignment.due_date.asc(),
            models.Assignment.created_at.desc(),
        )
    )
    return list(db.scalars(statement).all())


@router.get("/search", response_model=list[schemas.AssignmentRead])
def search_assignments(
    query: str,
    db: Session = Depends(get_db),
) -> list[models.Assignment]:
    cleaned_query = query.strip()
    if not cleaned_query:
        return []

    pattern = f"%{cleaned_query}%"
    statement = (
        select(models.Assignment)
        .where(
            models.Assignment.deleted_at.is_(None),
            or_(
                models.Assignment.course_name.ilike(pattern),
                models.Assignment.title.ilike(pattern),
                models.Assignment.description.ilike(pattern),
                models.Assignment.link.ilike(pattern),
                models.Assignment.source_name.ilike(pattern),
                models.Assignment.source_file.ilike(pattern),
                models.Assignment.source_url.ilike(pattern),
            ),
        )
        .order_by(models.Assignment.due_date.is_(None), models.Assignment.due_date.asc())
    )
    return list(db.scalars(statement).all())


@router.get("/{assignment_id}", response_model=schemas.AssignmentRead)
def get_assignment(
    assignment_id: int,
    db: Session = Depends(get_db),
) -> models.Assignment:
    return get_assignment_or_404(db, assignment_id)


@router.put("/{assignment_id}", response_model=schemas.AssignmentRead)
@router.patch("/{assignment_id}", response_model=schemas.AssignmentRead)
def update_assignment(
    assignment_id: int,
    assignment_in: schemas.AssignmentUpdate,
    db: Session = Depends(get_db),
) -> models.Assignment:
    assignment = get_assignment_or_404(db, assignment_id)
    updates = assignment_in.model_dump(exclude_unset=True)
    requested_status = updates.pop("status", None)
    requested_progress = updates.pop("progress_percent", None)
    _resolve_organization(db, updates, current=assignment)

    for field_name, value in updates.items():
        setattr(assignment, field_name, value)

    _update_state_or_422(
        db,
        assignment,
        requested_status=requested_status,
        requested_progress=requested_progress,
    )
    _validate_deadline_state(assignment)
    db.commit()
    db.refresh(assignment)
    return assignment


@router.delete("/{assignment_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_assignment(
    assignment_id: int,
    db: Session = Depends(get_db),
) -> Response:
    assignment = get_assignment_or_404(db, assignment_id)
    deleted_at = utc_now()
    assignment.deleted_at = deleted_at
    db.execute(
        update(models.Reminder)
        .where(
            models.Reminder.assignment_id == assignment.id,
            models.Reminder.deleted_at.is_(None),
            models.Reminder.is_enabled.is_(True),
        )
        .values(is_enabled=False, updated_at=deleted_at)
    )
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.patch("/{assignment_id}/status", response_model=schemas.AssignmentRead)
def update_assignment_status(
    assignment_id: int,
    status_in: schemas.AssignmentStatusUpdate,
    db: Session = Depends(get_db),
) -> models.Assignment:
    assignment = get_assignment_or_404(db, assignment_id)
    _update_state_or_422(
        db,
        assignment,
        requested_status=status_in.status,
        requested_progress=None,
    )
    db.commit()
    db.refresh(assignment)
    return assignment


@router.post("/{assignment_id}/restore", response_model=schemas.AssignmentRead)
def restore_assignment(
    assignment_id: int,
    db: Session = Depends(get_db),
) -> models.Assignment:
    assignment = repositories.get_assignment(db, assignment_id)
    if assignment is None:
        raise HTTPException(status_code=404, detail="Assignment not found")
    if assignment.deleted_at is None:
        return assignment
    assignment.deleted_at = None
    assignment.updated_at = utc_now()
    _update_state_or_422(
        db,
        assignment,
        requested_status=None,
        requested_progress=None,
    )
    db.commit()
    db.refresh(assignment)
    return assignment
