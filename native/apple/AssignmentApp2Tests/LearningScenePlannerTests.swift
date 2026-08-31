import Foundation
import Testing

@testable import AssignmentApp2


/// The learning pages must decide everything in one place that has no database
/// and no SwiftUI, so the timetable, the exam list, and the Today overview
/// cannot disagree about what "today" or "overlapping" means.
@Suite("Learning scene planning")
struct LearningScenePlannerTests {

    // MARK: Fixtures

    private func makeMeeting(
        id: Int64,
        weekday: Int,
        start: String,
        end: String,
        timezoneID: String = "UTC",
        effectiveStart: String = "2026-01-01",
        effectiveEnd: String? = nil,
        deletedAt: Date? = nil
    ) -> CourseMeeting {
        CourseMeeting(
            id: id,
            uuid: UUID(),
            courseID: 1,
            weekday: weekday,
            startTimeLocal: start,
            endTimeLocal: end,
            location: nil,
            teacherOverride: nil,
            timezoneID: timezoneID,
            effectiveStartDate: effectiveStart,
            effectiveEndDate: effectiveEnd,
            sortOrder: 0,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            deletedAt: deletedAt
        )
    }

    private func makeExam(
        id: Int64,
        name: String,
        startsAtLocal: String,
        status: ExamStatus = .upcoming,
        timezoneID: String = "UTC",
        linkedAssignmentID: Int64? = nil,
        deletedAt: Date? = nil
    ) -> Exam {
        Exam(
            id: id,
            uuid: UUID(),
            courseID: 1,
            name: name,
            startsAtLocal: startsAtLocal,
            timezoneID: timezoneID,
            location: nil,
            scope: nil,
            notes: nil,
            status: status,
            linkedAssignmentID: linkedAssignmentID,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            deletedAt: deletedAt
        )
    }

