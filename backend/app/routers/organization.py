from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Response
from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from shared.schema_v3 import (
    attachment_storage_relative_path,
    canonical_name,
    new_v3_uuid,
)

from .. import models, repositories, schemas
from ..database import get_db
from ..services.task_state import (
    canonical_utc_now,
    recalculate_assignment_from_active_subtasks,
    set_subtask_status,
)
from .assignments import get_assignment_or_404


router = APIRouter(tags=["task organization"])


def _commit_or_conflict(db: Session, detail: str) -> None:
    try:
        db.commit()
    except IntegrityError as exc:
        db.rollback()
        raise HTTPException(status_code=409, detail=detail) from exc


def _course_or_404(db: Session, course_id: int) -> models.Course:
    course = repositories.get_active_course(db, course_id)
    if course is None:
        raise HTTPException(status_code=404, detail="Course not found")
    return course


def _project_or_404(db: Session, project_id: int) -> models.Project:
    project = repositories.get_active_project(db, project_id)
    if project is None:
        raise HTTPException(status_code=404, detail="Project not found")
    return project


def _tag_or_404(db: Session, tag_id: int) -> models.Tag:
    tag = repositories.get_active_tag(db, tag_id)
    if tag is None:
        raise HTTPException(status_code=404, detail="Tag not found")
    return tag


def _subtask_or_404(
    db: Session,
    assignment_id: int,
    subtask_id: int,
) -> models.Subtask:
    subtask = repositories.get_active_subtask(db, assignment_id, subtask_id)
    if subtask is None:
        raise HTTPException(status_code=404, detail="Subtask not found")
    return subtask


def _attachment_or_404(
    db: Session,
    assignment_id: int,
    attachment_id: int,
) -> models.Attachment:
    attachment = repositories.get_active_attachment(
        db, assignment_id, attachment_id
    )
    if attachment is None:
        raise HTTPException(status_code=404, detail="Attachment not found")
    return attachment


def _reminder_or_404(
    db: Session,
    assignment_id: int,
    reminder_id: int,
) -> models.Reminder:
    reminder = repositories.get_active_reminder(db, assignment_id, reminder_id)
    if reminder is None:
        raise HTTPException(status_code=404, detail="Reminder not found")
    return reminder


def _touch(record: object) -> None:
    setattr(record, "updated_at", canonical_utc_now())


@router.post("/courses", response_model=schemas.CourseRead, status_code=201)
def create_course(
    course_in: schemas.CourseCreate,
    db: Session = Depends(get_db),
) -> models.Course:
    values = course_in.model_dump()
    course = models.Course(
        uuid=new_v3_uuid(),
        normalized_name=canonical_name(values["name"]),
        **values,
    )
    db.add(course)
    _commit_or_conflict(db, "Course could not be created")
    db.refresh(course)
    return course


@router.get("/courses", response_model=list[schemas.CourseRead])
def list_courses(db: Session = Depends(get_db)) -> list[models.Course]:
    return list(
        db.scalars(
            select(models.Course)
            .where(models.Course.deleted_at.is_(None))
            .order_by(models.Course.is_archived, models.Course.name)
        ).all()
    )


@router.get("/courses/{course_id}", response_model=schemas.CourseRead)
def get_course(course_id: int, db: Session = Depends(get_db)) -> models.Course:
    return _course_or_404(db, course_id)


@router.patch("/courses/{course_id}", response_model=schemas.CourseRead)
def update_course(
    course_id: int,
    course_in: schemas.CourseUpdate,
    db: Session = Depends(get_db),
) -> models.Course:
    course = _course_or_404(db, course_id)
    values = course_in.model_dump(exclude_unset=True)
    if "name" in values:
        course.normalized_name = canonical_name(values["name"])
        db.execute(
            update(models.Assignment)
            .where(
                models.Assignment.course_id == course.id,
            )
            .values(course_name=values["name"], updated_at=canonical_utc_now())
        )
    for key, value in values.items():
        setattr(course, key, value)
    _touch(course)
    _commit_or_conflict(db, "Course update conflicts with existing data")
    db.refresh(course)
    return course


