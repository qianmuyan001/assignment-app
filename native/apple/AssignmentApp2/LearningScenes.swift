import Foundation


// MARK: - Errors

enum LearningSceneError: LocalizedError, Equatable {
    case invalidLocalTime(String)
    case invalidLocalDate(String)
    case invalidLocalDateTime(String)
    case invalidTimeZone(String)
    case unsupportedExamStatus(String)
    case meetingStartMustPrecedeEnd
    case meetingDoesNotOccurOnDate(String)
    case meetingWeekdayOutOfRange(Int)
    case relativeReminderWithoutDueDate
    case invalidRelativeLeadMinutes(Int)

    var errorDescription: String? {
        switch self {
        case .invalidLocalTime(let value):
            return "Time must use HH:mm:ss: \(value)."
        case .invalidLocalDate(let value):
            return "Date must use YYYY-MM-DD: \(value)."
        case .invalidLocalDateTime(let value):
            return "Date and time must use YYYY-MM-DD HH:mm:ss: \(value)."
        case .invalidTimeZone(let value):
            return "Unrecognized IANA time zone: \(value)."
        case .unsupportedExamStatus(let value):
            return "Unsupported exam status: \(value)."
        case .meetingStartMustPrecedeEnd:
            return "A course meeting must start before it ends."
        case .meetingDoesNotOccurOnDate(let value):
            return "This meeting does not occur on \(value)."
        case .meetingWeekdayOutOfRange(let value):
            return "Weekday must use ISO values 1 to 7: \(value)."
        case .relativeReminderWithoutDueDate:
            return "Add a due date before using a reminder that is relative to it."
        case .invalidRelativeLeadMinutes(let value):
            return "Reminder lead time cannot be negative: \(value)."
        }
    }
}


// MARK: - Strict local text

/// A `HH:mm:ss` wall-clock value with no date, offset, or time zone.
struct LocalClockTime: Equatable, Comparable, Hashable {
    let hour: Int
    let minute: Int
    let second: Int

    var text: String {
        String(format: "%02d:%02d:%02d", hour, minute, second)
    }

    init(hour: Int, minute: Int, second: Int = 0) throws {
        guard (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second) else {
            throw LearningSceneError.invalidLocalTime("\(hour):\(minute):\(second)")
        }
        self.hour = hour
        self.minute = minute
        self.second = second
    }

    init(_ text: String) throws {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isNumber) }),
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              let second = Int(parts[2]) else {
            throw LearningSceneError.invalidLocalTime(text)
        }
        try self.init(hour: hour, minute: minute, second: second)
    }

    static func < (lhs: LocalClockTime, rhs: LocalClockTime) -> Bool {
        (lhs.hour, lhs.minute, lhs.second) < (rhs.hour, rhs.minute, rhs.second)
    }
}


/// A `YYYY-MM-DD` calendar date with no time or time zone.
///
/// `anchor` is 12:00 UTC on that day. It only exists so ordering and day
/// arithmetic are free of daylight-saving shifts; it is never shown to a user.
struct LocalCalendarDate: Equatable, Comparable, Hashable {
    let year: Int
    let month: Int
    let day: Int
    /// ISO weekday: 1 is Monday, 7 is Sunday.
    let isoWeekday: Int
    private let anchor: Date

    var text: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    init(year: Int, month: Int, day: Int) throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            calendar: utc,
            timeZone: utc.timeZone,
            year: year,
            month: month,
            day: day,
            hour: 12
        )
        guard let anchor = utc.date(from: components) else {
            throw LearningSceneError.invalidLocalDate("\(year)-\(month)-\(day)")
        }
        let verified = utc.dateComponents([.year, .month, .day], from: anchor)
        guard verified.year == year, verified.month == month, verified.day == day else {
            throw LearningSceneError.invalidLocalDate("\(year)-\(month)-\(day)")
        }
        self.year = year
        self.month = month
        self.day = day
        self.anchor = anchor
        // Foundation weekday is 1-based starting on Sunday; ISO is 1-based
        // starting on Monday.
        let foundationWeekday = utc.component(.weekday, from: anchor)
        isoWeekday = ((foundationWeekday + 5) % 7) + 1
    }

    init(_ text: String) throws {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            throw LearningSceneError.invalidLocalDate(text)
        }
        try self.init(year: year, month: month, day: day)
    }

    func adding(days: Int) -> LocalCalendarDate {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let shifted = utc.date(byAdding: .day, value: days, to: anchor) ?? anchor
        let components = utc.dateComponents([.year, .month, .day], from: shifted)
        // `anchor` was produced from a verified date, so adding days cannot
        // produce an unverifiable one.
        return try! LocalCalendarDate(
            year: components.year ?? year,
            month: components.month ?? month,
            day: components.day ?? day
        )
    }

    static func < (lhs: LocalCalendarDate, rhs: LocalCalendarDate) -> Bool {
        lhs.anchor < rhs.anchor
    }
}


