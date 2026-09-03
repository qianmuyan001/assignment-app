"""Tests and corpus for the natural-language schedule parser.

These are pure-Python, database-free contract tests. They pin the deterministic
behaviour of :mod:`shared.natural_language` so that the parsing quality can be
measured and regressed before any WinUI import-preview UI is built.

A fixed ``NOW`` reference (Thursday 2026-09-03 10:00 local wall time) is used
for every case, because all relative dates resolve against it.
"""

from __future__ import annotations

import unittest
from datetime import datetime

from shared.natural_language import (
    ParsedSchedule,
    ParsedTask,
    parse_schedule,
)
from shared.natural_language.chinese_dates import (
    extract_reminder,
    infer_due_datetime,
    resolve_date,
    resolve_time,
)

# Thursday 2026-09-03 10:00 (local wall time, no timezone).
NOW = datetime(2026, 9, 3, 10, 0, 0)


def _parse(text: str, **kwargs) -> ParsedSchedule:
    return parse_schedule(text, now=NOW, **kwargs)


def _first(text: str, **kwargs) -> ParsedTask:
    sched = _parse(text, **kwargs)
    assert sched.tasks, f"expected at least one task from: {text!r}"
    return sched.tasks[0]


class ChineseDateResolutionTest(unittest.TestCase):
    """Pin the relative/absolute date resolution rules."""

    def test_absolute_year_month_day(self):
        d, warns, _ = resolve_date("2026年12月31日前提交", NOW)
        self.assertEqual(d, datetime(2026, 12, 31).date())

    def test_absolute_month_day_this_year(self):
        d, _, _ = resolve_date("9月15日交", NOW)
        self.assertEqual(d, datetime(2026, 9, 15).date())

    def test_absolute_slash_date(self):
        d, _, _ = resolve_date("10/5 之前", NOW)
        self.assertEqual(d, datetime(2026, 10, 5).date())

    def test_today(self):
        d, _, _ = resolve_date("今天交", NOW)
        self.assertEqual(d, datetime(2026, 9, 3).date())

    def test_tomorrow(self):
        d, _, _ = resolve_date("明天交", NOW)
        self.assertEqual(d, datetime(2026, 9, 4).date())

    def test_day_after_tomorrow(self):
        d, _, _ = resolve_date("后天交", NOW)
        self.assertEqual(d, datetime(2026, 9, 5).date())

    def test_weekend(self):
        d, _, _ = resolve_date("周末前", NOW)
        self.assertEqual(d, datetime(2026, 9, 5).date())  # Saturday

    def test_next_weekday(self):
        d, _, _ = resolve_date("下周三前", NOW)
        self.assertEqual(d, datetime(2026, 9, 16).date())

    def test_this_friday(self):
        d, _, _ = resolve_date("周五交", NOW)
        self.assertEqual(d, datetime(2026, 9, 4).date())

    def test_month_end(self):
        d, _, _ = resolve_date("月底前", NOW)
        self.assertEqual(d, datetime(2026, 9, 30).date())

    def test_month_start(self):
        d, _, _ = resolve_date("月初交", NOW)
        self.assertEqual(d, datetime(2026, 9, 1).date())

    def test_next_month(self):
        d, _, _ = resolve_date("下个月交", NOW)
        self.assertEqual(d, datetime(2026, 10, 1).date())

    def test_next_month_first_week(self):
        d, _, _ = resolve_date("下个月第一周复习", NOW)
        self.assertEqual(d, datetime(2026, 10, 5).date())  # first Monday

    def test_year_end(self):
        d, _, _ = resolve_date("年底前", NOW)
        self.assertEqual(d, datetime(2026, 12, 31).date())

    def test_past_date_warns(self):
        d, warns, _ = resolve_date("昨天交", NOW)
        self.assertEqual(d, datetime(2026, 9, 2).date())
        self.assertTrue(any("过去" in w for w in warns))

    def test_passed_no_year_date_rolls_next_year(self):
        # 2026-09-03 is after 2026-03-01, so "3月1日" must mean next year.
        d, warns, _ = resolve_date("3月1日交", NOW)
        self.assertEqual(d, datetime(2027, 3, 1).date())
        self.assertTrue(any("明年" in w or "明年" in w or "早于" in w for w in warns))


