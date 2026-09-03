"""Data contract for natural-language schedule parsing results.

The classes here describe *candidates*: structured interpretations of free text
that a later UI step shows to the user for confirmation. They intentionally
mirror the SQLite schema v3 task shape so that, once confirmed, a candidate can
be written with almost no transformation.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Optional

# Mirrors shared/schema_v3.py assignment priority domain and
# shared/task_rules.py TaskPriority literal.
VALID_PRIORITIES: tuple[str, ...] = ("low", "medium", "high")

# UI status literals accepted on import (the repository layer maps these to
# the database "not_started" / "in_progress" / "completed" values).
VALID_IMPORT_STATUSES: tuple[str, ...] = ("todo", "in_progress", "done")


@dataclass
class ParsedTask:
    """One structured task candidate parsed from a text segment."""

    title: str
    source_snippet: str
    description: Optional[str] = None
    due_date: Optional[datetime] = None
    course_name: Optional[str] = None
    project_name: Optional[str] = None
    tags: list[str] = field(default_factory=list)
    priority: Optional[str] = None
    link: Optional[str] = None
    location: Optional[str] = None
    reminder_at: Optional[datetime] = None
    reminder_lead_minutes: Optional[int] = None
    confidence: float = 1.0
    warnings: list[str] = field(default_factory=list)

    def __post_init__(self) -> None:
        if not self.title or not self.title.strip():
            raise ValueError("ParsedTask.title must be a non-empty string")
        if self.priority is not None and self.priority not in VALID_PRIORITIES:
            raise ValueError(f"unsupported priority: {self.priority!r}")
        if self.due_date is not None and self.due_date.tzinfo is not None:
            raise ValueError("due_date must be a timezone-free local wall time")
        if self.reminder_at is not None and self.reminder_at.tzinfo is not None:
            raise ValueError("reminder_at must be a timezone-free local wall time")
        self.tags = [t for t in self.tags if t]
        self.warnings = list(self.warnings)

    def to_contract_dict(self) -> dict[str, Any]:
        """Return a schema v3 shaped dict for the confirmed-import path.

        Missing optional fields are omitted so the repository layer applies its
        own defaults (status -> not_started, priority -> medium). ``due_date``
        is serialised as the local ISO string the schema stores.
        """

        data: dict[str, Any] = {
            "title": self.title.strip(),
            "status": "not_started",
        }
        if self.description:
            data["description"] = self.description
        if self.due_date is not None:
            data["due_date"] = self.due_date.strftime("%Y-%m-%dT%H:%M:%S")
            data["all_day"] = 0
        if self.course_name:
            data["course_name"] = self.course_name
        if self.project_name:
            data["project_name"] = self.project_name
        if self.priority:
            data["priority"] = self.priority
        if self.link:
            data["link"] = self.link
        if self.tags:
            data["tags"] = list(self.tags)
        if self.location:
            data["location"] = self.location
        return data


@dataclass
class ParsedSchedule:
    """The full result of parsing one block of text."""

    tasks: list[ParsedTask]
    source_text: str
    warnings: list[str] = field(default_factory=list)

    @property
    def task_count(self) -> int:
        return len(self.tasks)

    def to_contract_list(self) -> list[dict[str, Any]]:
        return [task.to_contract_dict() for task in self.tasks]