@router.delete("/courses/{course_id}", status_code=204)
def delete_course(course_id: int, db: Session = Depends(get_db)) -> Response:
    course = _course_or_404(db, course_id)
    course.deleted_at = canonical_utc_now()
    _touch(course)
    db.commit()
    return Response(status_code=204)


@router.post("/courses/{course_id}/restore", response_model=schemas.CourseRead)
def restore_course(course_id: int, db: Session = Depends(get_db)) -> models.Course:
    course = repositories.get_course(db, course_id)
    if course is None:
        raise HTTPException(status_code=404, detail="Course not found")
    if course.deleted_at is None:
        return course
    course.deleted_at = None
    _touch(course)
    _commit_or_conflict(db, "Course could not be restored")
    db.refresh(course)
    return course


@router.post("/projects", response_model=schemas.ProjectRead, status_code=201)
def create_project(
    project_in: schemas.ProjectCreate,
    db: Session = Depends(get_db),
) -> models.Project:
    if project_in.course_id is not None:
        _course_or_404(db, project_in.course_id)
    project = models.Project(uuid=new_v3_uuid(), **project_in.model_dump())
    db.add(project)
    _commit_or_conflict(db, "Project could not be created")
    db.refresh(project)
    return project


@router.get("/projects", response_model=list[schemas.ProjectRead])
def list_projects(
    course_id: int | None = None,
    db: Session = Depends(get_db),
) -> list[models.Project]:
    statement = select(models.Project).where(models.Project.deleted_at.is_(None))
    if course_id is not None:
        statement = statement.where(models.Project.course_id == course_id)
    return list(db.scalars(statement.order_by(models.Project.name)).all())


@router.get("/projects/{project_id}", response_model=schemas.ProjectRead)
def get_project(project_id: int, db: Session = Depends(get_db)) -> models.Project:
    return _project_or_404(db, project_id)


@router.patch("/projects/{project_id}", response_model=schemas.ProjectRead)
def update_project(
    project_id: int,
    project_in: schemas.ProjectUpdate,
    db: Session = Depends(get_db),
) -> models.Project:
    project = _project_or_404(db, project_id)
    values = project_in.model_dump(exclude_unset=True)
    if "course_id" in values:
        new_course_id = values["course_id"]
        if new_course_id is not None:
            _course_or_404(db, int(new_course_id))
        if new_course_id != project.course_id:
            incompatible_task = db.scalar(
                select(models.Assignment.id).where(
                    models.Assignment.project_id == project.id,
                    models.Assignment.course_id.is_distinct_from(new_course_id),
                ).limit(1)
            )
            if incompatible_task is not None:
                raise HTTPException(
                    status_code=409,
                    detail=(
                        "Project course cannot change while linked tasks belong "
                        "to a different course"
                    ),
                )
    for key, value in values.items():
        setattr(project, key, value)
    _touch(project)
    _commit_or_conflict(db, "Project update conflicts with existing data")
    db.refresh(project)
    return project


@router.delete("/projects/{project_id}", status_code=204)
def delete_project(project_id: int, db: Session = Depends(get_db)) -> Response:
    project = _project_or_404(db, project_id)
    project.deleted_at = canonical_utc_now()
    _touch(project)
    db.commit()
    return Response(status_code=204)


@router.post("/projects/{project_id}/restore", response_model=schemas.ProjectRead)
def restore_project(
    project_id: int,
    db: Session = Depends(get_db),
) -> models.Project:
    project = repositories.get_project(db, project_id)
    if project is None:
        raise HTTPException(status_code=404, detail="Project not found")
    if project.deleted_at is None:
        return project
    project.deleted_at = None
    _touch(project)
    _commit_or_conflict(db, "Project could not be restored")
    db.refresh(project)
    return project


@router.post("/tags", response_model=schemas.TagRead, status_code=201)
def create_tag(
    tag_in: schemas.TagCreate,
    db: Session = Depends(get_db),
) -> models.Tag:
    values = tag_in.model_dump()
    tag = models.Tag(
        uuid=new_v3_uuid(),
        normalized_name=canonical_name(values["name"]),
        **values,
    )
    db.add(tag)
    _commit_or_conflict(db, "A tag with this normalized name already exists")
    db.refresh(tag)
    return tag


