import Foundation
import Testing
@testable import AssignmentApp2


// MARK: - Fixtures

private enum CalendarFixtureError: Error {
    case invalidDate(String)
}

/// A Gregorian calendar with a pinned time zone and first-weekday, so every
/// assertion below is independent of the machine running the suite.
private func calendar(
    timeZone: String,
    firstWeekday: Int = 2,
    locale: String = "en_US_POSIX"
) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZone) ?? TimeZone(secondsFromGMT: 0)!
    calendar.firstWeekday = firstWeekday
    calendar.locale = Locale(identifier: locale)
    return calendar
}

/// Builds a `Date` from wall-clock text in the given zone.
private func date(_ text: String, in timeZone: String) throws -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: timeZone)
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    formatter.isLenient = false
    guard let date = formatter.date(from: text) else {
        throw CalendarFixtureError.invalidDate(text)
    }
    return date
}

private func assignment(
    id: Int64,
    title: String,
    due: String? = nil,
    timeZone: String = "UTC",
    status: AssignmentStatus = .todo,
    allDay: Bool = false
) throws -> Assignment {
    Assignment(
        id: id,
        courseName: "Course",
        title: title,
        dueDate: try due.map { try date($0, in: timeZone) },
        status: status,
        allDay: allDay,
        timeZoneIdentifier: due == nil ? nil : timeZone
    )
}


// MARK: - Grid shape

@Suite("Calendar month grid")
struct CalendarMonthGridTests {

    @Test("Grid is made of whole weeks and covers the displayed month")
    func gridIsWholeWeeks() throws {
        let calendar = calendar(timeZone: "America/New_York")
        // A month that starts mid-week and is longer than 28 days.
        let reference = try date("2026-09-01 12:00:00", in: "America/New_York")

        let grid = CalendarPlanner.monthGrid(
            containing: reference,
            calendar: calendar,
            now: reference
        )

        #expect(grid.count % 7 == 0)
        #expect(grid.count >= 28)
        #expect(grid.count <= 42)

        // Every day of September 2026 is present and flagged as displayed.
        let displayed = grid.filter(\.isInDisplayedMonth)
        #expect(displayed.count == 30)
        // The grid starts before the 1st and, for September 2026, runs past it.
        #expect(grid.first!.date < calendar.startOfDay(for: reference))
    }

    @Test("Grid starts on the calendar's first weekday")
    func gridStartHonoursFirstWeekday() throws {
        let reference = try date("2026-02-01 12:00:00", in: "UTC")

        let mondayFirst = CalendarPlanner.gridStart(
            containing: reference,
            calendar: calendar(timeZone: "UTC", firstWeekday: 2)
        )
        #expect(calendar(timeZone: "UTC").component(.weekday, from: mondayFirst) == 2)

        let sundayFirst = CalendarPlanner.gridStart(
            containing: reference,
            calendar: calendar(timeZone: "UTC", firstWeekday: 1)
        )
        #expect(calendar(timeZone: "UTC").component(.weekday, from: sundayFirst) == 1)
        // 1 Feb 2026 is a Sunday, so a Sunday-start grid begins on the 1st.
        #expect(sundayFirst == calendar(timeZone: "UTC").startOfDay(for: reference))
    }

    @Test("Month arithmetic clamps instead of spilling into the next month")
    func addingMonthsClamps() throws {
        let utc = calendar(timeZone: "UTC")
        let january31 = try date("2026-01-31 09:00:00", in: "UTC")

        let february = CalendarPlanner.addingMonths(1, to: january31, calendar: utc)
        let components = utc.dateComponents([.year, .month, .day], from: february)
        #expect(components.year == 2026)
        #expect(components.month == 2)
        #expect(components.day == 28)

        // Leap year takes the 29th.
        let january31Leap = try date("2024-01-31 09:00:00", in: "UTC")
        let februaryLeap = CalendarPlanner.addingMonths(1, to: january31Leap, calendar: utc)
        #expect(utc.component(.day, from: februaryLeap) == 29)
    }

    @Test("Exactly one day in the grid is flagged as today")
    func singleToday() throws {
        let calendar = calendar(timeZone: "Europe/Berlin")
        let now = try date("2026-05-14 22:30:00", in: "Europe/Berlin")

        let grid = CalendarPlanner.monthGrid(
            containing: now,
            calendar: calendar,
            now: now
        )
        #expect(grid.filter(\.isToday).count == 1)
        #expect(grid.first(where: \.isToday)!.date == calendar.startOfDay(for: now))
    }
}


