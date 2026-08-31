import Foundation
import SQLite3


final class SQLiteOrganizationRepository: OrganizationRepository, @unchecked Sendable {
    let databaseURL: URL
    let lastMigrationResult: MigrationResult

    private var database: OpaquePointer?
    private let lock = NSLock()

    init(databaseURL: URL = SQLiteAssignmentRepository.defaultDatabaseURL()) throws {
        self.databaseURL = databaseURL.standardizedFileURL
        SQLiteAssignmentRepository.preconditionSafeTestDatabaseURL(self.databaseURL)
        try FileManager.default.createDirectory(
            at: self.databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        lastMigrationResult = try MigrationCoordinator.prepareDatabase(at: self.databaseURL)
        let opened = try SQLiteSupport.open(self.databaseURL)
        do {
            try SQLiteSupport.configure(opened)
            try SQLiteSupport.execute("PRAGMA journal_mode = WAL", on: opened)
            try SQLiteSupport.execute("PRAGMA synchronous = NORMAL", on: opened)
        } catch {
            sqlite3_close(opened)
            throw error
        }
        database = opened
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    /// Shared entry point used by both repository writes and schema validation.
    static func canonicalRepeatRule(_ input: String?) throws -> String? {
        try validatedRepeatRule(input)
    }

    func fetchCourses(includeDeleted: Bool = false) throws -> [Course] {
        try lock.withLock {
            let database = try requireDatabase()
            return try Self.readCourses(
                sql: """
                SELECT id, uuid, name, normalized_name, color_hex, teacher, semester,
                       is_archived, created_at, updated_at, deleted_at
                FROM courses
                \(includeDeleted ? "" : "WHERE deleted_at IS NULL")
                ORDER BY is_archived, name COLLATE NOCASE, id
                """,
                on: database
            )
        }
    }

    func createCourse(_ draft: CourseDraft) throws -> Course {
        let values = try Self.validatedCourseDraft(draft)
        return try withWrite { database in
            let statement = try SQLiteSupport.prepare(
                """
                INSERT INTO courses (
                    uuid, name, normalized_name, color_hex, teacher, semester,
                    is_archived, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            let timestamp = DatabaseTimestamp.string(from: Date())
            SQLiteSupport.bind(UUID().canonicalString, to: statement, index: 1)
            SQLiteSupport.bind(values.name, to: statement, index: 2)
            SQLiteSupport.bind(SharedIdentity.canonicalName(values.name), to: statement, index: 3)
            SQLiteSupport.bind(values.colorHex, to: statement, index: 4)
            SQLiteSupport.bind(values.teacher, to: statement, index: 5)
            SQLiteSupport.bind(values.semester, to: statement, index: 6)
            sqlite3_bind_int(statement, 7, values.isArchived ? 1 : 0)
            SQLiteSupport.bind(timestamp, to: statement, index: 8)
            SQLiteSupport.bind(timestamp, to: statement, index: 9)
            try SQLiteSupport.checkDone(statement, on: database)
            return try Self.fetchCourse(id: sqlite3_last_insert_rowid(database), on: database)
        }
    }

    func updateCourse(_ course: Course) throws -> Course {
        let values = try Self.validatedCourseDraft(.init(
            name: course.name,
            colorHex: course.colorHex,
            teacher: course.teacher,
            semester: course.semester,
            isArchived: course.isArchived
        ))
        return try withWrite { database in
            let timestamp = DatabaseTimestamp.string(from: Date())
            let statement = try SQLiteSupport.prepare(
                """
                UPDATE courses
                SET name = ?, normalized_name = ?, color_hex = ?, teacher = ?, semester = ?,
                    is_archived = ?, updated_at = ?
                WHERE id = ? AND deleted_at IS NULL
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            SQLiteSupport.bind(values.name, to: statement, index: 1)
            SQLiteSupport.bind(SharedIdentity.canonicalName(values.name), to: statement, index: 2)
            SQLiteSupport.bind(values.colorHex, to: statement, index: 3)
            SQLiteSupport.bind(values.teacher, to: statement, index: 4)
            SQLiteSupport.bind(values.semester, to: statement, index: 5)
            sqlite3_bind_int(statement, 6, values.isArchived ? 1 : 0)
            SQLiteSupport.bind(timestamp, to: statement, index: 7)
            sqlite3_bind_int64(statement, 8, course.id)
            try SQLiteSupport.checkDone(statement, on: database)
            guard sqlite3_changes(database) == 1 else {
                throw OrganizationRepositoryError.notFound("Course", course.id)
            }

            let tasks = try SQLiteSupport.prepare(
                """
                UPDATE assignments SET course_name = ?, updated_at = ?
                WHERE course_id = ?
                """,
                on: database
            )
            SQLiteSupport.bind(values.name, to: tasks, index: 1)
            SQLiteSupport.bind(timestamp, to: tasks, index: 2)
            sqlite3_bind_int64(tasks, 3, course.id)
            do { try SQLiteSupport.checkDone(tasks, on: database) }
            catch { sqlite3_finalize(tasks); throw error }
            sqlite3_finalize(tasks)
            return try Self.fetchCourse(id: course.id, on: database)
        }
    }

    func deleteCourse(id: Int64) throws {
        try softDelete(table: "courses", entity: "Course", id: id)
    }

    func restoreCourse(id: Int64) throws -> Course {
        try withWrite { database in
            try Self.restoreRow(table: "courses", entity: "Course", id: id, on: database)
            return try Self.fetchCourse(id: id, on: database)
        }
    }

    func fetchProjects(
        courseID: Int64? = nil,
        includeDeleted: Bool = false
    ) throws -> [AssignmentProject] {
        try lock.withLock {
            let database = try requireDatabase()
            var predicates: [String] = []
            if !includeDeleted { predicates.append("deleted_at IS NULL") }
            if courseID != nil { predicates.append("course_id = ?") }
            let clause = predicates.isEmpty ? "" : "WHERE " + predicates.joined(separator: " AND ")
            let statement = try SQLiteSupport.prepare(
                """
                SELECT id, uuid, course_id, name, description, status,
                       created_at, updated_at, deleted_at
                FROM projects \(clause)
                ORDER BY name COLLATE NOCASE, id
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            if let courseID { sqlite3_bind_int64(statement, 1, courseID) }
            return try Self.collect(statement, on: database, mapper: Self.project)
        }
    }

    func createProject(_ draft: ProjectDraft) throws -> AssignmentProject {
        let values = try Self.validatedProjectDraft(draft)
        return try withWrite { database in
            try Self.validateProjectCourse(values.courseID, projectID: nil, on: database)
            let statement = try SQLiteSupport.prepare(
                """
                INSERT INTO projects (
                    uuid, course_id, name, description, status, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            let timestamp = DatabaseTimestamp.string(from: Date())
            SQLiteSupport.bind(UUID().canonicalString, to: statement, index: 1)
            SQLiteSupport.bind(values.courseID, to: statement, index: 2)
            SQLiteSupport.bind(values.name, to: statement, index: 3)
            SQLiteSupport.bind(values.projectDescription, to: statement, index: 4)
            SQLiteSupport.bind(values.status.rawValue, to: statement, index: 5)
            SQLiteSupport.bind(timestamp, to: statement, index: 6)
            SQLiteSupport.bind(timestamp, to: statement, index: 7)
            try SQLiteSupport.checkDone(statement, on: database)
            return try Self.fetchProject(id: sqlite3_last_insert_rowid(database), on: database)
        }
    }

    func updateProject(_ project: AssignmentProject) throws -> AssignmentProject {
        let values = try Self.validatedProjectDraft(.init(
            courseID: project.courseID,
            name: project.name,
            projectDescription: project.projectDescription,
            status: project.status
        ))
        return try withWrite { database in
            try Self.validateProjectCourse(
                values.courseID,
                projectID: project.id,
                on: database
            )
            let statement = try SQLiteSupport.prepare(
                """
                UPDATE projects
                SET course_id = ?, name = ?, description = ?, status = ?, updated_at = ?
                WHERE id = ? AND deleted_at IS NULL
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            SQLiteSupport.bind(values.courseID, to: statement, index: 1)
            SQLiteSupport.bind(values.name, to: statement, index: 2)
            SQLiteSupport.bind(values.projectDescription, to: statement, index: 3)
            SQLiteSupport.bind(values.status.rawValue, to: statement, index: 4)
            SQLiteSupport.bind(DatabaseTimestamp.string(from: Date()), to: statement, index: 5)
            sqlite3_bind_int64(statement, 6, project.id)
            try SQLiteSupport.checkDone(statement, on: database)
            guard sqlite3_changes(database) == 1 else {
                throw OrganizationRepositoryError.notFound("Project", project.id)
            }
            return try Self.fetchProject(id: project.id, on: database)
        }
    }

    func deleteProject(id: Int64) throws {
        try softDelete(table: "projects", entity: "Project", id: id)
    }

    func restoreProject(id: Int64) throws -> AssignmentProject {
        try withWrite { database in
            let courseID = try Self.projectCourseIDIncludingDeleted(id: id, on: database)
            try Self.validateProjectCourse(courseID, projectID: id, on: database)
            try Self.restoreRow(table: "projects", entity: "Project", id: id, on: database)
            return try Self.fetchProject(id: id, on: database)
        }
    }

    func fetchTags(includeDeleted: Bool = false) throws -> [AssignmentTag] {
        try lock.withLock {
            let database = try requireDatabase()
            let statement = try SQLiteSupport.prepare(
                """
                SELECT id, uuid, name, normalized_name, color_hex,
                       created_at, updated_at, deleted_at
                FROM tags
                \(includeDeleted ? "" : "WHERE deleted_at IS NULL")
                ORDER BY name COLLATE NOCASE, id
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            return try Self.collect(statement, on: database, mapper: Self.tag)
        }
    }

    func createTag(_ draft: TagDraft) throws -> AssignmentTag {
        let values = try Self.validatedTagDraft(draft)
        return try withWrite { database in
            let statement = try SQLiteSupport.prepare(
                """
                INSERT INTO tags (
                    uuid, name, normalized_name, color_hex, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            let timestamp = DatabaseTimestamp.string(from: Date())
            SQLiteSupport.bind(UUID().canonicalString, to: statement, index: 1)
            SQLiteSupport.bind(values.name, to: statement, index: 2)
            SQLiteSupport.bind(SharedIdentity.canonicalName(values.name), to: statement, index: 3)
            SQLiteSupport.bind(values.colorHex, to: statement, index: 4)
            SQLiteSupport.bind(timestamp, to: statement, index: 5)
            SQLiteSupport.bind(timestamp, to: statement, index: 6)
            try SQLiteSupport.checkDone(statement, on: database)
            return try Self.fetchTag(id: sqlite3_last_insert_rowid(database), on: database)
        }
    }

    func updateTag(_ tag: AssignmentTag) throws -> AssignmentTag {
        let values = try Self.validatedTagDraft(.init(name: tag.name, colorHex: tag.colorHex))
        return try withWrite { database in
            let statement = try SQLiteSupport.prepare(
                """
                UPDATE tags
                SET name = ?, normalized_name = ?, color_hex = ?, updated_at = ?
                WHERE id = ? AND deleted_at IS NULL
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            SQLiteSupport.bind(values.name, to: statement, index: 1)
            SQLiteSupport.bind(SharedIdentity.canonicalName(values.name), to: statement, index: 2)
            SQLiteSupport.bind(values.colorHex, to: statement, index: 3)
            SQLiteSupport.bind(DatabaseTimestamp.string(from: Date()), to: statement, index: 4)
            sqlite3_bind_int64(statement, 5, tag.id)
            try SQLiteSupport.checkDone(statement, on: database)
            guard sqlite3_changes(database) == 1 else {
                throw OrganizationRepositoryError.notFound("Tag", tag.id)
            }
            return try Self.fetchTag(id: tag.id, on: database)
        }
    }

    func deleteTag(id: Int64) throws {
        try withWrite { database in
            guard try Self.activeRowExists(table: "tags", id: id, on: database) else {
                throw OrganizationRepositoryError.notFound("Tag", id)
            }
            let timestamp = DatabaseTimestamp.string(from: Date())
            try Self.softDeleteRow(table: "tags", id: id, timestamp: timestamp, on: database)
            let links = try SQLiteSupport.prepare(
                """
                UPDATE task_tags SET deleted_at = ?, updated_at = ?
                WHERE tag_id = ? AND deleted_at IS NULL
                """,
                on: database
            )
            defer { sqlite3_finalize(links) }
            SQLiteSupport.bind(timestamp, to: links, index: 1)
            SQLiteSupport.bind(timestamp, to: links, index: 2)
            sqlite3_bind_int64(links, 3, id)
            try SQLiteSupport.checkDone(links, on: database)
        }
    }

    func restoreTag(id: Int64) throws -> AssignmentTag {
        try withWrite { database in
            try Self.restoreRow(table: "tags", entity: "Tag", id: id, on: database)
            return try Self.fetchTag(id: id, on: database)
        }
    }

    func fetchTagLinks(
        assignmentID: Int64,
        includeDeleted: Bool = false
    ) throws -> [TaskTagLink] {
        try lock.withLock {
            let database = try requireDatabase()
            let statement = try SQLiteSupport.prepare(
                """
                SELECT id, uuid, assignment_id, tag_id, created_at, updated_at, deleted_at
                FROM task_tags
                WHERE assignment_id = ? \(includeDeleted ? "" : "AND deleted_at IS NULL")
                ORDER BY id
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, assignmentID)
            return try Self.collect(statement, on: database, mapper: Self.tagLink)
        }
    }

    func attachTag(_ tagID: Int64, to assignmentID: Int64) throws -> TaskTagLink {
        try withWrite { database in
            guard try Self.activeRowExists(table: "assignments", id: assignmentID, on: database),
                  try Self.activeRowExists(table: "tags", id: tagID, on: database) else {
                throw OrganizationRepositoryError.validation("Task and tag must both be active.")
            }
            if let active = try Self.fetchTagLink(
                assignmentID: assignmentID,
                tagID: tagID,
                deleted: false,
                on: database
            ) {
                return active
            }
            if let deleted = try Self.fetchTagLink(
                assignmentID: assignmentID,
                tagID: tagID,
                deleted: true,
                on: database
            ) {
                let statement = try SQLiteSupport.prepare(
                    "UPDATE task_tags SET deleted_at = NULL, updated_at = ? WHERE id = ?",
                    on: database
                )
                defer { sqlite3_finalize(statement) }
                SQLiteSupport.bind(DatabaseTimestamp.string(from: Date()), to: statement, index: 1)
                sqlite3_bind_int64(statement, 2, deleted.id)
                try SQLiteSupport.checkDone(statement, on: database)
                return try Self.fetchTaskTagLink(id: deleted.id, on: database)
            }

            let statement = try SQLiteSupport.prepare(
                """
                INSERT INTO task_tags (
                    uuid, assignment_id, tag_id, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?)
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            let timestamp = DatabaseTimestamp.string(from: Date())
            SQLiteSupport.bind(UUID().canonicalString, to: statement, index: 1)
            sqlite3_bind_int64(statement, 2, assignmentID)
            sqlite3_bind_int64(statement, 3, tagID)
            SQLiteSupport.bind(timestamp, to: statement, index: 4)
            SQLiteSupport.bind(timestamp, to: statement, index: 5)
            try SQLiteSupport.checkDone(statement, on: database)
            return try Self.fetchTaskTagLink(id: sqlite3_last_insert_rowid(database), on: database)
        }
    }

    func detachTag(_ tagID: Int64, from assignmentID: Int64) throws {
        try withWrite { database in
            let statement = try SQLiteSupport.prepare(
                """
                UPDATE task_tags SET deleted_at = ?, updated_at = ?
                WHERE assignment_id = ? AND tag_id = ? AND deleted_at IS NULL
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            let timestamp = DatabaseTimestamp.string(from: Date())
            SQLiteSupport.bind(timestamp, to: statement, index: 1)
            SQLiteSupport.bind(timestamp, to: statement, index: 2)
            sqlite3_bind_int64(statement, 3, assignmentID)
            sqlite3_bind_int64(statement, 4, tagID)
            try SQLiteSupport.checkDone(statement, on: database)
            guard sqlite3_changes(database) == 1 else {
                throw OrganizationRepositoryError.validation("The task does not have that active tag.")
            }
        }
    }

    func fetchSubtasks(
        assignmentID: Int64,
        includeDeleted: Bool = false
    ) throws -> [AssignmentSubtask] {
        try lock.withLock {
            let database = try requireDatabase()
            let statement = try SQLiteSupport.prepare(
                """
                SELECT id, uuid, assignment_id, title, status, sort_order, completed_at,
                       created_at, updated_at, deleted_at
                FROM subtasks
                WHERE assignment_id = ? \(includeDeleted ? "" : "AND deleted_at IS NULL")
                ORDER BY sort_order, id
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, assignmentID)
            return try Self.collect(statement, on: database, mapper: Self.subtask)
        }
    }

    func createSubtask(_ draft: SubtaskDraft) throws -> AssignmentSubtask {
        let values = try Self.validatedSubtaskDraft(draft)
        return try withWrite { database in
            try Self.requireActiveAssignment(values.assignmentID, on: database)
            let statement = try SQLiteSupport.prepare(
                """
                INSERT INTO subtasks (
                    uuid, assignment_id, title, status, sort_order, completed_at,
                    created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            let timestamp = DatabaseTimestamp.string(from: Date())
            SQLiteSupport.bind(UUID().canonicalString, to: statement, index: 1)
            sqlite3_bind_int64(statement, 2, values.assignmentID)
            SQLiteSupport.bind(values.title, to: statement, index: 3)
            SQLiteSupport.bind(values.status.storageValue, to: statement, index: 4)
            sqlite3_bind_int64(statement, 5, Int64(values.sortOrder))
            SQLiteSupport.bind(values.status == .done ? timestamp : nil, to: statement, index: 6)
            SQLiteSupport.bind(timestamp, to: statement, index: 7)
            SQLiteSupport.bind(timestamp, to: statement, index: 8)
            try SQLiteSupport.checkDone(statement, on: database)
            let id = sqlite3_last_insert_rowid(database)
            _ = try TaskProgressPersistence.recalculateParent(
                assignmentID: values.assignmentID,
                resetWhenEmpty: true,
                timestamp: timestamp,
                on: database
            )
            return try Self.fetchSubtask(id: id, on: database)
        }
    }

    func updateSubtask(_ subtask: AssignmentSubtask) throws -> AssignmentSubtask {
        let values = try Self.validatedSubtaskDraft(.init(
            assignmentID: subtask.assignmentID,
            title: subtask.title,
            status: subtask.status,
            sortOrder: subtask.sortOrder
        ))
        return try withWrite { database in
            let stored = try Self.fetchSubtask(id: subtask.id, on: database)
            guard stored.uuid == subtask.uuid,
                  stored.assignmentID == values.assignmentID else {
                throw OrganizationRepositoryError.validation(
                    "A subtask's UUID and parent task cannot be changed."
                )
            }
            try Self.requireActiveAssignment(stored.assignmentID, on: database)
            let statement = try SQLiteSupport.prepare(
                """
                UPDATE subtasks
                SET title = ?, status = ?, sort_order = ?, completed_at = ?, updated_at = ?
                WHERE id = ? AND deleted_at IS NULL
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            let timestamp = DatabaseTimestamp.string(from: Date())
            SQLiteSupport.bind(values.title, to: statement, index: 1)
            SQLiteSupport.bind(values.status.storageValue, to: statement, index: 2)
            sqlite3_bind_int64(statement, 3, Int64(values.sortOrder))
            SQLiteSupport.bind(
                values.status == .done
                    ? DatabaseTimestamp.string(from: subtask.completedAt ?? Date())
                    : nil,
                to: statement,
                index: 4
            )
            SQLiteSupport.bind(timestamp, to: statement, index: 5)
            sqlite3_bind_int64(statement, 6, subtask.id)
            try SQLiteSupport.checkDone(statement, on: database)
            guard sqlite3_changes(database) == 1 else {
                throw OrganizationRepositoryError.notFound("Subtask", subtask.id)
            }
            _ = try TaskProgressPersistence.recalculateParent(
                assignmentID: stored.assignmentID,
                resetWhenEmpty: true,
                timestamp: timestamp,
                on: database
            )
            return try Self.fetchSubtask(id: subtask.id, on: database)
        }
    }

    func deleteSubtask(id: Int64) throws {
        try withWrite { database in
            let assignmentID = try Self.subtaskAssignmentID(
                id: id,
                requireDeleted: false,
                on: database
            )
            try Self.requireActiveAssignment(assignmentID, on: database)
            let timestamp = DatabaseTimestamp.string(from: Date())
            try Self.softDeleteRow(table: "subtasks", id: id, timestamp: timestamp, on: database)
            _ = try TaskProgressPersistence.recalculateParent(
                assignmentID: assignmentID,
                resetWhenEmpty: true,
                timestamp: timestamp,
                on: database
            )
        }
    }

    func restoreSubtask(id: Int64) throws -> AssignmentSubtask {
        try withWrite { database in
            let assignmentID = try Self.subtaskAssignmentID(
                id: id,
                requireDeleted: nil,
                on: database
            )
            try Self.requireActiveAssignment(assignmentID, on: database)
            try Self.restoreRow(table: "subtasks", entity: "Subtask", id: id, on: database)
            let timestamp = DatabaseTimestamp.string(from: Date())
            _ = try TaskProgressPersistence.recalculateParent(
                assignmentID: assignmentID,
                resetWhenEmpty: true,
                timestamp: timestamp,
                on: database
            )
            return try Self.fetchSubtask(id: id, on: database)
        }
    }

    func fetchAttachments(
        assignmentID: Int64,
        includeDeleted: Bool = false
    ) throws -> [AttachmentMetadata] {
        try lock.withLock {
            let database = try requireDatabase()
            let statement = try SQLiteSupport.prepare(
                """
                SELECT id, uuid, assignment_id, file_name, relative_path, mime_type,
                       byte_size, sha256, created_at, updated_at, deleted_at
                FROM attachments
                WHERE assignment_id = ? \(includeDeleted ? "" : "AND deleted_at IS NULL")
                ORDER BY id
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, assignmentID)
            return try Self.collect(statement, on: database, mapper: Self.attachment)
        }
    }

    func createAttachmentMetadata(_ draft: AttachmentMetadataDraft) throws -> AttachmentMetadata {
        let values = try Self.validatedAttachmentDraft(draft)
        return try withWrite { database in
            try Self.requireActiveAssignment(values.assignmentID, on: database)
            let uuid = values.uuid
            let path = try SharedIdentity.attachmentRelativePath(for: uuid)
            let statement = try SQLiteSupport.prepare(
                """
                INSERT INTO attachments (
                    uuid, assignment_id, file_name, relative_path, mime_type,
                    byte_size, sha256, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            let timestamp = DatabaseTimestamp.string(from: Date())
            SQLiteSupport.bind(uuid.canonicalString, to: statement, index: 1)
            sqlite3_bind_int64(statement, 2, values.assignmentID)
            SQLiteSupport.bind(values.fileName, to: statement, index: 3)
            SQLiteSupport.bind(path, to: statement, index: 4)
            SQLiteSupport.bind(values.mimeType, to: statement, index: 5)
            sqlite3_bind_int64(statement, 6, values.byteSize)
            SQLiteSupport.bind(values.sha256, to: statement, index: 7)
            SQLiteSupport.bind(timestamp, to: statement, index: 8)
            SQLiteSupport.bind(timestamp, to: statement, index: 9)
            try SQLiteSupport.checkDone(statement, on: database)
            return try Self.fetchAttachment(id: sqlite3_last_insert_rowid(database), on: database)
        }
    }

    func fetchAllAttachments(includeDeleted: Bool = false) throws -> [AttachmentMetadata] {
        try lock.withLock {
            let database = try requireDatabase()
            let statement = try SQLiteSupport.prepare(
                """
                SELECT id, uuid, assignment_id, file_name, relative_path, mime_type,
                       byte_size, sha256, created_at, updated_at, deleted_at
                FROM attachments
                \(includeDeleted ? "" : "WHERE deleted_at IS NULL")
                ORDER BY id
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            return try Self.collect(statement, on: database, mapper: Self.attachment)
        }
    }

    func updateAttachmentMetadata(_ attachment: AttachmentMetadata) throws -> AttachmentMetadata {
        let values = try Self.validatedAttachmentDraft(.init(
            assignmentID: attachment.assignmentID,
            fileName: attachment.fileName,
            mimeType: attachment.mimeType,
            byteSize: attachment.byteSize,
            sha256: attachment.sha256
        ))
        return try withWrite { database in
            let stored = try Self.fetchAttachment(id: attachment.id, on: database)
            guard stored.uuid == attachment.uuid,
                  stored.assignmentID == values.assignmentID,
                  stored.relativePath == attachment.relativePath else {
                throw OrganizationRepositoryError.validation(
                    "An attachment's UUID, parent task, and storage path cannot be changed."
                )
            }
            try Self.requireActiveAssignment(stored.assignmentID, on: database)
            guard attachment.relativePath
                    == (try SharedIdentity.attachmentRelativePath(for: attachment.uuid)) else {
                throw OrganizationRepositoryError.validation(
                    "Attachment storage path must remain derived from its immutable UUID."
                )
            }
            let statement = try SQLiteSupport.prepare(
                """
                UPDATE attachments
                SET file_name = ?, mime_type = ?, byte_size = ?, sha256 = ?, updated_at = ?
                WHERE id = ? AND deleted_at IS NULL
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            SQLiteSupport.bind(values.fileName, to: statement, index: 1)
            SQLiteSupport.bind(values.mimeType, to: statement, index: 2)
            sqlite3_bind_int64(statement, 3, values.byteSize)
            SQLiteSupport.bind(values.sha256, to: statement, index: 4)
            SQLiteSupport.bind(DatabaseTimestamp.string(from: Date()), to: statement, index: 5)
            sqlite3_bind_int64(statement, 6, attachment.id)
            try SQLiteSupport.checkDone(statement, on: database)
            guard sqlite3_changes(database) == 1 else {
                throw OrganizationRepositoryError.notFound("Attachment", attachment.id)
            }
            return try Self.fetchAttachment(id: attachment.id, on: database)
        }
    }

    func deleteAttachmentMetadata(id: Int64) throws {
        try softDelete(table: "attachments", entity: "Attachment", id: id)
    }

    func fetchReminders(
        assignmentID: Int64,
        includeDeleted: Bool = false
    ) throws -> [TaskReminder] {
        try lock.withLock {
            let database = try requireDatabase()
            let statement = try SQLiteSupport.prepare(
                """
                SELECT id, uuid, assignment_id, trigger_at_utc, lead_minutes,
                       repeat_rule, is_enabled, last_scheduled_at,
                       created_at, updated_at, deleted_at
                FROM reminders
                WHERE assignment_id = ? \(includeDeleted ? "" : "AND deleted_at IS NULL")
                ORDER BY trigger_at_utc, id
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, assignmentID)
            return try Self.collect(statement, on: database, mapper: Self.reminder)
        }
    }

    func createReminder(_ draft: ReminderDraft) throws -> TaskReminder {
        let values = try Self.validatedReminderDraft(draft)
        return try withWrite { database in
            try Self.requireActiveAssignment(values.assignmentID, on: database)
            let statement = try SQLiteSupport.prepare(
                """
                INSERT INTO reminders (
                    uuid, assignment_id, trigger_at_utc, lead_minutes, repeat_rule,
                    is_enabled, last_scheduled_at, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            let timestamp = DatabaseTimestamp.string(from: Date())
            SQLiteSupport.bind(UUID().canonicalString, to: statement, index: 1)
            sqlite3_bind_int64(statement, 2, values.assignmentID)
            SQLiteSupport.bind(
                DatabaseTimestamp.string(from: values.triggerAtUTC),
                to: statement,
                index: 3
            )
            sqlite3_bind_int64(statement, 4, Int64(values.leadMinutes))
            SQLiteSupport.bind(values.repeatRule, to: statement, index: 5)
            sqlite3_bind_int(statement, 6, values.isEnabled ? 1 : 0)
            SQLiteSupport.bind(
                values.lastScheduledAt.map(DatabaseTimestamp.string),
                to: statement,
                index: 7
            )
            SQLiteSupport.bind(timestamp, to: statement, index: 8)
            SQLiteSupport.bind(timestamp, to: statement, index: 9)
            try SQLiteSupport.checkDone(statement, on: database)
            return try Self.fetchReminder(id: sqlite3_last_insert_rowid(database), on: database)
        }
    }

    func updateReminder(_ reminder: TaskReminder) throws -> TaskReminder {
        let values = try Self.validatedReminderDraft(.init(
            assignmentID: reminder.assignmentID,
            triggerAtUTC: reminder.triggerAtUTC,
            leadMinutes: reminder.leadMinutes,
            repeatRule: reminder.repeatRule,
            isEnabled: reminder.isEnabled,
            lastScheduledAt: reminder.lastScheduledAt
        ))
        return try withWrite { database in
            let stored = try Self.fetchReminder(id: reminder.id, on: database)
            guard stored.uuid == reminder.uuid,
                  stored.assignmentID == values.assignmentID else {
                throw OrganizationRepositoryError.validation(
                    "A reminder's UUID and parent task cannot be changed."
                )
            }
            try Self.requireActiveAssignment(stored.assignmentID, on: database)
            let statement = try SQLiteSupport.prepare(
                """
                UPDATE reminders
                SET trigger_at_utc = ?, lead_minutes = ?, repeat_rule = ?, is_enabled = ?,
                    last_scheduled_at = ?, updated_at = ?
                WHERE id = ? AND deleted_at IS NULL
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            SQLiteSupport.bind(
                DatabaseTimestamp.string(from: values.triggerAtUTC),
                to: statement,
                index: 1
            )
            sqlite3_bind_int64(statement, 2, Int64(values.leadMinutes))
            SQLiteSupport.bind(values.repeatRule, to: statement, index: 3)
            sqlite3_bind_int(statement, 4, values.isEnabled ? 1 : 0)
            SQLiteSupport.bind(
                values.lastScheduledAt.map(DatabaseTimestamp.string),
                to: statement,
                index: 5
            )
            SQLiteSupport.bind(DatabaseTimestamp.string(from: Date()), to: statement, index: 6)
            sqlite3_bind_int64(statement, 7, reminder.id)
            try SQLiteSupport.checkDone(statement, on: database)
            guard sqlite3_changes(database) == 1 else {
                throw OrganizationRepositoryError.notFound("Reminder", reminder.id)
            }
            return try Self.fetchReminder(id: reminder.id, on: database)
        }
    }

    func deleteReminder(id: Int64) throws {
        try withWrite { database in
            let statement = try SQLiteSupport.prepare(
                """
                UPDATE reminders
                SET is_enabled = 0, deleted_at = ?, updated_at = ?
                WHERE id = ? AND deleted_at IS NULL
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            let timestamp = DatabaseTimestamp.string(from: Date())
            SQLiteSupport.bind(timestamp, to: statement, index: 1)
            SQLiteSupport.bind(timestamp, to: statement, index: 2)
            sqlite3_bind_int64(statement, 3, id)
            try SQLiteSupport.checkDone(statement, on: database)
            guard sqlite3_changes(database) == 1 else {
                throw OrganizationRepositoryError.notFound("Reminder", id)
            }
        }
    }

    private func requireDatabase() throws -> OpaquePointer {
        guard let database else {
            throw AssignmentRepositoryError.readOnlyAfterMigrationFailure
        }
        return database
    }

    private func withWrite<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try lock.withLock {
            let database = try requireDatabase()
            try SQLiteSupport.execute("BEGIN IMMEDIATE", on: database)
            do {
                let value = try body(database)
                try SQLiteSupport.execute("COMMIT", on: database)
                return value
            } catch {
                try? SQLiteSupport.execute("ROLLBACK", on: database)
                throw error
            }
        }
    }

    private func softDelete(table: String, entity: String, id: Int64) throws {
        try withWrite { database in
            let timestamp = DatabaseTimestamp.string(from: Date())
            guard try Self.activeRowExists(table: table, id: id, on: database) else {
                throw OrganizationRepositoryError.notFound(entity, id)
            }
            try Self.softDeleteRow(table: table, id: id, timestamp: timestamp, on: database)
        }
    }
}


// MARK: - Row mapping

private extension SQLiteOrganizationRepository {
    static func collect<T>(
        _ statement: OpaquePointer,
        on database: OpaquePointer,
        mapper: (OpaquePointer) throws -> T
    ) throws -> [T] {
        var values: [T] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            values.append(try mapper(statement))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw AssignmentRepositoryError.execute(String(cString: sqlite3_errmsg(database)))
        }
        return values
    }

    static func parsedUUID(_ statement: OpaquePointer, _ column: Int32) throws -> UUID {
        guard let text = SQLiteSupport.text(statement, column),
              let value = UUID(uuidString: text),
              value.canonicalString == text else {
            throw OrganizationRepositoryError.corruptData("Stored UUID is invalid.")
        }
        return value
    }

    static func parsedDate(_ statement: OpaquePointer, _ column: Int32) throws -> Date {
        try DatabaseTimestamp.date(from: SQLiteSupport.text(statement, column))
    }

    static func optionalDate(_ statement: OpaquePointer, _ column: Int32) throws -> Date? {
        try SQLiteSupport.text(statement, column).map { try DatabaseTimestamp.date(from: $0) }
    }

    static func course(_ statement: OpaquePointer) throws -> Course {
        guard let name = SQLiteSupport.text(statement, 2),
              let normalized = SQLiteSupport.text(statement, 3) else {
            throw OrganizationRepositoryError.corruptData("Course has missing required fields.")
        }
        return Course(
            id: sqlite3_column_int64(statement, 0),
            uuid: try parsedUUID(statement, 1),
            name: name,
            normalizedName: normalized,
            colorHex: SQLiteSupport.text(statement, 4),
            teacher: SQLiteSupport.text(statement, 5),
            semester: SQLiteSupport.text(statement, 6),
            isArchived: sqlite3_column_int(statement, 7) == 1,
            createdAt: try parsedDate(statement, 8),
            updatedAt: try parsedDate(statement, 9),
            deletedAt: try optionalDate(statement, 10)
        )
    }

    static func project(_ statement: OpaquePointer) throws -> AssignmentProject {
        guard let name = SQLiteSupport.text(statement, 3),
              let statusText = SQLiteSupport.text(statement, 5),
              let status = ProjectStatus(rawValue: statusText) else {
            throw OrganizationRepositoryError.corruptData("Project has invalid required fields.")
        }
        return AssignmentProject(
            id: sqlite3_column_int64(statement, 0),
            uuid: try parsedUUID(statement, 1),
            courseID: SQLiteSupport.int64(statement, 2),
            name: name,
            projectDescription: SQLiteSupport.text(statement, 4),
            status: status,
            createdAt: try parsedDate(statement, 6),
            updatedAt: try parsedDate(statement, 7),
            deletedAt: try optionalDate(statement, 8)
        )
    }

    static func tag(_ statement: OpaquePointer) throws -> AssignmentTag {
        guard let name = SQLiteSupport.text(statement, 2),
              let normalized = SQLiteSupport.text(statement, 3) else {
            throw OrganizationRepositoryError.corruptData("Tag has missing required fields.")
        }
        return AssignmentTag(
            id: sqlite3_column_int64(statement, 0),
            uuid: try parsedUUID(statement, 1),
            name: name,
            normalizedName: normalized,
            colorHex: SQLiteSupport.text(statement, 4),
            createdAt: try parsedDate(statement, 5),
            updatedAt: try parsedDate(statement, 6),
            deletedAt: try optionalDate(statement, 7)
        )
    }

    static func tagLink(_ statement: OpaquePointer) throws -> TaskTagLink {
        TaskTagLink(
            id: sqlite3_column_int64(statement, 0),
            uuid: try parsedUUID(statement, 1),
            assignmentID: sqlite3_column_int64(statement, 2),
            tagID: sqlite3_column_int64(statement, 3),
            createdAt: try parsedDate(statement, 4),
            updatedAt: try parsedDate(statement, 5),
            deletedAt: try optionalDate(statement, 6)
        )
    }

    static func subtask(_ statement: OpaquePointer) throws -> AssignmentSubtask {
        guard let title = SQLiteSupport.text(statement, 3),
              let statusText = SQLiteSupport.text(statement, 4),
              let sortOrder = Int(exactly: sqlite3_column_int64(statement, 5)) else {
            throw OrganizationRepositoryError.corruptData("Subtask has missing required fields.")
        }
        return AssignmentSubtask(
            id: sqlite3_column_int64(statement, 0),
            uuid: try parsedUUID(statement, 1),
            assignmentID: sqlite3_column_int64(statement, 2),
            title: title,
            status: try AssignmentStatus(storageValue: statusText),
            sortOrder: sortOrder,
            completedAt: try optionalDate(statement, 6),
            createdAt: try parsedDate(statement, 7),
            updatedAt: try parsedDate(statement, 8),
            deletedAt: try optionalDate(statement, 9)
        )
    }

    static func attachment(_ statement: OpaquePointer) throws -> AttachmentMetadata {
        guard let fileName = SQLiteSupport.text(statement, 3),
              let path = SQLiteSupport.text(statement, 4),
              let sha256 = SQLiteSupport.text(statement, 7) else {
            throw OrganizationRepositoryError.corruptData("Attachment has missing metadata.")
        }
        return AttachmentMetadata(
            id: sqlite3_column_int64(statement, 0),
            uuid: try parsedUUID(statement, 1),
            assignmentID: sqlite3_column_int64(statement, 2),
            fileName: fileName,
            relativePath: path,
            mimeType: SQLiteSupport.text(statement, 5),
            byteSize: sqlite3_column_int64(statement, 6),
            sha256: sha256,
            createdAt: try parsedDate(statement, 8),
            updatedAt: try parsedDate(statement, 9),
            deletedAt: try optionalDate(statement, 10)
        )
    }

    static func reminder(_ statement: OpaquePointer) throws -> TaskReminder {
        guard let leadMinutes = Int(exactly: sqlite3_column_int64(statement, 4)) else {
            throw OrganizationRepositoryError.corruptData(
                "Reminder lead_minutes cannot be represented on this platform."
            )
        }
        return TaskReminder(
            id: sqlite3_column_int64(statement, 0),
            uuid: try parsedUUID(statement, 1),
            assignmentID: sqlite3_column_int64(statement, 2),
            triggerAtUTC: try parsedDate(statement, 3),
            leadMinutes: leadMinutes,
            repeatRule: SQLiteSupport.text(statement, 5),
            isEnabled: sqlite3_column_int(statement, 6) == 1,
            lastScheduledAt: try optionalDate(statement, 7),
            createdAt: try parsedDate(statement, 8),
            updatedAt: try parsedDate(statement, 9),
            deletedAt: try optionalDate(statement, 10)
        )
    }
}


// MARK: - Single-row queries

private extension SQLiteOrganizationRepository {
    static func fetchCourse(id: Int64, on database: OpaquePointer) throws -> Course {
        let values = try readCourses(
            sql: """
            SELECT id, uuid, name, normalized_name, color_hex, teacher, semester,
                   is_archived, created_at, updated_at, deleted_at
            FROM courses WHERE id = ? AND deleted_at IS NULL
            """,
            id: id,
            on: database
        )
        guard let value = values.first else {
            throw OrganizationRepositoryError.notFound("Course", id)
        }
        return value
    }

    static func readCourses(
        sql: String,
        id: Int64? = nil,
        on database: OpaquePointer
    ) throws -> [Course] {
        let statement = try SQLiteSupport.prepare(sql, on: database)
        defer { sqlite3_finalize(statement) }
        if let id { sqlite3_bind_int64(statement, 1, id) }
        return try collect(statement, on: database, mapper: course)
    }

    static func fetchProject(id: Int64, on database: OpaquePointer) throws -> AssignmentProject {
        let statement = try SQLiteSupport.prepare(
            """
            SELECT id, uuid, course_id, name, description, status,
                   created_at, updated_at, deleted_at
            FROM projects WHERE id = ? AND deleted_at IS NULL
            """,
            on: database
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw OrganizationRepositoryError.notFound("Project", id)
        }
        return try project(statement)
    }

    static func fetchTag(id: Int64, on database: OpaquePointer) throws -> AssignmentTag {
        let statement = try SQLiteSupport.prepare(
            """
            SELECT id, uuid, name, normalized_name, color_hex,
                   created_at, updated_at, deleted_at
            FROM tags WHERE id = ? AND deleted_at IS NULL
            """,
            on: database
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw OrganizationRepositoryError.notFound("Tag", id)
        }
        return try tag(statement)
    }

    static func fetchTaskTagLink(id: Int64, on database: OpaquePointer) throws -> TaskTagLink {
        let statement = try SQLiteSupport.prepare(
            """
            SELECT id, uuid, assignment_id, tag_id, created_at, updated_at, deleted_at
            FROM task_tags WHERE id = ? AND deleted_at IS NULL
            """,
            on: database
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw OrganizationRepositoryError.notFound("Task tag", id)
        }
        return try tagLink(statement)
    }

    static func fetchTagLink(
        assignmentID: Int64,
        tagID: Int64,
        deleted: Bool,
        on database: OpaquePointer
    ) throws -> TaskTagLink? {
        let deletedPredicate = deleted ? "deleted_at IS NOT NULL" : "deleted_at IS NULL"
        let statement = try SQLiteSupport.prepare(
            """
            SELECT id, uuid, assignment_id, tag_id, created_at, updated_at, deleted_at
            FROM task_tags
            WHERE assignment_id = ? AND tag_id = ? AND \(deletedPredicate)
            ORDER BY id DESC LIMIT 1
            """,
            on: database
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, assignmentID)
        sqlite3_bind_int64(statement, 2, tagID)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else {
            throw AssignmentRepositoryError.execute(String(cString: sqlite3_errmsg(database)))
        }
        return try tagLink(statement)
    }

    static func fetchSubtask(id: Int64, on database: OpaquePointer) throws -> AssignmentSubtask {
        let statement = try SQLiteSupport.prepare(
            """
            SELECT id, uuid, assignment_id, title, status, sort_order, completed_at,
                   created_at, updated_at, deleted_at
            FROM subtasks WHERE id = ? AND deleted_at IS NULL
            """,
            on: database
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw OrganizationRepositoryError.notFound("Subtask", id)
        }
        return try subtask(statement)
    }

    static func fetchAttachment(id: Int64, on database: OpaquePointer) throws -> AttachmentMetadata {
        let statement = try SQLiteSupport.prepare(
            """
            SELECT id, uuid, assignment_id, file_name, relative_path, mime_type,
                   byte_size, sha256, created_at, updated_at, deleted_at
            FROM attachments WHERE id = ? AND deleted_at IS NULL
            """,
            on: database
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw OrganizationRepositoryError.notFound("Attachment", id)
        }
        return try attachment(statement)
    }

    static func fetchReminder(id: Int64, on database: OpaquePointer) throws -> TaskReminder {
        let statement = try SQLiteSupport.prepare(
            """
            SELECT id, uuid, assignment_id, trigger_at_utc, lead_minutes,
                   repeat_rule, is_enabled, last_scheduled_at,
                   created_at, updated_at, deleted_at
            FROM reminders WHERE id = ? AND deleted_at IS NULL
            """,
            on: database
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw OrganizationRepositoryError.notFound("Reminder", id)
        }
        return try reminder(statement)
    }

    static func activeRowExists(
        table: String,
        id: Int64,
        on database: OpaquePointer
    ) throws -> Bool {
        let statement = try SQLiteSupport.prepare(
            """
            SELECT 1 FROM \(SQLiteSupport.quoteIdentifier(table))
            WHERE id = ? AND deleted_at IS NULL LIMIT 1
            """,
            on: database
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    static func requireActiveAssignment(_ id: Int64, on database: OpaquePointer) throws {
        guard try TaskProgressPersistence.activeAssignmentExists(id, on: database) else {
            throw OrganizationRepositoryError.validation(
                "Child records require an active parent task."
            )
        }
    }

    static func softDeleteRow(
        table: String,
        id: Int64,
        timestamp: String,
        on database: OpaquePointer
    ) throws {
        let statement = try SQLiteSupport.prepare(
            """
            UPDATE \(SQLiteSupport.quoteIdentifier(table))
            SET deleted_at = ?, updated_at = ?
            WHERE id = ? AND deleted_at IS NULL
            """,
            on: database
        )
        defer { sqlite3_finalize(statement) }
        SQLiteSupport.bind(timestamp, to: statement, index: 1)
        SQLiteSupport.bind(timestamp, to: statement, index: 2)
        sqlite3_bind_int64(statement, 3, id)
        try SQLiteSupport.checkDone(statement, on: database)
    }

    static func restoreRow(
        table: String,
        entity: String,
        id: Int64,
        on database: OpaquePointer
    ) throws {
        let exists = try SQLiteSupport.prepare(
            "SELECT 1 FROM \(SQLiteSupport.quoteIdentifier(table)) WHERE id = ? LIMIT 1",
            on: database
        )
        sqlite3_bind_int64(exists, 1, id)
        let result = sqlite3_step(exists)
        sqlite3_finalize(exists)
        guard result == SQLITE_ROW else {
            if result == SQLITE_DONE {
                throw OrganizationRepositoryError.notFound(entity, id)
            }
            throw AssignmentRepositoryError.execute(String(cString: sqlite3_errmsg(database)))
        }

        let statement = try SQLiteSupport.prepare(
            """
            UPDATE \(SQLiteSupport.quoteIdentifier(table))
            SET deleted_at = NULL, updated_at = ? WHERE id = ?
            """,
            on: database
        )
        defer { sqlite3_finalize(statement) }
        SQLiteSupport.bind(DatabaseTimestamp.string(from: Date()), to: statement, index: 1)
        sqlite3_bind_int64(statement, 2, id)
        try SQLiteSupport.checkDone(statement, on: database)
    }

    static func projectCourseIDIncludingDeleted(
        id: Int64,
        on database: OpaquePointer
    ) throws -> Int64? {
        let statement = try SQLiteSupport.prepare(
            "SELECT course_id FROM projects WHERE id = ?",
            on: database
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            if result == SQLITE_DONE {
                throw OrganizationRepositoryError.notFound("Project", id)
            }
            throw AssignmentRepositoryError.execute(String(cString: sqlite3_errmsg(database)))
        }
        return SQLiteSupport.int64(statement, 0)
    }

    static func validateProjectCourse(
        _ courseID: Int64?,
        projectID: Int64?,
        on database: OpaquePointer
    ) throws {
        if let courseID,
           !(try activeRowExists(table: "courses", id: courseID, on: database)) {
            throw OrganizationRepositoryError.validation(
                "A project can only reference an active course."
            )
        }
        guard let projectID, let courseID else { return }
        let statement = try SQLiteSupport.prepare(
            """
            SELECT COUNT(*) FROM assignments
            WHERE project_id = ? AND (course_id IS NULL OR course_id != ?)
            """,
            on: database
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, projectID)
        sqlite3_bind_int64(statement, 2, courseID)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw AssignmentRepositoryError.execute(String(cString: sqlite3_errmsg(database)))
        }
        guard sqlite3_column_int64(statement, 0) == 0 else {
            throw OrganizationRepositoryError.validation(
                "Changing the project course would conflict with linked tasks."
            )
        }
    }

    static func subtaskAssignmentID(
        id: Int64,
        requireDeleted: Bool?,
        on database: OpaquePointer
    ) throws -> Int64 {
        let predicate: String
        switch requireDeleted {
        case true:
            predicate = "AND deleted_at IS NOT NULL"
        case false:
            predicate = "AND deleted_at IS NULL"
        case nil:
            predicate = ""
        }
        let statement = try SQLiteSupport.prepare(
            "SELECT assignment_id FROM subtasks WHERE id = ? \(predicate)",
            on: database
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            if result == SQLITE_DONE {
                throw OrganizationRepositoryError.notFound("Subtask", id)
            }
            throw AssignmentRepositoryError.execute(String(cString: sqlite3_errmsg(database)))
        }
        return sqlite3_column_int64(statement, 0)
    }
}


// MARK: - Input validation

private extension SQLiteOrganizationRepository {
    static func validatedCourseDraft(_ draft: CourseDraft) throws -> CourseDraft {
        var value = draft
        value.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.colorHex = try validatedColor(draft.colorHex)
        value.teacher = normalizedOptional(draft.teacher)
        value.semester = normalizedOptional(draft.semester)
        guard !value.name.isEmpty, value.name.count <= 120 else {
            throw OrganizationRepositoryError.validation(
                "Course name must contain 1 to 120 characters."
            )
        }
        return value
    }

    static func validatedProjectDraft(_ draft: ProjectDraft) throws -> ProjectDraft {
        var value = draft
        value.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.projectDescription = normalizedOptional(draft.projectDescription)
        guard !value.name.isEmpty, value.name.count <= 255 else {
            throw OrganizationRepositoryError.validation(
                "Project name must contain 1 to 255 characters."
            )
        }
        return value
    }

    static func validatedTagDraft(_ draft: TagDraft) throws -> TagDraft {
        var value = draft
        value.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.colorHex = try validatedColor(draft.colorHex)
        guard !value.name.isEmpty, value.name.count <= 80 else {
            throw OrganizationRepositoryError.validation(
                "Tag name must contain 1 to 80 characters."
            )
        }
        return value
    }

    static func validatedSubtaskDraft(_ draft: SubtaskDraft) throws -> SubtaskDraft {
        var value = draft
        value.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.title.isEmpty, value.title.count <= 255 else {
            throw OrganizationRepositoryError.validation(
                "Subtask title must contain 1 to 255 characters."
            )
        }
        guard value.assignmentID > 0, value.sortOrder >= 0 else {
            throw OrganizationRepositoryError.validation(
                "Subtask assignment and sort order are invalid."
            )
        }
        return value
    }

    static func validatedAttachmentDraft(
        _ draft: AttachmentMetadataDraft
    ) throws -> AttachmentMetadataDraft {
        var value = draft
        value.fileName = draft.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        value.mimeType = normalizedOptional(draft.mimeType)
        value.sha256 = draft.sha256.lowercased()
        guard value.assignmentID > 0,
              value.uuid.versionNumber == 4,
              !value.fileName.isEmpty,
              value.fileName.count <= 255,
              value.fileName != ".",
              value.fileName != "..",
              !value.fileName.contains("/"),
              !value.fileName.contains("\\"),
              !value.fileName.contains("\0") else {
            throw OrganizationRepositoryError.validation("Attachment file name is unsafe.")
        }
        guard value.byteSize >= 0 else {
            throw OrganizationRepositoryError.validation("Attachment byte size cannot be negative.")
        }
        guard value.sha256.range(
            of: "^[0-9a-f]{64}$",
            options: .regularExpression
        ) != nil else {
            throw OrganizationRepositoryError.validation(
                "Attachment SHA-256 must be 64 lowercase hexadecimal characters."
            )
        }
        return value
    }

    static func validatedReminderDraft(_ draft: ReminderDraft) throws -> ReminderDraft {
        var value = draft
        value.repeatRule = try validatedRepeatRule(draft.repeatRule)
        guard value.assignmentID > 0, value.leadMinutes >= 0 else {
            throw OrganizationRepositoryError.validation(
                "Reminder assignment and lead time are invalid."
            )
        }
        return value
    }

    static func validatedRepeatRule(_ input: String?) throws -> String? {
        guard let cleaned = normalizedOptional(input) else { return nil }
        guard !cleaned.contains("\n"),
              !cleaned.contains("\r"),
              !cleaned.uppercased().contains("DTSTART"),
              !cleaned.contains(where: \.isWhitespace) else {
            throw OrganizationRepositoryError.validation(
                "repeat_rule must be one RRULE without whitespace or DTSTART."
            )
        }

        let allowedKeys = Set([
            "FREQ", "INTERVAL", "COUNT", "UNTIL", "BYDAY", "BYMONTHDAY", "BYMONTH",
        ])
        var parsed: [String: String] = [:]
        var ordered: [(String, String)] = []
        for component in cleaned.split(separator: ";", omittingEmptySubsequences: false) {
            let parts = component.split(separator: "=", omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                throw OrganizationRepositoryError.validation(
                    "repeat_rule components must use KEY=VALUE syntax."
                )
            }
            let key = String(parts[0]).uppercased()
            let value = String(parts[1]).uppercased()
            guard allowedKeys.contains(key), parsed[key] == nil, !value.isEmpty else {
                throw OrganizationRepositoryError.validation(
                    "repeat_rule contains an unsupported, duplicate, or empty component."
                )
            }
            parsed[key] = value
            ordered.append((key, value))
        }

        guard ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"]
            .contains(parsed["FREQ"] ?? "") else {
            throw OrganizationRepositoryError.validation(
                "repeat_rule requires DAILY, WEEKLY, MONTHLY, or YEARLY FREQ."
            )
        }
        guard parsed["COUNT"] == nil || parsed["UNTIL"] == nil else {
            throw OrganizationRepositoryError.validation(
                "repeat_rule cannot combine COUNT and UNTIL."
            )
        }
        for (key, maximum) in [("INTERVAL", 999), ("COUNT", 9_999)] {
            if let raw = parsed[key] {
                guard raw.allSatisfy(\.isNumber),
                      let number = Int(raw),
                      (1...maximum).contains(number) else {
                    throw OrganizationRepositoryError.validation(
                        "repeat_rule \(key) is outside the allowed range."
                    )
                }
            }
        }
        if let until = parsed["UNTIL"] {
            guard isRealRepeatRuleUntil(until) else {
                throw OrganizationRepositoryError.validation(
                    "repeat_rule UNTIL must be a real YYYYMMDD or UTC timestamp."
                )
            }
        }
        if let byDay = parsed["BYDAY"] {
            let days = byDay.split(separator: ",", omittingEmptySubsequences: false)
                .map(String.init)
            let validDays = Set(["MO", "TU", "WE", "TH", "FR", "SA", "SU"])
            guard days.count == Set(days).count,
                  days.allSatisfy(validDays.contains) else {
                throw OrganizationRepositoryError.validation(
                    "repeat_rule BYDAY contains an unsupported weekday."
                )
            }
        }
        for (key, range) in [
            ("BYMONTHDAY", -31...31),
            ("BYMONTH", 1...12),
        ] {
            if let raw = parsed[key] {
                let components = raw.split(separator: ",", omittingEmptySubsequences: false)
                let pattern = key == "BYMONTHDAY"
                    ? "^-?[0-9]+$"
                    : "^[0-9]+$"
                guard components.allSatisfy({ component in
                    String(component).range(
                        of: pattern,
                        options: .regularExpression
                    ) != nil
                }) else {
                    throw OrganizationRepositoryError.validation(
                        "repeat_rule \(key) must contain ASCII integers."
                    )
                }
                let numbers = components.compactMap { Int($0) }
                guard numbers.count == components.count,
                      numbers.count == Set(numbers).count,
                      numbers.allSatisfy({ $0 != 0 && range.contains($0) }) else {
                    throw OrganizationRepositoryError.validation(
                        "repeat_rule \(key) contains an invalid value."
                    )
                }
            }
        }
        return ordered.map { "\($0.0)=\($0.1)" }.joined(separator: ";")
    }

    static func isRealRepeatRuleUntil(_ value: String) -> Bool {
        let format: String
        switch value.count {
        case 8 where value.range(
            of: "^[0-9]{8}$",
            options: .regularExpression
        ) != nil:
            format = "yyyyMMdd"
        case 16 where value.range(
            of: "^[0-9]{8}T[0-9]{6}Z$",
            options: .regularExpression
        ) != nil:
            format = "yyyyMMdd'T'HHmmss'Z'"
        default:
            return false
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    static func validatedColor(_ value: String?) throws -> String? {
        guard let normalized = normalizedOptional(value) else { return nil }
        guard normalized.range(
            of: "^#[0-9A-Fa-f]{6}$",
            options: .regularExpression
        ) != nil else {
            throw OrganizationRepositoryError.validation(
                "Color must use #RRGGBB hexadecimal syntax."
            )
        }
        return normalized
    }

    static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
