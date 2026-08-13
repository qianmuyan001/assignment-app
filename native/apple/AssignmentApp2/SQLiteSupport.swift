import Foundation
import SQLite3


enum SQLiteSupport {
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func open(
        _ url: URL,
        flags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    ) throws -> OpaquePointer {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "SQLite could not open the database."
            if let database { sqlite3_close(database) }
            throw AssignmentRepositoryError.open(message)
        }
        return database
    }

    static func configure(_ database: OpaquePointer, writable: Bool = true) throws {
        try execute("PRAGMA busy_timeout = 10000", on: database)
        try execute("PRAGMA foreign_keys = ON", on: database)
        if writable {
            try execute("PRAGMA synchronous = FULL", on: database)
        }
    }

    static func execute(_ sql: String, on database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw AssignmentRepositoryError.execute(message)
        }
    }

    static func prepare(_ sql: String, on database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw AssignmentRepositoryError.prepare(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    static func bind(_ value: String?, to statement: OpaquePointer, index: Int32) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, transient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    static func bind(_ value: Int64?, to statement: OpaquePointer, index: Int32) {
        if let value {
            sqlite3_bind_int64(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    static func bind(_ value: Int?, to statement: OpaquePointer, index: Int32) {
        if let value {
            sqlite3_bind_int(statement, index, Int32(value))
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: value)
    }

    static func int64(_ statement: OpaquePointer, _ column: Int32) -> Int64? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil
            : sqlite3_column_int64(statement, column)
    }

    static func scalarInt(_ sql: String, on database: OpaquePointer) throws -> Int64 {
        let statement = try prepare(sql, on: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw AssignmentRepositoryError.execute(String(cString: sqlite3_errmsg(database)))
        }
        return sqlite3_column_int64(statement, 0)
    }

    static func scalarText(_ sql: String, on database: OpaquePointer) throws -> String? {
        let statement = try prepare(sql, on: database)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else {
            throw AssignmentRepositoryError.execute(String(cString: sqlite3_errmsg(database)))
        }
        return text(statement, 0)
    }

    static func tableExists(_ name: String, on database: OpaquePointer) throws -> Bool {
        let statement = try prepare(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            on: database
        )
        defer { sqlite3_finalize(statement) }
        bind(name, to: statement, index: 1)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    static func columnNames(_ table: String, on database: OpaquePointer) throws -> [String] {
        let statement = try prepare("PRAGMA table_info(\(quoteIdentifier(table)))", on: database)
        defer { sqlite3_finalize(statement) }
        var names: [String] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let name = text(statement, 1) { names.append(name) }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw AssignmentRepositoryError.execute(String(cString: sqlite3_errmsg(database)))
        }
        return names
    }

    static func quoteIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    static func checkDone(_ statement: OpaquePointer, on database: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw AssignmentRepositoryError.execute(String(cString: sqlite3_errmsg(database)))
        }
    }

    static func onlineBackup(
        from source: OpaquePointer,
        to destinationURL: URL,
        standaloneDestination: Bool
    ) throws {
        var destination: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(destinationURL.path, &destination, flags, nil) == SQLITE_OK,
              let destination else {
            let message = destination.map { String(cString: sqlite3_errmsg($0)) }
                ?? "SQLite could not create the backup destination."
            if let destination { sqlite3_close(destination) }
            throw AssignmentRepositoryError.open(message)
        }
        defer { sqlite3_close(destination) }

        try onlineBackup(from: source, to: destination)

        if standaloneDestination {
            // A copied WAL-mode header otherwise makes an independent backup
            // depend on source sidecars which are deliberately not copied.
            // Never run this on a live restore destination: changing a live
            // database out of WAL can conflict with existing readers.
            guard try scalarText("PRAGMA journal_mode = DELETE", on: destination)?
                .lowercased() == "delete" else {
                throw AssignmentRepositoryError.execute(
                    "Could not make the independent online backup self-contained."
                )
            }
        }
    }

    /// Copies `source.main` into an already-open destination connection.
    /// This is the restore primitive: it preserves the live destination file,
    /// inode and journal mode instead of replacing or unlinking database files.
    static func onlineBackup(
        from source: OpaquePointer,
        to destination: OpaquePointer
    ) throws {
        guard sqlite3_get_autocommit(destination) != 0 else {
            throw AssignmentRepositoryError.execute(
                "SQLite online backup destination must not have an active transaction."
            )
        }
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw AssignmentRepositoryError.execute(String(cString: sqlite3_errmsg(destination)))
        }

        let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        var result = sqlite3_backup_step(backup, 128)
        while result == SQLITE_OK || result == SQLITE_BUSY || result == SQLITE_LOCKED {
            if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                guard DispatchTime.now().uptimeNanoseconds < deadline else { break }
                sqlite3_sleep(10)
            }
            result = sqlite3_backup_step(backup, 128)
        }
        let finish = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finish == SQLITE_OK else {
            throw AssignmentRepositoryError.execute(String(cString: sqlite3_errmsg(destination)))
        }
    }
}