// MARK: - Grouping

@Suite("Calendar day grouping")
struct CalendarGroupingTests {

    @Test("Tasks group into the civil day that contains their due instant")
    func groupsByCivilDay() throws {
        let calendar = calendar(timeZone: "America/New_York")
        let tasks = [
            try assignment(id: 1, title: "Morning", due: "2026-03-10 08:00:00", timeZone: "America/New_York"),
            try assignment(id: 2, title: "Evening", due: "2026-03-10 20:00:00", timeZone: "America/New_York"),
            try assignment(id: 3, title: "Next day", due: "2026-03-11 01:00:00", timeZone: "America/New_York"),
            try assignment(id: 4, title: "No due date"),
        ]

        let grouped = CalendarPlanner.groupedByDay(tasks, calendar: calendar)

        #expect(grouped.count == 2)
        #expect(grouped[try date("2026-03-10 00:00:00", in: "America/New_York")]?.map(\.title) == ["Morning", "Evening"])
        #expect(grouped[try date("2026-03-11 00:00:00", in: "America/New_York")]?.map(\.title) == ["Next day"])
    }

    @Test("The same instant lands on different days in different zones")
    func groupingFollowsCalendarTimeZone() throws {
        let instant = try date("2026-03-10 23:30:00", in: "America/New_York")
        let task = Assignment(
            id: 1,
            courseName: "Course",
            title: "Late night",
            dueDate: instant,
            timeZoneIdentifier: "America/New_York"
        )

        let newYork = CalendarPlanner.groupedByDay([task], calendar: calendar(timeZone: "America/New_York"))
        let tokyo = CalendarPlanner.groupedByDay([task], calendar: calendar(timeZone: "Asia/Tokyo"))

        let newYorkDay = try date("2026-03-10 00:00:00", in: "America/New_York")
        let tokyoDay = try date("2026-03-11 00:00:00", in: "Asia/Tokyo")
        #expect(newYork.keys.count == 1)
        #expect(newYork.keys.first == newYorkDay)
        #expect(tokyo.keys.first == tokyoDay)
    }

    @Test("Grouping survives the spring-forward day, which is 23 hours long")
    func groupingAcrossDSTSpringForward() throws {
        // 8 March 2026: US clocks jump 02:00 -> 03:00.
        let calendar = calendar(timeZone: "America/New_York")
        let beforeJump = try date("2026-03-08 01:30:00", in: "America/New_York")
        let afterJump = try date("2026-03-08 10:00:00", in: "America/New_York")
        let nextDay = try date("2026-03-09 01:30:00", in: "America/New_York")

        let tasks = [
            try assignment(id: 1, title: "Before", due: "2026-03-08 01:30:00", timeZone: "America/New_York"),
            try assignment(id: 2, title: "After", due: "2026-03-08 10:00:00", timeZone: "America/New_York"),
            try assignment(id: 3, title: "Next", due: "2026-03-09 01:30:00", timeZone: "America/New_York"),
        ]
        let grouped = CalendarPlanner.groupedByDay(tasks, calendar: calendar)

        // The transition is inside one civil day, so both land together.
        #expect(grouped[calendar.startOfDay(for: beforeJump)]?.count == 2)
        #expect(grouped[calendar.startOfDay(for: afterJump)]?.count == 2)
        #expect(grouped[calendar.startOfDay(for: nextDay)]?.count == 1)
        #expect(grouped.count == 2)
    }

    @Test("Grouping survives the fall-back day, which is 25 hours long")
    func groupingAcrossDSTFallBack() throws {
        // 1 November 2026: US clocks fall back 02:00 -> 01:00.
        let calendar = calendar(timeZone: "America/New_York")
        let tasks = [
            try assignment(id: 1, title: "First pass", due: "2026-11-01 01:30:00", timeZone: "America/New_York"),
            try assignment(id: 2, title: "Later", due: "2026-11-01 20:00:00", timeZone: "America/New_York"),
            try assignment(id: 3, title: "Tomorrow", due: "2026-11-02 09:00:00", timeZone: "America/New_York"),
        ]
        let grouped = CalendarPlanner.groupedByDay(tasks, calendar: calendar)

        #expect(grouped.count == 2)
        #expect(grouped[calendar.startOfDay(for: try date("2026-11-01 12:00:00", in: "America/New_York"))]?.count == 2)
    }

