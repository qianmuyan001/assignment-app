import Foundation
import SQLite3


enum DatabaseError: LocalizedError {
    case open(String)
    case prepare(String)
    case execute(String)

    var errorDescription: String? {
        switch self {
        case .open(let message): "Could not open the assignment database: \(message)"
        case .prepare(let message): "Could not prepare a database operation: \(message)"
        case .execute(let message): "Could not complete a database operation: \(message)"
        }
    }
}


final class AssignmentDatabase: @unchecked Sendable {
    let url: URL
    private var database: OpaquePointer?
    private let lock = NSLock()

    init(url: URL = AssignmentDatabase.defaultDatabaseURL()) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            throw DatabaseError.open(Self.message(from: database))
        }

        sqlite3_busy_timeout(database, 5_000)
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
        try createSchema()
    }

    deinit {
        sqlite3_close(database)
    }

    func fetchAssignments() throws -> [Assignment] {
        try lock.withLock {
            let sql = """
                SELECT id, course_name, title, due_date, description, link, status,
                       source_name, source_type, source_file, source_url,
                       created_at, updated_at
                FROM assignments
                ORDER BY due_date IS NULL, due_date ASC, created_at DESC
                """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }

            var assignments: [Assignment] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                assignments.append(
                    Assignment(
                        id: sqlite3_column_int64(statement, 0),
                        courseName: Self.text(statement, 1) ?? "",
                        title: Self.text(statement, 2) ?? "",
                        dueDate: Date.fromDatabase(Self.text(statement, 3)),
                        assignmentDescription: Self.text(statement, 4),
                        link: Self.text(statement, 5),
                        status: AssignmentStatus(
                            rawValue: Self.text(statement, 6) ?? ""
                        ) ?? .notStarted,
                        sourceName: Self.text(statement, 7),
                        sourceType: Self.text(statement, 8),
                        sourceFile: Self.text(statement, 9),
                        sourceURL: Self.text(statement, 10),
                        createdAt: Date.fromDatabase(Self.text(statement, 11)),
                        updatedAt: Date.fromDatabase(Self.text(statement, 12))
                    )
                )
                result = sqlite3_step(statement)
            }

            if result != SQLITE_DONE {
                throw DatabaseError.execute(Self.message(from: database))
            }
            return assignments
        }
    }

    @discardableResult
    func insertCandidates(
        _ candidates: [AssignmentCandidate],
        fallbackCourse: String,
        sourceName: String,
        sourceURL: String
    ) throws -> Int {
        try lock.withLock {
            try executeUnlocked("BEGIN IMMEDIATE")
            do {
                var inserted = 0
                for candidate in candidates {
                    let course = candidate.courseName?.trimmedNonEmpty
                        ?? fallbackCourse.trimmedNonEmpty
                        ?? "Imported"
                    let dueDate = Self.databaseDueDate(
                        date: candidate.dueDate,
                        time: candidate.dueTime
                    )
                    let resolvedSource = candidate.sourceName?.trimmedNonEmpty
                        ?? sourceName.trimmedNonEmpty
                    let resolvedURL = candidate.sourceURL?.trimmedNonEmpty
                        ?? sourceURL.trimmedNonEmpty

                    if try containsDuplicate(
                        course: course,
                        title: candidate.title,
                        dueDate: dueDate,
                        sourceURL: resolvedURL
                    ) {
                        continue
                    }

                    let statement = try prepare(
                        """
                        INSERT INTO assignments (
                            course_name, title, due_date, description, link, status,
                            source_name, source_type, source_file, source_url,
                            created_at, updated_at
                        ) VALUES (?, ?, ?, ?, ?, 'not_started', ?, 'secure_web', NULL, ?,
                                  CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                        """
                    )
                    defer { sqlite3_finalize(statement) }

                    Self.bind(course, to: statement, index: 1)
                    Self.bind(candidate.title.trimmedNonEmpty ?? "Untitled", to: statement, index: 2)
                    Self.bind(dueDate, to: statement, index: 3)
                    Self.bind(candidate.description?.trimmedNonEmpty, to: statement, index: 4)
                    Self.bind(resolvedURL, to: statement, index: 5)
                    Self.bind(resolvedSource, to: statement, index: 6)
                    Self.bind(resolvedURL, to: statement, index: 7)

                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw DatabaseError.execute(Self.message(from: database))
                    }
                    inserted += 1
                }
                try executeUnlocked("COMMIT")
                return inserted
            } catch {
                try? executeUnlocked("ROLLBACK")
                throw error
            }
        }
    }

    func updateStatus(id: Int64, status: AssignmentStatus) throws {
        try lock.withLock {
            let statement = try prepare(
                "UPDATE assignments SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?"
            )
            defer { sqlite3_finalize(statement) }
            Self.bind(status.rawValue, to: statement, index: 1)
            sqlite3_bind_int64(statement, 2, id)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.execute(Self.message(from: database))
            }
        }
    }

    func delete(id: Int64) throws {
        try lock.withLock {
            let statement = try prepare("DELETE FROM assignments WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, id)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.execute(Self.message(from: database))
            }
        }
    }

    static func defaultDatabaseURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["ASSIGNMENT_DB_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        let bundleCandidate = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("backend", isDirectory: true)
            .appendingPathComponent("assignments.db")
        if FileManager.default.fileExists(atPath: bundleCandidate.path) {
            return bundleCandidate
        }

        var directory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        for _ in 0..<8 {
            let candidate = directory
                .appendingPathComponent("backend", isDirectory: true)
                .appendingPathComponent("assignments.db")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }

        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport
            .appendingPathComponent("AssignmentNative", isDirectory: true)
            .appendingPathComponent("assignments.db")
    }

    private func createSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS assignments (
                id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
                course_name VARCHAR(120) NOT NULL,
                title VARCHAR(255) NOT NULL,
                due_date DATETIME,
                description TEXT,
                link VARCHAR(1000),
                status VARCHAR(20) NOT NULL DEFAULT 'not_started',
                source_name VARCHAR(255),
                source_type VARCHAR(80),
                source_file VARCHAR(1000),
                source_url VARCHAR(1000),
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
                CONSTRAINT assignment_status_check
                    CHECK (status IN ('not_started', 'in_progress', 'completed'))
            )
            """
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS ix_assignments_due_date ON assignments (due_date)"
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS ix_assignments_status ON assignments (status)"
        )
    }

    private func containsDuplicate(
        course: String,
        title: String,
        dueDate: String?,
        sourceURL: String?
    ) throws -> Bool {
        let statement = try prepare(
            """
            SELECT 1
            FROM assignments
            WHERE lower(course_name) = lower(?)
              AND lower(title) = lower(?)
              AND ifnull(due_date, '') = ifnull(?, '')
              AND ifnull(source_url, '') = ifnull(?, '')
            LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }
        Self.bind(course, to: statement, index: 1)
        Self.bind(title, to: statement, index: 2)
        Self.bind(dueDate, to: statement, index: 3)
        Self.bind(sourceURL, to: statement, index: 4)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func execute(_ sql: String) throws {
        try lock.withLock {
            try executeUnlocked(sql)
        }
    }

    private func executeUnlocked(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? Self.message(from: database)
            sqlite3_free(errorMessage)
            throw DatabaseError.execute(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw DatabaseError.prepare(Self.message(from: database))
        }
        return statement
    }

    private static func bind(
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

    private static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    private static func message(from database: OpaquePointer?) -> String {
        guard let database else { return "Unknown SQLite error." }
        return String(cString: sqlite3_errmsg(database))
    }

    private static func databaseDueDate(date: String?, time: String?) -> String? {
        guard let date = date?.trimmedNonEmpty else { return nil }
        return "\(date) \(time?.trimmedNonEmpty ?? "23:59")"
    }
}


private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)


private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
