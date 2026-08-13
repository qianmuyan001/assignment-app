from __future__ import annotations

import re
from datetime import datetime
from typing import Literal
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    field_serializer,
    field_validator,
    model_validator,
)

from shared.schema_v3 import (
    canonical_repeat_rule,
    is_iana_timezone_id,
    is_utc_audit_timestamp,
)


AssignmentStatus = Literal["todo", "in_progress", "done"]
AssignmentPriority = Literal["low", "medium", "high"]
ProjectStatus = Literal["active", "on_hold", "completed", "archived"]

_STATUS_TO_UI = {
    "todo": "todo",
    "not_started": "todo",
    "in_progress": "in_progress",
    "done": "done",
    "completed": "done",
}
_HEX_COLOR = re.compile(r"^#[0-9A-Fa-f]{6}$")
_SHA256 = re.compile(r"^[0-9a-f]{64}$")


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
            "%Y-%m-%d %H:%M:%S.%f",
            "%Y-%m-%dT%H:%M",
            "%Y-%m-%dT%H:%M:%S",
            "%Y-%m-%dT%H:%M:%S.%f",
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


def _clean_required(value: str) -> str:
    cleaned = value.strip()
    if not cleaned:
        raise ValueError("Field cannot be empty")
    return cleaned


def _clean_optional(value: str | None) -> str | None:
    if value is None:
        return None
    cleaned = value.strip()
    return cleaned or None


def _validate_color(value: str | None) -> str | None:
    cleaned = _clean_optional(value)
    if cleaned is not None and _HEX_COLOR.fullmatch(cleaned) is None:
        raise ValueError("color_hex must use #RRGGBB syntax")
    return cleaned


def _validate_timezone(value: str | None) -> str | None:
    cleaned = _clean_optional(value)
    if cleaned is None:
        return None
    if not is_iana_timezone_id(cleaned):
        raise ValueError("timezone_id must use IANA time-zone syntax")
    try:
        ZoneInfo(cleaned)
    except (ZoneInfoNotFoundError, ValueError) as exc:
        raise ValueError("timezone_id must identify an installed IANA timezone") from exc
    return cleaned


