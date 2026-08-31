import Foundation
import SQLite3


enum SQLiteSchemaV3 {
    static let databaseVersion: Int32 = 3

    private static let v2Columns = [
        "id", "course_name", "title", "due_date", "description", "link",
        "status", "priority", "source_name", "source_type", "source_file",
        "source_url", "created_at", "updated_at",
    ]

    private static let requiredColumns: [String: Set<String>] = [
        "database_identity": ["singleton", "instance_uuid", "created_at"],
        "assignments": Set(v2Columns + [
            "uuid", "course_id", "project_id", "completed_at", "progress_percent",
            "all_day", "timezone_id", "deleted_at",
        ]),
        "courses": [
            "id", "uuid", "name", "normalized_name", "color_hex", "teacher",
            "semester", "is_archived", "created_at", "updated_at", "deleted_at",
        ],
        "projects": [
            "id", "uuid", "course_id", "name", "description", "status",
            "created_at", "updated_at", "deleted_at",
        ],
        "tags": [
            "id", "uuid", "name", "normalized_name", "color_hex", "created_at",
            "updated_at", "deleted_at",
        ],
        "task_tags": [
            "id", "uuid", "assignment_id", "tag_id", "created_at", "updated_at",
            "deleted_at",
        ],
        "subtasks": [
            "id", "uuid", "assignment_id", "title", "status", "sort_order",
            "completed_at", "created_at", "updated_at", "deleted_at",
        ],
        "attachments": [
            "id", "uuid", "assignment_id", "file_name", "relative_path",
            "mime_type", "byte_size", "sha256", "created_at", "updated_at",
            "deleted_at",
        ],
        "reminders": [
            "id", "uuid", "assignment_id", "trigger_at_utc", "lead_minutes",
            "repeat_rule", "is_enabled", "last_scheduled_at", "created_at",
            "updated_at", "deleted_at",
        ],
    ]

    private static let indexes: [IndexContract] = [
        .init("ux_assignments_uuid", "assignments", ["uuid"], unique: true),
        .init("ix_assignments_course_id", "assignments", ["course_id"]),
        .init("ix_assignments_project_id", "assignments", ["project_id"]),
        .init("ix_assignments_due_date", "assignments", ["due_date"]),
        .init("ix_assignments_status", "assignments", ["status"]),
        .init("ix_assignments_priority", "assignments", ["priority"]),
        .init("ix_assignments_deleted_at", "assignments", ["deleted_at"]),
        .init("ux_courses_uuid", "courses", ["uuid"], unique: true),
        .init("ix_courses_normalized_name", "courses", ["normalized_name"]),
        .init("ix_courses_archived_name", "courses", ["is_archived", "name"]),
        .init("ux_projects_uuid", "projects", ["uuid"], unique: true),
        .init("ix_projects_course_status", "projects", ["course_id", "status"]),
        .init("ix_projects_deleted_at", "projects", ["deleted_at"]),
        .init("ux_tags_uuid", "tags", ["uuid"], unique: true),
        .init("ux_tags_normalized_name", "tags", ["normalized_name"], unique: true),
        .init("ix_tags_deleted_at", "tags", ["deleted_at"]),
        .init("ux_task_tags_uuid", "task_tags", ["uuid"], unique: true),
        .init(
            "ux_task_tags_active_pair", "task_tags", ["assignment_id", "tag_id"],
            unique: true, predicate: "deleted_at IS NULL"
        ),
        .init("ix_task_tags_assignment", "task_tags", ["assignment_id"]),
        .init("ix_task_tags_tag", "task_tags", ["tag_id"]),
        .init("ux_subtasks_uuid", "subtasks", ["uuid"], unique: true),
        .init(
            "ix_subtasks_assignment_order", "subtasks",
            ["assignment_id", "sort_order", "id"]
        ),
        .init("ix_subtasks_status", "subtasks", ["status"]),
        .init("ux_attachments_uuid", "attachments", ["uuid"], unique: true),
        .init(
            "ux_attachments_relative_path", "attachments", ["relative_path"],
            unique: true
        ),
        .init("ix_attachments_assignment", "attachments", ["assignment_id"]),
        .init("ix_attachments_sha256", "attachments", ["sha256"]),
        .init("ux_reminders_uuid", "reminders", ["uuid"], unique: true),
        .init("ix_reminders_assignment", "reminders", ["assignment_id"]),
        .init(
            "ix_reminders_enabled_trigger", "reminders", ["is_enabled", "trigger_at_utc"]
        ),
    ]

    private static let immutableUUIDTables = [
        "assignments", "courses", "projects", "tags", "task_tags", "subtasks",
        "attachments", "reminders",
    ]

    private static let expectedForeignKeys: [String: Set<ForeignKeyContract>] = [
        "assignments": [
            .init(from: "course_id", table: "courses", to: "id", onDelete: "SET NULL"),
            .init(from: "project_id", table: "projects", to: "id", onDelete: "SET NULL"),
        ],
        "projects": [
            .init(from: "course_id", table: "courses", to: "id", onDelete: "SET NULL"),
        ],
        "task_tags": [
            .init(from: "assignment_id", table: "assignments", to: "id", onDelete: "CASCADE"),
            .init(from: "tag_id", table: "tags", to: "id", onDelete: "CASCADE"),
        ],
        "subtasks": [
            .init(from: "assignment_id", table: "assignments", to: "id", onDelete: "CASCADE"),
        ],
        "attachments": [
            .init(from: "assignment_id", table: "assignments", to: "id", onDelete: "CASCADE"),
        ],
        "reminders": [
            .init(from: "assignment_id", table: "assignments", to: "id", onDelete: "CASCADE"),
        ],
    ]

