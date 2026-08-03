from __future__ import annotations

import re
from datetime import datetime
from typing import Any

from .ai_parser import AIAssignmentParser, ParserOutputError, ParserUnavailableError, RuleBasedAssignmentParser
from .parser_types import AssignmentCandidate, ImportContent, ImportSource, ParseResult


PARSER_MODES = {"auto", "ai", "rule"}
RELATIVE_DATE_WORDS = ("today", "tomorrow", "next ", "yesterday")


def parse_import_content(
    content: str | ImportContent,
    source_info: dict[str, Any] | ImportSource | None = None,
    parser_mode: str = "auto",
) -> ParseResult:
    """Parse cleaned import content from any source.

    Today the GUI passes cleaned text from a local HTML file. Future browser
    agents, pasted text importers, PDFs, CSVs, or course exports can call this
    same function with their own source_info and no local file path.
    """
    mode = _normalize_parser_mode(parser_mode)
    source = source_info if isinstance(source_info, ImportSource) else ImportSource.from_dict(source_info)
    import_content = content if isinstance(content, ImportContent) else ImportContent(cleaned_text=str(content))
    text = import_content.cleaned_text

    if mode == "rule":
        candidates = _run_rule_parser(text, source)
        return ParseResult(candidates=candidates, parser_mode=mode, parser_used="rule")

    ai_parser = AIAssignmentParser()
    if not ai_parser.is_available():
        message = "AI parser was not available. Rule-based parser was used instead."
        if mode == "ai":
            return ParseResult(
                candidates=[],
                parser_mode=mode,
                parser_used=None,
                error="AI parser is not configured. Switch to Auto or Rule-based mode, or set AI environment variables.",
            )

        return ParseResult(
            candidates=_run_rule_parser(text, source),
            parser_mode=mode,
            parser_used="rule",
            fallback_used=True,
            message=message,
            warnings=[message],
        )

    try:
        candidates = _normalize_candidates(ai_parser.parse(text, source.to_context()), source)
    except (ParserUnavailableError, ParserOutputError, ValueError) as error:
        if mode == "ai":
            return ParseResult(
                candidates=[],
                parser_mode=mode,
                parser_used="ai",
                error=str(error),
            )

        message = f"AI parser failed. Rule-based parser was used instead. Reason: {error}"
        return ParseResult(
            candidates=_run_rule_parser(text, source),
            parser_mode=mode,
            parser_used="rule",
            fallback_used=True,
            message=message,
            warnings=[message],
        )

    return ParseResult(candidates=candidates, parser_mode=mode, parser_used="ai")


def _run_rule_parser(text: str, source: ImportSource) -> list[dict[str, Any]]:
    parser = RuleBasedAssignmentParser()
    return _normalize_candidates(parser.parse(text, source.to_context()), source)


def _normalize_parser_mode(parser_mode: str) -> str:
    mode = (parser_mode or "auto").strip().lower()
    if mode == "rule-based":
        mode = "rule"
    if mode not in PARSER_MODES:
        return "auto"
    return mode


def _normalize_candidates(raw_candidates: list[dict[str, Any]], source: ImportSource) -> list[dict[str, Any]]:
    normalized: list[dict[str, Any]] = []
    seen: set[tuple[str, str | None, str | None]] = set()

    for raw in raw_candidates:
        candidate = _normalize_candidate(raw, source)
        if candidate is None:
            continue

        key = (
            candidate.title.lower(),
            candidate.due_date,
            candidate.due_time,
        )
        if key in seen:
            continue
        seen.add(key)
        normalized.append(candidate.to_dict())

    return normalized


def _normalize_candidate(raw: dict[str, Any], source: ImportSource) -> AssignmentCandidate | None:
    title = _clean_text(raw.get("title"))
    if not title:
        return None

    warnings = _normalize_warnings(raw.get("warnings"))
    due_date, due_time, due_warnings = _normalize_due_fields(raw.get("due_date"), raw.get("due_time"))
    warnings.extend(due_warnings)

    course_name = _clean_text(raw.get("course_name")) or source.course_name
    source_name = source.source_name or _clean_text(raw.get("source_name"))
    source_type = source.source_type or _clean_text(raw.get("source_type"))
    source_file = source.source_file or _clean_text(raw.get("source_file"))
    source_url = source.source_url or _clean_text(raw.get("source_url"))
    confidence = _normalize_confidence(raw.get("confidence"))

    return AssignmentCandidate(
        course_name=course_name,
        title=title[:255],
        due_date=due_date,
        due_time=due_time,
        description=_clean_text(raw.get("description")),
        source_name=source_name,
        source_type=source_type,
        source_file=source_file,
        source_url=source_url,
        confidence=confidence,
        raw_text=_clean_text(raw.get("raw_text")),
        warnings=warnings,
    )


def _normalize_due_fields(due_date_value: Any, due_time_value: Any) -> tuple[str | None, str | None, list[str]]:
    warnings: list[str] = []
    due_date_text = _clean_text(due_date_value)
    due_time_text = _clean_text(due_time_value)

    if due_date_text and _contains_relative_date(due_date_text):
        warnings.append(f"Unclear due date '{due_date_text}' was not imported.")
        due_date_text = None

    if due_date_text:
        combined = f"{due_date_text} {due_time_text}".strip()
        parsed = _parse_due_datetime(combined)
        if parsed is None:
            warnings.append(f"Could not safely parse due date '{combined}'.")
            due_date_text = None
            due_time_text = None
        else:
            if not due_time_text and re.search(r"\d{1,2}:\d{2}", due_date_text):
                due_time_text = parsed.strftime("%H:%M")
            due_date_text = parsed.strftime("%Y-%m-%d")
            due_time_text = due_time_text or None
            if due_time_text:
                due_time_text = parsed.strftime("%H:%M")
    elif due_time_text:
        warnings.append("Due time was found without a due date.")
        due_time_text = None

    return due_date_text, due_time_text, warnings


def _parse_due_datetime(value: str) -> datetime | None:
    value = value.strip()
    for date_format in (
        "%Y-%m-%d %H:%M",
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d",
        "%Y-%m-%dT%H:%M",
        "%Y-%m-%dT%H:%M:%S",
    ):
        try:
            return datetime.strptime(value, date_format)
        except ValueError:
            pass
    return None


def _contains_relative_date(value: str) -> bool:
    lowered = value.lower()
    return any(word in lowered for word in RELATIVE_DATE_WORDS)


def _normalize_warnings(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, list):
        return [str(item).strip() for item in value if str(item).strip()]
    text = str(value).strip()
    return [text] if text else []


def _normalize_confidence(value: Any) -> str:
    if isinstance(value, (int, float)):
        if value >= 0.75:
            return "high"
        if value >= 0.45:
            return "medium"
        return "low"

    text = _clean_text(value).lower()
    if text in {"high", "medium", "low"}:
        return text
    return "medium"


def _clean_text(value: Any) -> str | None:
    if value is None:
        return None
    cleaned = re.sub(r"\s+", " ", str(value)).strip()
    return cleaned or None
