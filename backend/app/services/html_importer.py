from __future__ import annotations

import re
from datetime import date, datetime
from pathlib import Path
from typing import Any

from bs4 import BeautifulSoup


MAX_HTML_BYTES = 8 * 1024 * 1024
ASSIGNMENT_WORDS = (
    "assignment",
    "homework",
    "essay",
    "paper",
    "project",
    "quiz",
    "quizzes",
    "exam",
    "test",
    "discussion",
    "lab",
    "worksheet",
    "reading",
    "module",
    "submission",
    "due",
)
MONTHS = {
    "jan": 1,
    "january": 1,
    "feb": 2,
    "february": 2,
    "mar": 3,
    "march": 3,
    "apr": 4,
    "april": 4,
    "may": 5,
    "jun": 6,
    "june": 6,
    "jul": 7,
    "july": 7,
    "aug": 8,
    "august": 8,
    "sep": 9,
    "sept": 9,
    "september": 9,
    "oct": 10,
    "october": 10,
    "nov": 11,
    "november": 11,
    "dec": 12,
    "december": 12,
}


def read_html_file(file_path: str | Path) -> str:
    path = Path(file_path).expanduser()
    if not path.exists():
        raise FileNotFoundError(f"HTML file was not found: {path}")
    if not path.is_file():
        raise ValueError(f"Selected path is not a file: {path}")
    if path.suffix.lower() not in {".html", ".htm"}:
        raise ValueError("Please select a .html or .htm file.")
    if path.stat().st_size > MAX_HTML_BYTES:
        raise ValueError("The selected HTML file is too large to import safely.")

    return path.read_text(encoding="utf-8", errors="replace")


def extract_clean_text_from_html(html_content: str) -> str:
    soup = BeautifulSoup(html_content, "html.parser")

    for tag in soup(["script", "style", "noscript", "svg", "canvas"]):
        tag.decompose()

    text = soup.get_text(separator="\n")
    lines = []
    previous_blank = False

    for raw_line in text.splitlines():
        line = re.sub(r"\s+", " ", raw_line).strip()
        is_blank = not line

        if is_blank and previous_blank:
            continue

        lines.append(line)
        previous_blank = is_blank

    return "\n".join(lines).strip()


def parse_assignments_from_text(
    text: str,
    default_course_name: str | None = None,
) -> list[dict[str, Any]]:
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    candidates: list[dict[str, Any]] = []
    seen: set[tuple[str, str | None]] = set()

    for index, line in enumerate(lines[:5000]):
        if not _looks_like_assignment_line(line):
            continue

        nearby_text = " ".join(lines[index : min(index + 3, len(lines))])
        due_at = _find_due_datetime(nearby_text)
        title = _clean_title(line)

        if len(title) < 3:
            continue

        due_date = due_at.strftime("%Y-%m-%d") if due_at else None
        due_time = due_at.strftime("%H:%M") if due_at else None
        key = (title.lower(), due_date, due_time)
        if key in seen:
            continue
        seen.add(key)

        candidates.append(
            {
                "course_name": (default_course_name or "").strip(),
                "title": title[:255],
                "due_date": due_date,
                "due_time": due_time,
                "description": nearby_text[:1000],
                "status": "not_started",
                "source_name": (default_course_name or "Local HTML import").strip(),
                "source_type": "local_html",
                "source_file": None,
                "source_url": None,
                "confidence": "medium" if due_at else "low",
                "raw_text": nearby_text[:1000],
                "warnings": [] if due_at else ["No due date was detected."],
            }
        )

    return candidates


def _looks_like_assignment_line(line: str) -> bool:
    lowered = line.lower()
    if len(line) > 350:
        return False
    has_assignment_word = any(
        re.search(rf"\b{re.escape(word)}s?\b", lowered)
        for word in ASSIGNMENT_WORDS
    )
    return has_assignment_word or _find_due_datetime(line) is not None


def _clean_title(line: str) -> str:
    title = re.sub(r"\b(due|available|until|by)\b.*$", "", line, flags=re.IGNORECASE).strip()
    title = re.sub(r"^\W+", "", title)
    title = re.sub(r"\s+", " ", title)
    return title or line[:255]


def _find_due_datetime(text: str) -> datetime | None:
    for parser in (_parse_iso_date, _parse_month_name_date, _parse_numeric_date):
        parsed = parser(text)
        if parsed is not None:
            return parsed
    return None


def _parse_iso_date(text: str) -> datetime | None:
    match = re.search(
        r"\b(?P<year>\d{4})-(?P<month>\d{1,2})-(?P<day>\d{1,2})"
        r"(?:[ T](?P<hour>\d{1,2})(?::(?P<minute>\d{2}))?\s*(?P<ampm>am|pm)?)?",
        text,
        re.IGNORECASE,
    )
    if not match:
        return None
    return _build_datetime(match.groupdict())


def _parse_numeric_date(text: str) -> datetime | None:
    match = re.search(
        r"\b(?P<month>\d{1,2})/(?P<day>\d{1,2})(?:/(?P<year>\d{2,4}))?"
        r"(?:\s*(?:at|by)?\s*(?P<hour>\d{1,2})(?::(?P<minute>\d{2}))?\s*(?P<ampm>am|pm)?)?",
        text,
        re.IGNORECASE,
    )
    if not match:
        return None
    return _build_datetime(match.groupdict())


def _parse_month_name_date(text: str) -> datetime | None:
    month_names = "|".join(sorted(MONTHS.keys(), key=len, reverse=True))
    match = re.search(
        rf"\b(?P<month_name>{month_names})\.?\s+(?P<day>\d{{1,2}})(?:,\s*(?P<year>\d{{4}}))?"
        rf"(?:\s*(?:at|by)?\s*(?P<hour>\d{{1,2}})(?::(?P<minute>\d{{2}}))?\s*(?P<ampm>am|pm)?)?",
        text,
        re.IGNORECASE,
    )
    if not match:
        return None

    values = match.groupdict()
    values["month"] = str(MONTHS[values["month_name"].lower().rstrip(".")])
    return _build_datetime(values)


def _build_datetime(values: dict[str, str | None]) -> datetime | None:
    try:
        year_text = values.get("year")
        year = int(year_text) if year_text else date.today().year
        if year < 100:
            year += 2000

        month = int(values["month"] or 0)
        day = int(values["day"] or 0)
        hour = int(values.get("hour") or 23)
        minute = int(values.get("minute") or 59)
        ampm = (values.get("ampm") or "").lower()

        if ampm == "pm" and hour < 12:
            hour += 12
        elif ampm == "am" and hour == 12:
            hour = 0

        return datetime(year, month, day, hour, minute)
    except (TypeError, ValueError):
        return None