@router.get("/tags", response_model=list[schemas.TagRead])
def list_tags(db: Session = Depends(get_db)) -> list[models.Tag]:
    return list(
        db.scalars(
            select(models.Tag)
            .where(models.Tag.deleted_at.is_(None))
            .order_by(models.Tag.name)
        ).all()
    )


@router.patch("/tags/{tag_id}", response_model=schemas.TagRead)
def update_tag(
    tag_id: int,
    tag_in: schemas.TagUpdate,
    db: Session = Depends(get_db),
) -> models.Tag:
    tag = _tag_or_404(db, tag_id)
    values = tag_in.model_dump(exclude_unset=True)
    if "name" in values:
        tag.normalized_name = canonical_name(values["name"])
    for key, value in values.items():
        setattr(tag, key, value)
    _touch(tag)
    _commit_or_conflict(db, "A tag with this normalized name already exists")
    db.refresh(tag)
    return tag


@router.delete("/tags/{tag_id}", status_code=204)
def delete_tag(tag_id: int, db: Session = Depends(get_db)) -> Response:
    tag = _tag_or_404(db, tag_id)
    deleted_at = canonical_utc_now()
    tag.deleted_at = deleted_at
    _touch(tag)
    db.execute(
        update(models.TaskTag)
        .where(
            models.TaskTag.tag_id == tag.id,
            models.TaskTag.deleted_at.is_(None),
        )
        .values(deleted_at=deleted_at, updated_at=deleted_at)
    )
    db.commit()
    return Response(status_code=204)


@router.post("/tags/{tag_id}/restore", response_model=schemas.TagRead)
def restore_tag(tag_id: int, db: Session = Depends(get_db)) -> models.Tag:
    tag = repositories.get_tag(db, tag_id)
    if tag is None:
        raise HTTPException(status_code=404, detail="Tag not found")
    if tag.deleted_at is None:
        return tag
    tag.deleted_at = None
    _touch(tag)
    _commit_or_conflict(db, "Tag could not be restored")
    db.refresh(tag)
    return tag


@router.post(
    "/assignments/{assignment_id}/tags/{tag_id}",
    response_model=schemas.TaskTagRead,
    status_code=201,
)
def add_task_tag(
    assignment_id: int,
    tag_id: int,
    db: Session = Depends(get_db),
) -> models.TaskTag:
    get_assignment_or_404(db, assignment_id)
    _tag_or_404(db, tag_id)
    existing = db.scalar(
        select(models.TaskTag).where(
            models.TaskTag.assignment_id == assignment_id,
            models.TaskTag.tag_id == tag_id,
            models.TaskTag.deleted_at.is_(None),
        )
    )
    if existing is not None:
        return existing
    task_tag = models.TaskTag(
        uuid=new_v3_uuid(), assignment_id=assignment_id, tag_id=tag_id
    )
    db.add(task_tag)
    _commit_or_conflict(db, "Tag is already attached to this task")
    db.refresh(task_tag)
    return task_tag


@router.get(
    "/assignments/{assignment_id}/tags",
    response_model=list[schemas.TaskTagRead],
)
def list_task_tags(
    assignment_id: int,
    db: Session = Depends(get_db),
) -> list[models.TaskTag]:
    get_assignment_or_404(db, assignment_id)
    return list(
        db.scalars(
            select(models.TaskTag)
            .where(
                models.TaskTag.assignment_id == assignment_id,
                models.TaskTag.deleted_at.is_(None),
            )
            .order_by(models.TaskTag.id)
        ).all()
    )


@router.delete("/assignments/{assignment_id}/tags/{tag_id}", status_code=204)
def delete_task_tag(
    assignment_id: int,
    tag_id: int,
    db: Session = Depends(get_db),
) -> Response:
    task_tag = db.scalar(
        select(models.TaskTag).where(
            models.TaskTag.assignment_id == assignment_id,
            models.TaskTag.tag_id == tag_id,
            models.TaskTag.deleted_at.is_(None),
        )
    )
    if task_tag is None:
        raise HTTPException(status_code=404, detail="Task tag not found")
    task_tag.deleted_at = canonical_utc_now()
    _touch(task_tag)
    db.commit()
    return Response(status_code=204)