    @Test("All-day tasks sort first, then by clock time, then by title")
    func orderingWithinADay() throws {
        let tasks = [
            try assignment(id: 1, title: "Zebra", due: "2026-06-01 09:00:00", timeZone: "UTC"),
            try assignment(id: 2, title: "All day", due: "2026-06-01 23:00:00", timeZone: "UTC", allDay: true),
            try assignment(id: 3, title: "Apple", due: "2026-06-01 09:00:00", timeZone: "UTC"),
        ]
        let order = CalendarPlanner.orderedForDay(tasks).map(\.title)
        #expect(order == ["All day", "Apple", "Zebra"])
    }

    @Test("Completed tasks can be hidden without changing the grouping of the rest")
    func completedToggle() throws {
        let tasks = [
            try assignment(id: 1, title: "Open", due: "2026-06-01 09:00:00", timeZone: "UTC"),
            try assignment(id: 2, title: "Finished", due: "2026-06-01 10:00:00", timeZone: "UTC", status: .done),
        ]

        let shown = CalendarPlanner.groupedByDay(tasks, calendar: calendar(timeZone: "UTC"), includeCompleted: true)
        let hidden = CalendarPlanner.groupedByDay(tasks, calendar: calendar(timeZone: "UTC"), includeCompleted: false)

        #expect(shown.values.flatMap { $0 }.count == 2)
        #expect(hidden.values.flatMap { $0 }.count == 1)
        #expect(hidden.values.flatMap { $0 }.first?.title == "Open")
    }

    @Test("Undated tasks are listed apart and never appear on a day")
    func undatedTasks() throws {
        let tasks = [
            try assignment(id: 1, title: "Dated", due: "2026-06-01 09:00:00", timeZone: "UTC"),
            try assignment(id: 2, title: "Someday"),
            try assignment(id: 3, title: "Anytime"),
        ]

        let undated = CalendarPlanner.undatedTasks(tasks).map(\.title)
        #expect(undated == ["Anytime", "Someday"])

        let grouped = CalendarPlanner.groupedByDay(tasks, calendar: calendar(timeZone: "UTC"))
        #expect(grouped.values.flatMap { $0 }.count == 1)
    }

    @Test("Buckets cover every grid day, including empty ones")
    func bucketsCoverWholeGrid() throws {
        let calendar = calendar(timeZone: "UTC")
        let reference = try date("2026-06-15 12:00:00", in: "UTC")
        let grid = CalendarPlanner.monthGrid(
            containing: reference,
            calendar: calendar,
            now: reference
        )
        let tasks = [try assignment(id: 1, title: "Only", due: "2026-06-15 09:00:00", timeZone: "UTC")]

        let buckets = CalendarPlanner.buckets(for: grid, assignments: tasks, calendar: calendar)

        #expect(buckets.count == grid.count)
        #expect(buckets.filter { !$0.tasks.isEmpty }.count == 1)
        #expect(buckets.first { !$0.tasks.isEmpty }?.tasks.first?.title == "Only")
    }

    @Test("The clock time shown follows the task's own IANA zone")
    func displayTimeZone() throws {
        let task = try assignment(id: 1, title: "Tokyo", due: "2026-06-01 09:00:00", timeZone: "Asia/Tokyo")
        let calendar = calendar(timeZone: "America/New_York")

        #expect(CalendarPlanner.displayTimeZone(for: task, calendar: calendar).identifier == "Asia/Tokyo")

        var noZone = task
        noZone.timeZoneIdentifier = nil
        #expect(CalendarPlanner.displayTimeZone(for: noZone, calendar: calendar).identifier == "America/New_York")
    }
}


// MARK: - Agreement with the task list

@Suite("Calendar agrees with the task list")
struct CalendarListConsistencyTests {