    static func migrateV2ToV3(
        on database: OpaquePointer,
        databaseInstanceUUID: UUID? = nil,
        migrationFailureInjector: (() throws -> Void)? = nil
    ) throws {
        guard sqlite3_get_autocommit(database) == 0 else {
            throw DatabaseMigrationError("Schema v3 migration requires an active transaction.")
        }
        guard try SQLiteSupport.scalarInt("PRAGMA foreign_keys", on: database) == 1 else {
            throw DatabaseMigrationError("Schema v3 migration requires foreign keys enabled.")
        }
        guard try SQLiteSupport.scalarInt("PRAGMA user_version", on: database) == 2 else {
            throw DatabaseMigrationError("v2 to v3 migration requires user_version 2.")
        }

        let existingColumns = Set(try SQLiteSupport.columnNames("assignments", on: database))
        let missing = Set(v2Columns).subtracting(existingColumns)
        guard missing.isEmpty else {
            throw DatabaseMigrationError(
                "v2 assignments table is missing columns: \(missing.sorted().joined(separator: ", "))."
            )
        }
        let reserved = Set([
            "uuid", "course_id", "project_id", "completed_at", "progress_percent",
            "all_day", "timezone_id", "deleted_at",
        ]).intersection(existingColumns)
        guard reserved.isEmpty else {
            throw DatabaseMigrationError(
                "user_version 2 contains reserved partial-v3 columns: "
                    + reserved.sorted().joined(separator: ", ")
            )
        }

        let existingTables = Set(try applicationTableNames(on: database))
        let conflicts = existingTables
            .intersection(Set(requiredColumns.keys))
            .subtracting(["assignments"])
        guard conflicts.isEmpty else {
            throw DatabaseMigrationError(
                "Partial v3 tables prevent migration: \(conflicts.sorted().joined(separator: ", "))."
            )
        }

        try ensureReservedTriggerNamesAvailable(on: database)
        let snapshot = try LegacySnapshot.capture(on: database, columns: v2Columns)
        try validateLegacyRows(snapshot.rows)
        let instanceUUID = databaseInstanceUUID ?? SharedIdentity.newUUID()
        guard instanceUUID.versionNumber == 4 else {
            throw DatabaseMigrationError("Database identity must be UUID v4.")
        }

        try createDatabaseIdentity(instanceUUID, on: database)
        try createPrimaryTables(on: database)
        let courseIDs = try migrateCourses(
            snapshot.rows,
            databaseInstanceUUID: instanceUUID,
            on: database
        )
        try addAssignmentColumns(on: database)

        let assignmentTriggers = try snapshotAssignmentTriggers(on: database)
        for trigger in assignmentTriggers {
            try SQLiteSupport.execute(
                "DROP TRIGGER \(SQLiteSupport.quoteIdentifier(trigger.name))",
                on: database
            )
        }
        try backfillAssignments(
            snapshot.rows,
            courseIDs: courseIDs,
            databaseInstanceUUID: instanceUUID,
            on: database
        )
        for trigger in assignmentTriggers {
            try SQLiteSupport.execute(trigger.sql, on: database)
        }

        try createChildTables(on: database)
        try createIndexes(on: database)
        try createContractTriggers(on: database)
        try migrationFailureInjector?()
        try SQLiteSupport.execute("PRAGMA user_version = 3", on: database)
        try verifyLegacySnapshot(
            snapshot,
            databaseInstanceUUID: instanceUUID,
            courseIDs: courseIDs,
            on: database
        )
        try validate(on: database)
    }

    static func validate(on database: OpaquePointer) throws {
        guard try SQLiteSupport.scalarInt("PRAGMA user_version", on: database) == 3 else {
            throw DatabaseMigrationError("Database user_version must be 3.")
        }
        try validateStructure(on: database)
    }

    /// Version-agnostic v3 contract check. Schema v4 calls this before checking
    /// its own additions so a v4 database still proves it kept every v3 object
    /// and value intact.
    static func validateStructure(on database: OpaquePointer) throws {
        guard try SQLiteSupport.scalarInt("PRAGMA foreign_keys", on: database) == 1 else {
            throw DatabaseMigrationError("Schema v3 validation requires foreign keys enabled.")
        }

        let existingTables = Set(try applicationTableNames(on: database))
        let missingTables = Set(requiredColumns.keys).subtracting(existingTables)
        guard missingTables.isEmpty else {
            throw DatabaseMigrationError(
                "Database v3 is missing tables: \(missingTables.sorted().joined(separator: ", "))."
            )
        }
        for (table, expected) in requiredColumns {
            let actual = Set(try SQLiteSupport.columnNames(table, on: database))
            let missing = expected.subtracting(actual)
            guard missing.isEmpty else {
                throw DatabaseMigrationError(
                    "Database v3 table \(table) is missing: \(missing.sorted().joined(separator: ", "))."
                )
            }
        }
        for index in indexes {
            try validateIndex(index, on: database)
        }
        for trigger in contractTriggers() {
            try validateTrigger(trigger, on: database)
        }
        for (table, expected) in expectedForeignKeys {
            try validateForeignKeys(expected, for: table, on: database)
        }

        guard try SQLiteSupport.scalarText("PRAGMA integrity_check", on: database) == "ok" else {
            throw DatabaseMigrationError("Database v3 integrity check failed.")
        }
        guard try SQLiteSupport.scalarInt(
            "SELECT COUNT(*) FROM pragma_foreign_key_check",
            on: database
        ) == 0 else {
            throw DatabaseMigrationError("Database v3 foreign key check failed.")
        }

        let identity = try SQLiteSupport.prepare(
            "SELECT singleton, instance_uuid, created_at FROM database_identity",
            on: database
        )
        defer { sqlite3_finalize(identity) }
        guard sqlite3_step(identity) == SQLITE_ROW,
              sqlite3_column_int64(identity, 0) == 1,
              let identityText = SQLiteSupport.text(identity, 1),
              let identityUUID = UUID(uuidString: identityText),
              identityUUID.canonicalString == identityText,
              identityUUID.versionNumber == 4,
              isCanonicalUTC(SQLiteSupport.text(identity, 2)),
              sqlite3_step(identity) == SQLITE_DONE else {
            throw DatabaseMigrationError("database_identity must contain one canonical UUID v4 row.")
        }

        try validateUUIDs(databaseInstanceUUID: identityUUID, on: database)
        try validateRows(on: database)
    }
}


// MARK: - Schema creation

// Not `private`: schema v4 reuses `auditColumns` and `uuidCheck` so its tables
// keep the exact v3 conventions instead of a second spelling of them.
extension SQLiteSchemaV3 {
    static var auditColumns: String {
        """
        created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
        updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
        deleted_at TEXT
        """
    }

    static func uuidCheck(_ column: String = "uuid", versions: [Int] = [4, 5]) -> String {
        let versionList = versions.map(String.init).map { "'\($0)'" }.joined(separator: ", ")
        return """
        length(\(column)) = 36
        AND length(replace(\(column), '-', '')) = 32
        AND \(column) = lower(\(column))
        AND substr(\(column), 9, 1) = '-'
        AND substr(\(column), 14, 1) = '-'
        AND substr(\(column), 19, 1) = '-'
        AND substr(\(column), 24, 1) = '-'
        AND substr(\(column), 15, 1) IN (\(versionList))
        AND substr(\(column), 20, 1) IN ('8', '9', 'a', 'b')
        AND replace(\(column), '-', '') NOT GLOB '*[^0-9a-f]*'
        """
    }

    static func createDatabaseIdentity(_ uuid: UUID, on database: OpaquePointer) throws {
        try SQLiteSupport.execute(
            """
            CREATE TABLE database_identity (
                singleton INTEGER NOT NULL PRIMARY KEY CHECK (singleton = 1),
                instance_uuid TEXT NOT NULL CHECK (\(uuidCheck("instance_uuid", versions: [4]))),
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            )
            """,
            on: database
        )
        let statement = try SQLiteSupport.prepare(
            "INSERT INTO database_identity (singleton, instance_uuid) VALUES (1, ?)",
            on: database
        )
        defer { sqlite3_finalize(statement) }
        SQLiteSupport.bind(uuid.canonicalString, to: statement, index: 1)
        try SQLiteSupport.checkDone(statement, on: database)
    }

