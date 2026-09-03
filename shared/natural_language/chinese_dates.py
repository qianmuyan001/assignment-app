"""Rule-based Chinese date and time resolution.

Every public function takes a ``now`` reference (a timezone-free local wall
time). Returning times relative to an explicit ``now`` keeps the parser fully
deterministic: "明天", "下周三" and "月底" resolve identically on every test
run, which is what makes the corpus tests reproducible.

None of these functions touch the database or the UI.
"""

from __future__ import annotations

import re
from datetime import date, datetime, time, timedelta
from typing import Optional

# ---------------------------------------------------------------------------
# Weekday helpers
# ---------------------------------------------------------------------------

_WEEKDAY_CN: dict[str, int] = {
    "一": 0, "二": 1, "三": 2, "四": 3, "五": 4, "六": 5, "日": 6, "天": 6,
    "1": 0, "2": 1, "3": 2, "4": 3, "5": 4, "6": 5, "7": 6,
}

# Spoken Chinese numerals used for clock hours and reminder lead amounts.
# Includes the two-character forms needed for clock hours 10-23.
_SPOKEN_HOUR: dict[str, int] = {
    "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6,
    "七": 7, "八": 8, "九": 9, "十": 10, "十一": 11, "十二": 12, "十三": 13,
    "十四": 14, "十五": 15, "十六": 16, "十七": 17, "十八": 18, "十九": 19,
    "二十": 20, "二十一": 21, "二十二": 22, "二十三": 23,
}

_WEEKDAY_PREFIXES_PAST = ("上", "上一", "上周", "上星期", "上礼拜")
_WEEKDAY_PREFIXES_NEXT = ("下", "下一", "下周", "下星期", "下礼拜")
_WEEKDAY_WORDS = ("周", "星期", "礼拜")

# Period words that shift a spoken 12-hour clock onto 24-hour time.
_PERIOD_AM = ("凌晨", "早上", "早晨", "上午")
_PERIOD_NOON = ("中午",)
_PERIOD_PM = ("下午", "傍晚", "晚上", "夜里", "深夜")


def _upcoming_weekday(now: date, weekday: int) -> date:
    """Return the date of ``weekday`` on or after ``now`` (today if it matches)."""

    days_ahead = (weekday - now.weekday()) % 7
    return now + timedelta(days=days_ahead)


# ---------------------------------------------------------------------------
# Date resolution
# ---------------------------------------------------------------------------