    /// The requirement the calendar has to meet: for the same database and the
    /// same calendar, the tasks on a day cell are exactly the tasks the Today
    /// list would show for that day.
    @Test("Each day cell matches the Today list for that day")
    func dayCellMatchesTodayList() throws {
        let calendar = calendar(timeZone: "America/New_York")
        let reference = try date("2026-03-10 12:00:00", in: "America/New_York")

        let tasks = [
            try assignment(id: 1, title: "Alpha", due: "2026-03-10 00:00:00", timeZone: "America/New_York"),
            try assignment(id: 2, title: "Beta", due: "2026-03-10 23:59:59", timeZone: "America/New_York"),
            try assignment(id: 3, title: "Gamma", due: "2026-03-11 00:00:00", timeZone: "America/New_York"),
            try assignment(id: 4, title: "Delta", due: "2026-03-09 23:59:59", timeZone: "America/New_York"),
            try assignment(id: 5, title: "Epsilon", due: "2026-03-25 08:00:00", timeZone: "America/New_York"),
            try assignment(id: 6, title: "Done thing", due: "2026-03-25 09:00:00", timeZone: "America/New_York", status: .done),
            try assignment(id: 7, title: "No date"),
        ]

        let grid = CalendarPlanner.monthGrid(
            containing: reference,
            calendar: calendar,
            now: reference
        )
        let buckets = CalendarPlanner.buckets(
            for: grid,
            assignments: tasks,
            calendar: calendar,
            includeCompleted: true
        )

        for bucket in buckets {
            let expected = Set(
                TaskRules.tasks(
                    tasks,
                    in: .today,
                    now: bucket.day.date,
                    calendar: calendar
                ).map(\.id)
            )
            let actual = Set(bucket.tasks.map(\.id))
            #expect(actual == expected, "Day \(bucket.day.date) disagreed with the list.")
        }
    }

    @Test("Overdue tasks stay visible on their original day")
    func overdueStaysOnItsDay() throws {
        let calendar = calendar(timeZone: "UTC")
        let now = try date("2026-06-20 12:00:00", in: "UTC")
        let overdueTask = try assignment(id: 1, title: "Late", due: "2026-06-01 09:00:00", timeZone: "UTC")

        #expect(TaskRules.matchesView(overdueTask, view: .overdue, now: now, calendar: calendar))

        let juneFirst = try date("2026-06-01 00:00:00", in: "UTC")
        let grouped = CalendarPlanner.groupedByDay([overdueTask], calendar: calendar)
        #expect(grouped.keys.first == juneFirst)
    }

    @Test("The calendar view never borrows the task-list filter")
    func calendarIsNotFilteredByTaskRules() throws {
        let task = try assignment(id: 1, title: "Anything", due: "2026-06-01 09:00:00", timeZone: "UTC")
        #expect(TaskRules.matchesView(task, view: .calendar, now: Date(), calendar: .current) == false)
    }
}


// MARK: - Accessibility

@Suite("Calendar accessibility")
struct CalendarAccessibilityTests {

    @Test("A day cell reads the date, the task count and the selection state")
    func dayLabelContainsDateCountAndSelection() throws {
        let calendar = calendar(timeZone: "UTC")
        let day = CalendarDay(
            date: try date("2026-06-15 00:00:00", in: "UTC"),
            isInDisplayedMonth: true,
            isToday: false
        )

        let selected = CalendarAccessibility.dayLabel(
            day: day,
            taskCount: 3,
            isSelected: true,
            calendar: calendar
        )
        #expect(selected.contains("3"))
        #expect(selected.contains("June"))
        #expect(selected.contains(L10n.tr("selected")))

        let unselected = CalendarAccessibility.dayLabel(
            day: day,
            taskCount: 3,
            isSelected: false,
            calendar: calendar
        )
        #expect(!unselected.contains(L10n.tr("selected")))
    }

    @Test("The task count uses the singular form for exactly one task")
    func taskCountText() {
        #expect(CalendarAccessibility.taskCountText(1) == L10n.tr("%lld task", 1))
        #expect(CalendarAccessibility.taskCountText(2) == L10n.tr("%lld tasks", 2))
        #expect(CalendarAccessibility.taskCountText(0) == L10n.tr("%lld tasks", 0))
    }

    @Test("Weekday titles follow the calendar's first weekday")
    func weekdayTitlesFollowFirstWeekday() {
        let monday = CalendarPlanner.shortWeekdayTitles(
            calendar: calendar(timeZone: "UTC", firstWeekday: 2)
        )
        let sunday = CalendarPlanner.shortWeekdayTitles(
            calendar: calendar(timeZone: "UTC", firstWeekday: 1)
        )
        #expect(monday.count == 7)
        #expect(sunday.count == 7)
        // Monday-first ends on Sunday, which is where Sunday-first begins.
        #expect(monday.last == sunday.first)
        #expect(monday.first == sunday[1])
        // The two orders hold the same seven weekdays, just rotated.
        #expect(Set(monday) == Set(sunday))
    }
}
