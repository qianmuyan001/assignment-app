"""Validated wire contracts for the shared v4 learning scenes."""
from __future__ import annotations

from dataclasses import fields
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from shared.schema_v4 import (
    MeetingWindow,
    SchemaV4Error,
    _validate_local_datetime,
    _validated_time_zone,
    parse_local_date,
    parse_local_time,
)

from .schemas import AssignmentRead

ExamStatus = Literal["upcoming", "completed", "cancelled"]


class SceneInput(BaseModel):
    model_config = ConfigDict(extra="forbid")

    @field_validator("*", mode="after")
    @classmethod
    def trim_text(cls, value: object) -> object:
        if isinstance(value, str):
            return value.strip()
        return value


class MeetingCreate(SceneInput):
    course_id: int = Field(ge=1, strict=True)
    weekday: int = Field(ge=1, le=7, strict=True)
    start_time_local: str
    end_time_local: str
    timezone_id: str = Field(min_length=1, max_length=255)
    effective_start_date: str
    effective_end_date: str | None = None
    location: str | None = Field(default=None, max_length=1000)
    teacher_override: str | None = Field(default=None, max_length=255)
    sort_order: int = Field(default=0, ge=0, strict=True)

    @model_validator(mode="after")
    def validate_window(self) -> "MeetingCreate":
        try:
            MeetingWindow(**{field.name: getattr(self, field.name) for field in fields(MeetingWindow)})
        except SchemaV4Error as exc:
            raise ValueError(str(exc)) from exc
        return self


class MeetingUpdate(SceneInput):
    course_id: int | None = Field(default=None, ge=1, strict=True)
    weekday: int | None = Field(default=None, ge=1, le=7, strict=True)
    start_time_local: str | None = None
    end_time_local: str | None = None
    timezone_id: str | None = Field(default=None, min_length=1, max_length=255)
    effective_start_date: str | None = None
    effective_end_date: str | None = None
    location: str | None = Field(default=None, max_length=1000)
    teacher_override: str | None = Field(default=None, max_length=255)
    sort_order: int | None = Field(default=None, ge=0, strict=True)

    @field_validator("start_time_local", "end_time_local")
    @classmethod
    def validate_clock(cls, value: str | None) -> str:
        try:
            parse_local_time(value)
        except SchemaV4Error as exc:
            raise ValueError(str(exc)) from exc
        return value

    @field_validator("effective_start_date", "effective_end_date")
    @classmethod
    def validate_date(cls, value: str | None) -> str | None:
        if value is not None:
            try:
                parse_local_date(value)
            except SchemaV4Error as exc:
                raise ValueError(str(exc)) from exc
        return value

    @field_validator("timezone_id")
    @classmethod
    def validate_zone(cls, value: str | None) -> str:
        try:
            _validated_time_zone(value)
        except SchemaV4Error as exc:
            raise ValueError(str(exc)) from exc
        return value

    @model_validator(mode="after")
    def reject_null_required(self) -> "MeetingUpdate":
        nullable = {"effective_end_date", "location", "teacher_override"}
        for name in self.model_fields_set - nullable:
            if getattr(self, name) is None:
                raise ValueError(f"{name} cannot be null")
        return self


class ExamCreate(SceneInput):
    course_id: int = Field(ge=1, strict=True)
    name: str = Field(min_length=1, max_length=255)
    starts_at_local: str
    timezone_id: str = Field(min_length=1, max_length=255)
    location: str | None = Field(default=None, max_length=1000)
    scope: str | None = Field(default=None, max_length=10000)
    notes: str | None = Field(default=None, max_length=10000)
    status: ExamStatus = "upcoming"

    @field_validator("name")
    @classmethod
    def require_name(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("name cannot be empty")
        return value.strip()

    @field_validator("starts_at_local")
    @classmethod
    def validate_start(cls, value: str) -> str:
        try:
            _validate_local_datetime(value)
        except SchemaV4Error as exc:
            raise ValueError(str(exc)) from exc
        return value

    @field_validator("timezone_id")
    @classmethod
    def validate_zone(cls, value: str) -> str:
        try:
            _validated_time_zone(value)
        except SchemaV4Error as exc:
            raise ValueError(str(exc)) from exc
        return value


class ExamUpdate(SceneInput):
    course_id: int | None = Field(default=None, ge=1, strict=True)
    name: str | None = Field(default=None, min_length=1, max_length=255)
    starts_at_local: str | None = None
    timezone_id: str | None = Field(default=None, min_length=1, max_length=255)
    location: str | None = Field(default=None, max_length=1000)
    scope: str | None = Field(default=None, max_length=10000)
    notes: str | None = Field(default=None, max_length=10000)
    status: ExamStatus | None = None

    @model_validator(mode="after")
    def reject_null_required(self) -> "ExamUpdate":
        for name in self.model_fields_set - {"location", "scope", "notes"}:
            if getattr(self, name) is None:
                raise ValueError(f"{name} cannot be null")
        return self


class SceneWarning(BaseModel):
    code: Literal["overlap", "nonexistent_local_time", "unresolvable_task_deadline"]
    message: str
    related_id: int | None = None
    on_date: str | None = None


class Occurrence(BaseModel):
    date: str
    starts_at_utc: str | None
    ends_at_utc: str | None


class MeetingRead(MeetingCreate):
    # Existing databases may carry extension columns; the API exposes the contract only.
    model_config = ConfigDict(extra="ignore")
    id: int
    uuid: str
    created_at: str
    updated_at: str
    deleted_at: str | None
    course_name: str
    warnings: list[SceneWarning] = Field(default_factory=list)
    occurrences: list[Occurrence] = Field(default_factory=list)


class ExamRead(ExamCreate):
    model_config = ConfigDict(extra="ignore")
    id: int
    uuid: str
    created_at: str
    updated_at: str
    deleted_at: str | None
    course_name: str
    linked_assignment_id: int | None
    starts_at_utc: str | None
    warnings: list[SceneWarning] = Field(default_factory=list)


class LearningTaskRead(AssignmentRead):
    deleted_at: str | None = None
    due_at_utc: str | None = None


class ReviewTaskRead(BaseModel):
    exam: ExamRead
    assignment: LearningTaskRead
    created: bool


class TodayRead(BaseModel):
    date: str
    timezone_id: str
    meetings: list[MeetingRead]
    upcoming_exams: list[ExamRead]
    due_today: list[LearningTaskRead]
    overdue: list[LearningTaskRead]
    warnings: list[SceneWarning]