    private func makeAssignment(
        id: Int64,
        title: String,
        dueDate: Date?,
        status: AssignmentStatus = .todo
    ) -> Assignment {
        Assignment(
            id: id,
            uuid: UUID(),
            courseName: "Physics",
            title: title,
            dueDate: dueDate,
            assignmentDescription: nil,
            link: nil,
            status: status,
            priority: .medium,
            sourceName: nil,
            sourceType: nil,
            sourceFile: nil,
            sourceURL: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            courseID: nil,
            projectID: nil,
            completedAt: nil,
            progressPercent: 0,
            allDay: false,
            timeZoneIdentifier: nil,
            deletedAt: nil
        )
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func utcDate(year: Int, month: Int, day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        utcCalendar.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }

    // MARK: Weekday boundaries

    @Test("ISO weekday keeps Monday at 1 and Sunday at 7")
    func isoWeekdayBoundaries() {
        #expect(LearningScenePlanner.isoWeekday(
            of: utcDate(year: 2026, month: 8, day: 17),
            calendar: utcCalendar
        ) == 1)
        #expect(LearningScenePlanner.isoWeekday(
            of: utcDate(year: 2026, month: 8, day: 23),
            calendar: utcCalendar
        ) == 7)
        #expect(LearningScenePlanner.isoWeekday(
            of: utcDate(year: 2026, month: 8, day: 21),
            calendar: utcCalendar
        ) == 5)
    }

    @Test("The week always has seven buckets, empty days included")
    func weekKeepsEmptyDays() {
        let monday = makeMeeting(id: 1, weekday: 1, start: "08:00:00", end: "09:40:00")
        let week = LearningScenePlanner.week([monday])

        #expect(week.count == 7)
        #expect(week.map(\.weekday) == [1, 2, 3, 4, 5, 6, 7])
        #expect(week[0].meetings.count == 1)
        #expect(week[1].meetings.isEmpty)
        #expect(week[6].meetings.isEmpty)
    }

    @Test("Meetings on one weekday come back earliest first")
    func meetingsAreSortedByStart() {
        let late = makeMeeting(id: 1, weekday: 3, start: "14:00:00", end: "15:40:00")
        let early = makeMeeting(id: 2, weekday: 3, start: "08:00:00", end: "09:40:00")
        let other = makeMeeting(id: 3, weekday: 4, start: "08:00:00", end: "09:40:00")

        let wednesday = LearningScenePlanner.meetings([late, early, other], on: 3)
        #expect(wednesday.map(\.id) == [2, 1])
    }

    @Test("Soft-deleted meetings never reach the timetable")
    func deletedMeetingsAreHidden() {
        let live = makeMeeting(id: 1, weekday: 2, start: "08:00:00", end: "09:00:00")
        let gone = makeMeeting(
            id: 2,
            weekday: 2,
            start: "10:00:00",
            end: "11:00:00",
            deletedAt: Date(timeIntervalSince1970: 100)
        )

        #expect(LearningScenePlanner.meetings([live, gone], on: 2).map(\.id) == [1])
        #expect(LearningScenePlanner.activeMeetings([live, gone]).count == 1)
    }

    // MARK: Overlap

    @Test("Overlapping meetings are reported as pairs, never removed")
    func overlappingPairsAreWarningsOnly() {
        let first = makeMeeting(id: 1, weekday: 3, start: "08:00:00", end: "09:40:00")
        let second = makeMeeting(id: 2, weekday: 3, start: "09:00:00", end: "10:40:00")
        let free = makeMeeting(id: 3, weekday: 3, start: "12:00:00", end: "13:00:00")

        let all = [first, second, free]
        let pairs = LearningScenePlanner.overlappingPairs(all)
        #expect(pairs.count == 1)
        #expect(pairs.first?.0.id == 1)
        #expect(pairs.first?.1.id == 2)
        // The input is untouched: a warning is not a mutation.
        #expect(all.map(\.id) == [1, 2, 3])
        #expect(all.count == 3)
    }

    @Test("Different weekdays and disjoint ranges never overlap")
    func separateMeetingsDoNotOverlap() {
        let monday = makeMeeting(id: 1, weekday: 1, start: "08:00:00", end: "09:40:00")
        let tuesday = makeMeeting(id: 2, weekday: 2, start: "08:00:00", end: "09:40:00")
        #expect(LearningScenePlanner.overlappingPairs([monday, tuesday]).isEmpty)

        let morning = makeMeeting(id: 3, weekday: 1, start: "08:00:00", end: "09:00:00")
        let afternoon = makeMeeting(id: 4, weekday: 1, start: "10:00:00", end: "11:00:00")
        #expect(LearningScenePlanner.overlappingPairs([morning, afternoon]).isEmpty)
    }

    @Test("Meetings with disjoint effective ranges never overlap")
    func effectiveRangesSeparateMeetings() {
        let spring = makeMeeting(
            id: 1,
            weekday: 1,
            start: "08:00:00",
            end: "09:40:00",
            effectiveStart: "2026-01-01",
            effectiveEnd: "2026-06-01"
        )
        let autumn = makeMeeting(
            id: 2,
            weekday: 1,
            start: "08:00:00",
            end: "09:40:00",
            effectiveStart: "2026-09-01",
            effectiveEnd: "2026-12-31"
        )
        #expect(LearningScenePlanner.overlappingPairs([spring, autumn]).isEmpty)
    }

    @Test("Deleted meetings never trigger a warning")
    func deletedMeetingsDoNotWarn() {
        let live = makeMeeting(id: 1, weekday: 5, start: "08:00:00", end: "09:40:00")
        let gone = makeMeeting(
            id: 2,
            weekday: 5,
            start: "09:00:00",
            end: "10:40:00",
            deletedAt: Date(timeIntervalSince1970: 100)
        )
        #expect(LearningScenePlanner.overlappingPairs([live, gone]).isEmpty)
    }

    // MARK: Exam sections

    @Test("Exam sections come back today, upcoming, completed, cancelled")
    func examSectionOrder() {
        let now = utcDate(year: 2026, month: 8, day: 21, hour: 9)
        let today = makeExam(id: 1, name: "Today exam", startsAtLocal: "2026-08-21 14:00:00")
        let later = makeExam(id: 2, name: "Later exam", startsAtLocal: "2026-09-01 09:00:00")
        let done = makeExam(
            id: 3,
            name: "Done exam",
            startsAtLocal: "2026-06-01 09:00:00",
            status: .completed
        )
        let dropped = makeExam(
            id: 4,
            name: "Cancelled exam",
            startsAtLocal: "2026-07-01 09:00:00",
            status: .cancelled
        )

        let sections = LearningScenePlanner.examSections(
            [dropped, done, later, today],
            now: now,
            calendar: utcCalendar
        )

        #expect(sections.map(\.kind) == [.today, .upcoming, .completed, .cancelled])
        #expect(sections[0].exams.map(\.id) == [1])
        #expect(sections[1].exams.map(\.id) == [2])
        #expect(sections[2].exams.map(\.id) == [3])
        #expect(sections[3].exams.map(\.id) == [4])
    }

    @Test("An exam that a clock change skips stays visible instead of vanishing")
    func skippedExamWallTimeStaysVisible() {
        // 02:30 does not exist in New York on the spring-forward Sunday.
        let skipped = makeExam(
            id: 1,
            name: "Skipped exam",
            startsAtLocal: "2026-03-08 02:30:00",
            timezoneID: "America/New_York"
        )
        let now = utcDate(year: 2026, month: 3, day: 1, hour: 12)
        let sections = LearningScenePlanner.examSections(
            [skipped],
            now: now,
            calendar: utcCalendar
        )

        #expect(sections.map(\.kind) == [.upcoming])
        #expect(sections[0].exams.map(\.id) == [1])
        #expect(skipped.startsAtUTC == nil)
    }

    @Test("Exams inside one section are ordered earliest first")
    func examsAreOrderedEarliestFirst() {
        let later = makeExam(id: 1, name: "Later", startsAtLocal: "2026-09-10 09:00:00")
        let earlier = makeExam(id: 2, name: "Earlier", startsAtLocal: "2026-09-01 09:00:00")
        let ordered = LearningScenePlanner.sortedExams([later, earlier])
        #expect(ordered.map(\.id) == [2, 1])
    }

    @Test("Upcoming exams stay inside the near horizon")
    func upcomingExamsUseHorizon() {
        let soon = makeExam(id: 1, name: "Soon", startsAtLocal: "2026-08-25 09:00:00")
        let far = makeExam(id: 2, name: "Far", startsAtLocal: "2026-12-25 09:00:00")
        let past = makeExam(id: 3, name: "Past", startsAtLocal: "2026-01-05 09:00:00")
        let now = utcDate(year: 2026, month: 8, day: 21, hour: 9)

        let upcoming = LearningScenePlanner.upcomingExams(
            [soon, far, past],
            withinDays: 14,
            now: now,
            calendar: utcCalendar
        )
        #expect(upcoming.map(\.id) == [1])
    }

    // MARK: Today overview

    @Test("Today overview separates due today from overdue")
    func todayOverviewSplitsDueAndOverdue() {
        let now = utcDate(year: 2026, month: 8, day: 21, hour: 9)
        let dueToday = makeAssignment(
            id: 1,
            title: "Lab report",
            dueDate: utcDate(year: 2026, month: 8, day: 21, hour: 18)
        )
        let overdue = makeAssignment(
            id: 2,
            title: "Problem set 3",
            dueDate: utcDate(year: 2026, month: 8, day: 19, hour: 18)
        )
        let finished = makeAssignment(
            id: 3,
            title: "Old homework",
            dueDate: utcDate(year: 2026, month: 8, day: 1, hour: 18),
            status: .done
        )
        // 2026-08-21 is a Friday.
        let friday = makeMeeting(id: 1, weekday: 5, start: "10:00:00", end: "11:40:00")
        let monday = makeMeeting(id: 2, weekday: 1, start: "08:00:00", end: "09:40:00")
        let exam = makeExam(id: 1, name: "Midterm", startsAtLocal: "2026-08-24 09:00:00")

        let overview = LearningScenePlanner.todayOverview(
            meetings: [friday, monday],
            exams: [exam],
            assignments: [dueToday, overdue, finished],
            now: now,
            calendar: utcCalendar
        )

        #expect(overview.meetings.map(\.id) == [1])
        #expect(overview.exams.map(\.id) == [1])
        #expect(overview.dueToday.map(\.id) == [1])
        // A completed task is not overdue.
        #expect(overview.overdue.map(\.id) == [2])
    }

    @Test("An empty overview reports itself empty")
    func emptyOverview() {
        let now = utcDate(year: 2026, month: 8, day: 21, hour: 9)
        let overview = LearningScenePlanner.todayOverview(
            meetings: [],
            exams: [],
            assignments: [],
            now: now,
            calendar: utcCalendar
        )
        #expect(overview.isEmpty)
    }
}
