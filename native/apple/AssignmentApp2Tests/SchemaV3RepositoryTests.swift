import CryptoKit
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
            ("ς / Σ", "σ / σ"),
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

        #expect(try repository.schemaVersion == SQLiteSchemaV4.databaseVersion)
        #expect(repository.lastMigrationResult.strategy == .v2ToV4)
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
        // 30 v3 contract indexes plus the 8 learning-scene indexes v4 adds.
        #expect(try v3ScalarInt(
            at: temporary.databaseURL,
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL"
        ) == 38)
        // 12 v3 contract triggers plus the 2 learning-scene UUID triggers.
        #expect(try v3ScalarInt(
            at: temporary.databaseURL,
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'"
        ) == 14)
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

    @Test("Rollback verification preserves a healthy external write after lock release")
    func rollbackExternalWriteIsPreserved() throws {
        let temporary = try V3TemporaryDatabase(fileName: "rollback-external-v2.db")
        defer { temporary.cleanup() }
        try createV2Fixture(at: temporary.databaseURL)

        var migrationError: DatabaseMigrationError?
        do {
            _ = try MigrationCoordinator.prepareDatabase(
                at: temporary.databaseURL,
                migrationFailureInjector: {
                    throw OrganizationRepositoryError.validation("transaction fault")
                },
                postRollbackFailureInjector: {
                    let external = try SQLiteSupport.open(temporary.databaseURL)
                    defer { sqlite3_close(external) }
                    try SQLiteSupport.configure(external)
                    try SQLiteSupport.execute(
                        """
                        UPDATE assignments
                        SET title = 'External write after rollback',
                            updated_at = '2026-08-12 21:30:00'
                        WHERE id = 1
                        """,
                        on: external
                    )
                }
            )
        } catch let error as DatabaseMigrationError {
            migrationError = error
        }

        let error = try #require(migrationError)
        #expect(error.errorDescription?.contains("healthy external change") == true)
        #expect(error.errorDescription?.contains("preserved") == true)
        #expect(try v3ScalarInt(at: temporary.databaseURL, "PRAGMA user_version") == 2)
        #expect(try v3ScalarText(
            at: temporary.databaseURL,
            "SELECT title FROM assignments WHERE id = 1"
        ) == "External write after rollback")
        let backupURL = try #require(error.backupURL)
        #expect(try v3ScalarInt(at: backupURL, "PRAGMA user_version") == 2)
        #expect(try v3ScalarText(
            at: backupURL,
            "SELECT title FROM assignments WHERE id = 1"
        ) != "External write after rollback")
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
        let largeSQLiteInteger = Int(Int32.max) + 1
        let subtask = try repository.createSubtask(.init(
            assignmentID: task.id,
            title: "整理数据",
            status: .done,
            sortOrder: largeSQLiteInteger
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
            leadMinutes: largeSQLiteInteger,
            repeatRule: nil,
            isEnabled: true
        ))

        #expect(project.uuid.versionNumber == 4)
        #expect(tag.uuid.versionNumber == 4)
        #expect(link.uuid.versionNumber == 4)
        #expect(subtask.uuid.versionNumber == 4)
        #expect(subtask.completedAt != nil)
        #expect(subtask.sortOrder == largeSQLiteInteger)
        #expect(attachment.uuid.versionNumber == 4)
        #expect(attachment.relativePath == "attachments/\(attachment.uuid.canonicalString)")
        #expect(reminder.uuid.versionNumber == 4)
        #expect(reminder.leadMinutes == largeSQLiteInteger)
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
            try SQLiteSchemaV4.validate(on: database)
        }
    }

    @Test("Attachment payload import, hashing, rollback, deletion, and orphan cleanup")
    func attachmentPayloadLifecycle() throws {
        let temporary = try V3TemporaryDatabase(fileName: "attachment-files.db")
        defer { temporary.cleanup() }
        let tasks = try SQLiteAssignmentRepository(databaseURL: temporary.databaseURL)
        let task = try tasks.create(.init(courseName: "Art", title: "作品集 🎨"))
        let organization = try SQLiteOrganizationRepository(databaseURL: temporary.databaseURL)
        let store = AttachmentFileStore(databaseURL: temporary.databaseURL)
        let source = temporary.directoryURL.appendingPathComponent("报告 final.txt")
        let payload = Data("中英文, emoji 🧪, and special characters <>&".utf8)
        try payload.write(to: source, options: .atomic)

        let attachment = try store.importFile(
            from: source,
            assignmentID: task.id,
            mimeType: "text/plain",
            repository: organization
        )
        let managedURL = try store.payloadURL(for: attachment)
        let presentationURL = try store.presentationURL(for: attachment)
        #expect(try Data(contentsOf: managedURL) == payload)
        #expect(presentationURL.lastPathComponent == "报告 final.txt")
        #expect(try Data(contentsOf: presentationURL) == payload)
        #expect(attachment.byteSize == payload.count)
        #expect(attachment.sha256 == SHA256.hash(data: payload).map {
            String(format: "%02x", $0)
        }.joined())

        let stagingURL = temporary.directoryURL
            .appendingPathComponent(".attachment-staging", isDirectory: true)
        let tombstoneURL = stagingURL
            .appendingPathComponent("\(attachment.uuid.uuidString.lowercased()).deleted")
        try FileManager.default.moveItem(at: managedURL, to: tombstoneURL)
        let partialURL = stagingURL.appendingPathComponent("interrupted.partial")
        try Data("partial".utf8).write(to: partialURL)
        let restored = try store.reconcile(
            activeAttachments: organization.fetchAllAttachments(includeDeleted: false)
        )
        #expect(restored.missingPayloadNames.isEmpty)
        #expect(try Data(contentsOf: managedURL) == payload)
        #expect(!FileManager.default.fileExists(atPath: tombstoneURL.path))
        #expect(!FileManager.default.fileExists(atPath: partialURL.path))

        let orphanUUID = UUID().uuidString.lowercased()
        let orphanURL = temporary.directoryURL
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(orphanUUID)
        try Data("orphan".utf8).write(to: orphanURL)
        let reconciliation = try store.reconcile(
            activeAttachments: organization.fetchAllAttachments(includeDeleted: false)
        )
        #expect(reconciliation.removedOrphanCount == 1)
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))

        do {
            _ = try store.importFile(
                from: source,
                assignmentID: Int64.max,
                mimeType: "text/plain",
                repository: organization
            )
            Issue.record("Import with a missing task should fail")
        } catch {
            let storedFiles = try FileManager.default.contentsOfDirectory(
                at: temporary.directoryURL.appendingPathComponent("attachments"),
                includingPropertiesForKeys: nil
            )
            #expect(storedFiles.map(\.lastPathComponent) == [managedURL.lastPathComponent])
        }

        try store.deleteFileAndMetadata(attachment, repository: organization)
        #expect(!FileManager.default.fileExists(atPath: managedURL.path))
        #expect(try organization.fetchAllAttachments(includeDeleted: false).isEmpty)
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
        #expect(strategies.filter { $0 == .v2ToV4 }.count == 1)
        #expect(strategies.filter { $0 == .none }.count == 1)
        #expect(
            try v3ScalarInt(at: temporary.databaseURL, "PRAGMA user_version")
                == SQLiteSchemaV4.databaseVersion
        )
    }

    @Test("Post-commit failure preserves the committed candidate after lock release")
    func postCommitFailurePreservesCommittedCandidate() throws {
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
        #expect(migrationError?.errorDescription?.contains("exact committed candidate") == true)
        #expect(migrationError?.errorDescription?.contains("restore was not attempted") == true)
        #expect(
            try v3ScalarInt(at: temporary.databaseURL, "PRAGMA user_version")
                == SQLiteSchemaV4.databaseVersion
        )
        #expect(try v3ScalarText(at: temporary.databaseURL, "PRAGMA journal_mode") == "wal")

        let backupURL = try #require(migrationError?.backupURL)
        #expect(try v3ScalarInt(at: backupURL, "PRAGMA user_version") == 2)

        try SQLiteSupport.execute("COMMIT", on: oldConnection)
        #expect(
            try SQLiteSupport.scalarInt("PRAGMA user_version", on: oldConnection)
                == SQLiteSchemaV4.databaseVersion
        )
        #expect(try SQLiteSupport.scalarInt(
            "SELECT COUNT(*) FROM assignments",
            on: oldConnection
        ) > 0)
    }

    @Test("Post-commit recovery preserves an external write instead of restoring over it")
    func postCommitExternalWriteIsPreserved() throws {
        let temporary = try V3TemporaryDatabase(fileName: "post-commit-external-v2.db")
        defer { temporary.cleanup() }
        try createV2Fixture(at: temporary.databaseURL)

        var migrationError: DatabaseMigrationError?
        do {
            _ = try MigrationCoordinator.prepareDatabase(
                at: temporary.databaseURL,
                postCommitValidationFailureInjector: {
                    let external = try SQLiteSupport.open(temporary.databaseURL)
                    defer { sqlite3_close(external) }
                    try SQLiteSupport.configure(external)
                    try SQLiteSupport.execute(
                        """
                        UPDATE assignments
                        SET title = 'External writer preserved',
                            updated_at = '2026-08-12T21:00:00.000Z'
                        WHERE id = 1
                        """,
                        on: external
                    )
                    throw OrganizationRepositoryError.validation(
                        "post-commit fault after external write"
                    )
                }
            )
        } catch let error as DatabaseMigrationError {
            migrationError = error
        }

        let error = try #require(migrationError)
        #expect(error.errorDescription?.contains("external change") == true)
        #expect(error.errorDescription?.contains("preserved") == true)
        #expect(
            try v3ScalarInt(at: temporary.databaseURL, "PRAGMA user_version")
                == SQLiteSchemaV4.databaseVersion
        )
        #expect(try v3ScalarText(
            at: temporary.databaseURL,
            "SELECT title FROM assignments WHERE id = 1"
        ) == "External writer preserved")
        let backupURL = try #require(error.backupURL)
        #expect(try v3ScalarInt(at: backupURL, "PRAGMA user_version") == 2)
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
        #expect(try repository.schemaVersion == SQLiteSchemaV4.databaseVersion)
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
                try SQLiteSchemaV4.validate(on: $0)
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
                try SQLiteSchemaV4.validate(on: $0)
            }
        } catch {
            predicateRejected = true
        }
        #expect(predicateRejected)
    }

    @Test("Schema validation rejects derived-state, RRULE, and attachment affinity drift")
    func strictOrganizationRowValidation() throws {
        let stateDatabase = try V3TemporaryDatabase(fileName: "invalid-parent-state.db")
        defer { stateDatabase.cleanup() }
        let stateTasks = try SQLiteAssignmentRepository(databaseURL: stateDatabase.databaseURL)
        let stateOrganization = try SQLiteOrganizationRepository(
            databaseURL: stateDatabase.databaseURL
        )
        let parent = try stateTasks.create(.init(courseName: "Math", title: "Parent"))
        _ = try stateOrganization.createSubtask(.init(
            assignmentID: parent.id,
            title: "Done child",
            status: .done
        ))
        try v3WithSQLite(at: stateDatabase.databaseURL) {
            try SQLiteSupport.execute(
                """
                UPDATE assignments
                SET status = 'not_started', progress_percent = 0, completed_at = NULL
                WHERE id = \(parent.id)
                """,
                on: $0
            )
        }
        var parentStateRejected = false
        do {
            try v3WithSQLite(at: stateDatabase.databaseURL) {
                try SQLiteSupport.configure($0)
                try SQLiteSchemaV4.validate(on: $0)
            }
        } catch {
            parentStateRejected = true
        }
        #expect(parentStateRejected)

        let reminderDatabase = try V3TemporaryDatabase(fileName: "invalid-rrule.db")
        defer { reminderDatabase.cleanup() }
        let reminderTasks = try SQLiteAssignmentRepository(
            databaseURL: reminderDatabase.databaseURL
        )
        let reminderOrganization = try SQLiteOrganizationRepository(
            databaseURL: reminderDatabase.databaseURL
        )
        let reminderParent = try reminderTasks.create(.init(
            courseName: "Math",
            title: "Reminder parent"
        ))
        let reminder = try reminderOrganization.createReminder(.init(
            assignmentID: reminderParent.id,
            triggerAtUTC: Date(timeIntervalSince1970: 1_800_000_000),
            repeatRule: "FREQ=DAILY"
        ))
        try v3WithSQLite(at: reminderDatabase.databaseURL) {
            try SQLiteSupport.execute(
                "UPDATE reminders SET repeat_rule = 'DTSTART=bad' WHERE id = \(reminder.id)",
                on: $0
            )
        }
        var repeatRuleRejected = false
        do {
            try v3WithSQLite(at: reminderDatabase.databaseURL) {
                try SQLiteSupport.configure($0)
                try SQLiteSchemaV4.validate(on: $0)
            }
        } catch {
            repeatRuleRejected = true
        }
        #expect(repeatRuleRejected)

        let attachmentDatabase = try V3TemporaryDatabase(fileName: "invalid-blob.db")
        defer { attachmentDatabase.cleanup() }
        do { _ = try SQLiteAssignmentRepository(databaseURL: attachmentDatabase.databaseURL) }
        try v3WithSQLite(at: attachmentDatabase.databaseURL) {
            try SQLiteSupport.execute(
                "ALTER TABLE attachments ADD COLUMN payload BLOB "
                    + "GENERATED ALWAYS AS (x'00') VIRTUAL",
                on: $0
            )
        }
        var attachmentAffinityRejected = false
        do {
            try v3WithSQLite(at: attachmentDatabase.databaseURL) {
                try SQLiteSupport.configure($0)
                try SQLiteSchemaV4.validate(on: $0)
            }
        } catch {
            attachmentAffinityRejected = true
        }
        #expect(attachmentAffinityRejected)

        let relationshipDatabase = try V3TemporaryDatabase(
            fileName: "invalid-course-snapshot.db"
        )
        defer { relationshipDatabase.cleanup() }
        let relationshipTasks = try SQLiteAssignmentRepository(
            databaseURL: relationshipDatabase.databaseURL
        )
        let relationshipOrganization = try SQLiteOrganizationRepository(
            databaseURL: relationshipDatabase.databaseURL
        )
        let linkedCourse = try relationshipOrganization.createCourse(.init(name: "Math"))
        let linkedTask = try relationshipTasks.create(.init(
            courseName: linkedCourse.name,
            title: "Linked task"
        ))
        try v3WithSQLite(at: relationshipDatabase.databaseURL) {
            try SQLiteSupport.execute(
                "UPDATE courses SET name = 'Applied Math' WHERE id = \(linkedCourse.id)",
                on: $0
            )
        }
        var staleSnapshotRejected = false
        do {
            try v3WithSQLite(at: relationshipDatabase.databaseURL) {
                try SQLiteSupport.configure($0)
                try SQLiteSchemaV4.validate(on: $0)
            }
        } catch {
            staleSnapshotRejected = true
        }
        #expect(staleSnapshotRejected)
        #expect(linkedTask.courseName == "Math")

        let scalarDatabase = try V3TemporaryDatabase(fileName: "invalid-scalar.db")
        defer { scalarDatabase.cleanup() }
        do { _ = try SQLiteAssignmentRepository(databaseURL: scalarDatabase.databaseURL) }
        try v3WithSQLite(at: scalarDatabase.databaseURL) {
            try SQLiteSupport.execute("PRAGMA ignore_check_constraints = ON", on: $0)
            try SQLiteSupport.execute(
                """
                INSERT INTO projects (uuid, name, status, created_at, updated_at)
                VALUES ('c3bbd89e-6fd7-4a71-98b2-a5f903ed0e21', 'Bad', 'bogus',
                        '2026-08-12T12:00:00Z', '2026-08-12T12:00:00Z')
                """,
                on: $0
            )
            try SQLiteSupport.execute("PRAGMA ignore_check_constraints = OFF", on: $0)
        }
        var scalarRejected = false
        do {
            try v3WithSQLite(at: scalarDatabase.databaseURL) {
                try SQLiteSupport.configure($0)
                try SQLiteSchemaV4.validate(on: $0)
            }
        } catch {
            scalarRejected = true
        }
        #expect(scalarRejected)
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

        let otherTask = try tasks.create(.init(courseName: "Math", title: "Other parent"))
        let forgedParent = AssignmentSubtask(
            id: first.id,
            uuid: first.uuid,
            assignmentID: otherTask.id,
            title: "Forged parent",
            status: .todo,
            sortOrder: first.sortOrder,
            completedAt: nil,
            createdAt: first.createdAt,
            updatedAt: first.updatedAt,
            deletedAt: nil
        )
        var forgedParentRejected = false
        do { _ = try organization.updateSubtask(forgedParent) }
        catch { forgedParentRejected = true }
        #expect(forgedParentRejected)
        let unchangedParent = try #require(try tasks.fetchAll().first { $0.id == task.id })
        #expect(unchangedParent.status == .inProgress)
        #expect(unchangedParent.progressPercent == 50)
        let unchangedOther = try #require(try tasks.fetchAll().first { $0.id == otherTask.id })
        #expect(unchangedOther.status == .todo)
        #expect(unchangedOther.progressPercent == 0)

        parent = try tasks.updateStatus(id: task.id, status: .done)
        #expect(parent.status == .done)
        #expect(parent.progressPercent == 100)
        #expect(try organization.fetchSubtasks(assignmentID: task.id).allSatisfy {
            $0.status == .done && $0.completedAt != nil
        })

        parent = try tasks.updateStatus(id: task.id, status: .inProgress)
        let reopened = try organization.fetchSubtasks(assignmentID: task.id)
        #expect(parent.status == .inProgress)
        #expect(parent.progressPercent == 50)
        #expect(reopened.first?.status == .done)
        #expect(reopened.last?.status == .inProgress)
        #expect(reopened.last?.completedAt == nil)

        parent = try tasks.updateStatus(id: task.id, status: .done)
        #expect(parent.status == .done)
        #expect(parent.progressPercent == 100)

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

        let attachment = try organization.createAttachmentMetadata(.init(
            assignmentID: upper.id,
            fileName: "notes.txt",
            mimeType: "text/plain",
            byteSize: 4,
            sha256: String(repeating: "a", count: 64)
        ))
        let forgedAttachment = AttachmentMetadata(
            id: attachment.id,
            uuid: attachment.uuid,
            assignmentID: lower.id,
            fileName: attachment.fileName,
            relativePath: attachment.relativePath,
            mimeType: attachment.mimeType,
            byteSize: attachment.byteSize,
            sha256: attachment.sha256,
            createdAt: attachment.createdAt,
            updatedAt: attachment.updatedAt,
            deletedAt: nil
        )
        var forgedAttachmentRejected = false
        do { _ = try organization.updateAttachmentMetadata(forgedAttachment) }
        catch { forgedAttachmentRejected = true }
        #expect(forgedAttachmentRejected)

        let forgedReminder = TaskReminder(
            id: reminder.id,
            uuid: reminder.uuid,
            assignmentID: lower.id,
            triggerAtUTC: reminder.triggerAtUTC,
            leadMinutes: reminder.leadMinutes,
            repeatRule: reminder.repeatRule,
            isEnabled: reminder.isEnabled,
            lastScheduledAt: reminder.lastScheduledAt,
            createdAt: reminder.createdAt,
            updatedAt: reminder.updatedAt,
            deletedAt: nil
        )
        var forgedReminderRejected = false
        do { _ = try organization.updateReminder(forgedReminder) }
        catch { forgedReminderRejected = true }
        #expect(forgedReminderRejected)

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

        try v3WithSQLite(at: temporary.databaseURL) {
            try SQLiteSupport.execute(
                """
                UPDATE assignments
                SET due_date = '2026-03-08 02:30:00',
                    timezone_id = 'America/Los_Angeles'
                WHERE id = 9
                """,
                on: $0
            )
        }
        var gapTask = try #require(try tasks.fetchAll().first { $0.id == 9 })
        #expect(gapTask.dueDate != nil)
        gapTask.title = "Timezone-only edit"
        gapTask.timeZoneIdentifier = "America/New_York"
        _ = try tasks.update(gapTask)
        #expect(try v3ScalarText(
            at: temporary.databaseURL,
            "SELECT due_date FROM assignments WHERE id = 9"
        ) == "2026-03-08 02:30:00")

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
            "FREQ=DAILY;COUNT=٢",
            "FREQ=YEARLY;BYMONTH=１",
            "FREQ=MONTHLY;BYMONTHDAY=+1",
            "FREQ=YEARLY;BYMONTH=+1",
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
