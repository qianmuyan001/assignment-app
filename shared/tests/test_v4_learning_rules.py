"""Phase 3A learning-scene rules: weekday/date boundaries, DST, time zones,
course-meeting overlap, exam ordering, and reminder schedule kinds.

These are platform-neutral rules. Apple reimplements them with Foundation's
Calendar and TimeZone; Windows and Web will port the same behaviour later.
"""

from __future__ import annotations

import unittest
from datetime import date, datetime, timezone

from shared.schema_v4 import (
    MeetingWindow,
    SchemaV4Error,
    exam_sort_key,
    meeting_occurs_on,
    meeting_times_overlap,
    meetings_overlap,
    parse_local_date,
    parse_local_time,
    relative_reminder_trigger,
    resolve_meeting_interval,
)


SHANGHAI = "Asia/Shanghai"
NEW_YORK = "America/New_York"

# 2026-09-07 is a Monday, 2026-09-13 is a Sunday, 2026-09-09 is a Wednesday.
MONDAY = "2026-09-07"
SUNDAY = "2026-09-13"
WEDNESDAY = "2026-09-09"
US_SPRING_FORWARD = "2026-03-08"
US_FALL_BACK = "2026-11-01"


def window(
    *,
    weekday: int,
    start: str,
    end: str,
    tz: str = SHANGHAI,
    start_date: str = "2026-09-01",
    end_date: str | None = None,
) -> MeetingWindow:
    return MeetingWindow(
        weekday=weekday,
        start_time_local=start,
        end_time_local=end,
        timezone_id=tz,
        effective_start_date=start_date,
        effective_end_date=end_date,
    )


class LocalTextParsingTests(unittest.TestCase):
    def test_local_date_and_time_reject_wall_clock_text_with_offsets(self) -> None:
        self.assertEqual(date(2026, 9, 7), parse_local_date(MONDAY))
        self.assertEqual("09:00:00", parse_local_time("09:00:00").strftime("%H:%M:%S"))
        for bad in ("2026-09-07T00:00:00Z", "2026-09-07 00:00:00+08:00", "09/07/2026"):
            with self.assertRaises(SchemaV4Error):
                parse_local_date(bad)
        for bad in ("9:00", "24:00:00", "09:60:00"):
            with self.assertRaises(SchemaV4Error):
                parse_local_time(bad)


class CourseMeetingBoundaryTests(unittest.TestCase):
    def test_start_must_precede_end(self) -> None:
        with self.assertRaises(SchemaV4Error):
            meeting_times_overlap("10:00:00", "10:00:00", "10:00:00", "11:00:00")
        with self.assertRaises(SchemaV4Error):
            meeting_times_overlap("10:00:00", "09:00:00", "08:00:00", "09:00:00")

    def test_adjacent_meetings_do_not_overlap(self) -> None:
        self.assertFalse(
            meeting_times_overlap("09:00:00", "10:00:00", "10:00:00", "11:00:00")
        )
        self.assertTrue(
            meeting_times_overlap("09:00:00", "10:01:00", "10:00:00", "11:00:00")
        )

    def test_monday_and_sunday_are_distinct_weekdays(self) -> None:
        monday = window(weekday=1, start="08:00:00", end="09:35:00")
        sunday = window(weekday=7, start="08:00:00", end="09:35:00")
        self.assertTrue(meeting_occurs_on(monday, MONDAY))
        self.assertFalse(meeting_occurs_on(monday, SUNDAY))
        self.assertTrue(meeting_occurs_on(sunday, SUNDAY))
        self.assertFalse(meeting_occurs_on(sunday, MONDAY))

    def test_weekday_boundaries_use_iso_numbering(self) -> None:
        for weekday in range(1, 8):
            self.assertTrue(
                meeting_occurs_on(
                    window(weekday=weekday, start="08:00:00", end="09:00:00"),
                    f"2026-09-{6 + weekday:02d}",
                )
            )
        with self.assertRaises(SchemaV4Error):
            meeting_occurs_on(window(weekday=0, start="08:00:00", end="09:00:00"), MONDAY)
        with self.assertRaises(SchemaV4Error):
            meeting_occurs_on(window(weekday=8, start="08:00:00", end="09:00:00"), MONDAY)

    def test_effective_date_range_gates_the_occurrence(self) -> None:
        bounded = window(
            weekday=1,
            start="08:00:00",
            end="09:35:00",
            start_date=MONDAY,
            end_date=MONDAY,
        )
        self.assertTrue(meeting_occurs_on(bounded, MONDAY))
        self.assertFalse(meeting_occurs_on(bounded, "2026-09-14"))

        not_yet = window(weekday=1, start="08:00:00", end="09:35:00", start_date="2026-10-01")
        self.assertFalse(meeting_occurs_on(not_yet, MONDAY))
        self.assertTrue(meeting_occurs_on(not_yet, "2026-10-05"))

    def test_effective_end_date_is_inclusive_and_must_not_precede_start(self) -> None:
        self.assertTrue(
            meeting_occurs_on(
                window(
                    weekday=1,
                    start="08:00:00",
                    end="09:35:00",
                    start_date=MONDAY,
                    end_date=MONDAY,
                ),
                MONDAY,
            )
        )
        with self.assertRaises(SchemaV4Error):
            window(
                weekday=1,
                start="08:00:00",
                end="09:35:00",
                start_date=MONDAY,
                end_date="2026-09-01",
            )


