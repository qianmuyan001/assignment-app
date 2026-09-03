"""Rule-based natural-language schedule parser.

The parser turns a block of free-form text into a list of
:class:`~shared.natural_language.contract.ParsedTask` candidates. It is the
first-milestone implementation: fully offline, deterministic, and free of any
database or UI dependency. The public entry point
(:func:`parse_schedule` / :class:`NaturalLanguageScheduleParser`) is stable so a
later AI-backed parser can be swapped in without changing callers.

Design notes
------------
* Segmentation splits on sentence enders, newlines and semicolons, and further
  splits a comma-joined clause when the right side opens with an independent
  action verb (so "开小组会，记得准备演示文稿" becomes two tasks).
* Field extraction collects character spans to strip from the title so the
  generated title reads like a real task name rather than raw metadata.
* Every candidate carries ``warnings`` for anything ambiguous (past date,
  inferred 23:59 deadline, missing course, etc.) and a heuristic ``confidence``
  so the import-preview UI can sort or flag low-confidence rows.
"""

from __future__ import annotations

import re
from datetime import datetime
from typing import Optional

from .chinese_dates import (
    extract_reminder,
    infer_due_datetime,
    resolve_date,
    resolve_time,
)
from .contract import ParsedSchedule, ParsedTask

# Course aliases -> canonical display name. Extend as needed; matching is
# case-insensitive on the alias and the canonical name is what gets stored.
_COURSE_ALIASES = {
    "高数": "高等数学",
    "高数课": "高等数学",
    "数分": "数学分析",
    "线代": "线性代数",
    "大物": "大学物理",
    "物理": "大学物理",
    "计组": "计算机组成原理",
    "组成": "计算机组成原理",
    "操统": "操作系统",
    "os": "操作系统",
    "数电": "数字电路",
    "模电": "模拟电路",
    "离散": "离散数学",
    "概率": "概率论与数理统计",
    "概率论": "概率论与数理统计",
    "英语": "英语",
    "思政": "思想政治理论",
    "马原": "马克思主义基本原理",
    "毛概": "毛泽东思想和中国特色社会主义理论体系概论",
    "史纲": "中国近现代史纲要",
    "数据结构": "数据结构",
    "算法": "算法设计与分析",
    "编译": "编译原理",
    "计网": "计算机网络",
    "网络": "计算机网络",
    "数据库": "数据库系统",
    "软工": "软件工程",
    "机器学习": "机器学习",
    "dl": "深度学习",
    "深度学习": "深度学习",
}

# Leading polite/reminder modifiers that are not part of the task title.
_LEADING_MODIFIERS = (
    "记得", "要", "需要", "请", "帮我", "务必", "一定", "别忘了", "别忘",
    "抽空", "有空", "顺便", "然后", "之后", "再", "也", "可以", "建议",
    "最好", "麻烦", "去", "把",
)

# Core action verbs whose object becomes the title; strip the verb itself.
_ACTION_VERBS = (
    "完成", "做完", "写好", "写", "做", "准备", "复习", "预习", "讨论", "开",
    "参加", "看", "读", "收拾", "整理", "打扫", "买", "取", "寄", "填",
    "申请", "报名", "学习", "练习", "练", "背", "听", "提交", "交", "发",
    "发给", "回复", "确认", "预约", "处理", "搞定", "修改", "改", "检查", "核对",
)

# Filler the user types but which carries no task semantics.
_FILLER_PHRASES = (
    "没有明确截止时间", "没有明确时间", "暂无截止时间", "时间待定",
    "截止时间待定", "日期待定", "时间未定",
)

# Trailing deadline verbs to drop when a due date was found.
_DEADLINE_VERBS = (
    "前提交", "之前提交", "前交", "之前交", "提交", "交上去", "交差",
    "发给", "送达", "搞定", "做完", "写完", "完成",
)

_PRIORITY_HIGH = ("紧急", "特急", "火速", "重要", "比较重要", "很重要",
                  "优先", "优先处理", "尽快", "赶紧", "asap", "urgent", "加急")
_PRIORITY_LOW = ("不急", "低优先", "不太重要", "随意", "有空再", "无所谓")