@router.post(
    "/assignments/{assignment_id}/subtasks",
    response_model=schemas.SubtaskRead,
    status_code=201,
)
def create_subtask(
    assignment_id: int,
    subtask_in: schemas.SubtaskCreate,
    db: Session = Depends(get_db),
) -> models.Subtask:
    assignment = get_assignment_or_404(db, assignment_id)
    values = subtask_in.model_dump(exclude={"status"})
    subtask = models.Subtask(
        uuid=new_v3_uuid(), assignment_id=assignment_id, **values
    )
    set_subtask_status(subtask, subtask_in.status)
    db.add(subtask)
    db.flush()
    recalculate_assignment_from_active_subtasks(db, assignment)
    _commit_or_conflict(db, "Subtask could not be created")
    db.refresh(subtask)
    return subtask


@router.get(
    "/assignments/{assignment_id}/subtasks",
    response_model=list[schemas.SubtaskRead],
)
def list_subtasks(
    assignment_id: int,
    db: Session = Depends(get_db),
) -> list[models.Subtask]:
    get_assignment_or_404(db, assignment_id)
    return list(
        db.scalars(
            select(models.Subtask)
            .where(
                models.Subtask.assignment_id == assignment_id,
                models.Subtask.deleted_at.is_(None),
            )
            .order_by(models.Subtask.sort_order, models.Subtask.id)
        ).all()
    )


@router.patch(
    "/assignments/{assignment_id}/subtasks/{subtask_id}",
    response_model=schemas.SubtaskRead,
)
def update_subtask(
    assignment_id: int,
    subtask_id: int,
    subtask_in: schemas.SubtaskUpdate,
    db: Session = Depends(get_db),
) -> models.Subtask:
    assignment = get_assignment_or_404(db, assignment_id)
    subtask = _subtask_or_404(db, assignment_id, subtask_id)
    values = subtask_in.model_dump(exclude_unset=True)
    requested_status = values.pop("status", None)
    for key, value in values.items():
        setattr(subtask, key, value)
    if requested_status is not None:
        set_subtask_status(subtask, requested_status)
    _touch(subtask)
    db.flush()
    recalculate_assignment_from_active_subtasks(db, assignment)
    _commit_or_conflict(db, "Subtask could not be updated")
    db.refresh(subtask)
    return subtask


@router.delete(
    "/assignments/{assignment_id}/subtasks/{subtask_id}", status_code=204
)
def delete_subtask(
    assignment_id: int,
    subtask_id: int,
    db: Session = Depends(get_db),
) -> Response:
    assignment = get_assignment_or_404(db, assignment_id)
    subtask = _subtask_or_404(db, assignment_id, subtask_id)
    subtask.deleted_at = canonical_utc_now()
    _touch(subtask)
    db.flush()
    recalculate_assignment_from_active_subtasks(
        db, assignment, reset_when_empty=True
    )
    db.commit()
    return Response(status_code=204)


@router.post(
    "/assignments/{assignment_id}/subtasks/{subtask_id}/restore",
    response_model=schemas.SubtaskRead,
)
def restore_subtask(
    assignment_id: int,
    subtask_id: int,
    db: Session = Depends(get_db),
) -> models.Subtask:
    assignment = get_assignment_or_404(db, assignment_id)
    subtask = repositories.get_subtask(db, assignment_id, subtask_id)
    if subtask is None:
        raise HTTPException(status_code=404, detail="Subtask not found")
    if subtask.deleted_at is None:
        return subtask
    subtask.deleted_at = None
    _touch(subtask)
    db.flush()
    recalculate_assignment_from_active_subtasks(db, assignment)
    _commit_or_conflict(db, "Subtask could not be restored")
    db.refresh(subtask)
    return subtask