class CourseMeetingOccurrenceTests(unittest.TestCase):
    def test_resolved_interval_uses_the_declared_time_zone(self) -> None:
        start, end = resolve_meeting_interval(
            window(weekday=1, start="08:00:00", end="09:35:00"), MONDAY
        )
        # Asia/Shanghai is UTC+8 all year.
        self.assertEqual(datetime(2026, 9, 7, 0, 0, tzinfo=timezone.utc), start)
        self.assertEqual(datetime(2026, 9, 7, 1, 35, tzinfo=timezone.utc), end)

    def test_time_zone_change_moves_the_instant_but_not_the_wall_time(self) -> None:
        shanghai = window(weekday=1, start="08:00:00", end="09:35:00", tz=SHANGHAI)
        new_york = window(weekday=1, start="08:00:00", end="09:35:00", tz=NEW_YORK)
        shanghai_start, _ = resolve_meeting_interval(shanghai, MONDAY)
        new_york_start, _ = resolve_meeting_interval(new_york, MONDAY)
        self.assertEqual(
            datetime(2026, 9, 7, 12, 0, tzinfo=timezone.utc), new_york_start
        )
        # Asia/Shanghai is UTC+8 and America/New_York is UTC-4 in September.
        self.assertEqual(12 * 3600, (new_york_start - shanghai_start).total_seconds())
        self.assertEqual(shanghai.start_time_local, new_york.start_time_local)

    def test_missing_daylight_saving_wall_time_has_no_occurrence(self) -> None:
        # 2026-03-08 02:30 does not exist in America/New_York.
        meeting = window(
            weekday=7,
            start="02:30:00",
            end="03:15:00",
            tz=NEW_YORK,
            start_date=US_SPRING_FORWARD,
        )
        self.assertIsNone(resolve_meeting_interval(meeting, US_SPRING_FORWARD))

    def test_repeated_daylight_saving_wall_time_uses_the_first_occurrence(self) -> None:
        # 2026-11-01 01:30 happens twice in America/New_York: first at UTC-4.
        meeting = window(
            weekday=7,
            start="01:30:00",
            end="02:15:00",
            tz=NEW_YORK,
            start_date=US_FALL_BACK,
        )
        start, end = resolve_meeting_interval(meeting, US_FALL_BACK)
        # 01:30 is ambiguous and takes its earlier EDT offset; 02:15 is
        # unambiguous EST, so the occurrence spans the repeated hour.
        self.assertEqual(datetime(2026, 11, 1, 5, 30, tzinfo=timezone.utc), start)
        self.assertEqual(datetime(2026, 11, 1, 7, 15, tzinfo=timezone.utc), end)

    def test_occurrences_are_time_zone_stable_across_a_transition(self) -> None:
        meeting = window(
            weekday=7,
            start="09:00:00",
            end="10:00:00",
            tz=NEW_YORK,
            start_date="2026-01-01",
        )
        before, _ = resolve_meeting_interval(meeting, "2026-03-01")
        after, _ = resolve_meeting_interval(meeting, "2026-03-15")
        # EDT starts 2026-03-08, so a 09:00 class shifts by one hour in UTC.
        self.assertEqual(datetime(2026, 3, 1, 14, 0, tzinfo=timezone.utc), before)
        self.assertEqual(datetime(2026, 3, 15, 13, 0, tzinfo=timezone.utc), after)

    def test_unknown_time_zone_is_rejected(self) -> None:
        with self.assertRaises(SchemaV4Error):
            resolve_meeting_interval(
                window(weekday=1, start="08:00:00", end="09:00:00", tz="Mars/Olympus"),
                MONDAY,
            )


