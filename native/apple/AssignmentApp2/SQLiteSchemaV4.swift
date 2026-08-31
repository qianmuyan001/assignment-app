import Foundation
import SQLite3


/// Additive v3 to v4 upgrade for the Phase 3A learning scenes.
///
/// Schema v4 reuses `courses`, `assignments`, and `reminders`. It only adds the
/// `reminders.schedule_kind` discriminator plus the `course_meetings` and
/// `exams` tables, their indexes, and their UUID-immutability triggers. It
/// never rebuilds, rewrites, or reinterprets a v3 row.
enum SQLiteSchemaV4 {
    static let databaseVersion: Int32 = 4

    static let scheduleKindCheck = "schedule_kind IN ('fixed', 'due_relative')"

    private static let requiredColumns: [String: Set<String>] = [
        "course_meetings": [
            "id", "uuid", "course_id", "weekday", "start_time_local",
            "end_time_local", "location", "teacher_override", "timezone_id",
            "effective_start_date", "effective_end_date", "sort_order",
            "created_at", "updated_at", "deleted_at",
        ],
        "exams": [
            "id", "uuid", "course_id", "name", "starts_at_local", "timezone_id",
            "location", "scope", "notes", "status", "linked_assignment_id",
            "created_at", "updated_at", "deleted_at",
        ],
    ]

    private static let indexes: [SQLiteSchemaV3.IndexContract] = [
        .init("ux_course_meetings_uuid", "course_meetings", ["uuid"], unique: true),
        .init(
            "ix_course_meetings_week", "course_meetings",
            ["weekday", "start_time_local", "course_id"]
        ),
        .init("ix_course_meetings_deleted_at", "course_meetings", ["deleted_at"]),
        .init("ux_exams_uuid", "exams", ["uuid"], unique: true),
        .init("ix_exams_course_start", "exams", ["course_id", "starts_at_local"]),
        .init("ix_exams_status_start", "exams", ["status", "starts_at_local"]),
        .init(
            "ux_exams_linked_assignment", "exams", ["linked_assignment_id"],
            unique: true, predicate: "linked_assignment_id IS NOT NULL"
        ),
        .init("ix_exams_deleted_at", "exams", ["deleted_at"]),
    ]

    private static let expectedForeignKeys: [
        String: Set<SQLiteSchemaV3.ForeignKeyContract>
    ] = [
        "course_meetings": [
            .init(
                from: "course_id", table: "courses", to: "id", onDelete: "RESTRICT"
            ),
        ],
        "exams": [
            .init(
                from: "course_id", table: "courses", to: "id", onDelete: "RESTRICT"
            ),
            .init(
                from: "linked_assignment_id", table: "assignments", to: "id",
                onDelete: "SET NULL"
            ),
        ],
    ]

    static func contractTriggers() -> [SQLiteSchemaV3.TriggerContract] {
        [
            "course_meetings", "exams",
        ].map { table in
            let name = "\(table)_uuid_immutable"
            return SQLiteSchemaV3.TriggerContract(
                name: name,
                table: table,
                sql: """
                CREATE TRIGGER \(name)
                BEFORE UPDATE OF uuid ON \(table)
                WHEN NEW.uuid IS NOT OLD.uuid
                BEGIN
                    SELECT RAISE(ABORT, '\(table) UUID is immutable');
                END
                """
            )
        }
    }