/// Transaction-scoped parent/subtask state rules shared by both repositories.
/// Callers must already hold `BEGIN IMMEDIATE` so child and parent changes are
/// observed atomically by every connection.
enum TaskProgressPersistence {
    struct ParentState: Equatable {
        let status: AssignmentStatus
        let progressPercent: Int
        let completedAt: String?
    }

    static func activeSubtaskCount(
        assignmentID: Int64,
        on database: OpaquePointer
    ) throws -> Int {
        Int(try SQLiteSupport.scalarInt(
            """
            SELECT COUNT(*) FROM subtasks
            WHERE assignment_id = \(assignmentID) AND deleted_at IS NULL
            """,
            on: database
        ))
    }

    static func derivedState(
        assignmentID: Int64,
        on database: OpaquePointer,
        completionTimestamp: String
    ) throws -> ParentState? {
        let statement = try SQLiteSupport.prepare(
            """
            SELECT COUNT(*),
                   SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END),
                   SUM(CASE WHEN status = 'in_progress' THEN 1 ELSE 0 END)
            FROM subtasks
            WHERE assignment_id = ? AND deleted_at IS NULL
            """,
            on: database
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, assignmentID)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw AssignmentRepositoryError.execute(String(cString: sqlite3_errmsg(database)))
        }
        let total = Int(sqlite3_column_int64(statement, 0))
        let done = Int(sqlite3_column_int64(statement, 1))
        let inProgress = Int(sqlite3_column_int64(statement, 2))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw AssignmentRepositoryError.execute(String(cString: sqlite3_errmsg(database)))
        }
        guard total > 0 else { return nil }

        let progress = (done * 100) / total
        if done == total {
            let existing = try existingCompletedAt(assignmentID: assignmentID, on: database)
            return .init(
                status: .done,
                progressPercent: 100,
                completedAt: existing ?? completionTimestamp
            )
        }
        return .init(
            status: done > 0 || inProgress > 0 ? .inProgress : .todo,
            progressPercent: progress,
            completedAt: nil
        )
    }

    @discardableResult
    static func recalculateParent(
        assignmentID: Int64,
        resetWhenEmpty: Bool,
        timestamp: String,
        on database: OpaquePointer
    ) throws -> ParentState? {
        let state: ParentState?
        if let derived = try derivedState(
            assignmentID: assignmentID,
            on: database,
            completionTimestamp: timestamp
        ) {
            state = derived
        } else if resetWhenEmpty {
            state = .init(status: .todo, progressPercent: 0, completedAt: nil)
        } else {
            state = nil
        }
        guard let state else { return nil }
        try updateParent(assignmentID: assignmentID, state: state, timestamp: timestamp, on: database)
        return state
    }

    @discardableResult
    static func applyParentStatusCommand(
        assignmentID: Int64,
        status: AssignmentStatus,
        timestamp: String,
        on database: OpaquePointer
    ) throws -> ParentState {
        guard try activeAssignmentExists(assignmentID, on: database) else {
            throw AssignmentRepositoryError.notFound(assignmentID)
        }
        let childCount = try activeSubtaskCount(assignmentID: assignmentID, on: database)
        if childCount == 0 {
            let current = try currentParentState(assignmentID: assignmentID, on: database)
            let progress: Int
            switch status {
            case .done:
                progress = 100
            case .todo:
                progress = 0
            case .inProgress:
                progress = current.status == .done
                    ? 0
                    : min(max(current.progressPercent, 0), 99)
            }
            let state = ParentState(
                status: status,
                progressPercent: progress,
                completedAt: status == .done
                    ? (current.completedAt ?? timestamp)
                    : nil
            )
            try updateParent(
                assignmentID: assignmentID,
                state: state,
                timestamp: timestamp,
                on: database
            )
            return state
        }

        switch status {
        case .done:
            let statement = try SQLiteSupport.prepare(
                """
                UPDATE subtasks
                SET status = 'completed', completed_at = COALESCE(completed_at, ?),
                    updated_at = ?
                WHERE assignment_id = ? AND deleted_at IS NULL
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            SQLiteSupport.bind(timestamp, to: statement, index: 1)
            SQLiteSupport.bind(timestamp, to: statement, index: 2)
            sqlite3_bind_int64(statement, 3, assignmentID)
            try SQLiteSupport.checkDone(statement, on: database)
        case .todo:
            let statement = try SQLiteSupport.prepare(
                """
                UPDATE subtasks
                SET status = 'not_started', completed_at = NULL, updated_at = ?
                WHERE assignment_id = ? AND deleted_at IS NULL
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            SQLiteSupport.bind(timestamp, to: statement, index: 1)
            sqlite3_bind_int64(statement, 2, assignmentID)
            try SQLiteSupport.checkDone(statement, on: database)
        case .inProgress:
            let hasInProgress = try SQLiteSupport.scalarInt(
                """
                SELECT COUNT(*) FROM subtasks
                WHERE assignment_id = \(assignmentID)
                  AND deleted_at IS NULL AND status = 'in_progress'
                """,
                on: database
            ) > 0
            if !hasInProgress {
                let statement = try SQLiteSupport.prepare(
                    """
                    UPDATE subtasks
                    SET status = 'in_progress', completed_at = NULL, updated_at = ?
                    WHERE id = (
                        SELECT id FROM subtasks
                        WHERE assignment_id = ? AND deleted_at IS NULL
                          AND status = 'not_started'
                        ORDER BY sort_order, id LIMIT 1
                    )
                    """,
                    on: database
                )
                defer { sqlite3_finalize(statement) }
                SQLiteSupport.bind(timestamp, to: statement, index: 1)
                sqlite3_bind_int64(statement, 2, assignmentID)
                try SQLiteSupport.checkDone(statement, on: database)
            }
        }
        guard let state = try recalculateParent(
            assignmentID: assignmentID,
            resetWhenEmpty: true,
            timestamp: timestamp,
            on: database
        ) else {
            throw AssignmentRepositoryError.corruptData(
                "Subtask state disappeared while deriving parent progress."
            )
        }
        return state
    }

    static func activeAssignmentExists(_ id: Int64, on database: OpaquePointer) throws -> Bool {
        let statement = try SQLiteSupport.prepare(
            "SELECT 1 FROM assignments WHERE id = ? AND deleted_at IS NULL LIMIT 1",
            on: database
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else {
            throw AssignmentRepositoryError.execute(String(cString: sqlite3_errmsg(database)))
        }
        return result == SQLITE_ROW
    }

    private static func currentParentState(
        assignmentID: Int64,
        on database: OpaquePointer
    ) throws -> ParentState {
        let statement = try SQLiteSupport.prepare(
            """
            SELECT status, progress_percent, completed_at FROM assignments
            WHERE id = ? AND deleted_at IS NULL
            """,
            on: database
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, assignmentID)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let storedStatus = SQLiteSupport.text(statement, 0) else {
            throw AssignmentRepositoryError.notFound(assignmentID)
        }
        return .init(
            status: try AssignmentStatus(storageValue: storedStatus),
            progressPercent: Int(sqlite3_column_int(statement, 1)),
            completedAt: SQLiteSupport.text(statement, 2)
        )
    }

    private static func existingCompletedAt(
        assignmentID: Int64,
        on database: OpaquePointer
    ) throws -> String? {
        let statement = try SQLiteSupport.prepare(
            "SELECT completed_at FROM assignments WHERE id = ?",
            on: database
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, assignmentID)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw AssignmentRepositoryError.notFound(assignmentID)
        }
        return SQLiteSupport.text(statement, 0)
    }

    private static func updateParent(
        assignmentID: Int64,
        state: ParentState,
        timestamp: String,
        on database: OpaquePointer
    ) throws {
        let statement = try SQLiteSupport.prepare(
            """
            UPDATE assignments
            SET status = ?, progress_percent = ?, completed_at = ?, updated_at = ?
            WHERE id = ? AND deleted_at IS NULL
            """,
            on: database
        )
        defer { sqlite3_finalize(statement) }
        SQLiteSupport.bind(state.status.storageValue, to: statement, index: 1)
        sqlite3_bind_int(statement, 2, Int32(state.progressPercent))
        SQLiteSupport.bind(state.completedAt, to: statement, index: 3)
        SQLiteSupport.bind(timestamp, to: statement, index: 4)
        sqlite3_bind_int64(statement, 5, assignmentID)
        try SQLiteSupport.checkDone(statement, on: database)
        guard sqlite3_changes(database) == 1 else {
            throw AssignmentRepositoryError.notFound(assignmentID)
        }
    }
}
