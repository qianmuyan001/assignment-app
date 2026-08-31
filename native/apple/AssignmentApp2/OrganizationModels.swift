import Foundation


struct Course: Identifiable, Hashable {
    let id: Int64
    let uuid: UUID
    var name: String
    var normalizedName: String
    var colorHex: String?
    var teacher: String?
    var semester: String?
    var isArchived: Bool
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
}


enum ProjectStatus: String, Codable, CaseIterable, Identifiable {
    case active
    case onHold = "on_hold"
    case completed
    case archived

    var id: String { rawValue }
}


struct AssignmentProject: Identifiable, Hashable {
    let id: Int64
    let uuid: UUID
    var courseID: Int64?
    var name: String
    var projectDescription: String?
    var status: ProjectStatus
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
}


struct AssignmentTag: Identifiable, Hashable {
    let id: Int64
    let uuid: UUID
    var name: String
    var normalizedName: String
    var colorHex: String?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
}


struct TaskTagLink: Identifiable, Hashable {
    let id: Int64
    let uuid: UUID
    let assignmentID: Int64
    let tagID: Int64
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
}


struct AssignmentSubtask: Identifiable, Hashable {
    let id: Int64
    let uuid: UUID
    let assignmentID: Int64
    var title: String
    var status: AssignmentStatus
    var sortOrder: Int
    var completedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
}


struct AttachmentMetadata: Identifiable, Hashable {
    let id: Int64
    let uuid: UUID
    let assignmentID: Int64
    var fileName: String
    let relativePath: String
    var mimeType: String?
    var byteSize: Int64
    var sha256: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
}


struct TaskReminder: Identifiable, Hashable {
    let id: Int64
    let uuid: UUID
    let assignmentID: Int64
    var triggerAtUTC: Date
    var leadMinutes: Int
    var repeatRule: String?
    var isEnabled: Bool
    var lastScheduledAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
}


struct CourseDraft: Equatable {
    var name: String
    var colorHex: String?
    var teacher: String?
    var semester: String?
    var isArchived: Bool = false
}


struct ProjectDraft: Equatable {
    var courseID: Int64?
    var name: String
    var projectDescription: String?
    var status: ProjectStatus = .active
}


struct TagDraft: Equatable {
    var name: String
    var colorHex: String?
}


struct SubtaskDraft: Equatable {
    var assignmentID: Int64
    var title: String
    var status: AssignmentStatus = .todo
    var sortOrder: Int = 0
}


struct AttachmentMetadataDraft: Equatable {
    var assignmentID: Int64
    var fileName: String
    var mimeType: String?
    var byteSize: Int64
    var sha256: String
    var uuid: UUID = UUID()
}


struct ReminderDraft: Equatable {
    var assignmentID: Int64
    var triggerAtUTC: Date
    var leadMinutes: Int = 0
    var repeatRule: String?
    var isEnabled: Bool = true
    var lastScheduledAt: Date?
}