class ChineseTimeResolutionTest(unittest.TestCase):
    """Pin the time-of-day resolution rules."""

    def test_24h_colon(self):
        t, explicit, _ = resolve_time("14:00 开会")
        self.assertEqual(t, datetime(2026, 1, 1, 14, 0).time())
        self.assertTrue(explicit)

    def test_pm_period_chinese_numeral(self):
        t, _, _ = resolve_time("下午两点开会")
        self.assertEqual(t, datetime(2026, 1, 1, 14, 0).time())

    def test_pm_three(self):
        t, _, _ = resolve_time("周五下午三点讨论")
        self.assertEqual(t, datetime(2026, 1, 1, 15, 0).time())

    def test_am_morning(self):
        t, _, _ = resolve_time("明天早上9点交")
        self.assertEqual(t, datetime(2026, 1, 1, 9, 0).time())

    def test_half_past_pm(self):
        # "下午" sets the PM period; "半" => :30.
        t, _, _ = resolve_time("下午三点半开会")
        self.assertEqual(t, datetime(2026, 1, 1, 15, 30).time())

    def test_half_past_bare_is_24h(self):
        # No period token => interpreted as the 24-hour clock (3:30). The
        # parser is fully deterministic here; `resolve_time` returns spans (not
        # warnings), and the only upstream AM/PM ambiguity warning fires for an
        # exact 00:00 mention, so a bare "三点半" carries no warning. This pins
        # the documented fallback rule. (See milestone notes: a future
        # improvement could warn on bare 1-11 spoken hours.)
        t, explicit, spans = resolve_time("三点半开会")
        self.assertEqual(t, datetime(2026, 1, 1, 3, 30).time())
        self.assertTrue(explicit)
        self.assertTrue(spans)

    def test_noon(self):
        t, _, _ = resolve_time("中午十二点吃饭")
        self.assertEqual(t, datetime(2026, 1, 1, 12, 0).time())

    def test_no_time(self):
        t, explicit, _ = resolve_time("下周三前提交")
        self.assertIsNone(t)
        self.assertFalse(explicit)


class ReminderResolutionTest(unittest.TestCase):
    """Pin reminder lead computation."""

    def test_lead_one_day(self):
        due = datetime(2026, 9, 15, 23, 59)
        at, lead, warns, _ = extract_reminder("提前一天提醒", due, NOW)
        self.assertEqual(lead, 1440)
        self.assertEqual(at, datetime(2026, 9, 14, 23, 59))

    def test_lead_chinese_numeral_two_hours(self):
        due = datetime(2026, 9, 15, 23, 59)
        at, lead, _, _ = extract_reminder("提前两小时提醒", due, NOW)
        self.assertEqual(lead, 120)
        self.assertEqual(at, datetime(2026, 9, 15, 21, 59))

    def test_lead_minutes(self):
        due = datetime(2026, 9, 15, 23, 59)
        at, lead, _, _ = extract_reminder("提前30分钟提醒", due, NOW)
        self.assertEqual(lead, 30)
        self.assertEqual(at, datetime(2026, 9, 15, 23, 29))

    def test_bare_reminder_at_due(self):
        due = datetime(2026, 9, 15, 23, 59)
        at, lead, warns, _ = extract_reminder("记得提醒我", due, NOW)
        self.assertEqual(lead, 0)
        self.assertEqual(at, due)
        self.assertTrue(any("提前量" in w for w in warns))


