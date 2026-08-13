import Foundation


protocol OrganizationRepository: AnyObject {
    var databaseURL: URL { get }

    func fetchCourses(includeDeleted: Bool) throws -> [Course]
    func createCourse(_ draft: CourseDraft) throws -> Course
    func updateCourse(_ course: Course) throws -> Course
    func deleteCourse(id: Int64) throws
    func restoreCourse(id: Int64) throws -> Course

    func fetchProjects(courseID: Int64?, includeDeleted: Bool) throws -> [AssignmentProject]
    func createProject(_ draft: ProjectDraft) throws -> AssignmentProject
    func updateProject(_ project: AssignmentProject) throws -> AssignmentProject
    func deleteProject(id: Int64) throws
    func restoreProject(id: Int64) throws -> AssignmentProject

    func fetchTags(includeDeleted: Bool) throws -> [AssignmentTag]
    func createTag(_ draft: TagDraft) throws -> AssignmentTag
    func updateTag(_ tag: AssignmentTag) throws -> AssignmentTag
    func deleteTag(id: Int64) throws
    func restoreTag(id: Int64) throws -> AssignmentTag
    func fetchTagLinks(assignmentID: Int64, includeDeleted: Bool) throws -> [TaskTagLink]
    func attachTag(_ tagID: Int64, to assignmentID: Int64) throws -> TaskTagLink
    func detachTag(_ tagID: Int64, from assignmentID: Int64) throws

    func fetchSubtasks(assignmentID: Int64, includeDeleted: Bool) throws -> [AssignmentSubtask]
    func createSubtask(_ draft: SubtaskDraft) throws -> AssignmentSubtask
    func updateSubtask(_ subtask: AssignmentSubtask) throws -> AssignmentSubtask
    func deleteSubtask(id: Int64) throws
    func restoreSubtask(id: Int64) throws -> AssignmentSubtask

    func fetchAttachments(assignmentID: Int64, includeDeleted: Bool) throws -> [AttachmentMetadata]
    func createAttachmentMetadata(_ draft: AttachmentMetadataDraft) throws -> AttachmentMetadata
    func updateAttachmentMetadata(_ attachment: AttachmentMetadata) throws -> AttachmentMetadata
    func deleteAttachmentMetadata(id: Int64) throws

    func fetchReminders(assignmentID: Int64, includeDeleted: Bool) throws -> [TaskReminder]
    func createReminder(_ draft: ReminderDraft) throws -> TaskReminder
    func updateReminder(_ reminder: TaskReminder) throws -> TaskReminder
    func deleteReminder(id: Int64) throws
}


enum OrganizationRepositoryError: LocalizedError, Equatable {
    case validation(String)
    case notFound(String, Int64)
    case corruptData(String)

    var errorDescription: String? {
        switch self {
        case .validation(let message), .corruptData(let message):
            return message
        case .notFound(let entity, let id):
            return "\(entity) \(id) no longer exists."
        }
    }
}
