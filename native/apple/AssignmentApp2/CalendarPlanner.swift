import Foundation


/// One cell in the month grid.
///
/// `date` is the start of the civil day in `calendar`'s time zone. `isToday`
/// is resolved against the same calendar so a day that is "today" in one zone
/// and not another is decided by the calendar the caller asked for.
struct CalendarDay: Identifiable, Equatable {
    let date: Date
    let isInDisplayedMonth: Bool
    let isToday: Bool

    var id: Date { date }
}


/// A day cell together with the tasks that land on it.
struct CalendarDayBucket: Identifiable, Equatable {
    let day: CalendarDay
    let tasks: [Assignment]

    var id: Date { day.id }
}


/// Pure date/grouping rules behind the task calendar.
///
/// Every function takes an explicit `Calendar`, so tests can pin a time zone,
/// a first-weekday, and a locale without touching process state.
///
/// Grouping deliberately uses the same absolute-day arithmetic as
/// `TaskRules.dayBounds`: a task belongs to the civil day that contains its due
/// instant in the calendar's time zone. That is what makes the calendar agree
/// with the Today list for the same database. A task's own
/// `timeZoneIdentifier` is a *display* concern — the repository already used it
/// to turn stored wall time into an absolute `Date`; the calendar only decides
/// which day cell that instant falls in and how the clock time is rendered.
enum CalendarPlanner {
    /// Day start for an instant, in `calendar`.
    static func dayStart(for date: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: date)
    }

    /// The day an assignment belongs to, or `nil` when it has no due date.
    static func dayStart(for assignment: Assignment, calendar: Calendar) -> Date? {
        assignment.dueDate.map { calendar.startOfDay(for: $0) }
    }

    /// First instant of the month containing `reference`, in `calendar`.
    static func monthStart(containing reference: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.year, .month], from: reference)
        return calendar.date(from: components) ?? calendar.startOfDay(for: reference)
    }

    /// Adds one month. Clamped so 31 Jan + 1 month lands on 28/29 Feb rather
    /// than spilling into March.
    static func addingMonths(
        _ count: Int,
        to date: Date,
        calendar: Calendar
    ) -> Date {
        guard let result = calendar.date(byAdding: .month, value: count, to: date) else {
            return date
        }
        return result
    }

    /// The first day of the grid: the start of the week containing the first of
    /// the month, honouring `calendar.firstWeekday`.
    static func gridStart(
        containing reference: Date,
        calendar: Calendar
    ) -> Date {
        let first = monthStart(containing: reference, calendar: calendar)
        let weekday = calendar.component(.weekday, from: first)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -offset, to: first) ?? first
    }

    /// A whole number of weeks covering the month, so the grid never changes
    /// height in a way that depends on the month.
    static func monthGrid(
        containing reference: Date,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [CalendarDay] {
        var grid = calendar
        grid.locale = calendar.locale
        let start = gridStart(containing: reference, calendar: calendar)
        let monthStart = self.monthStart(containing: reference, calendar: calendar)
        let displayedMonth = calendar.component(.month, from: monthStart)
        let displayedYear = calendar.component(.year, from: monthStart)
        let todayStart = calendar.startOfDay(for: now)

        var days: [CalendarDay] = []
        for index in 0..<42 {
            guard let date = calendar.date(byAdding: .day, value: index, to: start) else {
                continue
            }
            let components = calendar.dateComponents([.month, .year], from: date)
            days.append(
                CalendarDay(
                    date: date,
                    isInDisplayedMonth: components.month == displayedMonth
                        && components.year == displayedYear,
                    isToday: date == todayStart
                )
            )
            if days.count % 7 == 0,
               days.count >= 28,
               let last = days.last,
               !isMonthVisibleAfter(last, month: displayedMonth, year: displayedYear, calendar: calendar) {
                break
            }
        }
        _ = grid
        return days
    }

    /// Weekday titles ordered from `calendar.firstWeekday`, localized by
    /// `calendar.locale`.
    static func weekdayTitles(calendar: Calendar) -> [String] {
        let symbols = calendar.standaloneWeekdaySymbols
        let count = symbols.count
        guard count > 0 else { return [] }
        let startIndex = (calendar.firstWeekday - 1) % count
        return (0..<count).map { offset in
            symbols[(startIndex + offset) % count]
        }
    }

    /// Very short weekday titles (Sun/Mon or 日/一) for the grid header.
    static func shortWeekdayTitles(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let count = symbols.count
        guard count > 0 else { return [] }
        let startIndex = (calendar.firstWeekday - 1) % count
        return (0..<count).map { offset in
            symbols[(startIndex + offset) % count]
        }
    }

    /// Localized month and year heading, e.g. "September 2026".
    static func monthTitle(for reference: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.calendar = Calendar(identifier: calendar.identifier)
        formatter.setLocalizedDateFormatFromTemplate("MMMM y")
        return formatter.string(from: reference)
    }

    /// Buckets every day in `grid`, including empty days.
    static func buckets(
        for grid: [CalendarDay],
        assignments: [Assignment],
        calendar: Calendar = .current,
        includeCompleted: Bool = true
    ) -> [CalendarDayBucket] {
        let grouped = groupedByDay(
            assignments,
            calendar: calendar,
            includeCompleted: includeCompleted
        )
        return grid.map { day in
            CalendarDayBucket(day: day, tasks: grouped[day.date] ?? [])
        }
    }

    /// Tasks per day start. Days with no tasks are absent rather than empty.
    static func groupedByDay(
        _ assignments: [Assignment],
        calendar: Calendar = .current,
        includeCompleted: Bool = true
    ) -> [Date: [Assignment]] {
        var result: [Date: [Assignment]] = [:]
        for assignment in assignments {
            guard includeCompleted || assignment.status != .done else { continue }
            guard let key = dayStart(for: assignment, calendar: calendar) else { continue }
            result[key, default: []].append(assignment)
        }
        for key in result.keys {
            result[key] = orderedForDay(result[key] ?? [])
        }
        return result
    }

    /// Ordering inside one day: all-day first, then by clock time, then by the
    /// same title/id tie-break the shared list uses.
    static func orderedForDay(_ assignments: [Assignment]) -> [Assignment] {
        assignments.sorted { lhs, rhs in
            if lhs.allDay != rhs.allDay {
                return lhs.allDay
            }
            return Self.comesBeforeByDueDate(lhs, rhs)
        }
    }

    /// The due time as it should be read: in the task's own IANA time zone when
    /// it has one, otherwise in the calendar's.
    static func displayTimeZone(
        for assignment: Assignment,
        calendar: Calendar
    ) -> TimeZone {
        guard let identifier = assignment.timeZoneIdentifier,
              !identifier.isEmpty,
              let zone = TimeZone(identifier: identifier) else {
            return calendar.timeZone
        }
        return zone
    }

    /// `true` when the task should render without a clock time.
    static func isAllDay(_ assignment: Assignment) -> Bool {
        assignment.allDay
    }

    /// Tasks with no due date, ordered like the list.
    static func undatedTasks(_ assignments: [Assignment]) -> [Assignment] {
        assignments
            .filter { $0.dueDate == nil }
            .sorted { Self.comesBeforeByDueDate($0, $1) }
    }

    /// Whether any task on this day is already done.
    static func hasCompletedTasks(_ assignments: [Assignment]) -> Bool {
        assignments.contains { $0.status == .done }
    }

    // MARK: - Private

    private static func isMonthVisibleAfter(
        _ day: CalendarDay,
        month: Int,
        year: Int,
        calendar: Calendar
    ) -> Bool {
        guard let next = calendar.date(byAdding: .day, value: 1, to: day.date) else {
            return false
        }
        let components = calendar.dateComponents([.month, .year], from: next)
        return components.month == month && components.year == year
    }

    private static func comesBeforeByDueDate(
        _ lhs: Assignment,
        _ rhs: Assignment
    ) -> Bool {
        switch (lhs.dueDate, rhs.dueDate) {
        case let (left?, right?):
            if left != right {
                return left < right
            }
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            break
        }

        let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if titleOrder != .orderedSame {
            return titleOrder == .orderedAscending
        }
        return lhs.id < rhs.id
    }
}


/// Accessibility text for a day cell. Built from resolved strings so VoiceOver
/// reads the day, the task count, and the selection state in one utterance.
enum CalendarAccessibility {
    static func dayLabel(
        day: CalendarDay,
        taskCount: Int,
        isSelected: Bool,
        calendar: Calendar
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.calendar = Calendar(identifier: calendar.identifier)
        formatter.setLocalizedDateFormatFromTemplate("EEEE, MMMM d")
        var text = formatter.string(from: day.date)
        if day.isToday {
            text += ", " + L10n.tr("today")
        }
        text += ", " + taskCountText(taskCount)
        if isSelected {
            text += ", " + L10n.tr("selected")
        }
        return text
    }

    static func taskCountText(_ count: Int) -> String {
        count == 1
            ? L10n.tr("%lld task", count)
            : L10n.tr("%lld tasks", count)
    }
}
