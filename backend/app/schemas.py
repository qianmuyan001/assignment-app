from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_serializer, field_validator


AssignmentStatus = Literal["todo", "in_progress", "done"]
AssignmentPriority = Literal["low", "medium", "high"]

_STATUS_TO_UI = {
    "todo": "todo",
    "not_started": "todo",
    "in_progress": "in_progress",
    "done": "done",
    "completed": "done",
}


def normalize_status(value: object) -> object:
    if not isinstance(value, str):
        return value
    cleaned = value.strip().lower()
    return _STATUS_TO_UI.get(cleaned, cleaned)


def parse_due_date(value: object) -> object:
    if value is None:
        return None

    if isinstance(value, datetime):
        parsed = value

    elif isinstance(value, str):
        cleaned = value.strip()
        if not cleaned:
            return None

        parsed = None
        for date_format in (
            "%Y-%m-%d",
            "%Y-%m-%d %H:%M",
            "%Y-%m-%d %H:%M:%S",
            "%Y-%m-%dT%H:%M",
            "%Y-%m-%dT%H:%M:%S",
        ):
            try:
                parsed = datetime.strptime(cleaned, date_format)
                break
            except ValueError:
                continue

        if parsed is None:
            parsed = datetime.fromisoformat(cleaned)

    else:
        return value

    if parsed.tzinfo is not None and parsed.utcoffset() is not None:
        raise ValueError(
            "due_date must be a local wall time without a UTC offset or timezone"
        )
    return parsed


class AssignmentBase(BaseModel):
    course_name: str = Field(..., min_length=1, max_length=120)
    title: str = Field(..., min_length=1, max_length=255)
    due_date: datetime | None = None
    description: str | None = None
    link: str | None = Field(default=None, max_length=1000)
    status: AssignmentStatus = "todo"
    priority: AssignmentPriority = "medium"
    source_name: str | None = Field(default=None, max_length=255)
    source_type: str | None = Field(default=None, max_length=80)
    source_file: str | None = Field(default=None, max_length=1000)
    source_url: str | None = Field(default=None, max_length=1000)

    @field_validator("course_name", "title")
    @classmethod
    def strip_required_text(cls, value: str) -> str:
        cleaned = value.strip()
        if not cleaned:
            raise ValueError("Field cannot be empty")
        return cleaned

    @field_validator("description", "link", "source_name", "source_type", "source_file", "source_url")
    @classmethod
    def strip_optional_text(cls, value: str | None) -> str | None:
        if value is None:
            return None
        cleaned = value.strip()
        return cleaned or None

    @field_validator("due_date", mode="before")
    @classmethod
    def parse_due_date_value(cls, value: object) -> object:
        return parse_due_date(value)

    @field_validator("status", mode="before")
    @classmethod
    def normalize_status_value(cls, value: object) -> object:
        return normalize_status(value)


class AssignmentCreate(AssignmentBase):
    pass


class AssignmentUpdate(BaseModel):
    course_name: str | None = Field(default=None, min_length=1, max_length=120)
    title: str | None = Field(default=None, min_length=1, max_length=255)
    due_date: datetime | None = None
    description: str | None = None
    link: str | None = Field(default=None, max_length=1000)
    status: AssignmentStatus | None = None
    priority: AssignmentPriority | None = None
    source_name: str | None = Field(default=None, max_length=255)
    source_type: str | None = Field(default=None, max_length=80)
    source_file: str | None = Field(default=None, max_length=1000)
    source_url: str | None = Field(default=None, max_length=1000)

    @field_validator("course_name", "title")
    @classmethod
    def strip_required_text(cls, value: str | None) -> str | None:
        if value is None:
            return None
        cleaned = value.strip()
        if not cleaned:
            raise ValueError("Field cannot be empty")
        return cleaned

    @field_validator("description", "link", "source_name", "source_type", "source_file", "source_url")
    @classmethod
    def strip_optional_text(cls, value: str | None) -> str | None:
        if value is None:
            return None
        cleaned = value.strip()
        return cleaned or None

    @field_validator("due_date", mode="before")
    @classmethod
    def parse_due_date_value(cls, value: object) -> object:
        if value is None:
            return None
        return parse_due_date(value)

    @field_validator("status", mode="before")
    @classmethod
    def normalize_status_value(cls, value: object) -> object:
        if value is None:
            return None
        return normalize_status(value)


class AssignmentStatusUpdate(BaseModel):
    status: AssignmentStatus

    @field_validator("status", mode="before")
    @classmethod
    def normalize_status_value(cls, value: object) -> object:
        return normalize_status(value)


class AssignmentRead(AssignmentBase):
    model_config = ConfigDict(from_attributes=True)

    id: int
    created_at: datetime
    updated_at: datetime

    @field_serializer("due_date")
    def serialize_due_date(self, value: datetime | None) -> str | None:
        if value is None:
            return None
        return value.strftime("%Y-%m-%d %H:%M")
