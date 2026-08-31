import Foundation
import Testing
@testable import AssignmentApp2


/// Shared learning-scene rules, exercised on the Apple side with the same
/// fixtures the cross-platform suite uses.
@Suite("Learning-scene rules")
struct LearningSceneRuleTests {
    private let shanghai = "Asia/Shanghai"
    private let newYork = "America/New_York"
    private let utc = "UTC"

    private let monday = "2026-09-07"
    private let wednesday = "2026-09-09"
    private let sunday = "2026-09-13"
    /// Second Sunday of March: 02:00 to 03:00 does not exist in New York.
    private let springForward = "2026-03-08"
    /// First Sunday of November: 01:00 to 02:00 happens twice in New York.
    private let fallBack = "2026-11-01"

    private func window(
        weekday: Int,
        start: String,
        end: String,
        timeZone: String,
        from: String,
        to: String? = nil
    ) throws -> MeetingWindow {
        try MeetingWindow(
            weekday: weekday,
            startTimeLocal: start,
            endTimeLocal: end,
            timezoneID: timeZone,
            effectiveStartDate: from,
            effectiveEndDate: to
        )
    }

    private func offsetHours(_ date: Date, in zone: TimeZone) -> Int {
        zone.secondsFromGMT(for: date) / 3_600
    }

    // MARK: - Text primitives

    @Test("Wall-clock text is strict")
    func wallClockTextIsStrict() throws {
        #expect((try LocalClockTime("09:05:00")).text == "09:05:00")
        #expect(throws: LearningSceneError.self) { try LocalClockTime("24:00:00") }
        #expect(throws: LearningSceneError.self) { try LocalClockTime("09:60:00") }
        #expect(throws: LearningSceneError.self) { try LocalClockTime("9:05:00") }
        #expect(throws: LearningSceneError.self) { try LocalClockTime("09:05") }
        #expect(throws: LearningSceneError.self) { try LocalClockTime("09:05:00Z") }
    }

    @Test("Calendar dates must be real and unpadded")
    func calendarDatesAreReal() throws {
        #expect((try LocalCalendarDate(monday)).isoWeekday == 1)
        #expect((try LocalCalendarDate(wednesday)).isoWeekday == 3)
        #expect((try LocalCalendarDate(sunday)).isoWeekday == 7)
        #expect(throws: LearningSceneError.self) { try LocalCalendarDate("2026-02-30") }
        #expect(throws: LearningSceneError.self) { try LocalCalendarDate("2026-9-7") }
        #expect(throws: LearningSceneError.self) { try LocalCalendarDate("2026-09-07T00:00:00") }
    }

    // MARK: - Weekday and time boundaries

