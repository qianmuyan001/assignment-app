import Foundation


enum TaskRules {
    static func dayBounds(
        containing now: Date,
        calendar: Calendar = .current
    ) -> Range<Date> {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return start..<end
    }

    static func weekBounds(
        containing now: Date,
        calendar: Calendar = .current
    ) -> Range<Date> {
        var mondayCalendar = calendar
        mondayCalendar.firstWeekday = 2
        let dayStart = mondayCalendar.startOfDay(for: now)
        let weekday = mondayCalendar.component(.weekday, from: dayStart)
        let daysSinceMonday = (weekday - mondayCalendar.firstWeekday + 7) % 7
        let start = mondayCalendar.date(
            byAdding: .day,
            value: -daysSinceMonday,
            to: dayStart
        ) ?? dayStart
        let end = mondayCalendar.date(byAdding: .day, value: 7, to: start) ?? start
        return start..<end
    }

    static func matchesView(
        _ assignment: Assignment,
        view: AssignmentView,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        switch view {
        case .all:
            return true
        case .completed:
            return assignment.status == .done
        case .settings:
            return false
        case .today:
            guard let dueDate = assignment.dueDate else { return false }
            return dayBounds(containing: now, calendar: calendar).contains(dueDate)
        case .week:
            guard let dueDate = assignment.dueDate else { return false }
            return weekBounds(containing: now, calendar: calendar).contains(dueDate)
        case .overdue:
            guard assignment.status != .done,
                  let dueDate = assignment.dueDate else {
                return false
            }
            return dueDate < now
        case .timetable, .exams:
            // Learning-scene pages own their own content; they never borrow
            // the task list.
            return false
        }
    }

    static func tasks(
        _ assignments: [Assignment],
        in view: AssignmentView,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Assignment] {
        assignments.filter {
            matchesView($0, view: view, now: now, calendar: calendar)
        }
    }

    static func search(
        _ assignments: [Assignment],
        query: String
    ) -> [Assignment] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return assignments }
        return assignments.filter { assignment in
            assignment.title.localizedCaseInsensitiveContains(needle)
                || assignment.courseName.localizedCaseInsensitiveContains(needle)
                || (assignment.assignmentDescription ?? "")
                    .localizedCaseInsensitiveContains(needle)
        }
    }

    static func filter(
        _ assignments: [Assignment],
        status: AssignmentStatus? = nil,
        course: String? = nil,
        priority: AssignmentPriority? = nil
    ) -> [Assignment] {
        let expectedCourse = course?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return assignments.filter { assignment in
            if let status, assignment.status != status {
                return false
            }
            if let priority, assignment.priority != priority {
                return false
            }
            if let expectedCourse, !expectedCourse.isEmpty {
                let actualCourse = assignment.courseName.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                if actualCourse.localizedCaseInsensitiveCompare(expectedCourse) != .orderedSame {
                    return false
                }
            }
            return true
        }
    }

    static func sort(
        _ assignments: [Assignment],
        by order: AssignmentSortOrder
    ) -> [Assignment] {
        assignments.sorted { lhs, rhs in
            if order == .priority, lhs.priority.sortRank != rhs.priority.sortRank {
                return lhs.priority.sortRank < rhs.priority.sortRank
            }
            return comesBeforeByDueDate(lhs, rhs)
        }
    }

    static func apply(
        to assignments: [Assignment],
        view: AssignmentView,
        searchQuery: String = "",
        status: AssignmentStatus? = nil,
        course: String? = nil,
        priority: AssignmentPriority? = nil,
        sortOrder: AssignmentSortOrder = .dueDate,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Assignment] {
        let viewed = tasks(assignments, in: view, now: now, calendar: calendar)
        let searched = search(viewed, query: searchQuery)
        let filtered = filter(
            searched,
            status: status,
            course: course,
            priority: priority
        )
        return sort(filtered, by: sortOrder)
    }

    static func project(
        _ assignment: Assignment,
        for mode: DisplayMode
    ) -> AssignmentProjection {
        AssignmentProjection(
            title: assignment.title,
            courseName: assignment.courseName,
            dueDate: assignment.dueDate,
            status: assignment.status,
            assignmentDescription: mode == .professional
                ? assignment.assignmentDescription
                : nil,
            priority: mode == .professional ? assignment.priority : nil,
            link: mode == .professional ? assignment.link : nil
        )
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
