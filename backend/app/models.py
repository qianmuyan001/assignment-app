from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Integer,
    String,
    Text,
    case,
    text,
)
from sqlalchemy.ext.hybrid import hybrid_property
from sqlalchemy.orm import Mapped, mapped_column

from shared.schema_v3 import new_v3_uuid

from .database import Base


_STATUS_TO_STORAGE = {
    "todo": "not_started",
    "not_started": "not_started",
    "in_progress": "in_progress",
    "done": "completed",
    "completed": "completed",
}
_STATUS_TO_UI = {
    "not_started": "todo",
    "in_progress": "in_progress",
    "completed": "done",
}
_UTC_NOW = text("(strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))")


def _canonical_utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace(
        "+00:00", "Z"
    )


def _storage_status(value: str) -> str:
    try:
        return _STATUS_TO_STORAGE[value]
    except KeyError as exc:
        raise ValueError(f"Unsupported status: {value!r}") from exc


class Assignment(Base):
    __tablename__ = "assignments"
    __table_args__ = (
        CheckConstraint(
            "status IN ('not_started', 'in_progress', 'completed')",
            name="assignment_status_check",
        ),
        CheckConstraint(
            "priority IN ('low', 'medium', 'high')",
            name="assignment_priority_check",
        ),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    uuid: Mapped[str] = mapped_column(String(36), nullable=False, default=new_v3_uuid)
    course_name: Mapped[str] = mapped_column(String(120), nullable=False)
    course_id: Mapped[int | None] = mapped_column(
        ForeignKey("courses.id", ondelete="SET NULL"), nullable=True
    )
    project_id: Mapped[int | None] = mapped_column(
        ForeignKey("projects.id", ondelete="SET NULL"), nullable=True
    )
    title: Mapped[str] = mapped_column(String(255), nullable=False)
    due_date: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    description: Mapped[str | None] = mapped_column(Text, nullable=True)
    link: Mapped[str | None] = mapped_column(String(1000), nullable=True)
    _status: Mapped[str] = mapped_column(
        "status", String(20), nullable=False, default="not_started"
    )
    priority: Mapped[str] = mapped_column(
        String(10), nullable=False, default="medium"
    )
    source_name: Mapped[str | None] = mapped_column(String(255), nullable=True)
    source_type: Mapped[str | None] = mapped_column(String(80), nullable=True)
    source_file: Mapped[str | None] = mapped_column(String(1000), nullable=True)
    source_url: Mapped[str | None] = mapped_column(String(1000), nullable=True)
    completed_at: Mapped[str | None] = mapped_column(Text, nullable=True)
    progress_percent: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    all_day: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    timezone_id: Mapped[str | None] = mapped_column(String(255), nullable=True)
    created_at: Mapped[str] = mapped_column(
        Text, nullable=False, default=_canonical_utc_now
    )
    updated_at: Mapped[str] = mapped_column(
        Text,
        nullable=False,
        default=_canonical_utc_now,
        onupdate=_canonical_utc_now,
    )
    deleted_at: Mapped[str | None] = mapped_column(Text, nullable=True)

    @hybrid_property
    def status(self) -> str:
        """Expose canonical UI values while retaining v1/v2 storage values."""

        return _STATUS_TO_UI.get(self._status, self._status)

    @status.inplace.setter
    def _set_status(self, value: str) -> None:
        self._status = _storage_status(value)

    @status.inplace.expression
    @classmethod
    def _status_expression(cls):
        return case(
            (cls._status == "not_started", "todo"),
            (cls._status == "completed", "done"),
            else_=cls._status,
        )


class Course(Base):
    __tablename__ = "courses"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    uuid: Mapped[str] = mapped_column(String(36), nullable=False, default=new_v3_uuid)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    normalized_name: Mapped[str] = mapped_column(String(255), nullable=False)
    color_hex: Mapped[str | None] = mapped_column(String(7), nullable=True)
    teacher: Mapped[str | None] = mapped_column(String(255), nullable=True)
    semester: Mapped[str | None] = mapped_column(String(255), nullable=True)
    is_archived: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    created_at: Mapped[str] = mapped_column(
        Text, nullable=False, server_default=_UTC_NOW
    )
    updated_at: Mapped[str] = mapped_column(
        Text, nullable=False, server_default=_UTC_NOW
    )
    deleted_at: Mapped[str | None] = mapped_column(Text, nullable=True)


class Project(Base):
    __tablename__ = "projects"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    uuid: Mapped[str] = mapped_column(String(36), nullable=False, default=new_v3_uuid)
    course_id: Mapped[int | None] = mapped_column(
        ForeignKey("courses.id", ondelete="SET NULL"), nullable=True
    )
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    description: Mapped[str | None] = mapped_column(Text, nullable=True)
    status: Mapped[str] = mapped_column(String(20), nullable=False, default="active")
    created_at: Mapped[str] = mapped_column(
        Text, nullable=False, server_default=_UTC_NOW
    )
    updated_at: Mapped[str] = mapped_column(
        Text, nullable=False, server_default=_UTC_NOW
    )
    deleted_at: Mapped[str | None] = mapped_column(Text, nullable=True)


class Tag(Base):
    __tablename__ = "tags"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    uuid: Mapped[str] = mapped_column(String(36), nullable=False, default=new_v3_uuid)
    name: Mapped[str] = mapped_column(String(80), nullable=False)
    normalized_name: Mapped[str] = mapped_column(String(255), nullable=False)
    color_hex: Mapped[str | None] = mapped_column(String(7), nullable=True)
    created_at: Mapped[str] = mapped_column(
        Text, nullable=False, server_default=_UTC_NOW
    )
    updated_at: Mapped[str] = mapped_column(
        Text, nullable=False, server_default=_UTC_NOW
    )
    deleted_at: Mapped[str | None] = mapped_column(Text, nullable=True)


class TaskTag(Base):
    __tablename__ = "task_tags"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    uuid: Mapped[str] = mapped_column(String(36), nullable=False, default=new_v3_uuid)
    assignment_id: Mapped[int] = mapped_column(
        ForeignKey("assignments.id", ondelete="CASCADE"), nullable=False
    )
    tag_id: Mapped[int] = mapped_column(
        ForeignKey("tags.id", ondelete="CASCADE"), nullable=False
    )
    created_at: Mapped[str] = mapped_column(
        Text, nullable=False, server_default=_UTC_NOW
    )
    updated_at: Mapped[str] = mapped_column(
        Text, nullable=False, server_default=_UTC_NOW
    )
    deleted_at: Mapped[str | None] = mapped_column(Text, nullable=True)


class Subtask(Base):
    __tablename__ = "subtasks"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    uuid: Mapped[str] = mapped_column(String(36), nullable=False, default=new_v3_uuid)
    assignment_id: Mapped[int] = mapped_column(
        ForeignKey("assignments.id", ondelete="CASCADE"), nullable=False
    )
    title: Mapped[str] = mapped_column(String(255), nullable=False)
    _status: Mapped[str] = mapped_column(
        "status", String(20), nullable=False, default="not_started"
    )
    sort_order: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    completed_at: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[str] = mapped_column(
        Text, nullable=False, server_default=_UTC_NOW
    )
    updated_at: Mapped[str] = mapped_column(
        Text, nullable=False, server_default=_UTC_NOW
    )
    deleted_at: Mapped[str | None] = mapped_column(Text, nullable=True)

    @hybrid_property
    def status(self) -> str:
        return _STATUS_TO_UI.get(self._status, self._status)

    @status.inplace.setter
    def _set_status(self, value: str) -> None:
        self._status = _storage_status(value)

    @status.inplace.expression
    @classmethod
    def _status_expression(cls):
        return case(
            (cls._status == "not_started", "todo"),
            (cls._status == "completed", "done"),
            else_=cls._status,
        )


class Attachment(Base):
    __tablename__ = "attachments"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    uuid: Mapped[str] = mapped_column(String(36), nullable=False, default=new_v3_uuid)
    assignment_id: Mapped[int] = mapped_column(
        ForeignKey("assignments.id", ondelete="CASCADE"), nullable=False
    )
    file_name: Mapped[str] = mapped_column(String(255), nullable=False)
    relative_path: Mapped[str] = mapped_column(String(1000), nullable=False)
    mime_type: Mapped[str | None] = mapped_column(String(255), nullable=True)
    byte_size: Mapped[int] = mapped_column(Integer, nullable=False)
    sha256: Mapped[str] = mapped_column(String(64), nullable=False)
    created_at: Mapped[str] = mapped_column(
        Text, nullable=False, server_default=_UTC_NOW
    )
    updated_at: Mapped[str] = mapped_column(
        Text, nullable=False, server_default=_UTC_NOW
    )
    deleted_at: Mapped[str | None] = mapped_column(Text, nullable=True)


class Reminder(Base):
    __tablename__ = "reminders"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    uuid: Mapped[str] = mapped_column(String(36), nullable=False, default=new_v3_uuid)
    assignment_id: Mapped[int] = mapped_column(
        ForeignKey("assignments.id", ondelete="CASCADE"), nullable=False
    )
    trigger_at_utc: Mapped[str] = mapped_column(Text, nullable=False)
    lead_minutes: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    repeat_rule: Mapped[str | None] = mapped_column(Text, nullable=True)
    is_enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    last_scheduled_at: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[str] = mapped_column(
        Text, nullable=False, server_default=_UTC_NOW
    )
    updated_at: Mapped[str] = mapped_column(
        Text, nullable=False, server_default=_UTC_NOW
    )
    deleted_at: Mapped[str | None] = mapped_column(Text, nullable=True)
