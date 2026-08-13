import Foundation


enum AssignmentStatus: String, Codable, CaseIterable, Identifiable {
    case todo
    case inProgress = "in_progress"
    case done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .todo:
            return "To Do"
        case .inProgress:
            return "In Progress"
        case .done:
            return "Done"
        }
    }

    var storageValue: String {
        switch self {
        case .todo:
            return "not_started"
        case .inProgress:
            return "in_progress"
        case .done:
            return "completed"
        }
    }

    init(storageValue: String) throws {
        switch storageValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "not_started", "todo":
            self = .todo
        case "in_progress":
            self = .inProgress
        case "completed", "done":
            self = .done
        default:
            throw AssignmentDataError.unsupportedStatus(storageValue)
        }
    }
}


enum AssignmentPriority: String, Codable, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        }
    }

    var sortRank: Int {
        switch self {
        case .high:
            return 0
        case .medium:
            return 1
        case .low:
            return 2
        }
    }

    init(storageValue: String) throws {
        guard let value = Self(
            rawValue: storageValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        ) else {
            throw AssignmentDataError.unsupportedPriority(storageValue)
        }
        self = value
    }
}


enum AssignmentView: String, CaseIterable, Identifiable {
    case all
    case today
    case week
    case overdue
    case completed
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All Tasks"
        case .today:
            return "Today"
        case .week:
            return "This Week"
        case .overdue:
            return "Overdue"
        case .completed:
            return "Completed"
        case .settings:
            return "Settings"
        }
    }
}


enum AssignmentSortOrder: String, CaseIterable, Identifiable {
    case dueDate = "due_date"
    case priority

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dueDate:
            return "Due Date"
        case .priority:
            return "Priority"
        }
    }
}


enum DisplayMode: String, CaseIterable, Identifiable {
    case simple
    case professional

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simple:
            return "Simple"
        case .professional:
            return "Professional"
        }
    }
}


enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }
}


struct Assignment: Identifiable, Hashable {
    let id: Int64
    let uuid: UUID
    var courseName: String
    var title: String
    var dueDate: Date?
    var assignmentDescription: String?
    var link: String?
    var status: AssignmentStatus
    var priority: AssignmentPriority
    var sourceName: String?
    var sourceType: String?
    var sourceFile: String?
    var sourceURL: String?
    var createdAt: Date
    var updatedAt: Date
    var courseID: Int64?
    var projectID: Int64?
    var completedAt: Date?
    var progressPercent: Int
    var allDay: Bool
    var timeZoneIdentifier: String?
    var deletedAt: Date?
    /// Original SQLite wall-time text. Reused only when it still represents
    /// the unchanged `dueDate` loaded by the repository.
    var storedDueDateText: String?
    /// Parsed baseline paired with `storedDueDateText`. This is intentionally
    /// not persisted; it prevents a timezone-only edit or a device timezone
    /// change from rewriting legacy wall-time text.
    var storedDueDateValue: Date?

    init(
        id: Int64,
        uuid: UUID = UUID(),
        courseName: String,
        title: String,
        dueDate: Date? = nil,
        assignmentDescription: String? = nil,
        link: String? = nil,
        status: AssignmentStatus = .todo,
        priority: AssignmentPriority = .medium,
        sourceName: String? = nil,
        sourceType: String? = nil,
        sourceFile: String? = nil,
        sourceURL: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        courseID: Int64? = nil,
        projectID: Int64? = nil,
        completedAt: Date? = nil,
        progressPercent: Int? = nil,
        allDay: Bool = false,
        timeZoneIdentifier: String? = nil,
        deletedAt: Date? = nil,
        storedDueDateText: String? = nil,
        storedDueDateValue: Date? = nil
    ) {
        self.id = id
        self.uuid = uuid
        self.courseName = courseName
        self.title = title
        self.dueDate = dueDate
        self.assignmentDescription = assignmentDescription
        self.link = link
        self.status = status
        self.priority = priority
        self.sourceName = sourceName
        self.sourceType = sourceType
        self.sourceFile = sourceFile
        self.sourceURL = sourceURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.courseID = courseID
        self.projectID = projectID
        self.completedAt = completedAt ?? (status == .done ? updatedAt : nil)
        self.progressPercent = progressPercent ?? (status == .done ? 100 : 0)
        self.allDay = allDay
        self.timeZoneIdentifier = timeZoneIdentifier
        self.deletedAt = deletedAt
        self.storedDueDateText = storedDueDateText
        self.storedDueDateValue = storedDueDateValue
    }
}


struct AssignmentDraft: Equatable {
    var courseName: String
    var title: String
    var dueDate: Date?
    var assignmentDescription: String
    var link: String
    var status: AssignmentStatus
    var priority: AssignmentPriority
    var sourceName: String
    var sourceType: String
    var sourceFile: String
    var sourceURL: String