/// A `YYYY-MM-DD HH:mm:ss` local wall time with no offset.
struct LocalWallDateTime: Equatable {
    let date: LocalCalendarDate
    let clock: LocalClockTime

    var text: String { "\(date.text) \(clock.text)" }

    init(_ text: String) throws {
        let parts = text.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw LearningSceneError.invalidLocalDateTime(text)
        }
        date = try LocalCalendarDate(String(parts[0]))
        clock = try LocalClockTime(String(parts[1]))
    }

    init(date: LocalCalendarDate, clock: LocalClockTime) {
        self.date = date
        self.clock = clock
    }
}


// MARK: - Reminder schedule kinds

/// Distinguishes a reminder that fires at a stored instant from one that is
/// derived from a task deadline.
///
/// Schema v3 only had the stored instant, so every migrated row is `.fixed`.
/// Only rows a user explicitly marks as `.dueRelative` move when a deadline or
/// time zone changes.
enum ReminderScheduleKind: String, Codable, CaseIterable, Identifiable {
    case fixed
    case dueRelative = "due_relative"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fixed:
            return "Fixed time"
        case .dueRelative:
            return "Before due date"
        }
    }

    var explanation: String {
        switch self {
        case .fixed:
            return "Fires at the exact date and time you pick. It never moves."
        case .dueRelative:
            return "Fires a set amount of time before the task due date and follows it when the due date changes."
        }
    }
}


enum RelativeReminderPreset: Int, CaseIterable, Identifiable {
    case tenMinutes = 10
    case oneHour = 60
    case oneDay = 1_440

    var id: Int { rawValue }

    var leadMinutes: Int { rawValue }

    var title: String {
        switch self {
        case .tenMinutes:
            return "10 minutes before"
        case .oneHour:
            return "1 hour before"
        case .oneDay:
            return "1 day before"
        }
    }
}


// MARK: - Course meeting

struct CourseMeeting: Identifiable, Hashable {
    let id: Int64
    let uuid: UUID
    var courseID: Int64
    /// ISO weekday: 1 is Monday, 7 is Sunday.
    var weekday: Int
    var startTimeLocal: String
    var endTimeLocal: String
    var location: String?
    var teacherOverride: String?
    var timezoneID: String
    var effectiveStartDate: String
    var effectiveEndDate: String?
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    var meetingWindow: MeetingWindow? {
        try? MeetingWindow(
            weekday: weekday,
            startTimeLocal: startTimeLocal,
            endTimeLocal: endTimeLocal,
            timezoneID: timezoneID,
            effectiveStartDate: effectiveStartDate,
            effectiveEndDate: effectiveEndDate
        )
    }
}


struct CourseMeetingDraft: Equatable {
    var courseID: Int64
    var weekday: Int
    var startTimeLocal: String
    var endTimeLocal: String
    var location: String?
    var teacherOverride: String?
    var timezoneID: String
    var effectiveStartDate: String
    var effectiveEndDate: String?
    var sortOrder: Int = 0
}


// MARK: - Exam

enum ExamStatus: String, Codable, CaseIterable, Identifiable {
    case upcoming
    case completed
    case cancelled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .upcoming:
            return "Upcoming"
        case .completed:
            return "Completed"
        case .cancelled:
            return "Cancelled"
        }
    }

    /// Upcoming first, then completed, then cancelled.
    var sortRank: Int {
        switch self {
        case .upcoming: return 0
        case .completed: return 1
        case .cancelled: return 2
        }
    }
}


