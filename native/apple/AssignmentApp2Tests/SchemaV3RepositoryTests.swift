import Foundation
import SQLite3
import Testing
@testable import AssignmentApp2


private final class V3TemporaryDatabase {
    let directoryURL: URL
    let databaseURL: URL

    init(fileName: String = "assignments.db") throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssignmentApp2V3Tests-\(UUID().uuidString)", isDirectory: true)
        databaseURL = directoryURL.appendingPathComponent(fileName)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}


private func v3WithSQLite<T>(
    at url: URL,
    flags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
    _ body: (OpaquePointer) throws -> T
) throws -> T {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK,
          let database else {
        throw OrganizationRepositoryError.corruptData("Could not open temporary SQLite database.")
    }
    defer { sqlite3_close(database) }
    return try body(database)
}


private func createV2Fixture(at url: URL) throws {
    try v3WithSQLite(at: url) { database in
        try SQLiteSupport.execute(
            """
            PRAGMA journal_mode = WAL;
            CREATE TABLE assignments (
                id INTEGER NOT NULL PRIMARY KEY,
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
                CHECK (status IN ('not_started', 'in_progress', 'completed')),
                CHECK (priority IN ('low', 'medium', 'high'))
            );
            CREATE INDEX ix_assignments_due_date ON assignments(due_date);
            CREATE INDEX ix_assignments_status ON assignments(status);
            CREATE INDEX ix_assignments_priority ON assignments(priority);
            INSERT INTO assignments VALUES (
                1, 'Physics', 'Wave lab', '2026-11-01 01:30:00',
                'Ambiguous DST wall time stays byte-for-byte unchanged.',
                'https://example.test/lab?a=1&b=2', 'not_started', 'high',
                'LMS', 'html', NULL, 'https://example.test/source/1',
                '2026-08-01 09:00:00', '2026-08-02 10:00:00'
            );
            INSERT INTO assignments VALUES (
                9, 'Physics', 'Completed report ✅', '2026-08-07 12:00:00',
                'Done / 完成', NULL, 'completed', 'medium',
                NULL, NULL, NULL, NULL,
                '2026-08-03 11:00:00', '2026-08-05 15:45:30'
            );
            INSERT INTO assignments VALUES (
                41, '语文 / English', 'Legacy''s "special" task 📚', NULL,
                '保留换行
            、Emoji 🧪 与特殊字符 <>&.', 'https://例子.测试/?a=1&b=二',
                'in_progress', 'low', '导入文件', 'text', '资料/作业.txt', NULL,
                '2026-08-04 08:15:00', '2026-08-06 18:20:00'
            );
            INSERT INTO assignments VALUES (
                73, '高等数学', '复习积分 & 极限 🧮', '2026-08-10 00:00:00',
                NULL, NULL, 'not_started', 'medium', NULL, NULL, NULL, NULL,
                '2026-08-05 00:00:00', '2026-08-05 00:00:00'
            );
            PRAGMA user_version = 2;
            """,
            on: database
        )
    }
}


private func v3ScalarText(at url: URL, _ sql: String) throws -> String? {
    try v3WithSQLite(at: url) { try SQLiteSupport.scalarText(sql, on: $0) }
}


private func v3ScalarInt(at url: URL, _ sql: String) throws -> Int64 {
    try v3WithSQLite(at: url) { try SQLiteSupport.scalarInt(sql, on: $0) }
}


private func v3ForeignKeySignatures(at url: URL, table: String) throws -> Set<String> {
    try v3WithSQLite(at: url) { database in
        let statement = try SQLiteSupport.prepare(
            "PRAGMA foreign_key_list(\(SQLiteSupport.quoteIdentifier(table)))",
            on: database
        )
        defer { sqlite3_finalize(statement) }
        var signatures = Set<String>()
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let referencedTable = try #require(SQLiteSupport.text(statement, 2))
            let from = try #require(SQLiteSupport.text(statement, 3))
            let to = try #require(SQLiteSupport.text(statement, 4))
            let onDelete = try #require(SQLiteSupport.text(statement, 6))
            signatures.insert("\(from)|\(referencedTable)|\(to)|\(onDelete.uppercased())")
            result = sqlite3_step(statement)
        }
        #expect(result == SQLITE_DONE)
        return signatures
    }
}