    init(
        courseName: String = "",
        title: String = "",
        dueDate: Date? = nil,
        assignmentDescription: String = "",
        link: String = "",
        status: AssignmentStatus = .todo,
        priority: AssignmentPriority = .medium,
        sourceName: String = "",
        sourceType: String = "",
        sourceFile: String = "",
        sourceURL: String = ""
    ) {
        self.courseName = courseName
        self.title = title
        self.dueDate = dueDate
        self.assignmentDescription = assignmentDescription
        self.link = link
        self.status = status
        self.priority = priority
        self.sourceName = sourceName
        self.sourceType = sourceType
        self.sourceFile = sourceFile
        self.sourceURL = sourceURL
    }

    init(assignment: Assignment) {
        self.init(
            courseName: assignment.courseName,
            title: assignment.title,
            dueDate: assignment.dueDate,
            assignmentDescription: assignment.assignmentDescription ?? "",
            link: assignment.link ?? "",
            status: assignment.status,
            priority: assignment.priority,
            sourceName: assignment.sourceName ?? "",
            sourceType: assignment.sourceType ?? "",
            sourceFile: assignment.sourceFile ?? "",
            sourceURL: assignment.sourceURL ?? ""
        )
    }

    func validated() throws -> AssignmentDraft {
        var result = self
        result.courseName = courseName.trimmingCharacters(in: .whitespacesAndNewlines)
        result.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        result.assignmentDescription = assignmentDescription.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        result.link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        result.sourceName = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        result.sourceType = sourceType.trimmingCharacters(in: .whitespacesAndNewlines)
        result.sourceFile = sourceFile.trimmingCharacters(in: .whitespacesAndNewlines)
        result.sourceURL = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !result.title.isEmpty else {
            throw AssignmentValidationError.missingTitle
        }
        guard !result.courseName.isEmpty else {
            throw AssignmentValidationError.missingCourse
        }
        guard result.title.count <= 255 else {
            throw AssignmentValidationError.titleTooLong
        }
        guard result.courseName.count <= 120 else {
            throw AssignmentValidationError.courseTooLong
        }
        guard result.link.count <= 1_000,
              result.sourceFile.count <= 1_000,
              result.sourceURL.count <= 1_000 else {
            throw AssignmentValidationError.linkTooLong
        }
        guard result.sourceName.count <= 255 else {
            throw AssignmentValidationError.sourceNameTooLong
        }
        guard result.sourceType.count <= 80 else {
            throw AssignmentValidationError.sourceTypeTooLong
        }
        return result
    }
}


struct AssignmentProjection: Equatable {
    let title: String
    let courseName: String
    let dueDate: Date?
    let status: AssignmentStatus
    let assignmentDescription: String?
    let priority: AssignmentPriority?
    let link: String?
}


enum AssignmentValidationError: LocalizedError, Equatable {
    case missingTitle
    case missingCourse
    case titleTooLong
    case courseTooLong
    case linkTooLong
    case sourceNameTooLong
    case sourceTypeTooLong

    var errorDescription: String? {
        switch self {
        case .missingTitle:
            return "Enter a task title."
        case .missingCourse:
            return "Enter a course."
        case .titleTooLong:
            return "The title must be 255 characters or fewer."
        case .courseTooLong:
            return "The course must be 120 characters or fewer."
        case .linkTooLong:
            return "Links and file paths must be 1,000 characters or fewer."
        case .sourceNameTooLong:
            return "The source name must be 255 characters or fewer."
        case .sourceTypeTooLong:
            return "The source type must be 80 characters or fewer."
        }
    }
}


enum AssignmentDataError: LocalizedError, Equatable {
    case unsupportedStatus(String)
    case unsupportedPriority(String)
    case invalidLocalWallTime(String)
    case offsetBearingLocalWallTime(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedStatus(let value):
            return "Unsupported task status: \(value)."
        case .unsupportedPriority(let value):
            return "Unsupported task priority: \(value)."
        case .invalidLocalWallTime(let value):
            return "Invalid local date and time: \(value)."
        case .offsetBearingLocalWallTime(let value):
            return "Task due dates must not contain a timezone or UTC offset: \(value)."
        }
    }
}


/// Converts a task due date to and from the shared local-wall-time contract.
/// The database representation is always `yyyy-MM-dd HH:mm:ss` without an offset.
enum LocalWallTime {
    private static let canonicalPattern =
        #"^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}(:[0-9]{2})?$"#
    private static let legacyFractionPattern =
        #"^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{1,6}$"#

    static func string(from date: Date, timeZone: TimeZone = .current) -> String {
        formatter(format: "yyyy-MM-dd HH:mm:ss", timeZone: timeZone).string(from: date)
    }