def resolve_date(text: str, now: datetime) -> tuple[Optional[date], list[str], list[tuple[int, int]]]:
    """Find the first absolute or relative date mention in ``text``.

    Returns ``(date | None, warnings, spans)`` where ``spans`` are character
    ranges the caller should strip from the generated title.
    """

    warnings: list[str] = []
    spans: list[tuple[int, int]] = []

    # 1. YYYY年M月D日 / YYYY年M月D号
    m = re.search(r"(\d{4})\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*[日号]?", text)
    if m:
        y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
        return _build_date(y, mo, d, m.span(), now, warnings, spans)

    # 2. YYYY/M/D or YYYY-M-D (year first, unambiguous)
    m = re.search(r"(\d{4})\s*[-/]\s*(\d{1,2})\s*[-/]\s*(\d{1,2})", text)
    if m:
        y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
        return _build_date(y, mo, d, m.span(), now, warnings, spans)

    # 3. M月D日 / M月D号
    m = re.search(r"(\d{1,2})\s*月\s*(\d{1,2})\s*[日号]?", text)
    if m:
        mo, d = int(m.group(1)), int(m.group(2))
        return _build_date(now.year, mo, d, m.span(), now, warnings, spans)

    # 4. M/D or M-D (no year)
    m = re.search(r"(?<![\d/-])(\d{1,2})\s*[-/]\s*(\d{1,2})(?![\d/-])", text)
    if m:
        mo, d = int(m.group(1)), int(m.group(2))
        if 1 <= mo <= 12 and 1 <= d <= 31:
            return _build_date(now.year, mo, d, m.span(), now, warnings, spans)

    # 5. Relative day words
    for word, delta in (("大后天", 3), ("后天", 2), ("明天", 1), ("明日", 1),
                        ("今天", 0), ("今日", 0), ("前天", -2), ("昨天", -1),
                        ("昨日", -1)):
        m = re.search(word, text)
        if m:
            target = (now + timedelta(days=delta)).date()
            if delta < 0:
                warnings.append(f"日期「{word}」已在过去，请确认")
            return target, warnings, [m.span()]

    # 6. Weekday mentions
    for prefix in ("下下一", "下一", "下", "上一", "上", "这个", "本", "这", ""):
        for ww in _WEEKDAY_WORDS:
            pattern = re.escape(prefix) + ww + r"([一二三四五六日天1-7])"
            m = re.search(pattern, text)
            if m:
                wd = _WEEKDAY_CN[m.group(1)]
                target = _upcoming_weekday(now.date(), wd)
                if prefix in _WEEKDAY_PREFIXES_NEXT:
                    target = target + timedelta(days=7)
                elif prefix in _WEEKDAY_PREFIXES_PAST:
                    target = target - timedelta(days=7)
                    warnings.append(f"日期「{m.group(0)}」已在过去，请确认")
                return target, warnings, [m.span()]

    # 7. 周末 -> upcoming Saturday
    m = re.search(r"周末", text)
    if m:
        sat = _upcoming_weekday(now.date(), 5)
        return sat, warnings, [m.span()]

    # 8. 月底 / 月末 -> last day of current month
    m = re.search(r"(本|这个|这)?\s*月[底末]", text)
    if m:
        last = _last_day_of_month(now.year, now.month)
        return date(now.year, now.month, last), warnings, [m.span()]

    # 9. 月初 -> 1st of current month
    m = re.search(r"(本|这个|这)?\s*月[初头]", text)
    if m:
        return date(now.year, now.month, 1), warnings, [m.span()]

    # 10. 下个月 / 下月 (optionally 第一周)
    m = re.search(r"下\s*个?\s*月", text)
    if m:
        week_m = re.search(r"下\s*个?\s*月\s*第一?\s*周", text)
        if week_m:
            first = date(now.year, now.month, 1) + timedelta(days=32)
            first = date(first.year, first.month, 1)
            monday = _upcoming_weekday(first, 0)
            return monday, warnings, [week_m.span()]
        nxt = _first_day_next_month(now)
        return nxt, warnings, [m.span()]

    # 11. 年底前 / 年末 -> Dec 31
    m = re.search(r"(今|本|这)?\s*年\s*(底|末|底前|底之前)", text)
    if m:
        return date(now.year, 12, 31), warnings, [m.span()]

    # 11b. N年后 (e.g. "三年后", "2年后")
    m = re.search(r"(\d+|[零一二两三四五六七八九十])\s*年\s*(后|以后|之后)", text)
    if m:
        amount = _parse_spoken_hour(m.group(1))
        if amount is None:
            amount = 1
        target = date(now.year + amount, now.month, now.day)
        warnings.append(f"按「{m.group(0)}」解释为 {target.isoformat()}，请确认")
        return target, warnings, [m.span()]

    return None, warnings, spans


def _build_date(
    year: int,
    month: int,
    day: int,
    span: tuple[int, int],
    now: datetime,
    warnings: list[str],
    spans: list[tuple[int, int]],
) -> tuple[Optional[date], list[str], list[tuple[int, int]]]:
    try:
        target = date(year, month, day)
    except ValueError:
        warnings.append(f"无法识别的日期：{year}年{month}月{day}日")
        return None, warnings, [span]
    if target < now.date():
        warnings.append(f"日期 {target.isoformat()} 早于今天，已按今年/明年解释，请确认")
        # If a no-year date already passed this year, assume next year.
        if year == now.year:
            try:
                target = date(now.year + 1, month, day)
            except ValueError:
                pass
    return target, warnings, [span]