    static func migrateV3ToV4(
        on database: OpaquePointer,
        migrationFailureInjector: (() throws -> Void)? = nil
    ) throws {
        guard sqlite3_get_autocommit(database) == 0 else {
            throw DatabaseMigrationError("Schema v4 migration requires an active transaction.")
        }
        guard try SQLiteSupport.scalarInt("PRAGMA foreign_keys", on: database) == 1 else {
            throw DatabaseMigrationError("Schema v4 migration requires foreign keys enabled.")
        }
        guard try SQLiteSupport.scalarInt("PRAGMA user_version", on: database) == 3 else {
            throw DatabaseMigrationError("v3 to v4 migration requires user_version 3.")
        }

        // A v3 database must still satisfy its own contract before it is
        // extended; otherwise a corrupt file would be upgraded in place.
        try SQLiteSchemaV3.validateStructure(on: database)

        let existingTables = try tableNames(on: database)
        let conflicts = existingTables.intersection(Set(requiredColumns.keys))
        guard conflicts.isEmpty else {
            throw DatabaseMigrationError(
                "Partial v4 tables prevent migration: "
                    + conflicts.sorted().joined(separator: ", ") + "."
            )
        }
        let reminderColumns = Set(try SQLiteSupport.columnNames("reminders", on: database))
        guard !reminderColumns.contains("schedule_kind") else {
            throw DatabaseMigrationError(
                "Partial v4 reminder column prevents migration: schedule_kind."
            )
        }
        try ensureReservedTriggerNamesAvailable(on: database)

        // Snapshot every v3 reminder row so the additive upgrade can prove it
        // moved nothing. A fixed trigger must survive byte-for-byte.
        let remindersBefore = try orderedRows(
            "SELECT id, uuid, assignment_id, trigger_at_utc, lead_minutes, repeat_rule, "
                + "is_enabled, last_scheduled_at, created_at, updated_at, deleted_at "
                + "FROM reminders ORDER BY id",
            on: database
        )

        try SQLiteSupport.execute(
            "ALTER TABLE reminders ADD COLUMN schedule_kind TEXT NOT NULL "
                + "DEFAULT 'fixed' CHECK (\(scheduleKindCheck))",
            on: database
        )
        try createLearningTables(on: database)
        try createIndexes(on: database)
        try createTriggers(on: database)

        let remindersAfter = try orderedRows(
            "SELECT id, uuid, assignment_id, trigger_at_utc, lead_minutes, repeat_rule, "
                + "is_enabled, last_scheduled_at, created_at, updated_at, deleted_at "
                + "FROM reminders ORDER BY id",
            on: database
        )
        guard remindersBefore == remindersAfter else {
            throw DatabaseMigrationError(
                "v3 to v4 migration changed existing reminder rows."
            )
        }
        guard try SQLiteSupport.scalarInt(
            "SELECT COUNT(*) FROM reminders WHERE schedule_kind != 'fixed'",
            on: database
        ) == 0 else {
            throw DatabaseMigrationError(
                "Migrated v3 reminders must keep fixed-trigger semantics."
            )
        }

        try migrationFailureInjector?()
        try SQLiteSupport.execute(
            "PRAGMA user_version = \(databaseVersion)",
            on: database
        )
        try validate(on: database)
    }

    static func validate(on database: OpaquePointer) throws {
        guard try SQLiteSupport.scalarInt("PRAGMA foreign_keys", on: database) == 1 else {
            throw DatabaseMigrationError("Schema v4 validation requires foreign keys enabled.")
        }
        guard try SQLiteSupport.scalarInt("PRAGMA user_version", on: database)
            == databaseVersion else {
            throw DatabaseMigrationError(
                "Database user_version must be \(databaseVersion)."
            )
        }

        // A v4 database is a v3 database plus additions. Prove the v3 contract
        // still holds before checking anything v4 owns.
        try SQLiteSchemaV3.validateStructure(on: database)

        let existingTables = try tableNames(on: database)
        let missingTables = Set(requiredColumns.keys).subtracting(existingTables)
        guard missingTables.isEmpty else {
            throw DatabaseMigrationError(
                "Database v4 is missing tables: "
                    + missingTables.sorted().joined(separator: ", ") + "."
            )
        }
        for (table, expected) in requiredColumns {
            let actual = Set(try SQLiteSupport.columnNames(table, on: database))
            let missing = expected.subtracting(actual)
            guard missing.isEmpty else {
                throw DatabaseMigrationError(
                    "Database v4 table \(table) is missing: "
                        + missing.sorted().joined(separator: ", ") + "."
                )
            }
        }
        let reminderColumns = Set(try SQLiteSupport.columnNames("reminders", on: database))
        guard reminderColumns.contains("schedule_kind") else {
            throw DatabaseMigrationError(
                "Database v4 table reminders is missing: schedule_kind."
            )
        }

        for index in indexes {
            try SQLiteSchemaV3.validateIndex(index, on: database)
        }
        for trigger in contractTriggers() {
            try SQLiteSchemaV3.validateTrigger(trigger, on: database)
        }
        for (table, expected) in expectedForeignKeys {
            try validateForeignKeys(expected, for: table, on: database)
        }

        try validateLearningRows(on: database)

        guard try SQLiteSupport.scalarText("PRAGMA integrity_check", on: database) == "ok" else {
            throw DatabaseMigrationError("Database v4 integrity check failed.")
        }
        guard try SQLiteSupport.scalarInt(
            "SELECT COUNT(*) FROM pragma_foreign_key_check",
            on: database
        ) == 0 else {
            throw DatabaseMigrationError("Database v4 foreign key check failed.")
        }
    }
}