    static func date(
        from value: String?,
        timeZone: TimeZone = .current
    ) throws -> Date? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.range(of: canonicalPattern, options: .regularExpression) != nil else {
            if containsOffset(in: trimmed) {
                throw AssignmentDataError.offsetBearingLocalWallTime(trimmed)
            }
            throw AssignmentDataError.invalidLocalWallTime(trimmed)
        }

        let normalized = trimmed.replacingOccurrences(of: "T", with: " ")
        let format = normalized.count == 16 ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd HH:mm:ss"
        guard let date = formatter(format: format, timeZone: timeZone).date(from: normalized) else {
            throw AssignmentDataError.invalidLocalWallTime(trimmed)
        }
        return date
    }

    /// v1 SQLAlchemy databases may include fractional seconds, and historical
    /// local wall times may fall inside a daylight-saving gap. Both forms stay
    /// readable so an unrelated edit can preserve the stored text verbatim.
    static func legacyDate(
        from value: String,
        timeZone: TimeZone = .current
    ) throws -> Date {
        if let canonical = try? date(from: value, timeZone: timeZone) {
            return canonical
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let isCanonical = trimmed.range(
            of: canonicalPattern,
            options: .regularExpression
        ) != nil
        let isLegacyFraction = trimmed.range(
            of: legacyFractionPattern,
            options: .regularExpression
        ) != nil
        guard isCanonical || isLegacyFraction else {
            if containsOffset(in: trimmed) {
                throw AssignmentDataError.offsetBearingLocalWallTime(trimmed)
            }
            throw AssignmentDataError.invalidLocalWallTime(trimmed)
        }
        guard let date = compatibilityDate(from: trimmed, timeZone: timeZone) else {
            throw AssignmentDataError.invalidLocalWallTime(trimmed)
        }
        return date
    }

    private static func compatibilityDate(
        from value: String,
        timeZone: TimeZone
    ) -> Date? {
        let normalized = value.replacingOccurrences(of: "T", with: " ")
        let parts = normalized.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let dateParts = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        let timeAndFraction = parts[1].split(
            separator: ".",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let timeParts = timeAndFraction[0].split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        guard dateParts.count == 3, (2...3).contains(timeParts.count),
              let year = Int(dateParts[0]),
              let month = Int(dateParts[1]),
              let day = Int(dateParts[2]),
              let hour = Int(timeParts[0]),
              let minute = Int(timeParts[1]),
              let second = timeParts.count == 3 ? Int(timeParts[2]) : 0 else {
            return nil
        }

        var validation = Calendar(identifier: .gregorian)
        validation.timeZone = TimeZone(secondsFromGMT: 0)!
        let fields: Set<Calendar.Component> = [
            .year, .month, .day, .hour, .minute, .second,
        ]
        var components = DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )
        guard let validationDate = validation.date(from: components),
              validation.dateComponents(fields, from: validationDate) == components else {
            return nil
        }

        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        components.calendar = local
        components.timeZone = timeZone
        let dayStartComponents = DateComponents(year: year, month: month, day: day)
        guard let dayStart = local.date(from: dayStartComponents),
              let localDate = local.nextDate(
                  after: dayStart.addingTimeInterval(-1),
                  matching: DateComponents(hour: hour, minute: minute, second: second),
                  matchingPolicy: .nextTimePreservingSmallerComponents,
                  repeatedTimePolicy: .first,
                  direction: .forward
              ) else {
            return nil
        }
        guard local.dateComponents([.year, .month, .day], from: localDate)
            == DateComponents(year: year, month: month, day: day) else {
            return nil
        }
        guard timeAndFraction.count == 2 else { return localDate }
        let rawFraction = String(timeAndFraction[1])
        guard !rawFraction.isEmpty,
              rawFraction.allSatisfy(\.isNumber),
              let fraction = Double("0.\(rawFraction)") else {
            return nil
        }
        return localDate.addingTimeInterval(fraction)
    }

    private static func formatter(format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter
    }

    private static func containsOffset(in value: String) -> Bool {
        value.range(of: #"(Z|[+-][0-9]{2}:?[0-9]{2})$"#, options: .regularExpression) != nil
    }
}


enum DatabaseTimestamp {
    static func string(from date: Date) -> String {
        formatter(format: "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").string(from: date)
    }

    static func date(from value: String?) throws -> Date {
        guard let value else {
            throw AssignmentDataError.invalidLocalWallTime("NULL timestamp")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for format in [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss.SSSSSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
        ] {
            if let parsed = formatter(format: format).date(from: trimmed) {
                return parsed
            }
        }
        let fractionalISO = ISO8601DateFormatter()
        fractionalISO.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractionalISO.date(from: trimmed) {
            return parsed
        }
        if let parsed = ISO8601DateFormatter().date(from: trimmed) {
            return parsed
        }
        throw AssignmentDataError.invalidLocalWallTime(trimmed)
    }

    private static func formatter(format: String = "yyyy-MM-dd HH:mm:ss") -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter
    }
}