def _validate_repeat_rule(value: str | None) -> str | None:
    return canonical_repeat_rule(value)


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
    course_id: int | None = Field(default=None, ge=1)
    project_id: int | None = Field(default=None, ge=1)
    progress_percent: int = Field(default=0, ge=0, le=100)
    all_day: bool = False
    timezone_id: str | None = Field(default=None, max_length=255)

    @field_validator("course_name", "title")
    @classmethod
    def strip_required_text(cls, value: str) -> str:
        return _clean_required(value)

    @field_validator(
        "description",
        "link",
        "source_name",
        "source_type",
        "source_file",
        "source_url",
    )
    @classmethod
    def strip_optional_text(cls, value: str | None) -> str | None:
        return _clean_optional(value)

    @field_validator("due_date", mode="before")
    @classmethod
    def parse_due_date_value(cls, value: object) -> object:
        return parse_due_date(value)

    @field_validator("status", mode="before")
    @classmethod
    def normalize_status_value(cls, value: object) -> object:
        return normalize_status(value)

    @field_validator("timezone_id")
    @classmethod
    def validate_timezone(cls, value: str | None) -> str | None:
        return _validate_timezone(value)

    @model_validator(mode="after")
    def validate_task_state(self) -> AssignmentBase:
        if self.all_day and self.due_date is None:
            raise ValueError("all_day tasks require due_date")
        status_was_set = "status" in self.model_fields_set
        progress_was_set = "progress_percent" in self.model_fields_set
        if status_was_set and progress_was_set:
            if self.status == "done" and self.progress_percent != 100:
                raise ValueError("done status requires progress_percent 100")
            if self.status == "todo" and self.progress_percent != 0:
                raise ValueError("todo status requires progress_percent 0")
            if self.status == "in_progress" and self.progress_percent == 100:
                raise ValueError("progress_percent 100 requires done status")
        elif status_was_set:
            if self.status == "done":
                self.progress_percent = 100
            elif self.status == "todo":
                self.progress_percent = 0
        elif progress_was_set:
            if self.progress_percent == 100:
                self.status = "done"
            elif self.progress_percent > 0:
                self.status = "in_progress"
        return self


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
    course_id: int | None = Field(default=None, ge=1)
    project_id: int | None = Field(default=None, ge=1)
    progress_percent: int | None = Field(default=None, ge=0, le=100)
    all_day: bool | None = None
    timezone_id: str | None = Field(default=None, max_length=255)

    @field_validator("course_name", "title")
    @classmethod
    def strip_required_text(cls, value: str | None) -> str | None:
        if value is None:
            raise ValueError("Field cannot be null")
        return _clean_required(value)

    @field_validator(
        "description",
        "link",
        "source_name",
        "source_type",
        "source_file",
        "source_url",
    )
    @classmethod
    def strip_optional_text(cls, value: str | None) -> str | None:
        return _clean_optional(value)

    @field_validator("due_date", mode="before")
    @classmethod
    def parse_due_date_value(cls, value: object) -> object:
        return parse_due_date(value)

    @field_validator("status", mode="before")
    @classmethod
    def normalize_status_value(cls, value: object) -> object:
        if value is None:
            raise ValueError("status cannot be null")
        return normalize_status(value)

    @field_validator("priority")
    @classmethod
    def validate_priority(cls, value: str | None) -> str:
        if value is None:
            raise ValueError("priority cannot be null")
        return value

    @field_validator("progress_percent", "all_day")
    @classmethod
    def validate_required_scalars(cls, value: object) -> object:
        if value is None:
            raise ValueError("Field cannot be null")
        return value

    @field_validator("timezone_id")
    @classmethod
    def validate_timezone(cls, value: str | None) -> str | None:
        return _validate_timezone(value)

    @model_validator(mode="after")
    def validate_state_pair(self) -> AssignmentUpdate:
        fields = self.model_fields_set
        if {"status", "progress_percent"}.issubset(fields):
            if self.status == "done" and self.progress_percent != 100:
                raise ValueError("done status requires progress_percent 100")
            if self.status == "todo" and self.progress_percent != 0:
                raise ValueError("todo status requires progress_percent 0")
            if self.status == "in_progress" and self.progress_percent == 100:
                raise ValueError("progress_percent 100 requires done status")
        return self


class AssignmentStatusUpdate(BaseModel):
    status: AssignmentStatus

    @field_validator("status", mode="before")
    @classmethod
    def normalize_status_value(cls, value: object) -> object:
        return normalize_status(value)


class AssignmentRead(AssignmentBase):
    model_config = ConfigDict(from_attributes=True)

    id: int
    uuid: str
    completed_at: str | None
    created_at: datetime
    updated_at: datetime

    @field_serializer("due_date")
    def serialize_due_date(self, value: datetime | None) -> str | None:
        if value is None:
            return None
        return value.strftime("%Y-%m-%d %H:%M")


class CourseBase(BaseModel):
    name: str = Field(..., min_length=1, max_length=120)
    color_hex: str | None = None
    teacher: str | None = Field(default=None, max_length=255)
    semester: str | None = Field(default=None, max_length=255)
    is_archived: bool = False

    @field_validator("name")
    @classmethod
    def validate_name(cls, value: str) -> str:
        return _clean_required(value)

    @field_validator("teacher", "semester")
    @classmethod
    def validate_optional_text(cls, value: str | None) -> str | None:
        return _clean_optional(value)

    @field_validator("color_hex")
    @classmethod
    def validate_color(cls, value: str | None) -> str | None:
        return _validate_color(value)


class CourseCreate(CourseBase):
    pass


class CourseUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=120)
    color_hex: str | None = None
    teacher: str | None = Field(default=None, max_length=255)
    semester: str | None = Field(default=None, max_length=255)
    is_archived: bool | None = None

    @field_validator("name")
    @classmethod
    def validate_name(cls, value: str | None) -> str | None:
        if value is None:
            raise ValueError("name cannot be null")
        return _clean_required(value)

    @field_validator("teacher", "semester")
    @classmethod
    def validate_optional_text(cls, value: str | None) -> str | None:
        return _clean_optional(value)

    @field_validator("color_hex")
    @classmethod
    def validate_color(cls, value: str | None) -> str | None:
        return _validate_color(value)

    @field_validator("is_archived")
    @classmethod
    def validate_is_archived(cls, value: bool | None) -> bool:
        if value is None:
            raise ValueError("is_archived cannot be null")
        return value


class CourseRead(CourseBase):
    model_config = ConfigDict(from_attributes=True)

    id: int
    uuid: str
    normalized_name: str
    created_at: str
    updated_at: str


class ProjectBase(BaseModel):
    course_id: int | None = Field(default=None, ge=1)
    name: str = Field(..., min_length=1, max_length=255)
    description: str | None = None
    status: ProjectStatus = "active"

    @field_validator("name")
    @classmethod
    def validate_name(cls, value: str) -> str:
        return _clean_required(value)

    @field_validator("description")
    @classmethod
    def validate_description(cls, value: str | None) -> str | None:
        return _clean_optional(value)


class ProjectCreate(ProjectBase):
    pass


class ProjectUpdate(BaseModel):
    course_id: int | None = Field(default=None, ge=1)
    name: str | None = Field(default=None, min_length=1, max_length=255)
    description: str | None = None
    status: ProjectStatus | None = None

    @field_validator("name")
    @classmethod
    def validate_name(cls, value: str | None) -> str | None:
        if value is None:
            raise ValueError("name cannot be null")
        return _clean_required(value)

    @field_validator("description")
    @classmethod
    def validate_description(cls, value: str | None) -> str | None:
        return _clean_optional(value)

    @field_validator("status")
    @classmethod
    def validate_status(cls, value: str | None) -> str:
        if value is None:
            raise ValueError("status cannot be null")
        return value


class ProjectRead(ProjectBase):
    model_config = ConfigDict(from_attributes=True)

    id: int
    uuid: str
    created_at: str
    updated_at: str


class TagBase(BaseModel):
    name: str = Field(..., min_length=1, max_length=80)
    color_hex: str | None = None

    @field_validator("name")
    @classmethod
    def validate_name(cls, value: str) -> str:
        return _clean_required(value)

    @field_validator("color_hex")
    @classmethod
    def validate_color(cls, value: str | None) -> str | None:
        return _validate_color(value)


class TagCreate(TagBase):
    pass


class TagUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=80)
    color_hex: str | None = None

    @field_validator("name")
    @classmethod
    def validate_name(cls, value: str | None) -> str | None:
        if value is None:
            raise ValueError("name cannot be null")
        return _clean_required(value)

    @field_validator("color_hex")
    @classmethod
    def validate_color(cls, value: str | None) -> str | None:
        return _validate_color(value)


class TagRead(TagBase):
    model_config = ConfigDict(from_attributes=True)

    id: int
    uuid: str
    normalized_name: str
    created_at: str
    updated_at: str


class TaskTagRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    uuid: str
    assignment_id: int
    tag_id: int
    created_at: str
    updated_at: str


class SubtaskBase(BaseModel):
    title: str = Field(..., min_length=1, max_length=255)
    status: AssignmentStatus = "todo"
    sort_order: int = Field(default=0, ge=0)

    @field_validator("title")
    @classmethod
    def validate_title(cls, value: str) -> str:
        return _clean_required(value)

    @field_validator("status", mode="before")
    @classmethod
    def normalize_status_value(cls, value: object) -> object:
        return normalize_status(value)


class SubtaskCreate(SubtaskBase):
    pass


class SubtaskUpdate(BaseModel):
    title: str | None = Field(default=None, min_length=1, max_length=255)
    status: AssignmentStatus | None = None
    sort_order: int | None = Field(default=None, ge=0)

    @field_validator("title")
    @classmethod
    def validate_title(cls, value: str | None) -> str | None:
        if value is None:
            raise ValueError("title cannot be null")
        return _clean_required(value)

    @field_validator("status", mode="before")
    @classmethod
    def normalize_status_value(cls, value: object) -> object:
        if value is None:
            raise ValueError("status cannot be null")
        return normalize_status(value)

    @field_validator("sort_order")
    @classmethod
    def validate_sort_order(cls, value: int | None) -> int:
        if value is None:
            raise ValueError("sort_order cannot be null")
        return value