def _last_day_of_month(year: int, month: int) -> int:
    if month == 12:
        nxt = date(year + 1, 1, 1)
    else:
        nxt = date(year, month + 1, 1)
    return (nxt - timedelta(days=1)).day


def _first_day_next_month(now: datetime) -> date:
    if now.month == 12:
        return date(now.year + 1, 1, 1)
    return date(now.year, now.month + 1, 1)


# ---------------------------------------------------------------------------
# Time resolution
# ---------------------------------------------------------------------------


def _parse_spoken_hour(raw: str) -> Optional[int]:
    """Convert a clock-hour token that may be an ASCII digit or a Chinese numeral."""

    if raw.isdigit():
        return int(raw)
    return _SPOKEN_HOUR.get(raw)


def resolve_time(text: str) -> tuple[Optional[time], bool, list[tuple[int, int]]]:
    """Find an explicit time-of-day mention.

    Returns ``(time | None, explicit, spans)``. ``explicit`` is False when only
    a date was present (so the caller knows to infer an end-of-day deadline and
    warn the user). Spoken hours such as "两点" / "三点" are accepted.
    """

    spans: list[tuple[int, int]] = []

    # 24-hour HH:MM / HH：MM
    m = re.search(r"(?<![\d:])(\d{1,2})\s*[:：]\s*(\d{2})(?![\d:])", text)
    if m:
        h, mi = int(m.group(1)), int(m.group(2))
        if 0 <= h <= 23 and 0 <= mi <= 59:
            return time(h, mi), True, [m.span()]

    # Period word + spoken hour (+ fraction)
    m = re.search(
        r"(凌晨|早上|早晨|上午|中午|下午|傍晚|晚上|夜里|深夜)?\s*"
        r"(\d{1,2}|[零一二两三四五六七八九十]{1,2})\s*(点|時|时)"
        r"\s*(半|整|一?刻|两?刻|三刻|(\d{1,2})\s*分?)?",
        text,
    )
    if m:
        period = m.group(1)
        hour = _parse_spoken_hour(m.group(2))
        if hour is None or hour == 0 or hour > 23:
            return None, False, []
        # group(3) is the "点/時/时" marker; group(4) is the fraction
        # (半/整/刻/...), group(5) the optional numeric minute.
        frac = m.group(4)
        minute = _resolve_minute_fraction(frac, m.group(5))
        hour24 = _to_24h(period, hour)
        if hour24 is None:
            return None, False, []
        spans.append(m.span())
        return time(hour24, minute), True, spans

    return None, False, spans


def _resolve_minute_fraction(frac: Optional[str], raw_minute: Optional[str]) -> int:
    if frac is None:
        return 0
    if frac == "半":
        return 30
    if frac == "整":
        return 0
    if frac == "一刻":
        return 15
    if frac in ("两刻", "二刻"):
        return 30
    if frac == "三刻":
        return 45
    if raw_minute is not None and raw_minute.isdigit():
        return max(0, min(59, int(raw_minute)))
    return 0


def _to_24h(period: Optional[str], hour: int) -> Optional[int]:
    if period in _PERIOD_AM:
        return hour % 24
    if period in _PERIOD_NOON:
        return 12 if hour == 12 else 12 + hour
    if period in _PERIOD_PM:
        if hour == 12:
            return 0 if period in ("晚上", "夜里", "深夜") else 12
        return 12 + hour
    # No period: treat the spoken hour as 24-hour, but flag ambiguity upstream.
    if hour == 12:
        return 12
    return hour


# ---------------------------------------------------------------------------
# Deadline + reminder semantics
# ---------------------------------------------------------------------------


