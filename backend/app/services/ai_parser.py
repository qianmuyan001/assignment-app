from __future__ import annotations

import json
import os
import re
from abc import ABC, abstractmethod
from typing import Any

import requests

from .html_importer import parse_assignments_from_text


AI_ASSIGNMENT_PROMPT = """
Extract assignment candidates from the provided course page text.

Return only strict JSON. Do not include markdown or explanations.

Required JSON format:
[
  {
    "course_name": "INFO 201",
    "title": "Final Project Report",
    "due_date": "2026-07-15",
    "due_time": "23:59",
    "description": "Submit the final project report.",
    "source_name": "Canvas HTML",
    "source_type": "html_file",
    "source_file": "canvas_assignments.html",
    "source_url": "",
    "confidence": "medium",
    "raw_text": "Original text line or block used for this assignment",
    "warnings": []
  }
]

Rules:
- Only extract real assignments, quizzes, exams, projects, readings, discussions, labs, reflections, or submissions.
- Do not include navigation text, menu items, or unrelated course page text.
- If due date is missing, use null for due_date.
- If due time is missing, use null for due_time.
- If course name is not clear, use the provided default course name.
- Return an empty list if no assignments are found.
- Use YYYY-MM-DD for due_date when a date is clear.
- Use HH:MM 24-hour time for due_time when a time is clear.
- If a date is unclear, such as "tomorrow" or "next Friday", use null and add a warning.
""".strip()


class ParserUnavailableError(Exception):
    pass


class ParserOutputError(Exception):
    pass


class BaseAssignmentParser(ABC):
    name = "base"

    def is_available(self) -> bool:
        return True

    @abstractmethod
    def parse(self, text: str, context: dict[str, Any] | None = None) -> list[dict[str, Any]]:
        raise NotImplementedError


class RuleBasedAssignmentParser(BaseAssignmentParser):
    name = "rule"

    def parse(self, text: str, context: dict[str, Any] | None = None) -> list[dict[str, Any]]:
        context = context or {}
        return parse_assignments_from_text(text, context.get("course_name"))


class MockAIAssignmentParser(BaseAssignmentParser):
    name = "mock"

    def is_available(self) -> bool:
        return bool(os.getenv("ASSIGNMENT_AI_MOCK_RESPONSE"))

    def parse(self, text: str, context: dict[str, Any] | None = None) -> list[dict[str, Any]]:
        response = os.getenv("ASSIGNMENT_AI_MOCK_RESPONSE")
        if not response:
            raise ParserUnavailableError("Mock AI parser is not configured.")
        return parse_json_assignment_output(response)


class OpenAIAssignmentParser(BaseAssignmentParser):
    name = "openai"

    def __init__(self) -> None:
        self.api_key = os.getenv("OPENAI_API_KEY")
        self.model = os.getenv("ASSIGNMENT_AI_MODEL", "gpt-4o-mini")
        self.base_url = os.getenv("ASSIGNMENT_AI_BASE_URL", "https://api.openai.com/v1").rstrip("/")

    def is_available(self) -> bool:
        return bool(self.api_key)

    def parse(self, text: str, context: dict[str, Any] | None = None) -> list[dict[str, Any]]:
        if not self.api_key:
            raise ParserUnavailableError("OPENAI_API_KEY is not set.")

        payload = {
            "model": self.model,
            "input": [
                {
                    "role": "system",
                    "content": [{"type": "input_text", "text": AI_ASSIGNMENT_PROMPT}],
                },
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "input_text",
                            "text": _build_user_prompt(text, context or {}),
                        }
                    ],
                },
            ],
            "text": {
                "format": {
                    "type": "json_schema",
                    "name": "assignment_candidates",
                    "strict": True,
                    "schema": _assignment_json_schema(),
                }
            },
        }
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
        }

        try:
            response = requests.post(
                f"{self.base_url}/responses",
                headers=headers,
                json=payload,
                timeout=45,
            )
        except requests.RequestException as error:
            raise ParserUnavailableError(f"OpenAI parser request failed: {error}") from error

        if not response.ok:
            raise ParserUnavailableError(
                f"OpenAI parser returned HTTP {response.status_code}: {response.text[:500]}"
            )

        data = response.json()
        return parse_json_assignment_output(_extract_openai_text(data))