class CourseMeetingOverlapTests(unittest.TestCase):
    def test_overlap_requires_intersecting_dates_and_times(self) -> None:
        first = window(weekday=1, start="09:00:00", end="10:30:00")
        second = window(weekday=1, start="10:00:00", end="11:00:00")
        self.assertTrue(meetings_overlap(first, second))
        self.assertTrue(meetings_overlap(second, first))

    def test_disjoint_effective_date_ranges_do_not_overlap(self) -> None:
        first = window(
            weekday=1,
            start="09:00:00",
            end="10:30:00",
            start_date=MONDAY,
            end_date=MONDAY,
        )
        second = window(
            weekday=1,
            start="10:00:00",
            end="11:00:00",
            start_date="2026-09-14",
            end_date="2026-09-14",
        )
        self.assertFalse(meetings_overlap(first, second))

    def test_different_weekdays_never_overlap(self) -> None:
        self.assertFalse(
            meetings_overlap(
                window(weekday=1, start="09:00:00", end="10:30:00"),
                window(weekday=3, start="10:00:00", end="11:00:00"),
            )
        )

    def test_open_ended_ranges_still_overlap(self) -> None:
        self.assertTrue(
            meetings_overlap(
                window(weekday=1, start="09:00:00", end="10:30:00", end_date=None),
                window(weekday=1, start="10:00:00", end="11:00:00", end_date=None),
            )
        )

    def test_overlap_is_a_warning_and_never_mutates_the_meetings(self) -> None:
        first = window(weekday=1, start="09:00:00", end="10:30:00")
        second = window(weekday=1, start="10:00:00", end="11:00:00")
        self.assertTrue(meetings_overlap(first, second))
        self.assertEqual("09:00:00", first.start_time_local)
        self.assertEqual(1, first.weekday)


class ExamOrderingTests(unittest.TestCase):
    def test_upcoming_exams_sort_before_other_statuses(self) -> None:
        early = datetime(2026, 12, 1, 1, 0, tzinfo=timezone.utc)
        late = datetime(2026, 12, 2, 1, 0, tzinfo=timezone.utc)
        self.assertLess(exam_sort_key("upcoming", early), exam_sort_key("upcoming", late))
        self.assertLess(
            exam_sort_key("upcoming", late), exam_sort_key("completed", early)
        )
        self.assertLess(
            exam_sort_key("completed", early), exam_sort_key("cancelled", early)
        )

    def test_unknown_exam_status_is_rejected(self) -> None:
        with self.assertRaises(SchemaV4Error):
            exam_sort_key("pending", datetime(2026, 12, 1, tzinfo=timezone.utc))


class ReminderScheduleKindTests(unittest.TestCase):
    def test_relative_reminder_follows_the_deadline(self) -> None:
        first_due = datetime(2026, 11, 1, 6, 30, tzinfo=timezone.utc)
        moved_due = datetime(2026, 11, 3, 6, 30, tzinfo=timezone.utc)
        self.assertEqual(
            datetime(2026, 11, 1, 6, 20, tzinfo=timezone.utc),
            relative_reminder_trigger(first_due, 10),
        )
        self.assertEqual(
            datetime(2026, 11, 3, 5, 30, tzinfo=timezone.utc),
            relative_reminder_trigger(moved_due, 60),
        )

    def test_relative_reminder_requires_a_deadline(self) -> None:
        with self.assertRaises(SchemaV4Error):
            relative_reminder_trigger(None, 10)

    def test_naive_deadlines_and_negative_leads_are_rejected(self) -> None:
        with self.assertRaises(SchemaV4Error):
            relative_reminder_trigger(datetime(2026, 11, 1, 6, 30), 10)
        with self.assertRaises(SchemaV4Error):
            relative_reminder_trigger(
                datetime(2026, 11, 1, 6, 30, tzinfo=timezone.utc), -1
            )


if __name__ == "__main__":
    unittest.main()