// MARK: - Schema creation

extension SQLiteSchemaV4 {
    static func createLearningTables(on database: OpaquePointer) throws {
        let uuidCheck = SQLiteSchemaV3.uuidCheck(versions: [4])
        let audit = SQLiteSchemaV3.auditColumns
        try SQLiteSupport.execute(
            """
            CREATE TABLE course_meetings (
                id INTEGER NOT NULL PRIMARY KEY,
                uuid TEXT NOT NULL CHECK (\(uuidCheck)),
                course_id INTEGER NOT NULL REFERENCES courses(id) ON DELETE RESTRICT,
                weekday INTEGER NOT NULL CHECK (weekday BETWEEN 1 AND 7),
                start_time_local TEXT NOT NULL CHECK (
                    length(start_time_local) = 8
                    AND start_time_local GLOB '[0-2][0-9]:[0-5][0-9]:[0-5][0-9]'
                ),
                end_time_local TEXT NOT NULL CHECK (
                    length(end_time_local) = 8
                    AND end_time_local GLOB '[0-2][0-9]:[0-5][0-9]:[0-5][0-9]'
                    AND start_time_local < end_time_local
                ),
                location TEXT,
                teacher_override TEXT,
                timezone_id TEXT NOT NULL CHECK (length(trim(timezone_id)) > 0),
                effective_start_date TEXT NOT NULL CHECK (length(effective_start_date) = 10),
                effective_end_date TEXT CHECK (
                    effective_end_date IS NULL OR
                    (length(effective_end_date) = 10
                     AND effective_end_date >= effective_start_date)
                ),
                sort_order INTEGER NOT NULL DEFAULT 0 CHECK (sort_order >= 0),
                \(audit)
            )
            """,
            on: database
        )
        try SQLiteSupport.execute(
            """
            CREATE TABLE exams (
                id INTEGER NOT NULL PRIMARY KEY,
                uuid TEXT NOT NULL CHECK (\(uuidCheck)),
                course_id INTEGER NOT NULL REFERENCES courses(id) ON DELETE RESTRICT,
                name TEXT NOT NULL CHECK (length(trim(name)) > 0),
                starts_at_local TEXT NOT NULL CHECK (length(starts_at_local) = 19),
                timezone_id TEXT NOT NULL CHECK (length(trim(timezone_id)) > 0),
                location TEXT,
                scope TEXT,
                notes TEXT,
                status TEXT NOT NULL DEFAULT 'upcoming'
                    CHECK (status IN ('upcoming', 'completed', 'cancelled')),
                linked_assignment_id INTEGER REFERENCES assignments(id) ON DELETE SET NULL,
                \(audit)
            )
            """,
            on: database
        )
    }

    static func createIndexes(on database: OpaquePointer) throws {
        for index in indexes {
            try SQLiteSupport.execute(index.createSQL, on: database)
        }
    }

    static func createTriggers(on database: OpaquePointer) throws {
        try ensureReservedTriggerNamesAvailable(on: database)
        for trigger in contractTriggers() {
            try SQLiteSupport.execute(trigger.sql, on: database)
        }
    }

    static func ensureReservedTriggerNamesAvailable(on database: OpaquePointer) throws {
        for trigger in contractTriggers() {
            let statement = try SQLiteSupport.prepare(
                "SELECT type FROM sqlite_master WHERE name = ?",
                on: database
            )
            SQLiteSupport.bind(trigger.name, to: statement, index: 1)
            let conflict = sqlite3_step(statement) == SQLITE_ROW
            sqlite3_finalize(statement)
            guard !conflict else {
                throw DatabaseMigrationError(
                    "Reserved v4 trigger name is already used: \(trigger.name)."
                )
            }
        }
    }