    static func createPrimaryTables(on database: OpaquePointer) throws {
        try SQLiteSupport.execute(
            """
            CREATE TABLE courses (
                id INTEGER NOT NULL PRIMARY KEY,
                uuid TEXT NOT NULL CHECK (\(uuidCheck())),
                name TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 120),
                normalized_name TEXT NOT NULL CHECK (length(normalized_name) >= 1),
                color_hex TEXT CHECK (
                    color_hex IS NULL OR
                    (length(color_hex) = 7 AND substr(color_hex, 1, 1) = '#'
                     AND substr(color_hex, 2) NOT GLOB '*[^0-9A-Fa-f]*')
                ),
                teacher TEXT,
                semester TEXT,
                is_archived INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1)),
                \(auditColumns)
            )
            """,
            on: database
        )
        try SQLiteSupport.execute(
            """
            CREATE TABLE projects (
                id INTEGER NOT NULL PRIMARY KEY,
                uuid TEXT NOT NULL CHECK (\(uuidCheck(versions: [4]))),
                course_id INTEGER REFERENCES courses(id) ON DELETE SET NULL,
                name TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 255),
                description TEXT,
                status TEXT NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active', 'on_hold', 'completed', 'archived')),
                \(auditColumns)
            )
            """,
            on: database
        )
        try SQLiteSupport.execute(
            """
            CREATE TABLE tags (
                id INTEGER NOT NULL PRIMARY KEY,
                uuid TEXT NOT NULL CHECK (\(uuidCheck(versions: [4]))),
                name TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 80),
                normalized_name TEXT NOT NULL CHECK (length(normalized_name) >= 1),
                color_hex TEXT CHECK (
                    color_hex IS NULL OR
                    (length(color_hex) = 7 AND substr(color_hex, 1, 1) = '#'
                     AND substr(color_hex, 2) NOT GLOB '*[^0-9A-Fa-f]*')
                ),
                \(auditColumns)
            )
            """,
            on: database
        )
    }

    static func addAssignmentColumns(on database: OpaquePointer) throws {
        let definitions = [
            "uuid TEXT",
            "course_id INTEGER REFERENCES courses(id) ON DELETE SET NULL",
            "project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL",
            "completed_at TEXT",
            "progress_percent INTEGER NOT NULL DEFAULT 0 CHECK (progress_percent BETWEEN 0 AND 100)",
            "all_day INTEGER NOT NULL DEFAULT 0 CHECK (all_day IN (0, 1))",
            "timezone_id TEXT",
            "deleted_at TEXT",
        ]
        for definition in definitions {
            try SQLiteSupport.execute(
                "ALTER TABLE assignments ADD COLUMN \(definition)",
                on: database
            )
        }
    }

    static func createChildTables(on database: OpaquePointer) throws {
        try SQLiteSupport.execute(
            """
            CREATE TABLE task_tags (
                id INTEGER NOT NULL PRIMARY KEY,
                uuid TEXT NOT NULL CHECK (\(uuidCheck(versions: [4]))),
                assignment_id INTEGER NOT NULL REFERENCES assignments(id) ON DELETE CASCADE,
                tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                \(auditColumns)
            )
            """,
            on: database
        )
        try SQLiteSupport.execute(
            """
            CREATE TABLE subtasks (
                id INTEGER NOT NULL PRIMARY KEY,
                uuid TEXT NOT NULL CHECK (\(uuidCheck(versions: [4]))),
                assignment_id INTEGER NOT NULL REFERENCES assignments(id) ON DELETE CASCADE,
                title TEXT NOT NULL CHECK (length(trim(title)) BETWEEN 1 AND 255),
                status TEXT NOT NULL DEFAULT 'not_started'
                    CHECK (status IN ('not_started', 'in_progress', 'completed')),
                sort_order INTEGER NOT NULL DEFAULT 0 CHECK (sort_order >= 0),
                completed_at TEXT,
                \(auditColumns),
                CHECK (
                    (status = 'completed' AND completed_at IS NOT NULL)
                    OR (status != 'completed' AND completed_at IS NULL)
                )
            )
            """,
            on: database
        )
        try SQLiteSupport.execute(
            """
            CREATE TABLE attachments (
                id INTEGER NOT NULL PRIMARY KEY,
                uuid TEXT NOT NULL CHECK (\(uuidCheck(versions: [4]))),
                assignment_id INTEGER NOT NULL REFERENCES assignments(id) ON DELETE CASCADE,
                file_name TEXT NOT NULL CHECK (
                    length(file_name) BETWEEN 1 AND 255
                    AND file_name NOT IN ('.', '..')
                    AND instr(file_name, char(0)) = 0
                    AND instr(file_name, '/') = 0
                    AND instr(file_name, char(92)) = 0
                ),
                relative_path TEXT NOT NULL CHECK (
                    length(relative_path) BETWEEN 1 AND 1000
                    AND relative_path = 'attachments/' || uuid
                    AND substr(relative_path, 1, 1) != '/'
                    AND substr(relative_path, -1, 1) != '/'
                    AND instr(relative_path, char(0)) = 0
                    AND instr(relative_path, '//') = 0
                    AND instr(relative_path, char(92)) = 0
                    AND instr(relative_path, ':') = 0
                    AND relative_path != '..'
                    AND relative_path NOT LIKE '../%'
                    AND relative_path NOT LIKE '%/../%'
                    AND relative_path != '.'
                    AND relative_path NOT LIKE './%'
                    AND relative_path NOT LIKE '%/./%'
                    AND ('/' || relative_path || '/') NOT LIKE '%/./%'
                    AND ('/' || relative_path || '/') NOT LIKE '%/../%'
                ),
                mime_type TEXT,
                byte_size INTEGER NOT NULL CHECK (byte_size >= 0),
                sha256 TEXT NOT NULL CHECK (
                    length(sha256) = 64 AND sha256 = lower(sha256)
                    AND sha256 NOT GLOB '*[^0-9a-f]*'
                ),
                \(auditColumns)
            )
            """,
            on: database
        )
        try SQLiteSupport.execute(
            """
            CREATE TABLE reminders (
                id INTEGER NOT NULL PRIMARY KEY,
                uuid TEXT NOT NULL CHECK (\(uuidCheck(versions: [4]))),
                assignment_id INTEGER NOT NULL REFERENCES assignments(id) ON DELETE CASCADE,
                trigger_at_utc TEXT NOT NULL,
                lead_minutes INTEGER NOT NULL DEFAULT 0 CHECK (lead_minutes >= 0),
                repeat_rule TEXT,
                is_enabled INTEGER NOT NULL DEFAULT 1 CHECK (is_enabled IN (0, 1)),
                last_scheduled_at TEXT,
                \(auditColumns)
            )
            """,
            on: database
        )
    }
}


// MARK: - Legacy backfill and verification

private extension SQLiteSchemaV3 {
    struct LegacyRow: Equatable {
        let id: Int64
        let values: [String?]

        func value(_ column: String) -> String? {
            guard let index = v2Columns.firstIndex(of: column) else { return nil }
            return values[index]
        }
    }

    struct SchemaObject: Equatable {
        let type: String
        let name: String
        let table: String
        let sql: String
    }

    struct LegacySnapshot {
        let v2Rows: [LegacyRow]
        let allColumns: [String]
        let quotedRows: [[String]]
        let objects: [SchemaObject]

        var rows: [LegacyRow] { v2Rows }

        static func capture(on database: OpaquePointer, columns: [String]) throws -> Self {
            let allColumns = try SQLiteSupport.columnNames("assignments", on: database)
            let v2Rows = try readLegacyRows(columns: columns, on: database)
            let quotedRows = try readQuotedRows(columns: allColumns, on: database)
            let objects = try readSchemaObjects(on: database)
            return .init(
                v2Rows: v2Rows,
                allColumns: allColumns,
                quotedRows: quotedRows,
                objects: objects
            )
        }
    }

