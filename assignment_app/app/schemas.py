from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator


AssignmentStatus = Literal["todo", "in_progress", "done", "ignored"]


class AssignmentBase(BaseModel):
    course_name: str = Field(..., min_length=1)
    title: str = Field(..., min_length=1)
    due_date: datetime
    description: str | None = None
    source_url: str | None = None
    source_name: str | None = None
    status: AssignmentStatus = "todo"

    @field_validator("course_name", "title")
    @classmethod
    def required_text_cannot_be_empty(cls, value: str) -> str:
        cleaned = value.strip()
        if not cleaned:
            raise ValueError("This field cannot be empty")
        return cleaned

    @field_validator("description", "source_url", "source_name")
    @classmethod
    def clean_optional_text(cls, value: str | None) -> str | None:
        if value is None:
            return None

        cleaned = value.strip()
        return cleaned or None


class AssignmentCreate(AssignmentBase):
    """Data needed when creating a new assignment."""


class AssignmentRead(AssignmentBase):
    """Data returned by the API after an assignment has been saved."""

    model_config = ConfigDict(from_attributes=True)

    id: int
    created_at: datetime
    updated_at: datetime


class AssignmentUpdate(BaseModel):
    course_name: str | None = Field(default=None, min_length=1)
    title: str | None = Field(default=None, min_length=1)
    due_date: datetime | None = None
    description: str | None = None
    source_url: str | None = None
    source_name: str | None = None
    status: AssignmentStatus | None = None

    @field_validator("course_name", "title")
    @classmethod
    def required_text_cannot_be_empty(cls, value: str | None) -> str | None:
        if value is None:
            return None

        cleaned = value.strip()
        if not cleaned:
            raise ValueError("This field cannot be empty")
        return cleaned

    @field_validator("description", "source_url", "source_name")
    @classmethod
    def clean_optional_text(cls, value: str | None) -> str | None:
        if value is None:
            return None

        cleaned = value.strip()
        return cleaned or None


class AssignmentStatusUpdate(BaseModel):
    status: AssignmentStatus