class DueDatetimeInferenceTest(unittest.TestCase):
    """Pin the date+time combination and defaults."""

    def test_date_only_defaults_to_2359(self):
        dt, warns, _ = infer_due_datetime(
            "9月15日交", NOW, datetime(2026, 9, 15).date(), None, False
        )
        self.assertEqual(dt, datetime(2026, 9, 15, 23, 59))
        self.assertTrue(any("23:59" in w for w in warns))

    def test_date_with_time(self):
        dt, _, _ = infer_due_datetime(
            "9月15日 14:00", NOW, datetime(2026, 9, 15).date(),
            datetime(2026, 1, 1, 14, 0).time(), True,
        )
        self.assertEqual(dt, datetime(2026, 9, 15, 14, 0))

    def test_time_only_assumes_today(self):
        dt, warns, _ = infer_due_datetime(
            "下午两点开会", NOW, None, datetime(2026, 1, 1, 14, 0).time(), True
        )
        self.assertEqual(dt, datetime(2026, 9, 3, 14, 0))
        self.assertTrue(any("今天" in w for w in warns))


# ---------------------------------------------------------------------------
# End-to-end corpus: each entry asserts a subset of fields on the first task.
# ---------------------------------------------------------------------------

CORPUS = [
    # input, expected-fields dict (subset)
    ("高数作业第五章，下周三前提交",
     {"title": "高数作业第五章", "course_name": "高等数学",
      "due_date": datetime(2026, 9, 16, 23, 59)}),
    ("明天下午三点在图书馆讨论英语展示",
     {"title": "英语展示", "location": "图书馆",
      "due_date": datetime(2026, 9, 4, 15, 0)}),
    ("周五交实验报告和代码，报告比较重要",
     {"priority": "high", "due_date": datetime(2026, 9, 4, 23, 59)}),
    ("9月15日前完成开题材料，提前一天提醒",
     {"title": "开题材料", "due_date": datetime(2026, 9, 15, 23, 59),
      "reminder_at": datetime(2026, 9, 14, 23, 59)}),
    ("下个月第一周复习线代，没有明确截止时间",
     {"title": "线代", "due_date": datetime(2026, 10, 5, 23, 59)}),
    ("明天早上9点交数据库作业",
     {"title": "数据库作业", "due_date": datetime(2026, 9, 4, 9, 0)}),
    ("周末前把论文初稿发给导师",
     {"due_date": datetime(2026, 9, 5, 23, 59)}),
    ("2026年12月31日前提交毕业设计",
     {"title": "毕业设计", "due_date": datetime(2026, 12, 31, 23, 59)}),
    ("下午两点开会讨论项目进度",
     {"title": "会讨论项目进度", "due_date": datetime(2026, 9, 3, 14, 0)}),
    ("买三本参考书，不急",
     {"priority": "low"}),
    ("提前30分钟提醒我交数学作业",
     {"priority": None, "reminder_lead_minutes": 30}),
    ("下周三 14:00 交物理实验报告",
     {"course_name": "大学物理", "due_date": datetime(2026, 9, 16, 14, 0)}),
    ("周一上午十点参加小组讨论",
     {"due_date": datetime(2026, 9, 7, 10, 0)}),
    ("本周五之前把代码 push 上去",
     {"due_date": datetime(2026, 9, 4, 23, 59)}),
    ("12月25日圣诞节前准备好礼物",
     {"due_date": datetime(2026, 12, 25, 23, 59)}),
    ("后天晚上八点视频会议",
     {"due_date": datetime(2026, 9, 5, 20, 0)}),
    ("月底前提交月度总结，很重要",
     {"priority": "high", "due_date": datetime(2026, 9, 30, 23, 59)}),
    ("下个月1号交房租",
     {"due_date": datetime(2026, 10, 1, 23, 59)}),
    ("三年后（2029年）交毕业论文",
     {"due_date": datetime(2029, 9, 3, 23, 59)}),
    ("上午九点半开晨会",
     {"title": "晨会", "due_date": datetime(2026, 9, 3, 9, 30)}),
]