@router.post(
    "/assignments/{assignment_id}/attachments",
    response_model=schemas.AttachmentRead,
    status_code=201,
)
def create_attachment(
    assignment_id: int,
    attachment_in: schemas.AttachmentCreate,
    db: Session = Depends(get_db),
) -> models.Attachment:
    get_assignment_or_404(db, assignment_id)
    attachment_uuid = new_v3_uuid()
    attachment = models.Attachment(
        uuid=attachment_uuid,
        assignment_id=assignment_id,
        relative_path=attachment_storage_relative_path(attachment_uuid),
        **attachment_in.model_dump(),
    )
    db.add(attachment)
    _commit_or_conflict(db, "Attachment metadata could not be created")
    db.refresh(attachment)
    return attachment


@router.get(
    "/assignments/{assignment_id}/attachments",
    response_model=list[schemas.AttachmentRead],
)
def list_attachments(
    assignment_id: int,
    db: Session = Depends(get_db),
) -> list[models.Attachment]:
    get_assignment_or_404(db, assignment_id)
    return list(
        db.scalars(
            select(models.Attachment)
            .where(
                models.Attachment.assignment_id == assignment_id,
                models.Attachment.deleted_at.is_(None),
            )
            .order_by(models.Attachment.id)
        ).all()
    )


@router.delete(
    "/assignments/{assignment_id}/attachments/{attachment_id}", status_code=204
)
def delete_attachment(
    assignment_id: int,
    attachment_id: int,
    db: Session = Depends(get_db),
) -> Response:
    attachment = _attachment_or_404(db, assignment_id, attachment_id)
    attachment.deleted_at = canonical_utc_now()
    _touch(attachment)
    db.commit()
    return Response(status_code=204)


@router.post(
    "/assignments/{assignment_id}/reminders",
    response_model=schemas.ReminderRead,
    status_code=201,
)
def create_reminder(
    assignment_id: int,
    reminder_in: schemas.ReminderCreate,
    db: Session = Depends(get_db),
) -> models.Reminder:
    get_assignment_or_404(db, assignment_id)
    reminder = models.Reminder(
        uuid=new_v3_uuid(),
        assignment_id=assignment_id,
        **reminder_in.model_dump(),
    )
    db.add(reminder)
    _commit_or_conflict(db, "Reminder could not be created")
    db.refresh(reminder)
    return reminder


@router.get("/reminders/pending", response_model=list[schemas.ReminderRead])
def list_pending_reminders(
    db: Session = Depends(get_db),
) -> list[models.Reminder]:
    return repositories.list_schedulable_reminders(db)


@router.get(
    "/assignments/{assignment_id}/reminders",
    response_model=list[schemas.ReminderRead],
)
def list_reminders(
    assignment_id: int,
    db: Session = Depends(get_db),
) -> list[models.Reminder]:
    get_assignment_or_404(db, assignment_id)
    return list(
        db.scalars(
            select(models.Reminder)
            .where(
                models.Reminder.assignment_id == assignment_id,
                models.Reminder.deleted_at.is_(None),
            )
            .order_by(models.Reminder.trigger_at_utc)
        ).all()
    )


@router.patch(
    "/assignments/{assignment_id}/reminders/{reminder_id}",
    response_model=schemas.ReminderRead,
)
def update_reminder(
    assignment_id: int,
    reminder_id: int,
    reminder_in: schemas.ReminderUpdate,
    db: Session = Depends(get_db),
) -> models.Reminder:
    get_assignment_or_404(db, assignment_id)
    reminder = _reminder_or_404(db, assignment_id, reminder_id)
    for key, value in reminder_in.model_dump(exclude_unset=True).items():
        setattr(reminder, key, value)
    _touch(reminder)
    _commit_or_conflict(db, "Reminder could not be updated")
    db.refresh(reminder)
    return reminder


@router.delete(
    "/assignments/{assignment_id}/reminders/{reminder_id}", status_code=204
)
def delete_reminder(
    assignment_id: int,
    reminder_id: int,
    db: Session = Depends(get_db),
) -> Response:
    reminder = _reminder_or_404(db, assignment_id, reminder_id)
    reminder.deleted_at = canonical_utc_now()
    reminder.is_enabled = False
    _touch(reminder)
    db.commit()
    return Response(status_code=204)