class OllamaAssignmentParser(BaseAssignmentParser):
    name = "ollama"

    def __init__(self) -> None:
        self.model = os.getenv("ASSIGNMENT_AI_MODEL")
        self.base_url = os.getenv("ASSIGNMENT_AI_BASE_URL", "http://localhost:11434").rstrip("/")

    def is_available(self) -> bool:
        return bool(self.model and self.base_url)

    def parse(self, text: str, context: dict[str, Any] | None = None) -> list[dict[str, Any]]:
        if not self.is_available():
            raise ParserUnavailableError("Ollama parser needs ASSIGNMENT_AI_MODEL and ASSIGNMENT_AI_BASE_URL.")

        prompt = f"{AI_ASSIGNMENT_PROMPT}\n\n{_build_user_prompt(text, context or {})}"
        payload = {
            "model": self.model,
            "prompt": prompt,
            "stream": False,
            "format": "json",
        }

        try:
            response = requests.post(f"{self.base_url}/api/generate", json=payload, timeout=60)
        except requests.RequestException as error:
            raise ParserUnavailableError(f"Ollama parser request failed: {error}") from error

        if not response.ok:
            raise ParserUnavailableError(
                f"Ollama parser returned HTTP {response.status_code}: {response.text[:500]}"
            )

        data = response.json()
        return parse_json_assignment_output(str(data.get("response", "")))


class AIAssignmentParser(BaseAssignmentParser):
    name = "ai"

    def __init__(self) -> None:
        provider = os.getenv("ASSIGNMENT_AI_PROVIDER", "mock").strip().lower()
        self.provider_name = provider or "mock"
        self.provider = self._build_provider(self.provider_name)

    def is_available(self) -> bool:
        return self.provider.is_available()

    def parse(self, text: str, context: dict[str, Any] | None = None) -> list[dict[str, Any]]:
        if not self.provider.is_available():
            raise ParserUnavailableError(f"AI parser provider '{self.provider_name}' is not configured.")
        return self.provider.parse(text, context)

    def _build_provider(self, provider_name: str) -> BaseAssignmentParser:
        if provider_name == "openai":
            return OpenAIAssignmentParser()
        if provider_name == "ollama":
            return OllamaAssignmentParser()
        if provider_name == "mock":
            return MockAIAssignmentParser()
        return UnavailableAssignmentParser(provider_name)


class UnavailableAssignmentParser(BaseAssignmentParser):
    def __init__(self, provider_name: str) -> None:
        self.name = provider_name

    def is_available(self) -> bool:
        return False

    def parse(self, text: str, context: dict[str, Any] | None = None) -> list[dict[str, Any]]:
        raise ParserUnavailableError(f"Unknown AI parser provider: {self.name}")


def parse_json_assignment_output(output: str) -> list[dict[str, Any]]:
    cleaned = _strip_json_fence(output)
    try:
        data = json.loads(cleaned)
    except json.JSONDecodeError as error:
        raise ParserOutputError(f"AI parser returned malformed JSON: {error}") from error

    if isinstance(data, dict) and isinstance(data.get("assignments"), list):
        data = data["assignments"]

    if not isinstance(data, list):
        raise ParserOutputError("AI parser JSON must be a list of assignments.")

    assignments = []
    for item in data:
        if isinstance(item, dict):
            assignments.append(item)
    return assignments


def _strip_json_fence(output: str) -> str:
    text = output.strip()
    fence_match = re.match(r"^```(?:json)?\s*(.*?)\s*```$", text, re.DOTALL | re.IGNORECASE)
    if fence_match:
        return fence_match.group(1).strip()
    return text


def _build_user_prompt(text: str, context: dict[str, Any]) -> str:
    safe_text = text[:24000]
    return (
        "Context:\n"
        f"{json.dumps(context, indent=2)}\n\n"
        "Course page text:\n"
        f"{safe_text}"
    )


def _assignment_json_schema() -> dict[str, Any]:
    item_schema = {
        "type": "object",
        "properties": {
            "course_name": {"type": ["string", "null"]},
            "title": {"type": "string"},
            "due_date": {"type": ["string", "null"]},
            "due_time": {"type": ["string", "null"]},
            "description": {"type": ["string", "null"]},
            "source_name": {"type": ["string", "null"]},
            "source_type": {"type": ["string", "null"]},
            "source_file": {"type": ["string", "null"]},
            "source_url": {"type": ["string", "null"]},
            "confidence": {"type": ["string", "null"]},
            "raw_text": {"type": ["string", "null"]},
            "warnings": {"type": "array", "items": {"type": "string"}},
        },
        "required": [
            "course_name",
            "title",
            "due_date",
            "due_time",
            "description",
            "source_name",
            "source_type",
            "source_file",
            "source_url",
            "confidence",
            "raw_text",
            "warnings",
        ],
        "additionalProperties": False,
    }
    return {"type": "array", "items": item_schema}


def _extract_openai_text(data: dict[str, Any]) -> str:
    if isinstance(data.get("output_text"), str):
        return data["output_text"]

    pieces = []
    for item in data.get("output", []):
        for content in item.get("content", []):
            if isinstance(content.get("text"), str):
                pieces.append(content["text"])

    if not pieces:
        raise ParserOutputError("OpenAI response did not include text output.")

    return "\n".join(pieces)