struct Exam: Identifiable, Hashable {
    let id: Int64
    let uuid: UUID
    var courseID: Int64
    var name: String
    var startsAtLocal: String
    var timezoneID: String
    var location: String?
    var scope: String?
    var notes: String?
    var status: ExamStatus
    var linkedAssignmentID: Int64?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    /// The resolved start instant, or `nil` when the declared wall time does
    /// not exist because a daylight-saving transition skipped it.
    var startsAtUTC: Date? {
        guard let wall = try? LocalWallDateTime(startsAtLocal),
              let zone = try? LearningRules.validatedTimeZone(timezoneID) else {
            return nil
        }
        return LearningRules.resolveWallTime(wall, in: zone)
    }
}


struct ExamDraft: Equatable {
    var courseID: Int64
    var name: String
    var startsAtLocal: String
    var timezoneID: String
    var location: String?
    var scope: String?
    var notes: String?
    var status: ExamStatus = .upcoming
}


/// The result of asking an exam for its Review Task.
///
/// `created` records whether this call inserted the task; a repeat call that
/// finds the existing link returns the same identity with `created == false`.
struct ExamReviewTaskLink: Equatable {
    let exam: Exam
    let assignment: Assignment
    let created: Bool
}


// MARK: - Learning-scene rules

/// A weekly meeting reduced to the fields the shared rules need.
struct MeetingWindow: Equatable {
    let weekday: Int
    let startTimeLocal: String
    let endTimeLocal: String
    let timezoneID: String
    let effectiveStartDate: String
    let effectiveEndDate: String?

    let startDate: LocalCalendarDate
    let endDate: LocalCalendarDate?
    let start: LocalClockTime
    let end: LocalClockTime

    init(
        weekday: Int,
        startTimeLocal: String,
        endTimeLocal: String,
        timezoneID: String,
        effectiveStartDate: String,
        effectiveEndDate: String?
    ) throws {
        guard (1...7).contains(weekday) else {
            throw LearningSceneError.meetingWeekdayOutOfRange(weekday)
        }
        let start = try LocalClockTime(startTimeLocal)
        let end = try LocalClockTime(endTimeLocal)
        guard start < end else {
            throw LearningSceneError.meetingStartMustPrecedeEnd
        }
        _ = try LearningRules.validatedTimeZone(timezoneID)
        let startDate = try LocalCalendarDate(effectiveStartDate)
        let endDate = try effectiveEndDate.map { try LocalCalendarDate($0) }
        if let endDate, endDate < startDate {
            throw LearningSceneError.invalidLocalDate(effectiveEndDate ?? "")
        }
        self.weekday = weekday
        self.startTimeLocal = startTimeLocal
        self.endTimeLocal = endTimeLocal
        self.timezoneID = timezoneID
        self.effectiveStartDate = effectiveStartDate
        self.effectiveEndDate = effectiveEndDate
        self.startDate = startDate
        self.endDate = endDate
        self.start = start
        self.end = end
    }
}


enum LearningRules {
    /// Monday first, matching the ISO weekday the database stores.
    static func weekdayTitle(_ weekday: Int) -> String {
        let symbols = Calendar(identifier: .gregorian).standaloneWeekdaySymbols
        // Foundation symbols start on Sunday; ISO weekday 1 is Monday.
        let index = weekday % 7
        return symbols[index]
    }

    static func shortWeekdayTitle(_ weekday: Int) -> String {
        let symbols = Calendar(identifier: .gregorian).shortStandaloneWeekdaySymbols
        return symbols[weekday % 7]
    }

    static func validatedTimeZone(_ identifier: String) throws -> TimeZone {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isIANATimeZoneIdentifier(trimmed) else {
            throw LearningSceneError.invalidTimeZone(identifier)
        }
        guard let zone = TimeZone(identifier: trimmed) else {
            throw LearningSceneError.invalidTimeZone(identifier)
        }
        return zone
    }

