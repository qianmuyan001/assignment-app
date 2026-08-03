from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass
class ImportSource:
    source_name: str | None = None
    source_type: str | None = None
    source_file: str | None = None
    source_url: str | None = None
    course_name: str | None = None
    metadata: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_dict(cls, data: dict[str, Any] | None) -> "ImportSource":
        data = data or {}
        return cls(
            source_name=_clean_optional_text(data.get("source_name")),
            source_type=_clean_optional_text(data.get("source_type")),
            source_file=_clean_optional_text(data.get("source_file")),
            source_url=_clean_optional_text(data.get("source_url")),
            course_name=_clean_optional_text(data.get("course_name")),
            metadata=dict(data.get("metadata") or {}),
        )

    def to_context(self) -> dict[str, Any]:
        return {
            "source_name": self.source_name,
            "source_type": self.source_type,
            "source_file": self.source_file,
            "source_url": self.source_url,
            "course_name": self.course_name,
            "metadata": self.metadata,
        }


@dataclass
class ImportContent:
    cleaned_text: str
    raw_content: str | None = None
    content_type: str = "clean_text"


@dataclass
class AssignmentCandidate:
    course_name: str | None
    title: str
    due_date: str | None = None
    due_time: str | None = None
    description: str | None = None
    source_name: str | None = None
    source_type: str | None = None
    source_file: str | None = None
    source_url: str | None = None
    confidence: str = "medium"
    raw_text: str | None = None
    warnings: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "course_name": self.course_name,
            "title": self.title,
            "due_date": self.due_date,
            "due_time": self.due_time,
            "description": self.description,
            "source_name": self.source_name,
            "source_type": self.source_type,
            "source_file": self.source_file,
            "source_url": self.source_url,
            "confidence": self.confidence,
            "raw_text": self.raw_text,
            "warnings": self.warnings,
        }


@dataclass
class ParseResult:
    candidates: list[dict[str, Any]]
    parser_mode: str
    parser_used: str | None
    fallback_used: bool = False
    message: str | None = None
    warnings: list[str] = field(default_factory=list)
    error: str | None = None


def _clean_optional_text(value: Any) -> str | None:
    if value is None:
        return None
    cleaned = str(value).strip()
    return cleaned or None