@Suite("Schema v3 identity, migration, and organization repository")
struct SchemaV3RepositoryTests {
    @Test("UUID v5 and Unicode normalization match shared fixture vectors")
    func sharedIdentityVectors() throws {
        let namespace = try #require(UUID(uuidString: "8c0f31e2-19a2-4c37-9b5d-4fc09f667c8d"))
        let vectors = [
            ("task", "1", "b6f8937a-8325-5149-9dd7-2f0b1fe4a7ff"),
            ("task", "41", "db6e7c95-5fde-5b99-8ee5-3ce314ea94d6"),
            ("course", "Physics", "86915390-c8d1-534d-a037-24c88c9e3ae4"),
            ("course", "physics", "a0550578-1e0f-5567-b3b0-b1337c1610af"),
            ("course", "语文 / English", "62a43b68-df97-57f4-9786-35ff9a5b3da8"),
            ("course", "高等数学", "81d3ead5-dce5-57a6-a27c-22106a018a61"),
        ]
        for vector in vectors {
            #expect(
                try SharedIdentity.deterministicUUID(
                    databaseInstanceUUID: namespace,
                    entity: vector.0,
                    legacyKey: vector.1
                ).canonicalString == vector.2
            )
        }

        let normalization = [
            (" Physics ", "physics"),
            ("Ｐｈｙｓｉｃｓ", "physics"),
            ("Straße", "strasse"),
            ("İ", "i̇"),
            ("  语文  / \t English  ", "语文 / english"),
            ("Ångström", "ångström"),
        ]
        for vector in normalization {
            #expect(SharedIdentity.canonicalName(vector.0) == vector.1)
        }
    }

    @Test("v2 fixture migrates additively without changing legacy payload")
    func sharedV2FixtureMigration() throws {
        let temporary = try V3TemporaryDatabase(fileName: "fixture-v2.db")
        defer { temporary.cleanup() }
        try createV2Fixture(at: temporary.databaseURL)
        let namespace = try #require(UUID(uuidString: "8c0f31e2-19a2-4c37-9b5d-4fc09f667c8d"))

        let repository = try SQLiteAssignmentRepository(
            databaseURL: temporary.databaseURL,
            migrationFailureInjector: nil,
            databaseInstanceUUID: namespace
        )
        let tasks = try repository.fetchAll()

        #expect(try repository.schemaVersion == 3)
        #expect(repository.lastMigrationResult.strategy == .v2ToV3)
        #expect(tasks.map(\.id) == [1, 9, 41, 73])
        #expect(tasks.map(\.uuid.canonicalString) == [
            "b6f8937a-8325-5149-9dd7-2f0b1fe4a7ff",
            "3588462a-cabb-551b-b492-efc68b736584",
            "db6e7c95-5fde-5b99-8ee5-3ce314ea94d6",
            "6a266058-ae29-5daf-b9eb-697b3cca48ae",
        ])
        #expect(tasks[1].completedAt != nil)
        #expect(tasks[1].progressPercent == 100)
        #expect(tasks[0].completedAt == nil)
        #expect(tasks[0].progressPercent == 0)
        #expect(
            try v3ScalarText(
                at: temporary.databaseURL,
                "SELECT due_date FROM assignments WHERE id = 1"
            ) == "2026-11-01 01:30:00"
        )
        #expect(try v3ScalarInt(at: temporary.databaseURL, "SELECT COUNT(*) FROM courses") == 3)
        #expect(try v3ScalarInt(
            at: temporary.databaseURL,
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL"
        ) == 30)
        #expect(try v3ScalarInt(
            at: temporary.databaseURL,
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'"
        ) == 12)
        #expect(
            try v3ScalarText(
                at: temporary.databaseURL,
                "SELECT uuid FROM courses WHERE name = '语文 / English'"
            ) == "62a43b68-df97-57f4-9786-35ff9a5b3da8"
        )
        let expectedForeignKeys: [String: Set<String>] = [
            "assignments": [
                "course_id|courses|id|SET NULL",
                "project_id|projects|id|SET NULL",
            ],
            "projects": ["course_id|courses|id|SET NULL"],
            "task_tags": [
                "assignment_id|assignments|id|CASCADE",
                "tag_id|tags|id|CASCADE",
            ],
            "subtasks": ["assignment_id|assignments|id|CASCADE"],
            "attachments": ["assignment_id|assignments|id|CASCADE"],
            "reminders": ["assignment_id|assignments|id|CASCADE"],
        ]
        for (table, expected) in expectedForeignKeys {
            #expect(try v3ForeignKeySignatures(at: temporary.databaseURL, table: table) == expected)
        }
        for table in ["projects", "tags", "task_tags", "subtasks", "attachments", "reminders"] {
            #expect(
                try v3ScalarInt(at: temporary.databaseURL, "SELECT COUNT(*) FROM \(table)") == 0
            )
        }
    }

    @Test("Injected v3 failure leaves the original v2 logical fingerprint intact")
    func failureRecoveryFingerprint() throws {
        let temporary = try V3TemporaryDatabase(fileName: "recovery-v2.db")
        defer { temporary.cleanup() }
        try createV2Fixture(at: temporary.databaseURL)
        let before = try v3WithSQLite(at: temporary.databaseURL) {
            try DatabaseLogicalFingerprint.capture(on: $0)
        }
        var captured: DatabaseMigrationError?
        do {
            _ = try SQLiteAssignmentRepository(
                databaseURL: temporary.databaseURL,
                migrationFailureInjector: { throw OrganizationRepositoryError.validation("fault") }
            )
        } catch let error as DatabaseMigrationError {
            captured = error
        }
        let after = try v3WithSQLite(at: temporary.databaseURL) {
            try DatabaseLogicalFingerprint.capture(on: $0)
        }
        #expect(captured != nil)
        #expect(captured?.backupURL != nil)
        #expect(before == after)
        #expect(try v3ScalarInt(at: temporary.databaseURL, "PRAGMA user_version") == 2)
        if let backupURL = captured?.backupURL {
            #expect(FileManager.default.fileExists(atPath: backupURL.path))
            #expect(try v3ScalarInt(at: backupURL, "PRAGMA user_version") == 2)
        }
    }

    @Test("Organization CRUD uses v4 UUIDs, metadata-only attachments, and soft delete")
    func organizationCRUD() throws {
        let temporary = try V3TemporaryDatabase()
        defer { temporary.cleanup() }
        let taskRepository = try SQLiteAssignmentRepository(databaseURL: temporary.databaseURL)
        let task = try taskRepository.create(
            AssignmentDraft(courseName: "Physics", title: "组织测试 📚")
        )
        let repository = try SQLiteOrganizationRepository(databaseURL: temporary.databaseURL)

        var course = try #require(try repository.fetchCourses(includeDeleted: false).first)
        let originalCourseUUID = course.uuid
        course.name = "物理 / Physics"
        course = try repository.updateCourse(course)
        #expect(course.uuid == originalCourseUUID)
        #expect(try taskRepository.fetchAll().first?.courseName == "物理 / Physics")

        let project = try repository.createProject(.init(
            courseID: course.id,
            name: "Semester project",
            projectDescription: "中英文 <>&",
            status: .active
        ))
        let tag = try repository.createTag(.init(name: "实验 🧪", colorHex: "#3366AA"))
        let link = try repository.attachTag(tag.id, to: task.id)
        let subtask = try repository.createSubtask(.init(
            assignmentID: task.id,
            title: "整理数据",
            status: .done,
            sortOrder: 2
        ))
        let attachment = try repository.createAttachmentMetadata(.init(
            assignmentID: task.id,
            fileName: "实验报告.pdf",
            mimeType: "application/pdf",
            byteSize: 4_096,
            sha256: String(repeating: "a", count: 64)
        ))
        let reminder = try repository.createReminder(.init(
            assignmentID: task.id,
            triggerAtUTC: Date(timeIntervalSince1970: 1_800_000_000),
            leadMinutes: 30,
            repeatRule: nil,
            isEnabled: true
        ))

        #expect(project.uuid.versionNumber == 4)
        #expect(tag.uuid.versionNumber == 4)
        #expect(link.uuid.versionNumber == 4)
        #expect(subtask.uuid.versionNumber == 4)
        #expect(subtask.completedAt != nil)
        #expect(attachment.uuid.versionNumber == 4)
        #expect(attachment.relativePath == "attachments/\(attachment.uuid.canonicalString)")
        #expect(reminder.uuid.versionNumber == 4)
        #expect(try v3ScalarInt(
            at: temporary.databaseURL,
            "SELECT COUNT(*) FROM pragma_table_info('attachments') WHERE upper(type) LIKE '%BLOB%'"
        ) == 0)

        try repository.detachTag(tag.id, from: task.id)
        try repository.deleteSubtask(id: subtask.id)
        try repository.deleteAttachmentMetadata(id: attachment.id)
        try repository.deleteReminder(id: reminder.id)
        #expect(try repository.fetchTagLinks(assignmentID: task.id, includeDeleted: false).isEmpty)
        #expect(try repository.fetchSubtasks(assignmentID: task.id, includeDeleted: false).isEmpty)
        #expect(try repository.fetchAttachments(assignmentID: task.id, includeDeleted: false).isEmpty)
        #expect(try repository.fetchReminders(assignmentID: task.id, includeDeleted: false).isEmpty)

        try v3WithSQLite(
            at: temporary.databaseURL,
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        ) { database in
            try SQLiteSupport.configure(database, writable: false)
            try SQLiteSchemaV3.validate(on: database)
        }
    }

    @Test("Concurrent repository initialization serializes migration")
    func concurrentMigrationInitialization() throws {
        let temporary = try V3TemporaryDatabase(fileName: "concurrent-v2.db")
        defer { temporary.cleanup() }
        try createV2Fixture(at: temporary.databaseURL)
        let resultLock = NSLock()
        var strategies: [MigrationStrategy] = []
        var errors: [String] = []

        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            do {
                let repository = try SQLiteAssignmentRepository(databaseURL: temporary.databaseURL)
                resultLock.withLock { strategies.append(repository.lastMigrationResult.strategy) }
            } catch {
                resultLock.withLock { errors.append(error.localizedDescription) }
            }
        }

        #expect(errors.isEmpty)
        #expect(strategies.count == 2)
        #expect(strategies.filter { $0 == .v2ToV3 }.count == 1)
        #expect(strategies.filter { $0 == .none }.count == 1)
        #expect(try v3ScalarInt(at: temporary.databaseURL, "PRAGMA user_version") == 3)
    }

    @Test("Post-commit validation failure restores v2 in place while WAL reader stays usable")
    func postCommitFailureUsesSafeWALRestore() throws {
        let temporary = try V3TemporaryDatabase(fileName: "post-commit-v2.db")
        defer { temporary.cleanup() }
        try createV2Fixture(at: temporary.databaseURL)

        let oldConnection = try SQLiteSupport.open(temporary.databaseURL)
        defer { sqlite3_close(oldConnection) }
        try SQLiteSupport.configure(oldConnection)
        _ = try SQLiteSupport.scalarText("PRAGMA journal_mode = WAL", on: oldConnection)
        try SQLiteSupport.execute("BEGIN", on: oldConnection)
        _ = try SQLiteSupport.scalarInt("SELECT COUNT(*) FROM assignments", on: oldConnection)

        var migrationError: DatabaseMigrationError?
        do {
            _ = try MigrationCoordinator.prepareDatabase(
                at: temporary.databaseURL,
                postCommitValidationFailureInjector: {
                    throw OrganizationRepositoryError.validation("post-commit fault")
                }
            )
        } catch let error as DatabaseMigrationError {
            migrationError = error
        }
        #expect(migrationError != nil)
        #expect(try v3ScalarInt(at: temporary.databaseURL, "PRAGMA user_version") == 2)
        #expect(try v3ScalarText(at: temporary.databaseURL, "PRAGMA journal_mode") == "wal")

        try SQLiteSupport.execute("COMMIT", on: oldConnection)
        try SQLiteSupport.execute(
            """
            INSERT INTO assignments (
                id, course_name, title, status, priority, created_at, updated_at
            ) VALUES (
                101, 'Reader', 'Still writable', 'not_started', 'medium',
                '2026-08-11 00:00:00', '2026-08-11 00:00:00'
            )
            """,
            on: oldConnection
        )
        #expect(try v3ScalarInt(
            at: temporary.databaseURL,
            "SELECT COUNT(*) FROM assignments WHERE id = 101"
        ) == 1)
    }

    @Test("Fingerprint supports WITHOUT ROWID and includes sqlite_sequence")
    func extensionFingerprintAndMigration() throws {
        let temporary = try V3TemporaryDatabase(fileName: "extensions-v2.db")
        defer { temporary.cleanup() }
        try createV2Fixture(at: temporary.databaseURL)
        try v3WithSQLite(at: temporary.databaseURL) { database in
            try SQLiteSupport.execute(
                """
                CREATE TABLE extension_key (
                    namespace TEXT NOT NULL,
                    key TEXT NOT NULL,
                    value BLOB,
                    PRIMARY KEY (namespace, key)
                ) WITHOUT ROWID;
                INSERT INTO extension_key VALUES ('学习', 'emoji-📚', X'00FF');
                CREATE TABLE extension_auto (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    note TEXT NOT NULL
                );
                INSERT INTO extension_auto(note) VALUES ('first');
                UPDATE sqlite_sequence SET seq = 42 WHERE name = 'extension_auto';
                """,
                on: database
            )
            _ = try DatabaseLogicalFingerprint.capture(on: database)
        }

        let repository = try SQLiteAssignmentRepository(databaseURL: temporary.databaseURL)
        #expect(try repository.schemaVersion == 3)
        #expect(try v3ScalarText(
            at: temporary.databaseURL,
            "SELECT hex(value) FROM extension_key WHERE namespace = '学习'"
        ) == "00FF")
        #expect(try v3ScalarInt(
            at: temporary.databaseURL,
            "SELECT seq FROM sqlite_sequence WHERE name = 'extension_auto'"
        ) == 42)

        let before = try v3WithSQLite(at: temporary.databaseURL) {
            try DatabaseLogicalFingerprint.capture(on: $0)
        }
        try v3WithSQLite(at: temporary.databaseURL) {
            try SQLiteSupport.execute(
                "UPDATE sqlite_sequence SET seq = 43 WHERE name = 'extension_auto'",
                on: $0
            )
        }
        let after = try v3WithSQLite(at: temporary.databaseURL) {
            try DatabaseLogicalFingerprint.capture(on: $0)
        }
        #expect(before != after)
    }

    @Test("Schema validation rejects non-UTC completion dates and forged partial predicates")
    func strictSchemaMetadataAndCompletionValidation() throws {
        let timestampDatabase = try V3TemporaryDatabase(fileName: "invalid-completed.db")
        defer { timestampDatabase.cleanup() }
        do {
            let repository = try SQLiteAssignmentRepository(databaseURL: timestampDatabase.databaseURL)
            _ = try repository.create(.init(
                courseName: "Physics",
                title: "Done",
                status: .done
            ))
        }
        try v3WithSQLite(at: timestampDatabase.databaseURL) {
            try SQLiteSupport.execute(
                "UPDATE assignments SET completed_at = 'not-a-date' WHERE id = 1",
                on: $0
            )
        }
        var completionRejected = false
        do {
            try v3WithSQLite(at: timestampDatabase.databaseURL) {
                try SQLiteSupport.configure($0)
                try SQLiteSchemaV3.validate(on: $0)
            }
        } catch {
            completionRejected = true
        }
        #expect(completionRejected)

        let indexDatabase = try V3TemporaryDatabase(fileName: "invalid-index.db")
        defer { indexDatabase.cleanup() }
        do { _ = try SQLiteAssignmentRepository(databaseURL: indexDatabase.databaseURL) }
        try v3WithSQLite(at: indexDatabase.databaseURL) {
            try SQLiteSupport.execute(
                """
                DROP INDEX ux_task_tags_active_pair;
                CREATE UNIQUE INDEX ux_task_tags_active_pair
                ON task_tags(assignment_id, tag_id)
                WHERE deleted_at = deleted_at AND deleted_at IS NULL;
                """,
                on: $0
            )
        }
        var predicateRejected = false
        do {
            try v3WithSQLite(at: indexDatabase.databaseURL) {
                try SQLiteSupport.configure($0)
                try SQLiteSchemaV3.validate(on: $0)
            }
        } catch {
            predicateRejected = true
        }
        #expect(predicateRejected)
    }

    @Test("Subtasks atomically derive parent progress and status commands cascade")
    func subtaskProgressMatrix() throws {
        let temporary = try V3TemporaryDatabase(fileName: "subtask-matrix.db")
        defer { temporary.cleanup() }
        let tasks = try SQLiteAssignmentRepository(databaseURL: temporary.databaseURL)
        let organization = try SQLiteOrganizationRepository(databaseURL: temporary.databaseURL)
        let task = try tasks.create(.init(courseName: "Math", title: "Problem set"))
        var first = try organization.createSubtask(.init(
            assignmentID: task.id,
            title: "A",
            status: .todo,
            sortOrder: 0
        ))
        let second = try organization.createSubtask(.init(
            assignmentID: task.id,
            title: "B",
            status: .todo,
            sortOrder: 1
        ))
        first.status = .done
        first = try organization.updateSubtask(first)
        var parent = try #require(try tasks.fetchAll().first)
        #expect(parent.status == .inProgress)
        #expect(parent.progressPercent == 50)
        #expect(parent.completedAt == nil)

        parent = try tasks.updateStatus(id: task.id, status: .done)
        #expect(parent.status == .done)
        #expect(parent.progressPercent == 100)
        #expect(try organization.fetchSubtasks(assignmentID: task.id).allSatisfy {
            $0.status == .done && $0.completedAt != nil
        })

        parent = try tasks.updateStatus(id: task.id, status: .todo)
        #expect(parent.status == .todo)
        #expect(parent.progressPercent == 0)
        #expect(try organization.fetchSubtasks(assignmentID: task.id).allSatisfy {
            $0.status == .todo && $0.completedAt == nil
        })

        parent = try tasks.updateStatus(id: task.id, status: .inProgress)
        #expect(parent.status == .inProgress)
        #expect(try organization.fetchSubtasks(assignmentID: task.id).first?.status == .inProgress)

        try organization.deleteSubtask(id: first.id)
        try organization.deleteSubtask(id: second.id)
        parent = try #require(try tasks.fetchAll().first)
        #expect(parent.status == .todo)
        #expect(parent.progressPercent == 0)

        let restored = try organization.restoreSubtask(id: first.id)
        #expect(restored.uuid == first.uuid)
        parent = try #require(try tasks.fetchAll().first)
        #expect(parent.status == .inProgress)
    }

    @Test("Restore, course identity, project invariants, and soft-delete cascades match contract")
    func restoreAndOrganizationInvariants() throws {
        let temporary = try V3TemporaryDatabase(fileName: "restore-contract.db")
        defer { temporary.cleanup() }
        let tasks = try SQLiteAssignmentRepository(databaseURL: temporary.databaseURL)
        let organization = try SQLiteOrganizationRepository(databaseURL: temporary.databaseURL)
        let upper = try tasks.create(.init(courseName: "Math", title: "Upper"))
        let lower = try tasks.create(.init(courseName: "math", title: "Lower"))
        #expect(upper.courseID != lower.courseID)

        let reminder = try organization.createReminder(.init(
            assignmentID: upper.id,
            triggerAtUTC: Date(timeIntervalSince1970: 1_800_000_000),
            repeatRule: "freq=weekly;byday=mo,we;count=3"
        ))
        #expect(reminder.repeatRule == "FREQ=WEEKLY;BYDAY=MO,WE;COUNT=3")

        let tag = try organization.createTag(.init(name: "Exam"))
        _ = try organization.attachTag(tag.id, to: upper.id)
        try organization.deleteTag(id: tag.id)
        let restoredTag = try organization.restoreTag(id: tag.id)
        #expect(restoredTag.uuid == tag.uuid)
        #expect(try organization.fetchTagLinks(assignmentID: upper.id).isEmpty)

        try tasks.delete(id: upper.id)
        #expect(try v3ScalarInt(
            at: temporary.databaseURL,
            "SELECT is_enabled FROM reminders WHERE id = \(reminder.id)"
        ) == 0)
        var upperCourse = try #require(
            try organization.fetchCourses(includeDeleted: false).first { $0.id == upper.courseID }
        )
        upperCourse.name = "Mathematics"
        upperCourse = try organization.updateCourse(upperCourse)
        let restoredTask = try tasks.restore(id: upper.id)
        #expect(restoredTask.uuid == upper.uuid)
        #expect(restoredTask.courseName == "Mathematics")
        #expect(try v3ScalarInt(
            at: temporary.databaseURL,
            "SELECT is_enabled FROM reminders WHERE id = \(reminder.id)"
        ) == 0)

        let lowerCourseID = try #require(lower.courseID)
        let project = try organization.createProject(.init(
            courseID: lowerCourseID,
            name: "Lower project"
        ))
        var mismatched = restoredTask
        mismatched.projectID = project.id
        var mismatchRejected = false
        do { _ = try tasks.update(mismatched) }
        catch { mismatchRejected = true }
        #expect(mismatchRejected)

        try tasks.delete(id: lower.id)
        var childRejected = false
        do {
            _ = try organization.createSubtask(.init(
                assignmentID: lower.id,
                title: "Deleted parent"
            ))
        } catch {
            childRejected = true
        }
        #expect(childRejected)
    }

    @Test("Legacy due text is stable and timezone plus RRULE validation is strict")
    func dueTimezoneAndRepeatRuleValidation() throws {
        let temporary = try V3TemporaryDatabase(fileName: "due-rules-v2.db")
        defer { temporary.cleanup() }
        try createV2Fixture(at: temporary.databaseURL)
        try v3WithSQLite(at: temporary.databaseURL) {
            try SQLiteSupport.execute(
                "UPDATE assignments SET due_date = '2026-11-01T01:30:00.123456' WHERE id = 1",
                on: $0
            )
        }
        let tasks = try SQLiteAssignmentRepository(databaseURL: temporary.databaseURL)
        var task = try #require(try tasks.fetchAll().first { $0.id == 1 })
        task.title = "Edited title only"
        task = try tasks.update(task)
        #expect(try v3ScalarText(
            at: temporary.databaseURL,
            "SELECT due_date FROM assignments WHERE id = 1"
        ) == "2026-11-01T01:30:00.123456")

        task.timeZoneIdentifier = "Mars/Olympus"
        var timezoneRejected = false
        do { _ = try tasks.update(task) }
        catch { timezoneRejected = true }
        #expect(timezoneRejected)

        let organization = try SQLiteOrganizationRepository(databaseURL: temporary.databaseURL)
        for invalid in [
            "FREQ=WEEKLY;COUNT=2;UNTIL=20270101",
            "FREQ=WEEKLY;BYDAY=MO,MO",
            "FREQ=MONTHLY;BYMONTHDAY=0",
            "FREQ=DAILY;UNTIL=20260230",
            "FREQ=HOURLY",
            "DTSTART=20260101;FREQ=DAILY",
        ] {
            var rejected = false
            do {
                _ = try organization.createReminder(.init(
                    assignmentID: task.id,
                    triggerAtUTC: Date(timeIntervalSince1970: 1_800_000_000),
                    repeatRule: invalid
                ))
            } catch {
                rejected = true
            }
            #expect(rejected, "Expected invalid RRULE to be rejected: \(invalid)")
        }
    }
}