_URL_RE = re.compile(r"https?://\S+|www\.\S+")
_TAG_RE = re.compile(r"#\s*([^\s#]+)")
_LOCATION_RE = re.compile(
    r"(?:在|去|到)\s*([^，。；;，\s]{1,20}?)\s*"
    r"(?:开会|讨论|见面|集合|上课|考试|交|做|进行|举办|开展|见|答辩|汇报)"
)
_COURSE_PATTERN_RE = re.compile(
    r"([\u4e00-\u9fa5A-Za-z0-9]{1,12}?)"
    r"(?:作业|的课|实验报告|实验|报告|课|考试|测验|论文|大作业|project)",
    re.IGNORECASE,
)

# Characters that must not appear inside a detected course-name prefix; their
# presence means we matched a verb/date fragment, not a course.
_FORBIDDEN_COURSE_CHARS = set(
    "交写做提交完成复习准备讨论参加预习去到在前面之后然后周月日号点时早晚"
    "上下本这今提醒记得需要请帮要和与及"
)


class NaturalLanguageScheduleParser:
    """Stateless rule-based parser.

    A ``now`` reference is required for every call so relative dates resolve
    deterministically. ``timezone_id`` is accepted for forward compatibility
    with schema v3 (stored on the task) but the first milestone does not use
    it for resolution.
    """

    def parse(self, text: str, *, now: datetime, timezone_id: Optional[str] = None) -> ParsedSchedule:
        if not text or not text.strip():
            return ParsedSchedule(tasks=[], source_text=text or "")
        segments = _split_segments(text)
        tasks: list[ParsedTask] = []
        schedule_warnings: list[str] = []
        for seg in segments:
            task = self._parse_one(seg, now=now, timezone_id=timezone_id)
            if task is not None:
                tasks.append(task)
        if not tasks:
            schedule_warnings.append("未能从文本中识别出任何任务，请检查输入或手动添加")
        return ParsedSchedule(tasks=tasks, source_text=text, warnings=schedule_warnings)

    # -- per-segment parsing -------------------------------------------------

    def _parse_one(
        self, seg: str, *, now: datetime, timezone_id: Optional[str]
    ) -> Optional[ParsedTask]:
        if len(seg.strip()) < 2:
            return None
        if not _looks_like_task(seg):
            return None

        warnings: list[str] = []
        remove_literals: list[str] = []

        # Date + time -> due datetime
        resolved_date, date_warns, date_spans = resolve_date(seg, now)
        resolved_time, time_explicit, time_spans = resolve_time(seg)
        due, due_warns, _ = infer_due_datetime(
            seg, now, resolved_date, resolved_time, time_explicit
        )
        warnings.extend(date_warns)
        warnings.extend(due_warns)
        if date_spans:
            remove_literals.append(seg[date_spans[0][0]:date_spans[0][1]])
        if time_spans:
            remove_literals.append(seg[time_spans[0][0]:time_spans[0][1]])

        # Reminder
        reminder_at, lead, rem_warns, rem_spans = extract_reminder(seg, due, now)
        warnings.extend(rem_warns)
        if rem_spans:
            remove_literals.append(seg[rem_spans[0][0]:rem_spans[0][1]])

        # Priority
        priority, prio_literal = _extract_priority(seg)
        if prio_literal:
            remove_literals.append(prio_literal)

        # Course
        course_name, course_literal = _extract_course(seg)
        # Course literal is intentionally NOT stripped from the title: course
        # words usually double as the task noun (e.g. "高数作业").
        if course_name is None and re.search(r"作业|的课|实验|考试|测验|论文|大作业", seg):
            warnings.append("未识别到课程，导入后请在编辑器中补充")

        # Location
        location, loc_literal = _extract_location(seg)
        if loc_literal:
            remove_literals.append(loc_literal)

        # Link
        link, link_literal = _extract_link(seg)
        if link_literal:
            remove_literals.append(link_literal)

        # Tags
        tags = _extract_tags(seg)

        # Title
        title, title_fallback = _build_title(seg, remove_literals, due is not None)
        if title_fallback:
            warnings.append("未能生成明确标题，已使用清理后的原文，请确认")

        if due is None:
            warnings.append("未识别到截止时间，导入后请在编辑器中补充")

        confidence = _confidence(warnings, title_fallback, due is not None)

        task = ParsedTask(
            title=title,
            source_snippet=seg,
            due_date=due,
            course_name=course_name,
            priority=priority,
            link=link,
            location=location,
            tags=tags,
            reminder_at=reminder_at,
            reminder_lead_minutes=lead,
            confidence=confidence,
            warnings=warnings,
        )
        if timezone_id is not None:
            # Stored forward-compat; resolution itself stays wall-clock.
            task.warnings.append(f"timezone_id 提示：{timezone_id}（本版本按本地时间解析）")
        return task