    /// Mirrors the shared contract: `UTC`, or an IANA identifier containing at
    /// least one `/`. Bare abbreviations such as `EST` are rejected.
    static func isIANATimeZoneIdentifier(_ value: String) -> Bool {
        if value == "UTC" { return true }
        guard value.contains("/") else { return false }
        let segments = value.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count >= 2, segments.allSatisfy({ !$0.isEmpty }) else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
            .union(.init(charactersIn: "abcdefghijklmnopqrstuvwxyz"))
            .union(.init(charactersIn: "0123456789"))
            .union(.init(charactersIn: "_+-."))
        return segments.allSatisfy { segment in
            segment.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    /// Resolves one wall time in one zone.
    ///
    /// Returns `nil` when a daylight-saving transition skipped the wall time.
    /// An ambiguous wall time uses its first (earlier-offset) occurrence.
    static func resolveWallTime(
        _ wall: LocalWallDateTime,
        in zone: TimeZone
    ) -> Date? {
        resolveWallTime(on: wall.date, clock: wall.clock, in: zone)
    }

    static func resolveWallTime(
        on day: LocalCalendarDate,
        clock: LocalClockTime,
        in zone: TimeZone
    ) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let dayComponents = DateComponents(
            calendar: calendar,
            timeZone: zone,
            year: day.year,
            month: day.month,
            day: day.day
        )
        guard let dayStart = calendar.date(from: dayComponents) else { return nil }
        // Searching from just before midnight keeps midnight itself in range and
        // lets `repeatedTimePolicy: .first` pick the earlier offset of a wall
        // time that a fall-back transition repeats.
        guard let resolved = calendar.nextDate(
            after: dayStart.addingTimeInterval(-1),
            matching: DateComponents(
                hour: clock.hour,
                minute: clock.minute,
                second: clock.second
            ),
            matchingPolicy: .nextTimePreservingSmallerComponents,
            repeatedTimePolicy: .first,
            direction: .forward
        ) else {
            return nil
        }
        // A skipped wall time resolves to a nearby instant. Round-tripping back
        // to components detects that shift and reports "no occurrence".
        let roundTrip = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: resolved
        )
        guard roundTrip.year == day.year,
              roundTrip.month == day.month,
              roundTrip.day == day.day,
              roundTrip.hour == clock.hour,
              roundTrip.minute == clock.minute,
              roundTrip.second == clock.second else {
            return nil
        }
        return resolved
    }

    static func meetingOccursOn(
        _ meeting: MeetingWindow,
        date: String
    ) throws -> Bool {
        let day = try LocalCalendarDate(date)
        guard day.isoWeekday == meeting.weekday else { return false }
        guard day >= meeting.startDate else { return false }
        guard let endDate = meeting.endDate else { return true }
        return day <= endDate
    }

    /// One occurrence as a UTC interval.
    ///
    /// Returns `nil` when the local wall time does not exist on that date. Both
    /// endpoints are resolved independently, so an occurrence spanning a
    /// fall-back boundary reports the real elapsed interval.
    static func resolveMeetingInterval(
        _ meeting: MeetingWindow,
        on date: String
    ) throws -> (start: Date, end: Date)? {
        guard try meetingOccursOn(meeting, date: date) else {
            throw LearningSceneError.meetingDoesNotOccurOnDate(date)
        }
        let day = try LocalCalendarDate(date)
        let zone = try validatedTimeZone(meeting.timezoneID)
        guard let start = resolveWallTime(on: day, clock: meeting.start, in: zone),
              let end = resolveWallTime(on: day, clock: meeting.end, in: zone) else {
            return nil
        }
        return (start, end)
    }

    static func meetingTimesOverlap(
        firstStart: String,
        firstEnd: String,
        secondStart: String,
        secondEnd: String
    ) throws -> Bool {
        let first = (try LocalClockTime(firstStart), try LocalClockTime(firstEnd))
        let second = (try LocalClockTime(secondStart), try LocalClockTime(secondEnd))
        guard first.0 < first.1, second.0 < second.1 else {
            throw LearningSceneError.meetingStartMustPrecedeEnd
        }
        return first.0 < second.1 && second.0 < first.1
    }

