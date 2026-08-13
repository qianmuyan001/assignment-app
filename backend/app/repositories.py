"""Schema-v3 data access helpers shared by the HTTP route layer."""

from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.orm import Session

from . import models


def get_active_assignment(
    db: Session,
    assignment_id: int,
) -> models.Assignment | None:
    return db.scalar(
        select(models.Assignment).where(
            models.Assignment.id == assignment_id,
            models.Assignment.deleted_at.is_(None),
        )
    )


def get_assignment(db: Session, assignment_id: int) -> models.Assignment | None:
    return db.get(models.Assignment, assignment_id)


def get_active_course(db: Session, course_id: int) -> models.Course | None:
    return db.scalar(
        select(models.Course).where(
            models.Course.id == course_id,
            models.Course.deleted_at.is_(None),
        )
    )


def get_course(db: Session, course_id: int) -> models.Course | None:
    return db.get(models.Course, course_id)


def get_active_project(db: Session, project_id: int) -> models.Project | None:
    return db.scalar(
        select(models.Project).where(
            models.Project.id == project_id,
            models.Project.deleted_at.is_(None),
        )
    )


def get_project(db: Session, project_id: int) -> models.Project | None:
    return db.get(models.Project, project_id)


def get_active_tag(db: Session, tag_id: int) -> models.Tag | None:
    return db.scalar(
        select(models.Tag).where(
            models.Tag.id == tag_id,
            models.Tag.deleted_at.is_(None),
        )
    )


def get_tag(db: Session, tag_id: int) -> models.Tag | None:
    return db.get(models.Tag, tag_id)


def get_active_subtask(
    db: Session,
    assignment_id: int,
    subtask_id: int,
) -> models.Subtask | None:
    return db.scalar(
        select(models.Subtask).where(
            models.Subtask.id == subtask_id,
            models.Subtask.assignment_id == assignment_id,
            models.Subtask.deleted_at.is_(None),
        )
    )


def get_subtask(
    db: Session,
    assignment_id: int,
    subtask_id: int,
) -> models.Subtask | None:
    return db.scalar(
        select(models.Subtask).where(
            models.Subtask.id == subtask_id,
            models.Subtask.assignment_id == assignment_id,
        )
    )


def list_schedulable_reminders(db: Session) -> list[models.Reminder]:
    """Return enabled reminders only when their parent task is active."""

    return list(
        db.scalars(
            select(models.Reminder)
            .join(
                models.Assignment,
                models.Reminder.assignment_id == models.Assignment.id,
            )
            .where(
                models.Reminder.deleted_at.is_(None),
                models.Reminder.is_enabled.is_(True),
                models.Assignment.deleted_at.is_(None),
            )
            .order_by(models.Reminder.trigger_at_utc)
        ).all()
    )


def get_active_attachment(
    db: Session,
    assignment_id: int,
    attachment_id: int,
) -> models.Attachment | None:
    return db.scalar(
        select(models.Attachment).where(
            models.Attachment.id == attachment_id,
            models.Attachment.assignment_id == assignment_id,
            models.Attachment.deleted_at.is_(None),
        )
    )


def get_active_reminder(
    db: Session,
    assignment_id: int,
    reminder_id: int,
) -> models.Reminder | None:
    return db.scalar(
        select(models.Reminder).where(
            models.Reminder.id == reminder_id,
            models.Reminder.assignment_id == assignment_id,
            models.Reminder.deleted_at.is_(None),
        )
    )
