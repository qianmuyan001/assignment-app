"""Atomic task and subtask state transitions for schema v3."""

from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import select
from sqlalchemy.orm import Session

from .. import models


class TaskStateConflict(ValueError):
    """Raised when a requested state contradicts derived subtask state."""


def canonical_utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace(
        "+00:00", "Z"
    )


def active_subtasks(db: Session, assignment_id: int) -> list[models.Subtask]:
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


def set_subtask_status(subtask: models.Subtask, requested_status: str) -> None:
    subtask.status = requested_status
    if requested_status == "done":
        subtask.completed_at = subtask.completed_at or canonical_utc_now()
    else:
        subtask.completed_at = None
    subtask.updated_at = canonical_utc_now()


def derive_assignment_from_subtasks(
    assignment: models.Assignment,
    subtasks: list[models.Subtask],
) -> None:
    if not subtasks:
        return
    completed_count = sum(subtask.status == "done" for subtask in subtasks)
    progress = int(completed_count * 100 / len(subtasks))
    if completed_count == len(subtasks):
        status = "done"
    elif completed_count > 0 or any(
        subtask.status == "in_progress" for subtask in subtasks
    ):
        status = "in_progress"
    else:
        status = "todo"
    _write_assignment_state(assignment, status=status, progress=progress)


def recalculate_assignment_from_active_subtasks(
    db: Session,
    assignment: models.Assignment,
    *,
    reset_when_empty: bool = False,
) -> None:
    subtasks = active_subtasks(db, assignment.id)
    if not subtasks:
        if reset_when_empty:
            _write_assignment_state(assignment, status="todo", progress=0)
        return
    derive_assignment_from_subtasks(assignment, subtasks)


def update_assignment_state(
    db: Session,
    assignment: models.Assignment,
    *,
    requested_status: str | None,
    requested_progress: int | None,
) -> None:
    subtasks = active_subtasks(db, assignment.id) if assignment.id is not None else []
    if not subtasks:
        _update_independent_assignment_state(
            assignment,
            requested_status=requested_status,
            requested_progress=requested_progress,
        )
        return

    derive_assignment_from_subtasks(assignment, subtasks)
    if requested_status is not None:
        _apply_status_command_to_subtasks(subtasks, requested_status)
        derive_assignment_from_subtasks(assignment, subtasks)

    if requested_progress is not None and requested_progress != assignment.progress_percent:
        raise TaskStateConflict(
            "progress_percent is derived from active subtasks and cannot be overridden"
        )
    if requested_status is not None and requested_status != assignment.status:
        raise TaskStateConflict(
            "status contradicts the state derived from active subtasks"
        )


def _apply_status_command_to_subtasks(
    subtasks: list[models.Subtask],
    requested_status: str,
) -> None:
    if requested_status == "done":
        for subtask in subtasks:
            set_subtask_status(subtask, "done")
        return
    if requested_status == "todo":
        for subtask in subtasks:
            set_subtask_status(subtask, "todo")
        return
    if requested_status != "in_progress":
        raise TaskStateConflict(f"Unsupported task status: {requested_status!r}")

    if any(subtask.status == "in_progress" for subtask in subtasks):
        return
    candidate = next(
        (subtask for subtask in subtasks if subtask.status == "todo"),
        subtasks[-1],
    )
    set_subtask_status(candidate, "in_progress")


def _update_independent_assignment_state(
    assignment: models.Assignment,
    *,
    requested_status: str | None,
    requested_progress: int | None,
) -> None:
    if (
        requested_status == "done"
        and requested_progress is not None
        and requested_progress != 100
    ):
        raise TaskStateConflict("done status requires progress_percent 100")
    if (
        requested_status == "todo"
        and requested_progress is not None
        and requested_progress != 0
    ):
        raise TaskStateConflict("todo status requires progress_percent 0")
    if requested_status == "in_progress" and requested_progress == 100:
        raise TaskStateConflict("progress_percent 100 requires done status")

    target_status = requested_status or assignment.status
    target_progress = (
        requested_progress
        if requested_progress is not None
        else assignment.progress_percent
    )
    if requested_status == "done":
        target_progress = 100
    elif requested_status == "todo":
        target_progress = 0
    elif requested_status == "in_progress" and assignment.status == "done":
        target_progress = requested_progress or 0
    elif requested_progress is not None and requested_status is None:
        if requested_progress == 100:
            target_status = "done"
        elif requested_progress > 0:
            target_status = "in_progress"
        else:
            target_status = "todo"

    _write_assignment_state(
        assignment,
        status=target_status,
        progress=target_progress,
    )


def _write_assignment_state(
    assignment: models.Assignment,
    *,
    status: str,
    progress: int,
) -> None:
    if status == "done":
        assignment.status = "done"
        assignment.progress_percent = 100
        assignment.completed_at = assignment.completed_at or canonical_utc_now()
        return
    if progress >= 100:
        raise TaskStateConflict("non-completed tasks must have progress below 100")
    assignment.status = status
    assignment.progress_percent = progress
    assignment.completed_at = None