class CorpusTest(unittest.TestCase):
    def test_corpus(self):
        failures = []
        for text, expected in CORPUS:
            sched = _parse(text)
            if not sched.tasks:
                failures.append(f"{text!r}: no task parsed")
                continue
            task = sched.tasks[0]
            for field, value in expected.items():
                actual = getattr(task, field)
                if actual != value:
                    failures.append(
                        f"{text!r}: {field} expected {value!r}, got {actual!r}"
                    )
        if failures:
            self.fail("\n".join(failures))


class SegmentationTest(unittest.TestCase):
    def test_multi_task_split_on_period(self):
        sched = _parse(
            "高数作业第五章，下周三前提交。"
            "周五下午两点在教学楼开小组会，记得准备演示文稿。"
        )
        titles = [t.title for t in sched.tasks]
        self.assertIn("高数作业第五章", titles)
        self.assertIn("在教学楼开小组会", titles)
        self.assertIn("演示文稿", titles)
        self.assertEqual(len(sched.tasks), 3)

    def test_comma_splits_independent_action(self):
        sched = _parse("周五下午两点开会，记得准备材料")
        titles = [t.title for t in sched.tasks]
        self.assertIn("材料", titles)
        self.assertIn("会", titles)

    def test_non_task_fragment_skipped(self):
        sched = _parse("窗外的梧桐树叶黄了，风吹起来很舒服")
        self.assertEqual(sched.task_count, 0)
        self.assertTrue(sched.warnings)

    def test_empty_input(self):
        sched = _parse("")
        self.assertEqual(sched.task_count, 0)


class ContractMappingTest(unittest.TestCase):
    def test_to_contract_dict_shape(self):
        task = _first("明天下午三点交数据库作业")
        data = task.to_contract_dict()
        self.assertEqual(data["title"], "数据库作业")
        self.assertEqual(data["status"], "not_started")
        self.assertEqual(data["due_date"], "2026-09-04T15:00:00")
        self.assertEqual(data["all_day"], 0)
        self.assertNotIn("reminder_at", data)

    def test_to_contract_list(self):
        sched = _parse("任务A明天交。任务B后天交。")
        items = sched.to_contract_list()
        self.assertEqual(len(items), 2)
        self.assertTrue(all("title" in it for it in items))

    def test_priority_medium_default_omitted(self):
        # When no priority is detected the contract dict omits it so the
        # repository applies its own "medium" default.
        task = _first("明天交作业")
        self.assertIsNone(task.priority)
        self.assertNotIn("priority", task.to_contract_dict())


class ConfidenceAndWarningsTest(unittest.TestCase):
    def test_clean_task_high_confidence(self):
        task = _first("明天早上9点交数据库作业")
        self.assertGreaterEqual(task.confidence, 0.8)

    def test_missing_due_lowers_confidence(self):
        task = _first("买三本参考书")
        self.assertLess(task.confidence, 1.0)
        self.assertTrue(any("截止" in w for w in task.warnings))

    def test_confidence_floor(self):
        for text, _ in CORPUS:
            for task in _parse(text).tasks:
                self.assertGreaterEqual(task.confidence, 0.2)
                self.assertLessEqual(task.confidence, 1.0)

    def test_title_never_empty(self):
        for text, _ in CORPUS:
            for task in _parse(text).tasks:
                self.assertTrue(task.title.strip())


class LinkAndTagTest(unittest.TestCase):
    def test_link_extracted(self):
        task = _first("明天交作业 https://example.com/hw")
        self.assertEqual(task.link, "https://example.com/hw")

    def test_tag_extracted(self):
        task = _first("明天交作业 # urgent #期末")
        self.assertIn("urgent", task.tags)
        self.assertIn("期末", task.tags)


if __name__ == "__main__":
    unittest.main(verbosity=2)
