import Foundation
import SQLite3


final class SQLiteAssignmentRepository: AssignmentRepository, @unchecked Sendable {
    static let databaseVersion: Int32 = 3

    #if DEBUG
    /// Unit-test host applications are constructed before XCTest can run a
    /// test-level `setUp`. Keep the host's implicit repository away from every
    /// user database at the earliest possible default-path lookup.
    private static let xctestHostRootURL: URL = {
        URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "assignment-app-xctest-\(ProcessInfo.processInfo.processIdentifier)-"
                    + UUID().uuidString.lowercased(),
                isDirectory: true
            )
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }()

    private static let xctestHostDatabaseURL: URL = {
        let url = xctestHostRootURL
            .appendingPathComponent("assignments.db", isDirectory: false)
        FileHandle.standardError.write(
            Data("assignment_xctest_database_path=\(url.path)\n".utf8)
        )
        return url
    }()
    #endif

    let databaseURL: URL
    let lastMigrationResult: MigrationResult

    private var database: OpaquePointer?
    private let lock = NSLock()

    convenience init(
        databaseURL: URL = SQLiteAssignmentRepository.defaultDatabaseURL()
    ) throws {
        try self.init(databaseURL: databaseURL, migrationFailureInjector: nil)
    }

    /// Internal test seam. Tests may inject an error after schema changes but
    /// before final validation and commit to prove backup restoration.
    init(
        databaseURL: URL,
        migrationFailureInjector: (() throws -> Void)?,
        databaseInstanceUUID: UUID? = nil
    ) throws {
        self.databaseURL = databaseURL.standardizedFileURL
        Self.preconditionSafeTestDatabaseURL(self.databaseURL)
        try FileManager.default.createDirectory(
            at: self.databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        self.lastMigrationResult = try MigrationCoordinator.prepareDatabase(
            at: self.databaseURL,
            migrationFailureInjector: migrationFailureInjector,
            databaseInstanceUUID: databaseInstanceUUID
        )

        let opened = try Self.openConnection(at: self.databaseURL)
        do {
            try Self.execute("PRAGMA busy_timeout = 10000", on: opened)
            try Self.execute("PRAGMA foreign_keys = ON", on: opened)
            try Self.execute("PRAGMA journal_mode = WAL", on: opened)
            try Self.execute("PRAGMA synchronous = NORMAL", on: opened)
        } catch {
            sqlite3_close(opened)
            throw error
        }
        database = opened
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    var schemaVersion: Int32 {
        get throws {
            try lock.withLock {
                try Self.userVersion(on: requireDatabase())
            }
        }
    }

    func fetchAll() throws -> [Assignment] {
        try lock.withLock {
            let database = try requireDatabase()
            let statement = try Self.prepare(
                """
                SELECT id, uuid, course_name, title, due_date, description, link,
                       status, priority, source_name, source_type, source_file,
                       source_url, created_at, updated_at, course_id, project_id,
                       completed_at, progress_percent, all_day, timezone_id, deleted_at
                FROM assignments
                WHERE deleted_at IS NULL
                ORDER BY id ASC
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }

            var assignments: [Assignment] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                assignments.append(try Self.assignment(from: statement))
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else {
                throw AssignmentRepositoryError.execute(Self.message(from: database))
            }
            return assignments
        }
    }

    @discardableResult
    func create(_ draft: AssignmentDraft) throws -> Assignment {
        let draft = try draft.validated()
        return try lock.withLock {
            let database = try requireDatabase()
            try Self.execute("BEGIN IMMEDIATE", on: database)
            do {
                let courseID = try Self.resolveCourseID(
                    named: draft.courseName,
                    preferredID: nil,
                    on: database
                )
                let statement = try Self.prepare(
                    """
                    INSERT INTO assignments (
                        uuid, course_name, title, due_date, description, link, status,
                        priority, source_name, source_type, source_file, source_url,
                        created_at, updated_at, course_id, project_id, completed_at,
                        progress_percent, all_day, timezone_id, deleted_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, 0, NULL, NULL)
                    """,
                    on: database
                )
                defer { sqlite3_finalize(statement) }
                let now = Date()
                let timestamp = DatabaseTimestamp.string(from: now)
                Self.bind(UUID().canonicalString, to: statement, index: 1)
                Self.bind(draft.courseName, to: statement, index: 2)
                Self.bind(draft.title, to: statement, index: 3)
                Self.bind(
                    draft.dueDate.map { LocalWallTime.string(from: $0) },
                    to: statement,
                    index: 4
                )
                Self.bind(draft.assignmentDescription.nilIfEmpty, to: statement, index: 5)
                Self.bind(draft.link.nilIfEmpty, to: statement, index: 6)
                Self.bind(draft.status.storageValue, to: statement, index: 7)
                Self.bind(draft.priority.rawValue, to: statement, index: 8)
                Self.bind(draft.sourceName.nilIfEmpty, to: statement, index: 9)
                Self.bind(draft.sourceType.nilIfEmpty, to: statement, index: 10)
                Self.bind(draft.sourceFile.nilIfEmpty, to: statement, index: 11)
                Self.bind(draft.sourceURL.nilIfEmpty, to: statement, index: 12)
                Self.bind(timestamp, to: statement, index: 13)
                Self.bind(timestamp, to: statement, index: 14)
                sqlite3_bind_int64(statement, 15, courseID)
                Self.bind(draft.status == .done ? timestamp : nil, to: statement, index: 16)
                sqlite3_bind_int(statement, 17, draft.status == .done ? 100 : 0)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw AssignmentRepositoryError.execute(Self.message(from: database))
                }
                let id = sqlite3_last_insert_rowid(database)
                let created = try Self.fetch(id: id, on: database)
                try Self.execute("COMMIT", on: database)
                return created
            } catch {
                try? Self.execute("ROLLBACK", on: database)
                throw error
            }
        }
    }

    @discardableResult
    func update(_ assignment: Assignment) throws -> Assignment {
        let draft = try AssignmentDraft(assignment: assignment).validated()
        return try lock.withLock {
            let database = try requireDatabase()
            guard !assignment.allDay || draft.dueDate != nil else {
                throw AssignmentRepositoryError.corruptData(
                    "An all-day task must have a due date."
                )
            }
            try Self.execute("BEGIN IMMEDIATE", on: database)
            do {
                let current = try Self.fetch(id: assignment.id, on: database)
                let effectiveTimeZone = try Self.validatedTimeZone(
                    identifier: assignment.timeZoneIdentifier
                )
                let courseID = try Self.resolveCourseID(
                    named: draft.courseName,
                    preferredID: assignment.courseID,
                    on: database
                )
                try Self.validateProject(
                    assignment.projectID,
                    courseID: courseID,
                    on: database
                )
                let timestamp = DatabaseTimestamp.string(from: Date())
                let childCount = try TaskProgressPersistence.activeSubtaskCount(
                    assignmentID: assignment.id,
                    on: database
                )
                let finalState: TaskProgressPersistence.ParentState
                if childCount > 0 {
                    if assignment.status != current.status {
                        finalState = try TaskProgressPersistence.applyParentStatusCommand(
                            assignmentID: assignment.id,
                            status: assignment.status,
                            timestamp: timestamp,
                            on: database
                        )
                    } else {
                        guard let derived = try TaskProgressPersistence.derivedState(
                            assignmentID: assignment.id,
                            on: database,
                            completionTimestamp: timestamp
                        ) else {
                            throw AssignmentRepositoryError.corruptData(
                                "Active subtasks disappeared during task update."
                            )
                        }
                        guard assignment.progressPercent == derived.progressPercent else {
                            throw AssignmentRepositoryError.validation(
                                "Task progress is derived from active subtasks and cannot conflict."
                            )
                        }
                        finalState = derived
                    }
                } else {
                    finalState = try Self.independentParentState(
                        requested: assignment,
                        current: current,
                        timestamp: timestamp
                    )
                }
                let statement = try Self.prepare(
                    """
                    UPDATE assignments
                    SET course_name = ?, title = ?, due_date = ?, description = ?,
                        link = ?, status = ?, priority = ?, source_name = ?,
                        source_type = ?, source_file = ?, source_url = ?, updated_at = ?,
                        course_id = ?, project_id = ?, completed_at = ?,
                        progress_percent = ?, all_day = ?, timezone_id = ?
                    WHERE id = ? AND deleted_at IS NULL
                    """,
                    on: database
                )
                defer { sqlite3_finalize(statement) }
                Self.bind(draft.courseName, to: statement, index: 1)
                Self.bind(draft.title, to: statement, index: 2)
                Self.bind(
                    try Self.storedDueDateText(
                        date: draft.dueDate,
                        originalText: assignment.storedDueDateText,
                        timeZone: effectiveTimeZone
                    ),
                    to: statement,
                    index: 3
                )
                Self.bind(draft.assignmentDescription.nilIfEmpty, to: statement, index: 4)
                Self.bind(draft.link.nilIfEmpty, to: statement, index: 5)
                Self.bind(finalState.status.storageValue, to: statement, index: 6)
                Self.bind(draft.priority.rawValue, to: statement, index: 7)
                Self.bind(draft.sourceName.nilIfEmpty, to: statement, index: 8)
                Self.bind(draft.sourceType.nilIfEmpty, to: statement, index: 9)
                Self.bind(draft.sourceFile.nilIfEmpty, to: statement, index: 10)
                Self.bind(draft.sourceURL.nilIfEmpty, to: statement, index: 11)
                Self.bind(timestamp, to: statement, index: 12)
                sqlite3_bind_int64(statement, 13, courseID)
                if let projectID = assignment.projectID {
                    sqlite3_bind_int64(statement, 14, projectID)
                } else {
                    sqlite3_bind_null(statement, 14)
                }
                Self.bind(finalState.completedAt, to: statement, index: 15)
                sqlite3_bind_int(statement, 16, Int32(finalState.progressPercent))
                sqlite3_bind_int(statement, 17, assignment.allDay ? 1 : 0)
                Self.bind(assignment.timeZoneIdentifier, to: statement, index: 18)
                sqlite3_bind_int64(statement, 19, assignment.id)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw AssignmentRepositoryError.execute(Self.message(from: database))
                }
                guard sqlite3_changes(database) == 1 else {
                    throw AssignmentRepositoryError.notFound(assignment.id)
                }
                let updated = try Self.fetch(id: assignment.id, on: database)
                try Self.execute("COMMIT", on: database)
                return updated
            } catch {
                try? Self.execute("ROLLBACK", on: database)
                throw error
            }
        }
    }

    func delete(id: Int64) throws {
        try lock.withLock {
            let database = try requireDatabase()
            try Self.execute("BEGIN IMMEDIATE", on: database)
            do {
                let timestamp = DatabaseTimestamp.string(from: Date())
                let statement = try Self.prepare(
                    """
                    UPDATE assignments
                    SET deleted_at = ?, updated_at = ?
                    WHERE id = ? AND deleted_at IS NULL
                    """,
                    on: database
                )
                Self.bind(timestamp, to: statement, index: 1)
                Self.bind(timestamp, to: statement, index: 2)
                sqlite3_bind_int64(statement, 3, id)
                do { try SQLiteSupport.checkDone(statement, on: database) }
                catch { sqlite3_finalize(statement); throw error }
                sqlite3_finalize(statement)
                guard sqlite3_changes(database) == 1 else {
                    throw AssignmentRepositoryError.notFound(id)
                }

                let reminders = try Self.prepare(
                    """
                    UPDATE reminders SET is_enabled = 0, updated_at = ?
                    WHERE assignment_id = ? AND deleted_at IS NULL
                    """,
                    on: database
                )
                Self.bind(timestamp, to: reminders, index: 1)
                sqlite3_bind_int64(reminders, 2, id)
                do { try SQLiteSupport.checkDone(reminders, on: database) }
                catch { sqlite3_finalize(reminders); throw error }
                sqlite3_finalize(reminders)
                try Self.execute("COMMIT", on: database)
            } catch {
                try? Self.execute("ROLLBACK", on: database)
                throw error
            }
        }
    }

    @discardableResult
    func restore(id: Int64) throws -> Assignment {
        try lock.withLock {
            let database = try requireDatabase()
            try Self.execute("BEGIN IMMEDIATE", on: database)
            do {
                guard try Self.assignmentExists(id: id, on: database) else {
                    throw AssignmentRepositoryError.notFound(id)
                }
                let timestamp = DatabaseTimestamp.string(from: Date())
                let statement = try Self.prepare(
                    "UPDATE assignments SET deleted_at = NULL, updated_at = ? WHERE id = ?",
                    on: database
                )
                Self.bind(timestamp, to: statement, index: 1)
                sqlite3_bind_int64(statement, 2, id)
                do { try SQLiteSupport.checkDone(statement, on: database) }
                catch { sqlite3_finalize(statement); throw error }
                sqlite3_finalize(statement)
                _ = try TaskProgressPersistence.recalculateParent(
                    assignmentID: id,
                    resetWhenEmpty: false,
                    timestamp: timestamp,
                    on: database
                )
                let restored = try Self.fetch(id: id, on: database)
                try Self.execute("COMMIT", on: database)
                return restored
            } catch {
                try? Self.execute("ROLLBACK", on: database)
                throw error
            }
        }
    }

    @discardableResult
    func updateStatus(
        id: Int64,
        status: AssignmentStatus
    ) throws -> Assignment {
        try lock.withLock {
            let database = try requireDatabase()
            try Self.execute("BEGIN IMMEDIATE", on: database)
            do {
                let timestamp = DatabaseTimestamp.string(from: Date())
                _ = try TaskProgressPersistence.applyParentStatusCommand(
                    assignmentID: id,
                    status: status,
                    timestamp: timestamp,
                    on: database
                )
                let updated = try Self.fetch(id: id, on: database)
                try Self.execute("COMMIT", on: database)
                return updated
            } catch {
                try? Self.execute("ROLLBACK", on: database)
                throw error
            }
        }
    }

    static func defaultDatabaseURL() -> URL {
        #if DEBUG
        // XCTest host initialization can occur before test setUp. Ignore every
        // caller-supplied environment override in a test process and use a
        // unique process-owned /private/tmp directory instead.
        if isRunningUnderXCTest {
            preconditionSafeTestDatabaseURL(xctestHostDatabaseURL)
            return xctestHostDatabaseURL
        }
        if let override = ProcessInfo.processInfo.environment["ASSIGNMENT_DB_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let overrideURL = URL(fileURLWithPath: override).standardizedFileURL
            preconditionSafeTestDatabaseURL(overrideURL)
            return overrideURL
        }
        #endif

        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("AssignmentApp2", isDirectory: true)
            .appendingPathComponent("assignments.db", isDirectory: false)
    }

    static func preconditionSafeTestDatabaseURL(_ url: URL) {
        #if DEBUG
        guard isRunningUnderXCTest else { return }
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
        let roots = [
            xctestHostRootURL,
            URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath(),
            FileManager.default.temporaryDirectory
                .standardizedFileURL.resolvingSymlinksInPath(),
        ]
        let path = candidate.path
        let isInsideDisposableRoot = roots.contains { root in
            let rootPath = root.path
            return path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
        }
        precondition(
            candidate.isFileURL && isInsideDisposableRoot,
            "XCTest database paths must resolve inside the process test root or /private/tmp: "
                + path
        )
        #endif
    }

    #if DEBUG
    private static var isRunningUnderXCTest: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCInjectBundleInto"] != nil {
            return true
        }
        if environment["DYLD_INSERT_LIBRARIES"]?
            .localizedCaseInsensitiveContains("xctest") == true {
            return true
        }
        return NSClassFromString("XCTestCase") != nil
    }
    #endif

    private func requireDatabase() throws -> OpaquePointer {
        guard let database else {
            throw AssignmentRepositoryError.readOnlyAfterMigrationFailure
        }
        return database
    }
}


// MARK: - Row mapping

private extension SQLiteAssignmentRepository {
    static func validatedTimeZone(identifier: String?) throws -> TimeZone {
        guard let identifier else { return .current }
        guard !identifier.isEmpty, let timeZone = TimeZone(identifier: identifier) else {
            throw AssignmentRepositoryError.validation(
                "Task timezone_id must be a valid IANA timezone identifier."
            )
        }
        return timeZone
    }

    static func storedDueDateText(
        date: Date?,
        originalText: String?,
        timeZone: TimeZone
    ) throws -> String? {
        guard let date else { return nil }
        if let originalText,
           let originalDate = try? LocalWallTime.legacyDate(
               from: originalText,
               timeZone: timeZone
           ),
           originalDate == date {
            return originalText
        }
        return LocalWallTime.string(from: date, timeZone: timeZone)
    }

    static func independentParentState(
        requested: Assignment,
        current: Assignment,
        timestamp: String
    ) throws -> TaskProgressPersistence.ParentState {
        guard (0...100).contains(requested.progressPercent) else {
            throw AssignmentRepositoryError.validation(
                "Task progress must be between 0 and 100."
            )
        }

        let status: AssignmentStatus
        let progress: Int
        if requested.status != current.status {
            status = requested.status
            switch status {
            case .done:
                progress = 100
            case .todo:
                progress = 0
            case .inProgress:
                progress = requested.progressPercent == 100
                    ? 0
                    : requested.progressPercent
            }
        } else if requested.progressPercent != current.progressPercent {
            progress = requested.progressPercent
            status = progress == 100 ? .done : (progress == 0 ? .todo : .inProgress)
        } else {
            status = current.status
            progress = current.progressPercent
        }
        let completedAt = status == .done
            ? DatabaseTimestamp.string(
                from: requested.completedAt ?? current.completedAt ?? Date()
            )
            : nil
        return .init(
            status: status,
            progressPercent: progress,
            completedAt: status == .done ? (completedAt ?? timestamp) : nil
        )
    }

    static func validateProject(
        _ projectID: Int64?,
        courseID: Int64,
        on database: OpaquePointer
    ) throws {
        guard let projectID else { return }
        let statement = try prepare(
            "SELECT course_id FROM projects WHERE id = ? AND deleted_at IS NULL",
            on: database
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, projectID)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            if result == SQLITE_DONE {
                throw AssignmentRepositoryError.validation(
                    "A task can only reference an active project."
                )
            }
            throw AssignmentRepositoryError.execute(message(from: database))
        }
        if let projectCourseID = SQLiteSupport.int64(statement, 0),
           projectCourseID != courseID {
            throw AssignmentRepositoryError.validation(
                "Task and project must reference the same course."
            )
        }
    }

    static func assignmentExists(id: Int64, on database: OpaquePointer) throws -> Bool {
        let statement = try prepare(
            "SELECT 1 FROM assignments WHERE id = ? LIMIT 1",
            on: database
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else {
            throw AssignmentRepositoryError.execute(message(from: database))
        }
        return result == SQLITE_ROW
    }

    static func assignment(from statement: OpaquePointer) throws -> Assignment {
        guard let uuidText = text(statement, 1),
              let uuid = UUID(uuidString: uuidText),
              uuid.canonicalString == uuidText,
              let courseName = text(statement, 2),
              let title = text(statement, 3),
              let storedStatus = text(statement, 7),
              let storedPriority = text(statement, 8) else {
            throw AssignmentRepositoryError.corruptData(
                "A required task field is NULL."
            )
        }

        do {
            let timeZoneIdentifier = text(statement, 20)
            let timeZone = try validatedTimeZone(identifier: timeZoneIdentifier)
            let storedDueDateText = text(statement, 4)
            return Assignment(
                id: sqlite3_column_int64(statement, 0),
                uuid: uuid,
                courseName: courseName,
                title: title,
                dueDate: try storedDueDateText.map {
                    try LocalWallTime.legacyDate(from: $0, timeZone: timeZone)
                },
                assignmentDescription: text(statement, 5),
                link: text(statement, 6),
                status: try AssignmentStatus(storageValue: storedStatus),
                priority: try AssignmentPriority(storageValue: storedPriority),
                sourceName: text(statement, 9),
                sourceType: text(statement, 10),
                sourceFile: text(statement, 11),
                sourceURL: text(statement, 12),
                createdAt: try DatabaseTimestamp.date(from: text(statement, 13)),
                updatedAt: try DatabaseTimestamp.date(from: text(statement, 14)),
                courseID: sqlite3_column_type(statement, 15) == SQLITE_NULL
                    ? nil : sqlite3_column_int64(statement, 15),
                projectID: sqlite3_column_type(statement, 16) == SQLITE_NULL
                    ? nil : sqlite3_column_int64(statement, 16),
                completedAt: try text(statement, 17).map { try DatabaseTimestamp.date(from: $0) },
                progressPercent: Int(sqlite3_column_int(statement, 18)),
                allDay: sqlite3_column_int(statement, 19) == 1,
                timeZoneIdentifier: timeZoneIdentifier,
                deletedAt: try text(statement, 21).map { try DatabaseTimestamp.date(from: $0) },
                storedDueDateText: storedDueDateText
            )
        } catch let error as AssignmentRepositoryError {
            throw error
        } catch {
            throw AssignmentRepositoryError.corruptData(error.localizedDescription)
        }
    }

    static func fetch(id: Int64, on database: OpaquePointer) throws -> Assignment {
        let statement = try prepare(
            """
            SELECT id, uuid, course_name, title, due_date, description, link,
                   status, priority, source_name, source_type, source_file,
                   source_url, created_at, updated_at, course_id, project_id,
                   completed_at, progress_percent, all_day, timezone_id, deleted_at
            FROM assignments
            WHERE id = ? AND deleted_at IS NULL
            """,
            on: database
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            if result == SQLITE_DONE {
                throw AssignmentRepositoryError.notFound(id)
            }
            throw AssignmentRepositoryError.execute(message(from: database))
        }
        return try assignment(from: statement)
    }

    static func resolveCourseID(
        named name: String,
        preferredID: Int64?,
        on database: OpaquePointer
    ) throws -> Int64 {
        if let preferredID {
            let preferred = try prepare(
                "SELECT name FROM courses WHERE id = ? AND deleted_at IS NULL",
                on: database
            )
            sqlite3_bind_int64(preferred, 1, preferredID)
            let matches = sqlite3_step(preferred) == SQLITE_ROW
                && text(preferred, 0) == name
            sqlite3_finalize(preferred)
            if matches { return preferredID }
        }

        let existing = try prepare(
            """
            SELECT id FROM courses
            WHERE name = ? AND deleted_at IS NULL
            ORDER BY id LIMIT 1
            """,
            on: database
        )
        bind(name, to: existing, index: 1)
        if sqlite3_step(existing) == SQLITE_ROW {
            let id = sqlite3_column_int64(existing, 0)
            sqlite3_finalize(existing)
            return id
        }
        sqlite3_finalize(existing)

        let timestamp = DatabaseTimestamp.string(from: Date())
        let normalized = SharedIdentity.canonicalName(name)
        let insert = try prepare(
            """
            INSERT INTO courses (
                uuid, name, normalized_name, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?)
            """,
            on: database
        )
        defer { sqlite3_finalize(insert) }
        bind(UUID().canonicalString, to: insert, index: 1)
        bind(name, to: insert, index: 2)
        bind(normalized, to: insert, index: 3)
        bind(timestamp, to: insert, index: 4)
        bind(timestamp, to: insert, index: 5)
        guard sqlite3_step(insert) == SQLITE_DONE else {
            throw AssignmentRepositoryError.execute(message(from: database))
        }
        return sqlite3_last_insert_rowid(database)
    }
}


// MARK: - Schema creation and migration

private extension SQLiteAssignmentRepository {
    struct DatabaseState {
        let userVersion: Int32
        let hasAssignmentsTable: Bool
    }

    struct ColumnInfo {
        let name: String
        let notNull: Bool
        let defaultValue: String?
        let isPrimaryKey: Bool
    }

    static func prepareDatabase(
        at url: URL,
        migrationFailureInjector: (() throws -> Void)?
    ) throws -> MigrationResult {
        let state = try inspectDatabase(at: url)
        guard state.userVersion <= databaseVersion else {
            throw DatabaseMigrationError(
                "Database schema version \(state.userVersion) is newer than supported "
                    + "version \(databaseVersion)."
            )
        }

        if !state.hasAssignmentsTable {
            try createNewDatabase(at: url)
            return MigrationResult(
                fromVersion: state.userVersion,
                toVersion: databaseVersion,
                migrated: true,
                backupURL: nil,
                strategy: .createV3
            )
        }

        if state.userVersion == databaseVersion {
            let database = try openConnection(at: url)
            defer { sqlite3_close(database) }
            try validateV2Schema(on: database, requireVersion: true)
            return MigrationResult(
                fromVersion: databaseVersion,
                toVersion: databaseVersion,
                migrated: false,
                backupURL: nil,
                strategy: .none
            )
        }

        guard state.userVersion == 0 || state.userVersion == 1 else {
            throw DatabaseMigrationError(
                "Unsupported database schema version \(state.userVersion)."
            )
        }

        let inferredVersion: Int32 = 1
        let backupURL = try backupDatabase(
            at: url,
            fromVersion: inferredVersion
        )

        do {
            let strategy = try upgradeExistingDatabase(
                at: url,
                migrationFailureInjector: migrationFailureInjector
            )
            return MigrationResult(
                fromVersion: inferredVersion,
                toVersion: databaseVersion,
                migrated: true,
                backupURL: backupURL,
                strategy: strategy
            )
        } catch {
            do {
                try restoreDatabase(from: backupURL, to: url)
            } catch let restoreError {
                throw DatabaseMigrationError(
                    "Database migration failed and automatic restoration also failed. "
                        + "The consistent backup is preserved at \(backupURL.path). "
                        + "Restore error: \(restoreError.localizedDescription)",
                    backupURL: backupURL
                )
            }
            throw DatabaseMigrationError(
                "Database migration failed; the original database was restored from "
                    + "\(backupURL.lastPathComponent). Cause: \(error.localizedDescription)",
                backupURL: backupURL
            )
        }
    }

    static func inspectDatabase(at url: URL) throws -> DatabaseState {
        let database = try openConnection(at: url)
        defer { sqlite3_close(database) }
        try execute("PRAGMA busy_timeout = 10000", on: database)
        return DatabaseState(
            userVersion: try userVersion(on: database),
            hasAssignmentsTable: try tableExists("assignments", on: database)
        )
    }

    static func createNewDatabase(at url: URL) throws {
        let database = try openConnection(at: url)
        defer { sqlite3_close(database) }
        try execute("BEGIN IMMEDIATE", on: database)
        do {
            try createAssignmentsTable(on: database)
            try createIndexes(on: database)
            try execute("PRAGMA user_version = \(databaseVersion)", on: database)
            try validateV2Schema(on: database, requireVersion: true)
            try requireIntegrity(on: database)
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    static func upgradeExistingDatabase(
        at url: URL,
        migrationFailureInjector: (() throws -> Void)?
    ) throws -> MigrationStrategy {
        let database = try openConnection(at: url)
        defer { sqlite3_close(database) }
        try execute("PRAGMA foreign_keys = OFF", on: database)
        try execute("BEGIN IMMEDIATE", on: database)
        do {
            guard !(try tableExists("assignments_v1_migration", on: database)) else {
                throw DatabaseMigrationError(
                    "Cannot migrate while assignments_v1_migration already exists."
                )
            }

            let columns = try assignmentColumns(table: "assignments", on: database)
            let required = Set(["id", "course_name", "title"])
            let missingRequired = required.subtracting(columns.keys)
            guard missingRequired.isEmpty else {
                throw DatabaseMigrationError(
                    "Legacy assignments table is missing required columns: "
                        + missingRequired.sorted().joined(separator: ", ")
                )
            }

            try validateLegacyValues(columns: columns, on: database)
            let idsBefore = try assignmentIDs(on: database)

            let strategy: MigrationStrategy
            if try requiresRebuild(columns: columns, on: database) {
                try rebuildAssignments(columns: columns, on: database)
                strategy = .v1RebuildToV3
            } else {
                try addV2Columns(columns: columns, on: database)
                try createIndexes(on: database)
                strategy = .v1AdditiveToV3
            }

            try normalizeLegacyDueDates(on: database)
            let idsAfter = try assignmentIDs(on: database)
            guard idsBefore == idsAfter else {
                throw DatabaseMigrationError(
                    "Assignment identity validation failed during migration."
                )
            }

            try migrationFailureInjector?()
            try validateV2Schema(on: database, requireVersion: false)
            try execute("PRAGMA user_version = \(databaseVersion)", on: database)
            try requireIntegrity(on: database)
            try execute("COMMIT", on: database)

            try validateV2Schema(on: database, requireVersion: true)
            try requireIntegrity(on: database)
            return strategy
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    static func validateLegacyValues(
        columns: [String: ColumnInfo],
        on database: OpaquePointer
    ) throws {
        if columns["status"] != nil,
           let value = try firstText(
                """
                SELECT ifnull(status, '<NULL>')
                FROM assignments
                WHERE status IS NULL
                   OR lower(trim(status)) NOT IN (
                       'not_started', 'todo', 'in_progress', 'completed', 'done'
                   )
                LIMIT 1
                """,
                on: database
           ) {
            throw DatabaseMigrationError(
                "Unsupported assignment status prevents migration: \(value)."
            )
        }

        if columns["priority"] != nil,
           let value = try firstText(
                """
                SELECT priority
                FROM assignments
                WHERE priority IS NOT NULL
                  AND trim(priority) != ''
                  AND lower(trim(priority)) NOT IN ('low', 'medium', 'high')
                LIMIT 1
                """,
                on: database
           ) {
            throw DatabaseMigrationError(
                "Unsupported assignment priority prevents migration: \(value)."
            )
        }
    }

    static func requiresRebuild(
        columns: [String: ColumnInfo],
        on database: OpaquePointer
    ) throws -> Bool {
        guard let id = columns["id"],
              let course = columns["course_name"],
              let title = columns["title"] else {
            return true
        }
        if !id.isPrimaryKey || !course.notNull || !title.notNull {
            return true
        }
        if columns["due_date"]?.notNull == true {
            return true
        }
        guard columns["created_at"]?.notNull == true,
              columns["updated_at"]?.notNull == true else {
            return true
        }

        let tableSQL = try assignmentTableSQL(on: database).lowercased()
        if columns["status"] != nil {
            let hasLegacyConstraint = tableSQL.contains("check")
                && tableSQL.contains("not_started")
                && tableSQL.contains("completed")
            let hasNoncanonicalStatus = try rowExists(
                """
                SELECT 1 FROM assignments
                WHERE status != lower(trim(status))
                   OR status IN ('todo', 'done')
                LIMIT 1
                """,
                on: database
            )
            if !hasLegacyConstraint
                || hasNoncanonicalStatus {
                return true
            }
        }

        if let priority = columns["priority"] {
            let defaultPriority = priority.defaultValue?
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                .lowercased()
            let hasPriorityConstraint = tableSQL.contains("check")
                && tableSQL.contains("'low'")
                && tableSQL.contains("'medium'")
                && tableSQL.contains("'high'")
            let hasNoncanonicalPriority = try rowExists(
                """
                SELECT 1 FROM assignments
                WHERE priority IS NULL
                   OR priority != lower(trim(priority))
                   OR priority NOT IN ('low', 'medium', 'high')
                LIMIT 1
                """,
                on: database
            )
            if !priority.notNull
                || defaultPriority != "medium"
                || !hasPriorityConstraint
                || hasNoncanonicalPriority {
                return true
            }
        }
        return false
    }

    static func addV2Columns(
        columns: [String: ColumnInfo],
        on database: OpaquePointer
    ) throws {
        let additions: [(String, String)] = [
            ("due_date", "DATETIME"),
            ("description", "TEXT"),
            ("link", "VARCHAR(1000)"),
            (
                "status",
                "VARCHAR(20) NOT NULL DEFAULT 'not_started' "
                    + "CHECK (status IN ('not_started', 'in_progress', 'completed'))"
            ),
            (
                "priority",
                "VARCHAR(10) NOT NULL DEFAULT 'medium' "
                    + "CHECK (priority IN ('low', 'medium', 'high'))"
            ),
            ("source_name", "VARCHAR(255)"),
            ("source_type", "VARCHAR(80)"),
            ("source_file", "VARCHAR(1000)"),
            ("source_url", "VARCHAR(1000)"),
        ]
        for (name, definition) in additions where columns[name] == nil {
            try execute(
                "ALTER TABLE assignments ADD COLUMN \(name) \(definition)",
                on: database
            )
        }
    }

    static func rebuildAssignments(
        columns: [String: ColumnInfo],
        on database: OpaquePointer
    ) throws {
        try execute(
            "ALTER TABLE assignments RENAME TO assignments_v1_migration",
            on: database
        )
        try createAssignmentsTable(on: database)

        let targetColumns = [
            "id", "course_name", "title", "due_date", "description", "link",
            "status", "priority", "source_name", "source_type", "source_file",
            "source_url", "created_at", "updated_at",
        ]
        let expressions = targetColumns.map {
            migrationExpression(for: $0, columns: columns)
        }
        try execute(
            """
            INSERT INTO assignments (\(targetColumns.joined(separator: ", ")))
            SELECT \(expressions.joined(separator: ", "))
            FROM assignments_v1_migration
            """,
            on: database
        )
        try execute("DROP TABLE assignments_v1_migration", on: database)
        try createIndexes(on: database)
    }

    static func migrationExpression(
        for column: String,
        columns: [String: ColumnInfo]
    ) -> String {
        if column == "status" {
            guard columns[column] != nil else { return "'not_started' AS status" }
            return """
                CASE lower(trim(status))
                    WHEN 'todo' THEN 'not_started'
                    WHEN 'done' THEN 'completed'
                    ELSE lower(trim(status))
                END AS status
                """
        }
        if column == "priority" {
            guard columns[column] != nil else { return "'medium' AS priority" }
            return """
                CASE
                    WHEN priority IS NULL OR trim(priority) = '' THEN 'medium'
                    ELSE lower(trim(priority))
                END AS priority
                """
        }
        if columns[column] != nil {
            return column
        }
        if column == "created_at" || column == "updated_at" {
            return "CURRENT_TIMESTAMP AS \(column)"
        }
        return "NULL AS \(column)"
    }

    static func normalizeLegacyDueDates(on database: OpaquePointer) throws {
        let query = try prepare(
            "SELECT id, due_date FROM assignments WHERE due_date IS NOT NULL",
            on: database
        )
        defer { sqlite3_finalize(query) }
        var result = sqlite3_step(query)
        while result == SQLITE_ROW {
            guard let stored = text(query, 1) else {
                throw DatabaseMigrationError("A non-null due date could not be read.")
            }
            // Parse only. Legacy wall-time text is user data and must remain
            // byte-for-byte unchanged until the user edits that due date.
            _ = try LocalWallTime.legacyDate(from: stored)
            result = sqlite3_step(query)
        }
        guard result == SQLITE_DONE else {
            throw AssignmentRepositoryError.execute(message(from: database))
        }
    }

    static func createAssignmentsTable(on database: OpaquePointer) throws {
        try execute(
            """
            CREATE TABLE assignments (
                id INTEGER NOT NULL,
                course_name VARCHAR(120) NOT NULL,
                title VARCHAR(255) NOT NULL,
                due_date DATETIME,
                description TEXT,
                link VARCHAR(1000),
                status VARCHAR(20) NOT NULL DEFAULT 'not_started',
                priority VARCHAR(10) NOT NULL DEFAULT 'medium',
                source_name VARCHAR(255),
                source_type VARCHAR(80),
                source_file VARCHAR(1000),
                source_url VARCHAR(1000),
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
                PRIMARY KEY (id),
                CONSTRAINT assignment_status_check
                    CHECK (status IN ('not_started', 'in_progress', 'completed')),
                CONSTRAINT assignment_priority_check
                    CHECK (priority IN ('low', 'medium', 'high'))
            )
            """,
            on: database
        )
    }

    static func createIndexes(on database: OpaquePointer) throws {
        let indexes = [
            "ix_assignments_course_name": "course_name",
            "ix_assignments_due_date": "due_date",
            "ix_assignments_id": "id",
            "ix_assignments_priority": "priority",
            "ix_assignments_status": "status",
            "ix_assignments_title": "title",
        ]
        for (name, column) in indexes {
            try execute(
                "CREATE INDEX IF NOT EXISTS \(name) ON assignments (\(column))",
                on: database
            )
        }
    }

    static func validateV2Schema(
        on database: OpaquePointer,
        requireVersion: Bool
    ) throws {
        if requireVersion, try userVersion(on: database) != databaseVersion {
            throw DatabaseMigrationError(
                "Database v2 must set PRAGMA user_version to \(databaseVersion)."
            )
        }

        let columns = try assignmentColumns(table: "assignments", on: database)
        let expected = Set([
            "id", "course_name", "title", "due_date", "description", "link",
            "status", "priority", "source_name", "source_type", "source_file",
            "source_url", "created_at", "updated_at",
        ])
        let missing = expected.subtracting(columns.keys)
        guard missing.isEmpty else {
            throw DatabaseMigrationError(
                "Database v2 schema is missing columns: "
                    + missing.sorted().joined(separator: ", ")
            )
        }
        guard columns["id"]?.isPrimaryKey == true,
              columns["course_name"]?.notNull == true,
              columns["title"]?.notNull == true else {
            throw DatabaseMigrationError(
                "Database v2 requires a primary-key id and non-null course/title."
            )
        }
        guard columns["due_date"]?.notNull == false else {
            throw DatabaseMigrationError("Database v2 requires a nullable due_date column.")
        }
        guard columns["status"]?.notNull == true else {
            throw DatabaseMigrationError("Database v2 requires a non-null status column.")
        }
        guard columns["priority"]?.notNull == true else {
            throw DatabaseMigrationError("Database v2 requires a non-null priority column.")
        }
        guard columns["created_at"]?.notNull == true,
              columns["updated_at"]?.notNull == true else {
            throw DatabaseMigrationError(
                "Database v2 requires non-null created_at and updated_at columns."
            )
        }

        let statusDefault = columns["status"]?.defaultValue?
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            .lowercased()
        guard statusDefault == "not_started" else {
            throw DatabaseMigrationError(
                "Database v2 requires status to default to not_started."
            )
        }
        let priorityDefault = columns["priority"]?.defaultValue?
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            .lowercased()
        guard priorityDefault == "medium" else {
            throw DatabaseMigrationError(
                "Database v2 requires priority to default to medium."
            )
        }

        let tableSQL = try assignmentTableSQL(on: database).lowercased()
        guard tableSQL.contains("check"),
              tableSQL.contains("not_started"),
              tableSQL.contains("completed") else {
            throw DatabaseMigrationError(
                "Database v2 must retain legacy status storage constraints."
            )
        }
        guard tableSQL.contains("'low'"),
              tableSQL.contains("'medium'"),
              tableSQL.contains("'high'") else {
            throw DatabaseMigrationError(
                "Database v2 must constrain priority to low, medium, and high."
            )
        }

        if try rowExists(
            """
            SELECT 1 FROM assignments
            WHERE status NOT IN ('not_started', 'in_progress', 'completed')
            LIMIT 1
            """,
            on: database
        ) {
            throw DatabaseMigrationError("Database v2 contains an invalid status value.")
        }
        if try rowExists(
            """
            SELECT 1 FROM assignments
            WHERE priority NOT IN ('low', 'medium', 'high')
            LIMIT 1
            """,
            on: database
        ) {
            throw DatabaseMigrationError("Database v2 contains an invalid priority value.")
        }
        try validateDueDates(on: database)
        try validateIndexes(on: database)
    }

    static func validateDueDates(on database: OpaquePointer) throws {
        let statement = try prepare(
            "SELECT due_date FROM assignments WHERE due_date IS NOT NULL",
            on: database
        )
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let value = text(statement, 0) else {
                throw DatabaseMigrationError(
                    "Database v2 contains a due date outside the local-wall-time contract."
                )
            }
            _ = try LocalWallTime.legacyDate(from: value)
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw AssignmentRepositoryError.execute(message(from: database))
        }
    }

    static func validateIndexes(on database: OpaquePointer) throws {
        let expected = [
            "ix_assignments_course_name": "course_name",
            "ix_assignments_due_date": "due_date",
            "ix_assignments_id": "id",
            "ix_assignments_priority": "priority",
            "ix_assignments_status": "status",
            "ix_assignments_title": "title",
        ]
        for (name, expectedColumn) in expected {
            let statement = try prepare("PRAGMA index_info(\(name))", on: database)
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  text(statement, 2) == expectedColumn else {
                throw DatabaseMigrationError(
                    "Database v2 is missing the expected \(name) index."
                )
            }
        }
    }

    static func requireIntegrity(on database: OpaquePointer) throws {
        guard try firstText("PRAGMA integrity_check", on: database) == "ok" else {
            throw DatabaseMigrationError("SQLite integrity_check failed.")
        }
    }
}


// MARK: - SQLite online backup and restore

private extension SQLiteAssignmentRepository {
    static func backupDatabase(
        at url: URL,
        fromVersion: Int32
    ) throws -> URL {
        let timestamp = backupTimestamp()
        let backupURL = url.deletingLastPathComponent().appendingPathComponent(
            "\(url.lastPathComponent).v\(fromVersion)-to-v\(databaseVersion)."
                + "\(timestamp).\(UUID().uuidString.prefix(8)).bak"
        )
        do {
            try copyDatabase(from: url, to: backupURL)
            try makeStandaloneBackup(at: backupURL)
            try removeSQLiteSidecars(for: backupURL)
            let database = try openConnection(at: backupURL, readOnly: true)
            defer { sqlite3_close(database) }
            try requireIntegrity(on: database)
            return backupURL
        } catch {
            try? FileManager.default.removeItem(at: backupURL)
            throw DatabaseMigrationError(
                "Could not create a consistent migration backup: \(error.localizedDescription)"
            )
        }
    }

    /// SQLite's backup API copies the source's persistent WAL journal mode.
    /// Convert the destination to DELETE mode while it is writable so a later
    /// read-only recovery check never needs to create a sibling `-wal` file.
    static func makeStandaloneBackup(at backupURL: URL) throws {
        let database = try openConnection(at: backupURL)
        defer { sqlite3_close(database) }
        guard try firstText("PRAGMA journal_mode = DELETE", on: database)?
            .lowercased() == "delete" else {
            throw DatabaseMigrationError(
                "Could not finalize the migration backup as a standalone database."
            )
        }
        try requireIntegrity(on: database)
    }

    static func restoreDatabase(from backupURL: URL, to databaseURL: URL) throws {
        // The failed migration connection is closed before restoration. Remove
        // its sidecars so stale WAL frames cannot shadow pages restored from
        // the standalone online-backup snapshot.
        try removeSQLiteSidecars(for: databaseURL)
        try copyDatabase(from: backupURL, to: databaseURL)
        let database = try openConnection(at: databaseURL)
        defer { sqlite3_close(database) }
        try requireIntegrity(on: database)
        try execute("PRAGMA wal_checkpoint(TRUNCATE)", on: database)
    }

    static func copyDatabase(from sourceURL: URL, to destinationURL: URL) throws {
        let source = try openConnection(at: sourceURL, readOnly: true)
        defer { sqlite3_close(source) }
        let destination = try openConnection(at: destinationURL)
        defer { sqlite3_close(destination) }

        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw DatabaseMigrationError(
                "SQLite backup initialization failed: \(message(from: destination))"
            )
        }

        var result: Int32 = SQLITE_OK
        var retryCount = 0
        repeat {
            result = sqlite3_backup_step(backup, -1)
            if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                retryCount += 1
                sqlite3_sleep(10)
            }
        } while (result == SQLITE_BUSY || result == SQLITE_LOCKED) && retryCount < 100

        let finishResult = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw DatabaseMigrationError(
                "SQLite online backup failed: \(message(from: destination))"
            )
        }
    }

    static func backupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return formatter.string(from: Date())
    }

    static func removeSQLiteSidecars(for databaseURL: URL) throws {
        let fileManager = FileManager.default
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: databaseURL.path + suffix)
            if fileManager.fileExists(atPath: sidecar.path) {
                try fileManager.removeItem(at: sidecar)
            }
        }
    }
}


// MARK: - SQLite primitives

private extension SQLiteAssignmentRepository {
    static func openConnection(
        at url: URL,
        readOnly: Bool = false
    ) throws -> OpaquePointer {
        var database: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let errorMessage = message(from: database)
            if let database {
                sqlite3_close(database)
            }
            throw AssignmentRepositoryError.open(errorMessage)
        }
        sqlite3_busy_timeout(database, 10_000)
        return database
    }

    static func execute(_ sql: String, on database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let resolved = errorMessage.map { String(cString: $0) }
                ?? message(from: database)
            sqlite3_free(errorMessage)
            throw AssignmentRepositoryError.execute(resolved)
        }
    }

    static func prepare(
        _ sql: String,
        on database: OpaquePointer
    ) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw AssignmentRepositoryError.prepare(message(from: database))
        }
        return statement
    }

    static func bind(
        _ value: String?,
        to statement: OpaquePointer,
        index: Int32
    ) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    static func message(from database: OpaquePointer?) -> String {
        guard let database else { return "Unknown SQLite error." }
        return String(cString: sqlite3_errmsg(database))
    }

    static func userVersion(on database: OpaquePointer) throws -> Int32 {
        let statement = try prepare("PRAGMA user_version", on: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw AssignmentRepositoryError.execute(message(from: database))
        }
        return sqlite3_column_int(statement, 0)
    }

    static func tableExists(
        _ name: String,
        on database: OpaquePointer
    ) throws -> Bool {
        let statement = try prepare(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            on: database
        )
        defer { sqlite3_finalize(statement) }
        bind(name, to: statement, index: 1)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw AssignmentRepositoryError.execute(message(from: database))
    }

    static func assignmentColumns(
        table: String,
        on database: OpaquePointer
    ) throws -> [String: ColumnInfo] {
        let statement = try prepare("PRAGMA table_info(\(table))", on: database)
        defer { sqlite3_finalize(statement) }
        var columns: [String: ColumnInfo] = [:]
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let name = text(statement, 1) else {
                throw DatabaseMigrationError("SQLite returned an unnamed column.")
            }
            columns[name] = ColumnInfo(
                name: name,
                notNull: sqlite3_column_int(statement, 3) != 0,
                defaultValue: text(statement, 4),
                isPrimaryKey: sqlite3_column_int(statement, 5) != 0
            )
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw AssignmentRepositoryError.execute(message(from: database))
        }
        return columns
    }

    static func assignmentTableSQL(on database: OpaquePointer) throws -> String {
        guard let value = try firstText(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'assignments'",
            on: database
        ) else {
            throw DatabaseMigrationError("The assignments table is missing.")
        }
        return value
    }

    static func assignmentIDs(on database: OpaquePointer) throws -> [Int64] {
        let statement = try prepare(
            "SELECT id FROM assignments ORDER BY id",
            on: database
        )
        defer { sqlite3_finalize(statement) }
        var ids: [Int64] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            ids.append(sqlite3_column_int64(statement, 0))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw AssignmentRepositoryError.execute(message(from: database))
        }
        return ids
    }

    static func firstText(
        _ sql: String,
        on database: OpaquePointer
    ) throws -> String? {
        let statement = try prepare(sql, on: database)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW {
            return text(statement, 0)
        }
        if result == SQLITE_DONE {
            return nil
        }
        throw AssignmentRepositoryError.execute(message(from: database))
    }

    static func rowExists(
        _ sql: String,
        on database: OpaquePointer
    ) throws -> Bool {
        let statement = try prepare(sql, on: database)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw AssignmentRepositoryError.execute(message(from: database))
    }
}


// Internal transaction-owned v1/v2 primitives used only by MigrationCoordinator.
// The coordinator owns BEGIN/COMMIT, the online backup, locking, and recovery.
extension SQLiteAssignmentRepository {
    static func createV2SchemaInCurrentTransaction(on database: OpaquePointer) throws {
        // A fresh database uses v2 only as the transaction-local structural
        // seed required by the additive v3 migration. Do not create the three
        // obsolete v2-only lookup indexes here: canonical fresh and canonical
        // migrated v3 databases must both contain exactly the shared v3 index
        // set. Final v3 validation is the authoritative validation for this
        // no-user-data path.
        try createAssignmentsTable(on: database)
        try execute("PRAGMA user_version = 2", on: database)
    }

    /// Returns true when the legacy table required a rebuild rather than an
    /// additive v1-to-v2 upgrade.
    static func migrateV1ToV2InCurrentTransaction(on database: OpaquePointer) throws -> Bool {
        guard !(try tableExists("assignments_v1_migration", on: database)) else {
            throw DatabaseMigrationError(
                "Cannot migrate while assignments_v1_migration already exists."
            )
        }
        let columns = try assignmentColumns(table: "assignments", on: database)
        let missingRequired = Set(["id", "course_name", "title"]).subtracting(columns.keys)
        guard missingRequired.isEmpty else {
            throw DatabaseMigrationError(
                "Legacy assignments table is missing required columns: "
                    + missingRequired.sorted().joined(separator: ", ")
            )
        }
        try validateLegacyValues(columns: columns, on: database)
        let idsBefore = try assignmentIDs(on: database)
        let rebuilt = try requiresRebuild(columns: columns, on: database)
        if rebuilt {
            try rebuildAssignments(columns: columns, on: database)
        } else {
            try addV2Columns(columns: columns, on: database)
            try createIndexes(on: database)
        }
        try normalizeLegacyDueDates(on: database)
        guard idsBefore == (try assignmentIDs(on: database)) else {
            throw DatabaseMigrationError(
                "Assignment identity validation failed during v1-to-v2 migration."
            )
        }
        try validateV2Schema(on: database, requireVersion: false)
        try execute("PRAGMA user_version = 2", on: database)
        return rebuilt
    }
}


private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)


private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