    static func validateForeignKeys(
        _ expected: Set<SQLiteSchemaV3.ForeignKeyContract>,
        for table: String,
        on database: OpaquePointer
    ) throws {
        let statement = try SQLiteSupport.prepare(
            "PRAGMA foreign_key_list(\(SQLiteSupport.quoteIdentifier(table)))",
            on: database
        )
        defer { sqlite3_finalize(statement) }
        var actual = Set<SQLiteSchemaV3.ForeignKeyContract>()
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let referencedTable = SQLiteSupport.text(statement, 2),
                  let from = SQLiteSupport.text(statement, 3),
                  let to = SQLiteSupport.text(statement, 4),
                  let onUpdate = SQLiteSupport.text(statement, 5),
                  let onDelete = SQLiteSupport.text(statement, 6),
                  let match = SQLiteSupport.text(statement, 7) else {
                throw DatabaseMigrationError(
                    "Database v4 table \(table) has invalid foreign key metadata."
                )
            }
            actual.insert(
                .init(
                    from: from,
                    table: referencedTable,
                    to: to,
                    onDelete: onDelete.uppercased(),
                    onUpdate: onUpdate.uppercased(),
                    match: match.uppercased()
                )
            )
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw DatabaseMigrationError(String(cString: sqlite3_errmsg(database)))
        }
        guard actual == expected else {
            let missing = expected.subtracting(actual)
            let unexpected = actual.subtracting(expected)
            let details = [
                missing.isEmpty
                    ? nil
                    : "missing " + missing.map(\.description).sorted().joined(separator: ", "),
                unexpected.isEmpty
                    ? nil
                    : "unexpected "
                        + unexpected.map(\.description).sorted().joined(separator: ", "),
            ].compactMap { $0 }.joined(separator: "; ")
            throw DatabaseMigrationError(
                "Database v4 table \(table) has invalid foreign keys: \(details)."
            )
        }
    }

    static func validateLearningRows(on database: OpaquePointer) throws {
        let invalidReminder = try SQLiteSupport.scalarInt(
            """
            SELECT COUNT(*) FROM reminders
            WHERE schedule_kind NOT IN ('fixed', 'due_relative')
               OR (schedule_kind = 'due_relative' AND lead_minutes < 0)
            """,
            on: database
        )
        guard invalidReminder == 0 else {
            throw DatabaseMigrationError(
                "Database v4 reminder rows violate the schedule-kind contract."
            )
        }

        let invalidMeeting = try SQLiteSupport.scalarInt(
            """
            SELECT COUNT(*) FROM course_meetings
            WHERE weekday NOT BETWEEN 1 AND 7
               OR start_time_local >= end_time_local
               OR sort_order < 0
               OR length(trim(timezone_id)) = 0
               OR length(effective_start_date) != 10
               OR (effective_end_date IS NOT NULL
                   AND effective_end_date < effective_start_date)
            """,
            on: database
        )
        guard invalidMeeting == 0 else {
            throw DatabaseMigrationError(
                "Database v4 course meeting rows violate the v4 contract."
            )
        }

        let invalidExam = try SQLiteSupport.scalarInt(
            """
            SELECT COUNT(*) FROM exams
            WHERE status NOT IN ('upcoming', 'completed', 'cancelled')
               OR length(trim(name)) = 0
               OR length(starts_at_local) != 19
               OR length(trim(timezone_id)) = 0
            """,
            on: database
        )
        guard invalidExam == 0 else {
            throw DatabaseMigrationError("Database v4 exam rows violate the v4 contract.")
        }

        for table in ["course_meetings", "exams"] {
            let statement = try SQLiteSupport.prepare(
                "SELECT uuid FROM \(table) ORDER BY id",
                on: database
            )
            defer { sqlite3_finalize(statement) }
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                guard let text = SQLiteSupport.text(statement, 0),
                      let uuid = UUID(uuidString: text),
                      uuid.canonicalString == text,
                      uuid.versionNumber == 4 else {
                    throw DatabaseMigrationError(
                        "Database v4 table \(table) contains a non-canonical UUID v4."
                    )
                }
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else {
                throw DatabaseMigrationError(String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    static func tableNames(on database: OpaquePointer) throws -> Set<String> {
        let statement = try SQLiteSupport.prepare(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
            on: database
        )
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let name = SQLiteSupport.text(statement, 0) {
                names.insert(name)
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw DatabaseMigrationError(String(cString: sqlite3_errmsg(database)))
        }
        return names
    }

    static func orderedRows(_ sql: String, on database: OpaquePointer) throws -> [[String]] {
        let statement = try SQLiteSupport.prepare(sql, on: database)
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let columnCount = sqlite3_column_count(statement)
            var row: [String] = []
            row.reserveCapacity(Int(columnCount))
            for column in Int32(0)..<columnCount {
                if let text = SQLiteSupport.text(statement, column) {
                    row.append("t:" + text)
                } else if let value = SQLiteSupport.int64(statement, column) {
                    row.append("i:\(value)")
                } else {
                    row.append("null")
                }
            }
            rows.append(row)
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw DatabaseMigrationError(String(cString: sqlite3_errmsg(database)))
        }
        return rows
    }
}