    @Test("Monday and Sunday are the inclusive week boundaries")
    func weekdayBoundaries() throws {
        let mondayMeeting = try window(
            weekday: 1, start: "08:00:00", end: "09:00:00",
            timeZone: shanghai, from: monday
        )
        #expect(try LearningRules.meetingOccursOn(mondayMeeting, date: monday))
        #expect(try !LearningRules.meetingOccursOn(mondayMeeting, date: sunday))
        #expect(try !LearningRules.meetingOccursOn(mondayMeeting, date: wednesday))

        let sundayMeeting = try window(
            weekday: 7, start: "08:00:00", end: "09:00:00",
            timeZone: shanghai, from: monday
        )
        #expect(try LearningRules.meetingOccursOn(sundayMeeting, date: sunday))
        #expect(try !LearningRules.meetingOccursOn(sundayMeeting, date: monday))

        #expect(throws: LearningSceneError.self) {
            _ = try window(
                weekday: 0, start: "08:00:00", end: "09:00:00",
                timeZone: shanghai, from: monday
            )
        }
        #expect(throws: LearningSceneError.self) {
            _ = try window(
                weekday: 8, start: "08:00:00", end: "09:00:00",
                timeZone: shanghai, from: monday
            )
        }
    }

    @Test("A meeting must start before it ends")
    func meetingStartPrecedesEnd() {
        #expect(throws: LearningSceneError.self) {
            _ = try self.window(
                weekday: 1, start: "09:00:00", end: "09:00:00",
                timeZone: self.shanghai, from: self.monday
            )
        }
        #expect(throws: LearningSceneError.self) {
            _ = try self.window(
                weekday: 1, start: "10:00:00", end: "09:00:00",
                timeZone: self.shanghai, from: self.monday
            )
        }
    }

    @Test("Effective ranges are inclusive and cannot run backwards")
    func effectiveRangeBoundaries() throws {
        let meeting = try window(
            weekday: 1, start: "08:00:00", end: "09:00:00",
            timeZone: shanghai, from: monday, to: monday
        )
        #expect(try LearningRules.meetingOccursOn(meeting, date: monday))
        #expect(throws: LearningSceneError.self) {
            _ = try self.window(
                weekday: 1, start: "08:00:00", end: "09:00:00",
                timeZone: self.shanghai, from: self.sunday, to: self.monday
            )
        }
    }

    // MARK: - Daylight saving

    @Test("A wall time skipped by a spring-forward transition has no occurrence")
    func missingWallTimeHasNoOccurrence() throws {
        let meeting = try window(
            weekday: 7, start: "02:30:00", end: "03:30:00",
            timeZone: newYork, from: springForward
        )
        #expect(try LearningRules.meetingOccursOn(meeting, date: springForward))
        #expect(try LearningRules.resolveMeetingInterval(meeting, on: springForward) == nil)

        let safe = try window(
            weekday: 7, start: "03:30:00", end: "04:30:00",
            timeZone: newYork, from: springForward
        )
        #expect(try LearningRules.resolveMeetingInterval(safe, on: springForward) != nil)
    }

    @Test("A duplicated wall time uses its first, earlier-offset occurrence")
    func duplicatedWallTimeUsesFirstOccurrence() throws {
        let meeting = try window(
            weekday: 7, start: "01:30:00", end: "02:30:00",
            timeZone: newYork, from: fallBack
        )
        let interval = try #require(
            try LearningRules.resolveMeetingInterval(meeting, on: fallBack)
        )
        let zone = try #require(TimeZone(identifier: newYork))
        // The first 01:30 is still daylight time, UTC-4.
        #expect(offsetHours(interval.start, in: zone) == -4)
        #expect(offsetHours(interval.end, in: zone) == -5)
    }

    @Test("An occurrence spanning fall-back reports its real elapsed interval")
    func fallBackReportsRealElapsedInterval() throws {
        let meeting = try window(
            weekday: 7, start: "00:30:00", end: "02:30:00",
            timeZone: newYork, from: fallBack
        )
        let interval = try #require(
            try LearningRules.resolveMeetingInterval(meeting, on: fallBack)
        )
        let elapsed = interval.end.timeIntervalSince(interval.start)
        // Two nominal wall-clock hours, plus the repeated hour.
        #expect(elapsed == 3 * 3_600)
    }

    @Test("The same wall time resolves differently in different zones")
    func sameWallTimeDiffersByZone() throws {
        let inShanghai = try window(
            weekday: 1, start: "09:00:00", end: "10:00:00",
            timeZone: shanghai, from: monday
        )
        let inNewYork = try window(
            weekday: 1, start: "09:00:00", end: "10:00:00",
            timeZone: newYork, from: monday
        )
        let shanghaiInterval = try #require(
            try LearningRules.resolveMeetingInterval(inShanghai, on: monday)
        )
        let newYorkInterval = try #require(
            try LearningRules.resolveMeetingInterval(inNewYork, on: monday)
        )
        // Shanghai is UTC+8 and New York is UTC-4 in September: twelve hours.
        #expect(
            newYorkInterval.start.timeIntervalSince(shanghaiInterval.start) == 12 * 3_600
        )
    }

    // MARK: - Overlap

    @Test("Adjacent meetings do not overlap")
    func adjacencyIsNotOverlap() throws {
        #expect(
            try LearningRules.meetingTimesOverlap(
                firstStart: "09:00:00", firstEnd: "10:00:00",
                secondStart: "10:00:00", secondEnd: "11:00:00"
            ) == false
        )
        #expect(
            try LearningRules.meetingTimesOverlap(
                firstStart: "09:00:00", firstEnd: "10:30:00",
                secondStart: "10:00:00", secondEnd: "11:00:00"
            )
        )
    }

    @Test("Meetings on different weekdays never overlap")
    func differentWeekdaysNeverOverlap() throws {
        let mondayMeeting = try window(
            weekday: 1, start: "09:00:00", end: "10:00:00",
            timeZone: shanghai, from: monday
        )
        let tuesdayMeeting = try window(
            weekday: 2, start: "09:30:00", end: "10:30:00",
            timeZone: shanghai, from: monday
        )
        #expect(try !LearningRules.meetingsOverlap(mondayMeeting, tuesdayMeeting))
    }

    @Test("Disjoint effective ranges never overlap")
    func disjointEffectiveRangesNeverOverlap() throws {
        let first = try window(
            weekday: 1, start: "09:00:00", end: "10:00:00",
            timeZone: shanghai, from: monday, to: monday
        )
        let second = try window(
            weekday: 1, start: "09:30:00", end: "10:30:00",
            timeZone: shanghai, from: "2026-09-14", to: "2026-09-14"
        )
        #expect(try !LearningRules.meetingsOverlap(first, second))
    }

    @Test("Overlap is decided on resolved instants, not stored wall times")
    func overlapUsesResolvedInstantsAcrossZones() throws {
        let tokyo = "Asia/Tokyo"
        let inShanghai = try window(
            weekday: 1, start: "09:00:00", end: "10:00:00",
            timeZone: shanghai, from: monday
        )
        // 09:30 in Tokyo is 08:30 in Shanghai, so the resolved intervals meet
        // even though neither stored wall time overlaps the other's.
        let tokyoOverlap = try window(
            weekday: 1, start: "09:30:00", end: "10:30:00",
            timeZone: tokyo, from: monday
        )
        let tokyoEarlier = try window(
            weekday: 1, start: "08:00:00", end: "09:00:00",
            timeZone: tokyo, from: monday
        )
        #expect(try LearningRules.meetingsOverlap(inShanghai, tokyoOverlap))
        #expect(try !LearningRules.meetingsOverlap(inShanghai, tokyoEarlier))
    }

    @Test("A daylight-saving gap falls back to the stored wall clock")
    func dstGapFallsBackToWallClock() throws {
        let skipped = try window(
            weekday: 7, start: "02:30:00", end: "03:30:00",
            timeZone: newYork, from: springForward
        )
        let neighbour = try window(
            weekday: 7, start: "03:00:00", end: "04:00:00",
            timeZone: newYork, from: springForward
        )
        #expect(try LearningRules.resolveMeetingInterval(skipped, on: springForward) == nil)
        #expect(try LearningRules.meetingsOverlap(skipped, neighbour))
    }

    @Test("Overlap is a pure question and never rewrites a meeting")
    func overlapDoesNotMutate() throws {
        let first = try window(
            weekday: 1, start: "09:00:00", end: "10:00:00",
            timeZone: shanghai, from: monday
        )
        let second = try window(
            weekday: 1, start: "09:30:00", end: "10:30:00",
            timeZone: shanghai, from: monday
        )
        let firstBefore = first
        let secondBefore = second
        #expect(try LearningRules.meetingsOverlap(first, second))
        #expect(first == firstBefore)
        #expect(second == secondBefore)
    }

    // MARK: - Exams

    @Test("Exams order upcoming, completed, then cancelled")
    func examStatusOrdering() throws {
        #expect(ExamStatus.upcoming.sortRank < ExamStatus.completed.sortRank)
        #expect(ExamStatus.completed.sortRank < ExamStatus.cancelled.sortRank)

        let base = Date(timeIntervalSince1970: 0)
        let later = base.addingTimeInterval(600)
        // Within one status the earlier exam comes first.
        #expect(
            LearningRules.examSortKey(status: .upcoming, startsAtUTC: base)
                < LearningRules.examSortKey(status: .upcoming, startsAtUTC: later)
        )
        #expect(
            LearningRules.examSortKey(status: .upcoming, startsAtUTC: base)
                < LearningRules.examSortKey(status: .completed, startsAtUTC: base)
        )
    }

    @Test("An exam resolves in its declared time zone")
    func examResolvesInDeclaredZone() throws {
        let exam = Exam(
            id: 1,
            uuid: UUID(),
            courseID: 1,
            name: "Midterm",
            startsAtLocal: "2026-09-07 09:00:00",
            timezoneID: shanghai,
            location: nil,
            scope: nil,
            notes: nil,
            status: .upcoming,
            linkedAssignmentID: nil,
            createdAt: Date(),
            updatedAt: Date(),
            deletedAt: nil
        )
        let resolved = try #require(exam.startsAtUTC)
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = utcCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: resolved
        )
        #expect(components.year == 2026)
        #expect(components.month == 9)
        #expect(components.day == 7)
        #expect(components.hour == 1)
        #expect(components.minute == 0)
    }

    @Test("An exam inside a daylight-saving gap has no resolved instant")
    func examMissingWallTimeResolvesToNil() throws {
        let exam = Exam(
            id: 1,
            uuid: UUID(),
            courseID: 1,
            name: "Skipped",
            startsAtLocal: "2026-03-08 02:30:00",
            timezoneID: newYork,
            location: nil,
            scope: nil,
            notes: nil,
            status: .upcoming,
            linkedAssignmentID: nil,
            createdAt: Date(),
            updatedAt: Date(),
            deletedAt: nil
        )
        #expect(exam.startsAtUTC == nil)
    }

    // MARK: - Reminder schedule kinds

    @Test("A due-relative trigger subtracts the lead time from the deadline")
    func relativeTriggerSubtractsLead() throws {
        let due = Date(timeIntervalSince1970: 1_000_000)
        let trigger = try LearningRules.relativeReminderTrigger(
            dueAtUTC: due,
            leadMinutes: 60
        )
        #expect(trigger == due.addingTimeInterval(-3_600))
    }

    @Test("A due-relative reminder requires a deadline and a sane lead time")
    func relativeTriggerGuards() {
        #expect(throws: LearningSceneError.relativeReminderWithoutDueDate) {
            _ = try LearningRules.relativeReminderTrigger(dueAtUTC: nil, leadMinutes: 10)
        }
        #expect(throws: LearningSceneError.self) {
            _ = try LearningRules.relativeReminderTrigger(
                dueAtUTC: Date(),
                leadMinutes: -1
            )
        }
        #expect(
            LearningRules.relativeReminderDisabledReason(dueDate: nil) != nil
        )
        #expect(
            LearningRules.relativeReminderDisabledReason(dueDate: Date()) == nil
        )
    }

    @Test("Relative presets stay on the documented lead times")
    func relativePresets() {
        #expect(RelativeReminderPreset.allCases.map(\.leadMinutes) == [10, 60, 1_440])
    }

    // MARK: - Time zones

    @Test("Time zone identifiers follow the shared IANA contract")
    func timeZoneContract() throws {
        #expect(throws: (any Error).self) {
            _ = try LearningRules.validatedTimeZone("EST")
        }
        #expect(throws: (any Error).self) {
            _ = try LearningRules.validatedTimeZone("   ")
        }
        #expect(throws: (any Error).self) {
            _ = try LearningRules.validatedTimeZone("Not/AZone")
        }
        // Foundation normalizes "UTC" to its own identifier, so the contract is
        // asserted on the resolved zone instead of on the literal string.
        #expect(
            (try LearningRules.validatedTimeZone(utc)).identifier
                == TimeZone(identifier: utc)?.identifier
        )
        #expect((try LearningRules.validatedTimeZone(utc)).secondsFromGMT() == 0)
        #expect((try LearningRules.validatedTimeZone(shanghai)).identifier == shanghai)
    }
}