def parse_schedule(
    text: str, *, now: datetime, timezone_id: Optional[str] = None
) -> ParsedSchedule:
    """Convenience wrapper around :class:`NaturalLanguageScheduleParser`."""

    return NaturalLanguageScheduleParser().parse(text, now=now, timezone_id=timezone_id)


# ---------------------------------------------------------------------------
# Segmentation
# ---------------------------------------------------------------------------


def _split_segments(text: str) -> list[str]:
    text = text.strip()
    pieces = re.split(r"[。！？\n\r]+", text)
    segments: list[str] = []
    for piece in pieces:
        piece = piece.strip()
        if not piece:
            continue
        for sub in re.split(r"[；;]+", piece):
            sub = sub.strip()
            if sub:
                segments.extend(_maybe_split_comma(sub))
    return segments


def _maybe_split_comma(sub: str) -> list[str]:
    if "，" not in sub and "," not in sub:
        return [sub]
    parts = re.split(r"[，,]", sub)
    if len(parts) <= 1:
        return [sub]
    tasks: list[str] = []
    buf = parts[0]
    for part in parts[1:]:
        stripped = part.strip()
        if stripped and _starts_with_action(stripped):
            tasks.append(buf.strip())
            buf = part
        else:
            buf = f"{buf}，{part}"
    tasks.append(buf.strip())
    return [t for t in tasks if t]


def _starts_with_action(text: str) -> bool:
    return any(text.startswith(v) for v in ("记得", "准备", "去", "做", "写", "完成",
            "复习", "买", "预约", "参加", "开", "讨论", "交", "提交", "看", "读",
            "收拾", "整理", "打扫", "打电话", "发", "回复", "确认", "学习", "练",
            "背", "听", "取", "寄", "填", "申请", "报名", "处理", "改", "检查"))


def _looks_like_task(seg: str) -> bool:
    """Heuristic gate: skip pure connective/punctuation fragments."""

    if not re.search(r"[\u4e00-\u9fa5A-Za-z]", seg):
        return False
    # Require at least one task-like signal: a verb, a date, a course word, or
    # a deadline word.
    signals = (
        r"作业|任务|交|提交|完成|做|写|复习|考试|测验|开会|开|讨论|准备|提醒|截止|"
        r"前|之前|报告|论文|项目|预习|练|背|读|买|预约|参加|实验|大作业|会"
    )
    if re.search(signals, seg):
        return True
    # A bare date/course mention is still worth a candidate.
    return bool(resolve_date(seg, datetime.now())[0]) or bool(
        _COURSE_PATTERN_RE.search(seg)
    )


# ---------------------------------------------------------------------------
# Field extractors
# ---------------------------------------------------------------------------


def _extract_priority(seg: str) -> tuple[Optional[str], Optional[str]]:
    low = seg_lower = seg.lower()
    for word in _PRIORITY_HIGH:
        if word.lower() in low:
            idx = low.find(word.lower())
            return "high", seg[idx:idx + len(word)]
    for word in _PRIORITY_LOW:
        if word.lower() in low:
            idx = low.find(word.lower())
            return "low", seg[idx:idx + len(word)]
    return None, None