class SubtaskRead(SubtaskBase):
    model_config = ConfigDict(from_attributes=True)

    id: int
    uuid: str
    assignment_id: int
    completed_at: str | None
    created_at: str
    updated_at: str


class AttachmentCreate(BaseModel):
    file_name: str = Field(..., min_length=1, max_length=255)
    mime_type: str | None = Field(default=None, max_length=255)
    byte_size: int = Field(..., ge=0)
    sha256: str

    @field_validator("file_name")
    @classmethod
    def validate_file_name(cls, value: str) -> str:
        cleaned = value.strip()
        if (
            cleaned in {"", ".", ".."}
            or "\x00" in cleaned
            or "/" in cleaned
            or "\\" in cleaned
        ):
            raise ValueError("file_name must be safe metadata without path separators")
        return cleaned

    @field_validator("mime_type")
    @classmethod
    def validate_mime_type(cls, value: str | None) -> str | None:
        return _clean_optional(value)

    @field_validator("sha256")
    @classmethod
    def validate_sha256(cls, value: str) -> str:
        cleaned = value.strip()
        if _SHA256.fullmatch(cleaned) is None:
            raise ValueError("sha256 must be 64 lowercase hexadecimal characters")
        return cleaned


class AttachmentRead(AttachmentCreate):
    model_config = ConfigDict(from_attributes=True)

    id: int
    uuid: str
    assignment_id: int
    relative_path: str
    created_at: str
    updated_at: str


class ReminderBase(BaseModel):
    trigger_at_utc: str
    lead_minutes: int = Field(default=0, ge=0)
    repeat_rule: str | None = None
    is_enabled: bool = True

    @field_validator("trigger_at_utc")
    @classmethod
    def validate_trigger(cls, value: str) -> str:
        cleaned = value.strip()
        if not is_utc_audit_timestamp(cleaned):
            raise ValueError("trigger_at_utc must be canonical ISO-8601 UTC with Z")
        return cleaned

    @field_validator("repeat_rule")
    @classmethod
    def validate_repeat_rule(cls, value: str | None) -> str | None:
        return _validate_repeat_rule(value)


class ReminderCreate(ReminderBase):
    pass


class ReminderUpdate(BaseModel):
    trigger_at_utc: str | None = None
    lead_minutes: int | None = Field(default=None, ge=0)
    repeat_rule: str | None = None
    is_enabled: bool | None = None
    last_scheduled_at: str | None = None

    @field_validator("trigger_at_utc")
    @classmethod
    def validate_trigger_at(cls, value: str | None) -> str:
        if value is None:
            raise ValueError("trigger_at_utc cannot be null")
        cleaned = _clean_optional(value)
        if cleaned is None or not is_utc_audit_timestamp(cleaned):
            raise ValueError("timestamp must be canonical ISO-8601 UTC with Z")
        return cleaned

    @field_validator("last_scheduled_at")
    @classmethod
    def validate_last_scheduled(cls, value: str | None) -> str | None:
        cleaned = _clean_optional(value)
        if cleaned is not None and not is_utc_audit_timestamp(cleaned):
            raise ValueError("timestamp must be canonical ISO-8601 UTC with Z")
        return cleaned

    @field_validator("repeat_rule")
    @classmethod
    def validate_repeat_rule(cls, value: str | None) -> str | None:
        return _validate_repeat_rule(value)

    @field_validator("lead_minutes", "is_enabled")
    @classmethod
    def validate_required_scalars(cls, value: object) -> object:
        if value is None:
            raise ValueError("Field cannot be null")
        return value


class ReminderRead(ReminderBase):
    model_config = ConfigDict(from_attributes=True)

    id: int
    uuid: str
    assignment_id: int
    last_scheduled_at: str | None
    created_at: str
    updated_at: str