    struct TriggerSnapshot {
        let name: String
        let sql: String
    }

    static func readLegacyRows(
        columns: [String],
        on database: OpaquePointer
    ) throws -> [LegacyRow] {
        let select = columns.map(SQLiteSupport.quoteIdentifier).joined(separator: ", ")
        let statement = try SQLiteSupport.prepare(
            "SELECT \(select) FROM assignments ORDER BY id",
            on: database
        )
        defer { sqlite3_finalize(statement) }
        var rows: [LegacyRow] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let values = columns.indices.map { index in
                SQLiteSupport.text(statement, Int32(index))
            }
            rows.append(.init(id: sqlite3_column_int64(statement, 0), values: values))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw DatabaseMigrationError(String(cString: sqlite3_errmsg(database)))
        }
        return rows
    }

    static func readQuotedRows(
        columns: [String],
        on database: OpaquePointer
    ) throws -> [[String]] {
        let select = columns.map { "quote(\(SQLiteSupport.quoteIdentifier($0)))" }
            .joined(separator: ", ")
        let statement = try SQLiteSupport.prepare(
            "SELECT \(select) FROM assignments ORDER BY id",
            on: database
        )
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            rows.append(columns.indices.map {
                SQLiteSupport.text(statement, Int32($0)) ?? "NULL"
            })
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw DatabaseMigrationError(String(cString: sqlite3_errmsg(database)))
        }
        return rows
    }

    static func readSchemaObjects(on database: OpaquePointer) throws -> [SchemaObject] {
        let statement = try SQLiteSupport.prepare(
            """
            SELECT type, name, tbl_name, sql FROM sqlite_master
            WHERE tbl_name = 'assignments'
              AND type IN ('index', 'trigger') AND sql IS NOT NULL
            ORDER BY type, name
            """,
            on: database
        )
        defer { sqlite3_finalize(statement) }
        var result: [SchemaObject] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            guard let type = SQLiteSupport.text(statement, 0),
                  let name = SQLiteSupport.text(statement, 1),
                  let table = SQLiteSupport.text(statement, 2),
                  let sql = SQLiteSupport.text(statement, 3) else {
                throw DatabaseMigrationError("Invalid legacy assignment schema object.")
            }
            result.append(.init(type: type, name: name, table: table, sql: sql))
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else {
            throw DatabaseMigrationError(String(cString: sqlite3_errmsg(database)))
        }
        return result
    }

    static func validateLegacyRows(_ rows: [LegacyRow]) throws {
        var ids = Set<Int64>()
        for row in rows {
            guard row.id > 0, ids.insert(row.id).inserted else {
                throw DatabaseMigrationError("Legacy assignment IDs must be unique and positive.")
            }
            guard let course = row.value("course_name"),
                  let title = row.value("title"),
                  !course.isEmpty,
                  !title.isEmpty else {
                throw DatabaseMigrationError("Legacy course_name and title must be non-null.")
            }
            guard let status = row.value("status"),
                  ["not_started", "in_progress", "completed"].contains(status) else {
                throw DatabaseMigrationError(
                    "Unsupported legacy status: \(row.value("status") ?? "NULL")."
                )
            }
            guard let priority = row.value("priority"),
                  ["low", "medium", "high"].contains(priority) else {
                throw DatabaseMigrationError(
                    "Unsupported legacy priority: \(row.value("priority") ?? "NULL")."
                )
            }
        }
    }

    static func migrateCourses(
        _ rows: [LegacyRow],
        databaseInstanceUUID: UUID,
        on database: OpaquePointer
    ) throws -> [String: Int64] {
        var earliest: [String: LegacyRow] = [:]
        for row in rows {
            guard let displayName = row.value("course_name"),
                  !SharedIdentity.canonicalName(displayName).isEmpty else {
                continue
            }
            if earliest[displayName] == nil || row.id < earliest[displayName]!.id {
                earliest[displayName] = row
            }
        }

        let sortedNames = earliest.keys.sorted {
            Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8))
        }
        var ids: [String: Int64] = [:]
        for name in sortedNames {
            guard let row = earliest[name] else { continue }
            let uuid = try SharedIdentity.deterministicUUID(
                databaseInstanceUUID: databaseInstanceUUID,
                entity: "course",
                legacyKey: name
            )
            let statement = try SQLiteSupport.prepare(
                """
                INSERT INTO courses (uuid, name, normalized_name, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                on: database
            )
            SQLiteSupport.bind(uuid.canonicalString, to: statement, index: 1)
            SQLiteSupport.bind(name, to: statement, index: 2)
            SQLiteSupport.bind(SharedIdentity.canonicalName(name), to: statement, index: 3)
            SQLiteSupport.bind(row.value("created_at"), to: statement, index: 4)
            SQLiteSupport.bind(row.value("updated_at"), to: statement, index: 5)
            do {
                try SQLiteSupport.checkDone(statement, on: database)
            } catch {
                sqlite3_finalize(statement)
                throw error
            }
            sqlite3_finalize(statement)
            ids[name] = sqlite3_last_insert_rowid(database)
        }
        return ids
    }

    static func backfillAssignments(
        _ rows: [LegacyRow],
        courseIDs: [String: Int64],
        databaseInstanceUUID: UUID,
        on database: OpaquePointer
    ) throws {
        let statement = try SQLiteSupport.prepare(
            """
            UPDATE assignments
            SET uuid = ?, course_id = ?, project_id = NULL,
                completed_at = ?, progress_percent = ?, all_day = 0,
                timezone_id = NULL, deleted_at = NULL
            WHERE id = ?
            """,
            on: database
        )
        defer { sqlite3_finalize(statement) }

        for row in rows {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            let uuid = try SharedIdentity.deterministicUUID(
                databaseInstanceUUID: databaseInstanceUUID,
                entity: "task",
                legacyKey: String(row.id)
            )
            let completed = row.value("status") == "completed"
            SQLiteSupport.bind(uuid.canonicalString, to: statement, index: 1)
            SQLiteSupport.bind(
                row.value("course_name").flatMap { courseIDs[$0] },
                to: statement,
                index: 2
            )
            SQLiteSupport.bind(completed ? row.value("updated_at") : nil, to: statement, index: 3)
            sqlite3_bind_int(statement, 4, completed ? 100 : 0)
            sqlite3_bind_int64(statement, 5, row.id)
            try SQLiteSupport.checkDone(statement, on: database)
            guard sqlite3_changes(database) == 1 else {
                throw DatabaseMigrationError("Assignment \(row.id) was not backfilled exactly once.")
            }
        }
    }

    static func verifyLegacySnapshot(
        _ snapshot: LegacySnapshot,
        databaseInstanceUUID: UUID,
        courseIDs: [String: Int64],
        on database: OpaquePointer
    ) throws {
        guard try readLegacyRows(columns: v2Columns, on: database) == snapshot.v2Rows,
              try readQuotedRows(columns: snapshot.allColumns, on: database) == snapshot.quotedRows else {
            throw DatabaseMigrationError("Existing assignment values changed during v3 migration.")
        }

        let currentObjects = try readSchemaObjects(on: database)
        for original in snapshot.objects {
            guard currentObjects.contains(original) else {
                throw DatabaseMigrationError(
                    "Existing assignment index or trigger changed: \(original.name)."
                )
            }
        }

        let statement = try SQLiteSupport.prepare(
            """
            SELECT uuid, course_id, project_id, completed_at, progress_percent,
                   all_day, timezone_id, deleted_at
            FROM assignments WHERE id = ?
            """,
            on: database
        )
        defer { sqlite3_finalize(statement) }
        for row in snapshot.rows {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_int64(statement, 1, row.id)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw DatabaseMigrationError("Migrated assignment \(row.id) is missing.")
            }
            let expectedUUID = try SharedIdentity.deterministicUUID(
                databaseInstanceUUID: databaseInstanceUUID,
                entity: "task",
                legacyKey: String(row.id)
            ).canonicalString
            let completed = row.value("status") == "completed"
            guard SQLiteSupport.text(statement, 0) == expectedUUID,
                  SQLiteSupport.int64(statement, 1)
                    == row.value("course_name").flatMap({ courseIDs[$0] }),
                  SQLiteSupport.int64(statement, 2) == nil,
                  SQLiteSupport.text(statement, 3)
                    == (completed ? row.value("updated_at") : nil),
                  sqlite3_column_int(statement, 4) == (completed ? 100 : 0),
                  sqlite3_column_int(statement, 5) == 0,
                  SQLiteSupport.text(statement, 6) == nil,
                  SQLiteSupport.text(statement, 7) == nil else {
                throw DatabaseMigrationError("Assignment \(row.id) has invalid v3 backfill fields.")
            }
        }

        for table in ["projects", "tags", "task_tags", "subtasks", "attachments", "reminders"] {
            guard try SQLiteSupport.scalarInt("SELECT COUNT(*) FROM \(table)", on: database) == 0 else {
                throw DatabaseMigrationError("Migration unexpectedly synthesized \(table) rows.")
            }
        }
    }

    static func snapshotAssignmentTriggers(on database: OpaquePointer) throws -> [TriggerSnapshot] {
        let statement = try SQLiteSupport.prepare(
            """
            SELECT name, sql FROM sqlite_master
            WHERE type = 'trigger' AND tbl_name = 'assignments' AND sql IS NOT NULL
            ORDER BY name
            """,
            on: database
        )
        defer { sqlite3_finalize(statement) }
        var triggers: [TriggerSnapshot] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let name = SQLiteSupport.text(statement, 0),
                  let sql = SQLiteSupport.text(statement, 1) else {
                throw DatabaseMigrationError("Invalid assignment trigger metadata.")
            }
            triggers.append(.init(name: name, sql: sql))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw DatabaseMigrationError(String(cString: sqlite3_errmsg(database)))
        }
        return triggers
    }
}


// MARK: - Index and trigger contract

// Not `private`: schema v4 validates its own indexes and triggers through the
// same contract types, so a v4 database is checked with identical rules.
extension SQLiteSchemaV3 {
    struct ForeignKeyContract: Hashable {
        let from: String
        let table: String
        let to: String
        let onDelete: String
        let onUpdate: String
        let match: String

        init(
            from: String,
            table: String,
            to: String,
            onDelete: String,
            onUpdate: String = "NO ACTION",
            match: String = "NONE"
        ) {
            self.from = from
            self.table = table
            self.to = to
            self.onDelete = onDelete
            self.onUpdate = onUpdate
            self.match = match
        }

        var description: String {
            "\(from)->\(table).\(to) ON UPDATE \(onUpdate) "
                + "ON DELETE \(onDelete) MATCH \(match)"
        }
    }

    struct IndexContract {
        let name: String
        let table: String
        let columns: [String]
        let unique: Bool
        let predicate: String?

        init(
            _ name: String,
            _ table: String,
            _ columns: [String],
            unique: Bool = false,
            predicate: String? = nil
        ) {
            self.name = name
            self.table = table
            self.columns = columns
            self.unique = unique
            self.predicate = predicate
        }

        var createSQL: String {
            let uniqueness = unique ? "UNIQUE " : ""
            let columnList = columns.joined(separator: ", ")
            let whereClause = predicate.map { " WHERE \($0)" } ?? ""
            return "CREATE \(uniqueness)INDEX \(name) ON \(table)(\(columnList))\(whereClause)"
        }
    }

    struct TriggerContract {
        let name: String
        let table: String
        let sql: String
    }

    static func createIndexes(on database: OpaquePointer) throws {
        for index in indexes {
            let statement = try SQLiteSupport.prepare(
                "SELECT type FROM sqlite_master WHERE name = ?",
                on: database
            )
            SQLiteSupport.bind(index.name, to: statement, index: 1)
            let exists = sqlite3_step(statement) == SQLITE_ROW
            sqlite3_finalize(statement)
            if exists {
                try validateIndex(index, on: database)
            } else {
                try SQLiteSupport.execute(index.createSQL, on: database)
            }
        }
    }

    static func validateForeignKeys(
        _ expected: Set<ForeignKeyContract>,
        for table: String,
        on database: OpaquePointer
    ) throws {
        let statement = try SQLiteSupport.prepare(
            "PRAGMA foreign_key_list(\(SQLiteSupport.quoteIdentifier(table)))",
            on: database
        )
        defer { sqlite3_finalize(statement) }
        var actual = Set<ForeignKeyContract>()
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let referencedTable = SQLiteSupport.text(statement, 2),
                  let from = SQLiteSupport.text(statement, 3),
                  let to = SQLiteSupport.text(statement, 4),
                  let onUpdate = SQLiteSupport.text(statement, 5),
                  let onDelete = SQLiteSupport.text(statement, 6),
                  let match = SQLiteSupport.text(statement, 7) else {
                throw DatabaseMigrationError(
                    "Database v3 table \(table) has invalid foreign key metadata."
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
        let isExtensibleLegacyTable = table == "assignments"
        let valid = isExtensibleLegacyTable
            ? expected.isSubset(of: actual)
            : actual == expected
        guard valid else {
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
                "Database v3 table \(table) has invalid foreign keys: \(details)."
            )
        }
    }

    static func validateIndex(_ contract: IndexContract, on database: OpaquePointer) throws {
        let statement = try SQLiteSupport.prepare(
            "SELECT type, tbl_name, sql FROM sqlite_master WHERE name = ?",
            on: database
        )
        SQLiteSupport.bind(contract.name, to: statement, index: 1)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              SQLiteSupport.text(statement, 0) == "index",
              SQLiteSupport.text(statement, 1) == contract.table else {
            throw DatabaseMigrationError("Database v3 index \(contract.name) has the wrong owner.")
        }
        let storedSQL = SQLiteSupport.text(statement, 2) ?? ""
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseMigrationError("Database v3 index \(contract.name) metadata is invalid.")
        }

        let info = try SQLiteSupport.prepare(
            "PRAGMA index_info(\(SQLiteSupport.quoteIdentifier(contract.name)))",
            on: database
        )
        defer { sqlite3_finalize(info) }
        var columns: [String] = []
        var result = sqlite3_step(info)
        while result == SQLITE_ROW {
            if let value = SQLiteSupport.text(info, 2) { columns.append(value) }
            result = sqlite3_step(info)
        }
        guard result == SQLITE_DONE, columns == contract.columns else {
            throw DatabaseMigrationError("Database v3 index \(contract.name) has wrong columns.")
        }

        let xinfo = try SQLiteSupport.prepare(
            "PRAGMA index_xinfo(\(SQLiteSupport.quoteIdentifier(contract.name)))",
            on: database
        )
        defer { sqlite3_finalize(xinfo) }
        var keyColumns: [(sequence: Int, name: String, descending: Bool, collation: String)] = []
        var xinfoResult = sqlite3_step(xinfo)
        while xinfoResult == SQLITE_ROW {
            let isKey = sqlite3_column_int(xinfo, 5) == 1
            if isKey {
                guard let name = SQLiteSupport.text(xinfo, 2),
                      let collation = SQLiteSupport.text(xinfo, 4) else {
                    throw DatabaseMigrationError(
                        "Database v3 index \(contract.name) has unreadable key metadata."
                    )
                }
                keyColumns.append(
                    (
                        sequence: Int(sqlite3_column_int(xinfo, 0)),
                        name: name,
                        descending: sqlite3_column_int(xinfo, 3) == 1,
                        collation: collation.uppercased()
                    )
                )
            }
            xinfoResult = sqlite3_step(xinfo)
        }
        guard xinfoResult == SQLITE_DONE,
              keyColumns.map(\.sequence) == Array(contract.columns.indices),
              keyColumns.map(\.name) == contract.columns,
              keyColumns.allSatisfy({ !$0.descending && $0.collation == "BINARY" }) else {
            throw DatabaseMigrationError(
                "Database v3 index \(contract.name) has invalid order or collation metadata."
            )
        }

        let list = try SQLiteSupport.prepare(
            "PRAGMA index_list(\(SQLiteSupport.quoteIdentifier(contract.table)))",
            on: database
        )
        defer { sqlite3_finalize(list) }
        var found: (unique: Bool, partial: Bool)?
        var listResult = sqlite3_step(list)
        while listResult == SQLITE_ROW {
            if SQLiteSupport.text(list, 1) == contract.name {
                found = (sqlite3_column_int(list, 2) == 1, sqlite3_column_int(list, 4) == 1)
            }
            listResult = sqlite3_step(list)
        }
        guard listResult == SQLITE_DONE,
              let found,
              found.unique == contract.unique,
              found.partial == (contract.predicate != nil) else {
            throw DatabaseMigrationError("Database v3 index \(contract.name) flags are invalid.")
        }
        if let predicate = contract.predicate {
            let normalized = normalizeSQL(storedSQL).lowercased()
            let marker = " where "
            guard let whereRange = normalized.range(of: marker),
                  normalized.range(
                      of: marker,
                      range: whereRange.upperBound..<normalized.endIndex
                  ) == nil,
                  String(normalized[whereRange.upperBound...])
                    == normalizeSQL(predicate).lowercased() else {
                throw DatabaseMigrationError("Database v3 index \(contract.name) predicate is invalid.")
            }
        } else if normalizeSQL(storedSQL).lowercased().contains(" where ") {
            throw DatabaseMigrationError(
                "Database v3 index \(contract.name) has an unexpected predicate."
            )
        }
    }

    static func contractTriggers() -> [TriggerContract] {
        let uuidValid = uuidCheck("NEW.uuid")
        let invalidProgress = """
        NEW.status IS NULL
        OR NEW.priority IS NULL
        OR NEW.status NOT IN ('not_started', 'in_progress', 'completed')
        OR NEW.priority NOT IN ('low', 'medium', 'high')
        OR NEW.progress_percent NOT BETWEEN 0 AND 100
        OR NEW.all_day NOT IN (0, 1)
        OR (NEW.all_day = 1 AND NEW.due_date IS NULL)
        OR (NEW.status = 'completed' AND
            (NEW.progress_percent != 100 OR NEW.completed_at IS NULL))
        OR (NEW.status != 'completed' AND
            (NEW.progress_percent = 100 OR NEW.completed_at IS NOT NULL))
        """
        var result = [
            TriggerContract(
                name: "assignments_v3_contract_insert",
                table: "assignments",
                sql: """
                CREATE TRIGGER assignments_v3_contract_insert
                BEFORE INSERT ON assignments
                WHEN NEW.uuid IS NULL OR NOT (\(uuidValid)) OR (\(invalidProgress))
                BEGIN
                    SELECT RAISE(ABORT, 'assignment violates schema v3 contract');
                END
                """
            ),
            TriggerContract(
                name: "assignments_v3_contract_update",
                table: "assignments",
                sql: """
                CREATE TRIGGER assignments_v3_contract_update
                BEFORE UPDATE ON assignments
                WHEN NEW.uuid IS NULL OR NOT (\(uuidValid)) OR (\(invalidProgress))
                BEGIN
                    SELECT RAISE(ABORT, 'assignment violates schema v3 contract');
                END
                """
            ),
            TriggerContract(
                name: "database_identity_immutable_update",
                table: "database_identity",
                sql: """
                CREATE TRIGGER database_identity_immutable_update
                BEFORE UPDATE ON database_identity
                BEGIN
                    SELECT RAISE(ABORT, 'database identity is immutable');
                END
                """
            ),
            TriggerContract(
                name: "database_identity_immutable_delete",
                table: "database_identity",
                sql: """
                CREATE TRIGGER database_identity_immutable_delete
                BEFORE DELETE ON database_identity
                BEGIN
                    SELECT RAISE(ABORT, 'database identity is immutable');
                END
                """
            ),
        ]
        result.append(contentsOf: immutableUUIDTables.map { table in
            let name = "\(table)_uuid_immutable"
            return TriggerContract(
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
        })
        return result
    }

    static func ensureReservedTriggerNamesAvailable(on database: OpaquePointer) throws {
        for trigger in contractTriggers() {
            let statement = try SQLiteSupport.prepare(
                "SELECT type, tbl_name FROM sqlite_master WHERE name = ?",
                on: database
            )
            SQLiteSupport.bind(trigger.name, to: statement, index: 1)
            let conflict = sqlite3_step(statement) == SQLITE_ROW
            sqlite3_finalize(statement)
            guard !conflict else {
                throw DatabaseMigrationError(
                    "Reserved v3 trigger name is already used: \(trigger.name)."
                )
            }
        }
    }

    static func createContractTriggers(on database: OpaquePointer) throws {
        try ensureReservedTriggerNamesAvailable(on: database)
        for trigger in contractTriggers() {
            try SQLiteSupport.execute(trigger.sql, on: database)
        }
    }

    static func validateTrigger(_ contract: TriggerContract, on database: OpaquePointer) throws {
        let statement = try SQLiteSupport.prepare(
            "SELECT tbl_name, sql FROM sqlite_master WHERE type = 'trigger' AND name = ?",
            on: database
        )
        SQLiteSupport.bind(contract.name, to: statement, index: 1)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              SQLiteSupport.text(statement, 0) == contract.table,
              normalizeSQL(SQLiteSupport.text(statement, 1) ?? "")
                == normalizeSQL(contract.sql) else {
            throw DatabaseMigrationError("Database v3 trigger \(contract.name) is invalid.")
        }
    }

    static func normalizeSQL(_ sql: String) -> String {
        sql.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
    }
}


// MARK: - Data contract validation

private extension SQLiteSchemaV3 {
    static func applicationTableNames(on database: OpaquePointer) throws -> [String] {
        let statement = try SQLiteSupport.prepare(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
            on: database
        )
        defer { sqlite3_finalize(statement) }
        var names: [String] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let name = SQLiteSupport.text(statement, 0) { names.append(name) }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw DatabaseMigrationError(String(cString: sqlite3_errmsg(database)))
        }
        return names
    }

    static func validateUUIDs(
        databaseInstanceUUID: UUID,
        on database: OpaquePointer
    ) throws {
        for table in requiredColumns.keys where table != "database_identity" {
            let statement = try SQLiteSupport.prepare("SELECT id, uuid FROM \(table)", on: database)
            defer { sqlite3_finalize(statement) }
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                let rowID = sqlite3_column_int64(statement, 0)
                guard let text = SQLiteSupport.text(statement, 1),
                      let uuid = UUID(uuidString: text),
                      uuid.canonicalString == text,
                      [4, 5].contains(uuid.versionNumber) else {
                    throw DatabaseMigrationError("\(table) row \(rowID) has an invalid UUID.")
                }
                if table != "assignments" && table != "courses" && uuid.versionNumber != 4 {
                    throw DatabaseMigrationError("\(table) row \(rowID) must use UUID v4.")
                }
                if table == "assignments", uuid.versionNumber == 5 {
                    let expected = try SharedIdentity.deterministicUUID(
                        databaseInstanceUUID: databaseInstanceUUID,
                        entity: "task",
                        legacyKey: String(rowID)
                    )
                    guard expected == uuid else {
                        throw DatabaseMigrationError(
                            "Assignment \(rowID) UUID does not match database lineage."
                        )
                    }
                }
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else {
                throw DatabaseMigrationError(String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    static func validateRows(on database: OpaquePointer) throws {
        let invalidTask = try SQLiteSupport.scalarInt(
            """
            SELECT COUNT(*) FROM assignments
            WHERE status IS NULL
               OR priority IS NULL
               OR status NOT IN ('not_started', 'in_progress', 'completed')
               OR priority NOT IN ('low', 'medium', 'high')
               OR progress_percent NOT BETWEEN 0 AND 100
               OR all_day NOT IN (0, 1)
               OR (all_day = 1 AND due_date IS NULL)
               OR (status = 'completed' AND
                   (progress_percent != 100 OR completed_at IS NULL))
               OR (status != 'completed' AND
                   (progress_percent = 100 OR completed_at IS NOT NULL))
            """,
            on: database
        )
        guard invalidTask == 0 else {
            throw DatabaseMigrationError("An assignment violates v3 progress semantics.")
        }

        let invalidOrganizationRow = try SQLiteSupport.scalarInt(
            """
            SELECT COUNT(*) FROM (
                SELECT id FROM courses
                WHERE is_archived IS NULL OR is_archived NOT IN (0, 1)
                UNION ALL
                SELECT id FROM projects
                WHERE status IS NULL
                   OR status NOT IN ('active', 'on_hold', 'completed', 'archived')
                UNION ALL
                SELECT id FROM subtasks
                WHERE status IS NULL
                   OR status NOT IN ('not_started', 'in_progress', 'completed')
                   OR sort_order IS NULL OR sort_order < 0
                   OR (status = 'completed' AND completed_at IS NULL)
                   OR (status != 'completed' AND completed_at IS NOT NULL)
                UNION ALL
                SELECT id FROM reminders
                WHERE lead_minutes IS NULL OR lead_minutes < 0
                   OR is_enabled IS NULL OR is_enabled NOT IN (0, 1)
                UNION ALL
                SELECT id FROM attachments
                WHERE byte_size IS NULL OR byte_size < 0
            )
            """,
            on: database
        )
        guard invalidOrganizationRow == 0 else {
            throw DatabaseMigrationError("An organization row violates the v3 contract.")
        }

        let staleCourseSnapshots = try SQLiteSupport.scalarInt(
            """
            SELECT COUNT(*) FROM assignments AS a
            JOIN courses AS c ON c.id = a.course_id
            WHERE a.course_name IS NULL OR a.course_name != c.name
            """,
            on: database
        )
        guard staleCourseSnapshots == 0 else {
            throw DatabaseMigrationError("An assignment has a stale course snapshot.")
        }

        let mismatchedProjectCourses = try SQLiteSupport.scalarInt(
            """
            SELECT COUNT(*) FROM assignments AS a
            JOIN projects AS p ON p.id = a.project_id
            WHERE p.course_id IS NOT NULL
              AND (a.course_id IS NULL OR a.course_id != p.course_id)
            """,
            on: database
        )
        guard mismatchedProjectCourses == 0 else {
            throw DatabaseMigrationError(
                "An assignment and its project disagree on course."
            )
        }

        let inconsistentSubtaskParents = try SQLiteSupport.scalarInt(
            """
            SELECT COUNT(*) FROM (
                SELECT a.id
                FROM assignments AS a
                JOIN subtasks AS s
                  ON s.assignment_id = a.id AND s.deleted_at IS NULL
                GROUP BY a.id, a.status, a.progress_percent
                HAVING a.progress_percent !=
                           CAST(SUM(CASE WHEN s.status = 'completed' THEN 1 ELSE 0 END)
                                * 100 / COUNT(s.id) AS INTEGER)
                    OR a.status != CASE
                        WHEN SUM(CASE WHEN s.status = 'completed' THEN 1 ELSE 0 END)
                             = COUNT(s.id) THEN 'completed'
                        WHEN SUM(CASE WHEN s.status = 'completed' THEN 1 ELSE 0 END) > 0
                          OR SUM(CASE WHEN s.status = 'in_progress' THEN 1 ELSE 0 END) > 0
                            THEN 'in_progress'
                        ELSE 'not_started'
                    END
            )
            """,
            on: database
        )
        guard inconsistentSubtaskParents == 0 else {
            throw DatabaseMigrationError(
                "An assignment does not match its active subtask state."
            )
        }

        for table in requiredColumns.keys where table != "database_identity" {
            let statement = try SQLiteSupport.prepare(
                "SELECT id, uuid, created_at, updated_at, deleted_at FROM \(table)",
                on: database
            )
            defer { sqlite3_finalize(statement) }
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                let rowID = sqlite3_column_int64(statement, 0)
                guard let uuidText = SQLiteSupport.text(statement, 1),
                      let uuid = UUID(uuidString: uuidText) else {
                    throw DatabaseMigrationError("\(table) row \(rowID) has an invalid UUID.")
                }
                if uuid.versionNumber == 4 {
                    guard isCanonicalUTC(SQLiteSupport.text(statement, 2)),
                          isCanonicalUTC(SQLiteSupport.text(statement, 3)) else {
                        throw DatabaseMigrationError(
                            "\(table) row \(rowID) has a noncanonical audit timestamp."
                        )
                    }
                }
                if SQLiteSupport.text(statement, 4) != nil,
                   !isCanonicalUTC(SQLiteSupport.text(statement, 4)) {
                    throw DatabaseMigrationError(
                        "\(table) row \(rowID) has a noncanonical deleted_at timestamp."
                    )
                }
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else {
                throw DatabaseMigrationError(String(cString: sqlite3_errmsg(database)))
            }
        }

        let names = try SQLiteSupport.prepare(
            """
            SELECT 'courses', id, name, normalized_name FROM courses
            UNION ALL
            SELECT 'tags', id, name, normalized_name FROM tags
            """,
            on: database
        )
        defer { sqlite3_finalize(names) }
        var nameResult = sqlite3_step(names)
        while nameResult == SQLITE_ROW {
            guard let table = SQLiteSupport.text(names, 0),
                  let name = SQLiteSupport.text(names, 2),
                  let normalized = SQLiteSupport.text(names, 3),
                  SharedIdentity.canonicalName(name) == normalized else {
                throw DatabaseMigrationError("A course or tag has invalid normalized_name.")
            }
            _ = table
            nameResult = sqlite3_step(names)
        }
        guard nameResult == SQLITE_DONE else {
            throw DatabaseMigrationError(String(cString: sqlite3_errmsg(database)))
        }

        let completionDates = try SQLiteSupport.prepare(
            """
            SELECT 'assignments', id, uuid, completed_at FROM assignments
            WHERE completed_at IS NOT NULL
            UNION ALL
            SELECT 'subtasks', id, uuid, completed_at FROM subtasks
            WHERE completed_at IS NOT NULL
            """,
            on: database
        )
        defer { sqlite3_finalize(completionDates) }
        var completionResult = sqlite3_step(completionDates)
        while completionResult == SQLITE_ROW {
            let table = SQLiteSupport.text(completionDates, 0) ?? "row"
            let id = sqlite3_column_int64(completionDates, 1)
            guard let uuidText = SQLiteSupport.text(completionDates, 2),
                  let uuid = UUID(uuidString: uuidText) else {
                throw DatabaseMigrationError(
                    "\(table) row \(id) has an invalid UUID."
                )
            }
            guard uuid.versionNumber != 4 ||
                    isCanonicalUTC(SQLiteSupport.text(completionDates, 3)) else {
                throw DatabaseMigrationError(
                    "\(table) row \(id) has a noncanonical completed_at timestamp."
                )
            }
            completionResult = sqlite3_step(completionDates)
        }
        guard completionResult == SQLITE_DONE else {
            throw DatabaseMigrationError(String(cString: sqlite3_errmsg(database)))
        }

        let attachmentColumns = try SQLiteSupport.prepare(
            "PRAGMA table_xinfo(attachments)",
            on: database
        )
        defer { sqlite3_finalize(attachmentColumns) }
        var attachmentColumnResult = sqlite3_step(attachmentColumns)
        while attachmentColumnResult == SQLITE_ROW {
            let declaredType = SQLiteSupport.text(attachmentColumns, 2)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased() ?? ""
            guard !declaredType.isEmpty, !declaredType.contains("BLOB") else {
                throw DatabaseMigrationError(
                    "Attachments must store metadata only, never BLOB-affinity columns."
                )
            }
            attachmentColumnResult = sqlite3_step(attachmentColumns)
        }
        guard attachmentColumnResult == SQLITE_DONE else {
            throw DatabaseMigrationError(String(cString: sqlite3_errmsg(database)))
        }

        let attachments = try SQLiteSupport.prepare(
            "SELECT id, uuid, file_name, relative_path, sha256 FROM attachments",
            on: database
        )
        defer { sqlite3_finalize(attachments) }
        var attachmentResult = sqlite3_step(attachments)
        while attachmentResult == SQLITE_ROW {
            let id = sqlite3_column_int64(attachments, 0)
            guard let uuidText = SQLiteSupport.text(attachments, 1),
                  let uuid = UUID(uuidString: uuidText) else {
                throw DatabaseMigrationError("Attachment \(id) has an invalid UUID.")
            }
            let expectedPath = try SharedIdentity.attachmentRelativePath(for: uuid)
            guard
                  let fileName = SQLiteSupport.text(attachments, 2),
                  !fileName.isEmpty,
                  fileName != ".",
                  fileName != "..",
                  fileName.count <= 255,
                  !fileName.contains("/"),
                  !fileName.contains("\\"),
                  !fileName.contains("\0"),
                  let path = SQLiteSupport.text(attachments, 3),
                  path == expectedPath,
                  let sha256 = SQLiteSupport.text(attachments, 4),
                  sha256.range(
                    of: "^[0-9a-f]{64}$",
                    options: .regularExpression
                  ) != nil else {
                throw DatabaseMigrationError("Attachment \(id) has unsafe metadata.")
            }
            attachmentResult = sqlite3_step(attachments)
        }
        guard attachmentResult == SQLITE_DONE else {
            throw DatabaseMigrationError(String(cString: sqlite3_errmsg(database)))
        }

        let reminders = try SQLiteSupport.prepare(
            "SELECT id, trigger_at_utc, last_scheduled_at, repeat_rule FROM reminders",
            on: database
        )
        defer { sqlite3_finalize(reminders) }
        var reminderResult = sqlite3_step(reminders)
        while reminderResult == SQLITE_ROW {
            let id = sqlite3_column_int64(reminders, 0)
            guard isCanonicalUTC(SQLiteSupport.text(reminders, 1)),
                  SQLiteSupport.text(reminders, 2) == nil
                    || isCanonicalUTC(SQLiteSupport.text(reminders, 2)) else {
                throw DatabaseMigrationError("Reminder \(id) has a noncanonical UTC timestamp.")
            }
            let storedRepeatRule = SQLiteSupport.text(reminders, 3)
            do {
                guard try SQLiteOrganizationRepository.canonicalRepeatRule(storedRepeatRule)
                        == storedRepeatRule else {
                    throw DatabaseMigrationError(
                        "Reminder \(id) repeat_rule is not stored canonically."
                    )
                }
            } catch let error as DatabaseMigrationError {
                throw error
            } catch {
                throw DatabaseMigrationError("Reminder \(id) has an invalid repeat_rule.")
            }
            reminderResult = sqlite3_step(reminders)
        }
        guard reminderResult == SQLITE_DONE else {
            throw DatabaseMigrationError(String(cString: sqlite3_errmsg(database)))
        }

        let zones = try SQLiteSupport.prepare(
            "SELECT id, timezone_id FROM assignments WHERE timezone_id IS NOT NULL",
            on: database
        )
        defer { sqlite3_finalize(zones) }
        var zoneResult = sqlite3_step(zones)
        while zoneResult == SQLITE_ROW {
            let id = sqlite3_column_int64(zones, 0)
            guard let value = SQLiteSupport.text(zones, 1),
                  value.range(
                    of: "^(UTC|[A-Za-z_+\\-]+(/[A-Za-z0-9_+\\-.]+)+)$",
                    options: .regularExpression
                  ) != nil,
                  value == "UTC" || TimeZone(identifier: value) != nil else {
                throw DatabaseMigrationError("Assignment \(id) has an invalid timezone_id.")
            }
            zoneResult = sqlite3_step(zones)
        }
        guard zoneResult == SQLITE_DONE else {
            throw DatabaseMigrationError(String(cString: sqlite3_errmsg(database)))
        }
    }

    static func isCanonicalUTC(_ value: String?) -> Bool {
        guard let value,
              value.range(
                of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,6})?Z$",
                options: .regularExpression
              ) != nil else {
            return false
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) != nil
            || ISO8601DateFormatter().date(from: value) != nil
    }
}