def infer_due_datetime(
    text: str,
    now: datetime,
    resolved_date: Optional[date],
    resolved_time: Optional[time],
    time_explicit: bool,
) -> tuple[Optional[datetime], list[str], list[tuple[int, int]]]:
    """Combine a resolved date and time into a due datetime.

    When a date is present but no time, the deadline defaults to 23:59 of that
    day and a warning is recorded so the UI can surface the assumption.
    """

    warnings: list[str] = []
    spans: list[tuple[int, int]] = []

    if resolved_date is None:
        if resolved_time is not None:
            dt = datetime.combine(now.date(), resolved_time)
            warnings.append("未指定日期，已按今天解释该时间，请确认")
            return dt, warnings, spans
        return None, warnings, spans

    if resolved_time is None:
        dt = datetime.combine(resolved_date, time(23, 59))
        warnings.append("未指定具体时间，截止时间默认为当天 23:59，请确认")
    else:
        dt = datetime.combine(resolved_date, resolved_time)
        if not time_explicit and resolved_time.hour == 0 and resolved_time.minute == 0:
            warnings.append("未明确上午/下午，已按 24 小时制解释，请确认")

    if dt < now:
        warnings.append(f"截止时间 {dt.strftime('%Y-%m-%d %H:%M')} 早于当前时间，请确认")
    return dt, warnings, spans


def extract_reminder(
    text: str,
    due: Optional[datetime],
    now: datetime,
) -> tuple[Optional[datetime], Optional[int], list[str], list[tuple[int, int]]]:
    """Detect a reminder request and compute its trigger time.

    Supports "提前N分钟/小时/天提醒" (with lead) and a bare "提醒/提醒我"
    (remind at the due time, lead 0). Returns
    ``(reminder_at, lead_minutes, warnings, spans)``.
    """

    warnings: list[str] = []
    spans: list[tuple[int, int]] = []

    # Explicit lead: 提前 N 单位 提醒 (N may be an ASCII or Chinese numeral)
    m = re.search(
        r"提前\s*(\d+|[零一二两三四五六七八九十])\s*(分钟|分|个小时|小时|天|日|号)?\s*(提醒|通知|闹钟)?",
        text,
    )
    if m:
        amount = _parse_spoken_hour(m.group(1))
        if amount is None:
            amount = 0
        unit = m.group(2)
        lead = _lead_minutes(amount, unit)
        spans.append(m.span())
        if due is not None:
            reminder_at = due - timedelta(minutes=lead)
            return reminder_at, lead, warnings, spans
        # Lead given but no due date: try to parse an explicit reminder datetime.
        reminder_at = _parse_reminder_datetime(text, now, exclude=spans)
        if reminder_at is not None:
            return reminder_at, lead, warnings, spans
        warnings.append("指定了提前提醒但没有截止时间，仅记录提醒意图")
        return None, lead, warnings, spans

    # Bare reminder keyword without lead.
    m = re.search(r"(提醒我|到时候提醒|通知我|设个?闹钟|提醒一下|提醒)", text)
    if m:
        spans.append(m.span())
        if due is not None:
            warnings.append("未指定提前量，已按截止时间提醒")
            return due, 0, warnings, spans
        reminder_at = _parse_reminder_datetime(text, now, exclude=spans)
        if reminder_at is not None:
            return reminder_at, 0, warnings, spans
        warnings.append("检测到提醒意图但没有截止时间，未生成提醒")
        return None, None, warnings, spans

    return None, None, warnings, spans


def _lead_minutes(amount: int, unit: Optional[str]) -> int:
    if unit in ("小时", "个小时"):
        return amount * 60
    if unit in ("天", "日", "号"):
        return amount * 1440
    return amount  # 分钟 / 分 / None


def _parse_reminder_datetime(
    text: str, now: datetime, exclude: list[tuple[int, int]]
) -> Optional[datetime]:
    """Best-effort parse of an explicit reminder datetime near a reminder word."""

    rd, warns, _ = resolve_date(text, now)
    rt, explicit, _ = resolve_time(text)
    if rd is None:
        return None
    if rt is None:
        return datetime.combine(rd, time(23, 59))
    return datetime.combine(rd, rt)
