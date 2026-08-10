import Foundation


enum AssignmentStatus: String, Codable, CaseIterable, Sendable {
    case notStarted = "not_started"
    case inProgress = "in_progress"
    case completed

    var title: String {
        switch self {
        case .notStarted: "Not started"
        case .inProgress: "In progress"
        case .completed: "Completed"
        }
    }
}


struct Assignment: Identifiable, Hashable, Sendable {
    let id: Int64
    var courseName: String
    var title: String
    var dueDate: Date?
    var assignmentDescription: String?
    var link: String?
    var status: AssignmentStatus
    var sourceName: String?
    var sourceType: String?
    var sourceFile: String?
    var sourceURL: String?
    var createdAt: Date?
    var updatedAt: Date?
}


struct AssignmentCandidate: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var courseName: String?
    var title: String
    var dueDate: String?
    var dueTime: String?
    var description: String?
    var sourceName: String?
    var sourceURL: String?
    var confidence: String
    var warnings: [String]

    enum CodingKeys: String, CodingKey {
        case courseName = "course_name"
        case title
        case dueDate = "due_date"
        case dueTime = "due_time"
        case description
        case sourceName = "source_name"
        case sourceURL = "source_url"
        case confidence
        case warnings
    }
}


struct CandidateEnvelope: Codable, Sendable {
    var assignments: [AssignmentCandidate]
}


struct CapturedLink: Codable, Hashable, Sendable {
    var text: String
    var url: String
}


struct CapturedPage: Codable, Hashable, Sendable {
    var url: String
    var title: String
    var text: String
    var links: [CapturedLink]
}


struct StoredCredential: Sendable {
    let origin: String
    let username: String
    let password: String
}


enum LoginMode: String, CaseIterable, Identifiable, Sendable {
    case interactive
    case savedCredential

    var id: String { rawValue }

    var title: String {
        switch self {
        case .interactive: "Interactive login"
        case .savedCredential: "Keychain fill"
        }
    }

    var help: String {
        switch self {
        case .interactive:
            "Recommended. Type credentials directly into the website; the app never reads them."
        case .savedCredential:
            "Save one credential for this exact HTTPS website origin and fill it only when you click Fill."
        }
    }
}


enum SidebarSelection: String, CaseIterable, Identifiable {
    case all
    case today
    case week
    case completed
    case sources
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All Assignments"
        case .today: "Today"
        case .week: "This Week"
        case .completed: "Completed"
        case .sources: "Sources"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "rectangle.grid.1x2"
        case .today: "sun.max"
        case .week: "calendar"
        case .completed: "checkmark.circle"
        case .sources: "link"
        case .settings: "gearshape"
        }
    }
}


extension Date {
    static let databaseFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    static let databaseFormatterWithSeconds: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func fromDatabase(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return databaseFormatter.date(from: value)
            ?? databaseFormatterWithSeconds.date(from: value)
            ?? ISO8601DateFormatter().date(from: value)
    }
}