def _extract_course(seg: str) -> tuple[Optional[str], Optional[str]]:
    # 1. Direct alias hit bounded by whitespace/punctuation.
    for alias, canonical in _COURSE_ALIASES.items():
        if re.search(rf"(?:^|[\s，,。；;]){re.escape(alias)}(?:[\s，,。；;]|$)", seg):
            if not any(c in _FORBIDDEN_COURSE_CHARS for c in alias):
                return canonical, alias
    # 2. "X作业" / "X实验" / "X考试" ... with a clean course prefix.
    _LEADING_VERB_CHARS = "交写做提交完成复习准备讨论参加预习去到在"
    for m in _COURSE_PATTERN_RE.finditer(seg):
        prefix = m.group(1)
        prefix = prefix.lstrip(_LEADING_VERB_CHARS)
        if not prefix:
            continue
        if any(c in _FORBIDDEN_COURSE_CHARS for c in prefix):
            continue
        if len(prefix) > 6:
            continue
        canonical = _COURSE_ALIASES.get(prefix.lower(), prefix)
        idx = m.start(1)
        return canonical, seg[idx:idx + len(m.group(1))]
    # 3. "上X课" pattern.
    m = re.search(r"上\s*([\u4e00-\u9fa5A-Za-z0-9]{1,8})\s*课", seg)
    if m:
        alias = m.group(1)
        if not any(c in _FORBIDDEN_COURSE_CHARS for c in alias):
            canonical = _COURSE_ALIASES.get(alias.lower(), alias)
            return canonical, m.group(0)
    return None, None


def _extract_location(seg: str) -> tuple[Optional[str], Optional[str]]:
    m = _LOCATION_RE.search(seg)
    if m:
        # Strip only the "在/去/到 <location>" wrapper, keep the verb clause.
        literal = seg[m.start():m.end(1)]
        return m.group(1), literal
    m = re.search(r"地点\s*[:：]\s*([^\s，。；;]{1,20})", seg)
    if m:
        return m.group(1), m.group(0)
    return None, None


def _extract_link(seg: str) -> tuple[Optional[str], Optional[str]]:
    m = _URL_RE.search(seg)
    if m:
        return m.group(0), m.group(0)
    return None, None


def _extract_tags(seg: str) -> list[str]:
    return [t for t in _TAG_RE.findall(seg)]


# ---------------------------------------------------------------------------
# Title construction
# ---------------------------------------------------------------------------


def _build_title(seg: str, remove_literals: list[str], due_found: bool) -> tuple[str, bool]:
    t = seg
    for lit in remove_literals:
        if lit:
            t = t.replace(lit, " ", 1)
    # Drop trailing deadline verbs only when a due date anchors them.
    if due_found:
        for verb in _DEADLINE_VERBS:
            if t.strip().endswith(verb) or f"前{verb}" in t or f"之前{verb}" in t:
                t = t.replace(verb, " ", 1)
    # Drop a dangling leading "前" / "之前" left after deadline-verb removal.
    t = t.strip()
    if t.startswith("之前"):
        t = t[2:]
    elif t.startswith("前"):
        t = t[1:]
    # Drop filler phrases that carry no task semantics.
    for filler in _FILLER_PHRASES:
        t = t.replace(filler, " ")
    # Strip leading modifiers and action verbs.
    changed = True
    while changed:
        changed = False
        for mod in _LEADING_MODIFIERS:
            if t.startswith(mod):
                t = t[len(mod):]
                changed = True
                break
        for verb in _ACTION_VERBS:
            if t.startswith(verb):
                t = t[len(verb):]
                changed = True
                break
    t = _clean_text(t)
    if t:
        return t, False
    # Fallback: keep a lightly cleaned version of the original segment.
    fallback = _clean_text(re.sub(r"https?://\S+|www\.\S+", " ", seg))
    return fallback or seg.strip(), True


def _clean_text(text: str) -> str:
    text = text.strip()
    text = re.sub(r"[，,。；;：:、\s]+", " ", text)
    text = re.sub(r"\s{2,}", " ", text).strip()
    return text


# ---------------------------------------------------------------------------
# Confidence
# ---------------------------------------------------------------------------


def _confidence(warnings: list[str], title_fallback: bool, due_found: bool) -> float:
    score = 1.0
    score -= 0.15 * len(warnings)
    if title_fallback:
        score -= 0.3
    if not due_found:
        score -= 0.1
    return round(max(0.2, score), 2)