    /// Whether two weekly meetings can collide.
    ///
    /// Overlap is a warning and never mutates, merges, or deletes a meeting.
    /// Meetings on different weekdays or with disjoint effective ranges never
    /// overlap. On a shared date the resolved UTC intervals decide; when that
    /// date has a daylight-saving gap the comparison falls back to the stored
    /// wall-clock intervals.
    static func meetingsOverlap(
        _ first: MeetingWindow,
        _ second: MeetingWindow
    ) throws -> Bool {
        guard first.weekday == second.weekday else { return false }
        let earliest = max(first.startDate, second.startDate)
        let latest: LocalCalendarDate? = [first.endDate, second.endDate]
            .compactMap { $0 }
            .min()
        if let latest, earliest > latest { return false }

        let offset = (first.weekday - earliest.isoWeekday + 7) % 7
        let shared = earliest.adding(days: offset)
        if let latest, shared > latest { return false }

        guard let firstInterval = interval(first, on: shared),
              let secondInterval = interval(second, on: shared) else {
            return try meetingTimesOverlap(
                firstStart: first.startTimeLocal,
                firstEnd: first.endTimeLocal,
                secondStart: second.startTimeLocal,
                secondEnd: second.endTimeLocal
            )
        }
        return firstInterval.start < secondInterval.end
            && secondInterval.start < firstInterval.end
    }

    static func examSortKey(
        status: ExamStatus,
        startsAtUTC: Date
    ) -> (Int, Date) {
        (status.sortRank, startsAtUTC)
    }

    /// The UTC trigger for a due-relative reminder.
    static func relativeReminderTrigger(
        dueAtUTC: Date?,
        leadMinutes: Int
    ) throws -> Date {
        guard leadMinutes >= 0 else {
            throw LearningSceneError.invalidRelativeLeadMinutes(leadMinutes)
        }
        guard let dueAtUTC else {
            throw LearningSceneError.relativeReminderWithoutDueDate
        }
        return dueAtUTC.addingTimeInterval(-Double(leadMinutes) * 60)
    }

    /// Why a due-relative reminder cannot be offered, or `nil` when it can.
    static func relativeReminderDisabledReason(dueDate: Date?) -> String? {
        dueDate == nil
            ? LearningSceneError.relativeReminderWithoutDueDate.localizedDescription
            : nil
    }

    private static func interval(
        _ meeting: MeetingWindow,
        on day: LocalCalendarDate
    ) -> (start: Date, end: Date)? {
        guard let zone = try? validatedTimeZone(meeting.timezoneID) else { return nil }
        guard let start = resolveWallTime(on: day, clock: meeting.start, in: zone),
              let end = resolveWallTime(on: day, clock: meeting.end, in: zone) else {
            return nil
        }
        return (start, end)
    }
}


// MARK: - Repository protocol

protocol LearningSceneRepository: AnyObject {
    // Course meetings
    func fetchMeetings(courseID: Int64?, includeDeleted: Bool) throws -> [CourseMeeting]
    func fetchMeetings(weekday: Int, includeDeleted: Bool) throws -> [CourseMeeting]
    func createMeeting(_ draft: CourseMeetingDraft) throws -> CourseMeeting
    func updateMeeting(_ meeting: CourseMeeting) throws -> CourseMeeting
    func deleteMeeting(id: Int64) throws
    func restoreMeeting(id: Int64) throws -> CourseMeeting

    /// Active meetings that collide with `draft`. Warnings only: nothing is
    /// changed, merged, or removed.
    func meetingsOverlapping(
        _ draft: CourseMeetingDraft,
        excludingID: Int64?
    ) throws -> [CourseMeeting]

    // Exams
    func fetchExams(courseID: Int64?, includeDeleted: Bool) throws -> [Exam]
    func createExam(_ draft: ExamDraft) throws -> Exam
    func updateExam(_ exam: Exam) throws -> Exam
    func deleteExam(id: Int64) throws
    func restoreExam(id: Int64) throws -> Exam

    // Reminders
    func fetchReminders(includeDeleted: Bool) throws -> [TaskReminder]

    /// Recomputes every due-relative reminder from the task deadlines currently
    /// stored in `assignments`. Fixed reminders are never touched.
    @discardableResult
    func rescheduleRelativeReminders() throws -> [TaskReminder]
}
