import Foundation
import SQLite3
import Testing
@testable import AssignmentApp2


// MARK: - Fixtures

private final class LearningTemporaryDatabase {
    let directoryURL: URL
    let databaseURL: URL

    init(fileName: String = "assignments.db") throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AssignmentApp2LearningTests-\(UUID().uuidString)",
                isDirectory: true
            )
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


private func learningWithSQLite<T>(
    at url: URL,
    flags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
    _ body: (OpaquePointer) throws -> T
) throws -> T {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK,
          let database else {
        throw AssignmentRepositoryError.open("Could not open temporary SQLite database.")
    }
    defer { sqlite3_close(database) }
    return try body(database)
}


private func learningScalarText(at url: URL, _ sql: String) throws -> String? {
    try learningWithSQLite(
        at: url,
        flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    ) { database in
        try SQLiteSupport.configure(database, writable: false)
        return try SQLiteSupport.scalarText(sql, on: database)
    }
}


private func learningScalarInt(at url: URL, _ sql: String) throws -> Int64 {
    try learningWithSQLite(
        at: url,
        flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    ) { database in
        try SQLiteSupport.configure(database, writable: false)
        return try SQLiteSupport.scalarInt(sql, on: database)
    }
}


private func learningRows(at url: URL, _ sql: String) throws -> [[String]] {
    try learningWithSQLite(
        at: url,
        flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    ) { database in
        try SQLiteSupport.configure(database, writable: false)
        return try SQLiteSchemaV4.orderedRows(sql, on: database)
    }
}


private func learningTableNames(at url: URL) throws -> Set<String> {
    try learningWithSQLite(
        at: url,
        flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    ) { database in
        try SQLiteSupport.configure(database, writable: false)
        return try SQLiteSchemaV4.tableNames(on: database)
    }
}


/// Sentinel values the migration must carry across untouched.
private let learningV3TaskTitle = "Wave lab 波动实验"
private let learningV3DueDateText = "2026-11-01 01:30:00"
private let learningV3CourseName = "Physics 物理"

/// The two reminders seeded into every v3 fixture. Both are plain v3 rows: a
/// stored instant with no notion of a schedule kind.
private let learningV3FixedTrigger = Date(timeIntervalSince1970: 1_800_000_000)
private let learningV3RepeatTrigger = Date(timeIntervalSince1970: 1_802_400_000)


/// Builds a genuine schema v3 database and leaves it at `user_version = 3`.
///
/// The fixture goes through the real v2 seed and the real v2-to-v3 migration
/// rather than hand-written DDL, so the file the v4 upgrade receives is exactly
/// the shape a shipped v3 app would leave behind.
private func makeV3Database(at url: URL) throws {
    try learningWithSQLite(at: url) { database in
        try SQLiteSupport.configure(database)
        try SQLiteSupport.execute("BEGIN IMMEDIATE", on: database)
        do {
            try SQLiteAssignmentRepository.createV2SchemaInCurrentTransaction(on: database)
            try SQLiteSupport.execute(
                """
                INSERT INTO assignments (
                    id, course_name, title, due_date, description, link,
                    status, priority, created_at, updated_at
                ) VALUES (
                    1, '\(learningV3CourseName)', '\(learningV3TaskTitle)',
                    '\(learningV3DueDateText)',
                    'Ambiguous DST wall time stays byte-for-byte unchanged.',
                    'https://example.test/lab?a=1&b=2', 'not_started', 'high',
                    '2026-08-01 09:00:00', '2026-08-02 10:00:00'
                )
                """,
                on: database
            )
            try SQLiteSchemaV3.migrateV2ToV3(on: database, databaseInstanceUUID: nil)

            let timestamp = DatabaseTimestamp.string(from: Date())
            try SQLiteSupport.execute(
                """
                INSERT INTO reminders (
                    id, uuid, assignment_id, trigger_at_utc, lead_minutes,
                    repeat_rule, is_enabled, last_scheduled_at, created_at,
                    updated_at, deleted_at
                ) VALUES
                    (1, '\(UUID().canonicalString)', 1,
                     '\(DatabaseTimestamp.string(from: learningV3FixedTrigger))', 0,
                     NULL, 1, NULL, '\(timestamp)', '\(timestamp)', NULL),
                    (2, '\(UUID().canonicalString)', 1,
                     '\(DatabaseTimestamp.string(from: learningV3RepeatTrigger))', 30,
                     'FREQ=DAILY;INTERVAL=1', 1, NULL, '\(timestamp)',
                     '\(timestamp)', NULL)
                """,
                on: database
            )
            try SQLiteSupport.execute("COMMIT", on: database)
        } catch {
            try? SQLiteSupport.execute("ROLLBACK", on: database)
            throw error
        }
    }
}


/// The column list a reminder row had before schema v4 existed. Comparing it
/// before and after the upgrade proves the migration moved nothing.
private let learningReminderSnapshotSQL = """
SELECT id, uuid, assignment_id, trigger_at_utc, lead_minutes, repeat_rule,
       is_enabled, last_scheduled_at, created_at, updated_at, deleted_at
FROM reminders ORDER BY id
"""


private struct LearningInjectedFailure: LocalizedError {
    var errorDescription: String? { "Injected migration failure." }
}


private func learningCaughtError<T>(_ body: () throws -> T) -> Error? {
    do {
        _ = try body()
        return nil
    } catch {
        return error
    }
}


/// True when `body` threw an error of exactly `expected`.
private func learningThrows<E: Error, T>(
    _ expected: E.Type,
    _ body: () throws -> T
) -> Bool {
    do {
        _ = try body()
        return false
    } catch {
        return error is E
    }
}


/// A pair of repositories over one fresh v4 database, plus the course both
/// learning scenes hang off.
private struct LearningSceneFixture {
    let database: LearningTemporaryDatabase
    let tasks: SQLiteAssignmentRepository
    let organization: SQLiteOrganizationRepository
    let course: Course
}


private func makeLearningSceneFixture(
    fileName: String = "assignments.db",
    courseName: String = "Physics 物理"
) throws -> LearningSceneFixture {
    let database = try LearningTemporaryDatabase(fileName: fileName)
    let tasks = try SQLiteAssignmentRepository(databaseURL: database.databaseURL)
    let organization = try SQLiteOrganizationRepository(databaseURL: database.databaseURL)
    let course = try organization.createCourse(.init(
        name: courseName,
        colorHex: "#3366AA",
        teacher: "Dr. Chen",
        semester: "2026-Fall"
    ))
    return .init(
        database: database,
        tasks: tasks,
        organization: organization,
        course: course
    )
}


private func learningMeetingDraft(
    courseID: Int64,
    weekday: Int,
    start: String,
    end: String,
    timezoneID: String = "Asia/Shanghai",
    effectiveStart: String = "2026-09-01"
) -> CourseMeetingDraft {
    .init(
        courseID: courseID,
        weekday: weekday,
        startTimeLocal: start,
        endTimeLocal: end,
        location: "Room A-101",
        teacherOverride: nil,
        timezoneID: timezoneID,
        effectiveStartDate: effectiveStart,
        effectiveEndDate: nil,
        sortOrder: 0
    )
}


// MARK: - Schema v4 migration

@Suite("Schema v4 migration and learning-scene repository")
struct LearningSceneRepositoryTests {

    @Test("v3 to v4 migration keeps every reminder on fixed-trigger semantics")
    func v3ToV4KeepsFixedReminders() throws {
        let temporary = try LearningTemporaryDatabase(fileName: "v3-to-v4.db")
        defer { temporary.cleanup() }
        try makeV3Database(at: temporary.databaseURL)

        let remindersBefore = try learningRows(at: temporary.databaseURL, learningReminderSnapshotSQL)
        #expect(remindersBefore.count == 2)

        let result = try MigrationCoordinator.prepareDatabase(at: temporary.databaseURL)

        #expect(result.fromVersion == 3)
        #expect(result.toVersion == 4)
        #expect(result.migrated)
        #expect(result.strategy == .v3ToV4)
        let backupURL = try #require(result.backupURL)
        #expect(FileManager.default.fileExists(atPath: backupURL.path))

        #expect(try learningScalarInt(at: temporary.databaseURL, "PRAGMA user_version") == 4)
        let tables = try learningTableNames(at: temporary.databaseURL)
        #expect(tables.contains("course_meetings"))
        #expect(tables.contains("exams"))

        // The v3 columns are byte-for-byte identical, and every migrated row
        // is a fixed reminder. Nothing moved, nothing was reinterpreted.
        let remindersAfter = try learningRows(at: temporary.databaseURL, learningReminderSnapshotSQL)
        #expect(remindersAfter == remindersBefore)
        #expect(try learningScalarInt(
            at: temporary.databaseURL,
            "SELECT COUNT(*) FROM reminders WHERE schedule_kind != 'fixed'"
        ) == 0)
        #expect(try learningScalarInt(
            at: temporary.databaseURL,
            "SELECT COUNT(*) FROM reminders"
        ) == 2)

        #expect(try learningScalarText(
            at: temporary.databaseURL,
            "SELECT title FROM assignments WHERE id = 1"
        ) == learningV3TaskTitle)
        #expect(try learningScalarText(
            at: temporary.databaseURL,
            "SELECT due_date FROM assignments WHERE id = 1"
        ) == learningV3DueDateText)
        #expect(try learningScalarText(
            at: temporary.databaseURL,
            "SELECT name FROM courses WHERE id = 1"
        ) == learningV3CourseName)

        // The committed file still satisfies the whole v4 contract.
        try learningWithSQLite(
            at: temporary.databaseURL,
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        ) { database in
            try SQLiteSupport.configure(database, writable: false)
            try SQLiteSchemaV4.validate(on: database)
        }
    }

    @Test("v3 to v4 migration preserves extension tables and columns")
    func v3ToV4PreservesExtensions() throws {
        let temporary = try LearningTemporaryDatabase(fileName: "v3-extension.db")
        defer { temporary.cleanup() }
        try makeV3Database(at: temporary.databaseURL)
        try learningWithSQLite(at: temporary.databaseURL) { database in
            try SQLiteSupport.configure(database)
            try SQLiteSupport.execute(
                "CREATE TABLE extension_probe (id INTEGER PRIMARY KEY, note TEXT)",
                on: database
            )
            try SQLiteSupport.execute(
                "INSERT INTO extension_probe VALUES (1, 'third-party sync marker')",
                on: database
            )
            try SQLiteSupport.execute(
                "ALTER TABLE assignments ADD COLUMN extension_probe TEXT",
                on: database
            )
            try SQLiteSupport.execute(
                "UPDATE assignments SET extension_probe = 'keep me' WHERE id = 1",
                on: database
            )
        }

        _ = try MigrationCoordinator.prepareDatabase(at: temporary.databaseURL)

        #expect(try learningScalarInt(at: temporary.databaseURL, "PRAGMA user_version") == 4)
        #expect(try learningScalarText(
            at: temporary.databaseURL,
            "SELECT note FROM extension_probe WHERE id = 1"
        ) == "third-party sync marker")
        #expect(try learningScalarText(
            at: temporary.databaseURL,
            "SELECT extension_probe FROM assignments WHERE id = 1"
        ) == "keep me")
    }

    @Test("A failed v3 to v4 migration rolls back and keeps the online backup")
    func v3ToV4FailureRollsBack() throws {
        let temporary = try LearningTemporaryDatabase(fileName: "v3-failure.db")
        defer { temporary.cleanup() }
        try makeV3Database(at: temporary.databaseURL)
        let remindersBefore = try learningRows(at: temporary.databaseURL, learningReminderSnapshotSQL)

        let error = learningCaughtError {
            try MigrationCoordinator.prepareDatabase(
                at: temporary.databaseURL,
                migrationFailureInjector: { throw LearningInjectedFailure() }
            )
        }
        let migrationError = try #require(error as? DatabaseMigrationError)
        #expect(migrationError.errorDescription?.contains("rolled back") == true)
        let backupURL = try #require(migrationError.backupURL)
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        // The backup is a real v3 file, not a half-migrated one.
        #expect(try learningScalarInt(at: backupURL, "PRAGMA user_version") == 3)

        #expect(try learningScalarInt(at: temporary.databaseURL, "PRAGMA user_version") == 3)
        let tables = try learningTableNames(at: temporary.databaseURL)
        #expect(!tables.contains("course_meetings"))
        #expect(!tables.contains("exams"))
        let reminderColumns = try learningWithSQLite(
            at: temporary.databaseURL,
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        ) { database in
            try SQLiteSupport.configure(database, writable: false)
            return Set(try SQLiteSupport.columnNames("reminders", on: database))
        }
        #expect(!reminderColumns.contains("schedule_kind"))
        #expect(try learningRows(at: temporary.databaseURL, learningReminderSnapshotSQL)
            == remindersBefore)
        #expect(try learningScalarText(
            at: temporary.databaseURL,
            "SELECT title FROM assignments WHERE id = 1"
        ) == learningV3TaskTitle)
    }

    @Test("A partially migrated v4 database is rejected instead of overwritten")
    func partialV4IsRejected() throws {
        let temporary = try LearningTemporaryDatabase(fileName: "partial-v4.db")
        defer { temporary.cleanup() }
        try makeV3Database(at: temporary.databaseURL)
        try learningWithSQLite(at: temporary.databaseURL) { database in
            try SQLiteSupport.configure(database)
            try SQLiteSupport.execute(
                "CREATE TABLE exams (id INTEGER PRIMARY KEY, name TEXT)",
                on: database
            )
        }

        let error = learningCaughtError {
            try MigrationCoordinator.prepareDatabase(at: temporary.databaseURL)
        }
        let migrationError = try #require(error as? DatabaseMigrationError)
        #expect(migrationError.errorDescription?.contains("Partial v4 tables") == true)

        #expect(try learningScalarInt(at: temporary.databaseURL, "PRAGMA user_version") == 3)
        // The hand-made table survived; the migration did not clobber it.
        #expect(try learningScalarInt(
            at: temporary.databaseURL,
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'exams'"
        ) == 1)
        #expect(try learningScalarInt(
            at: temporary.databaseURL,
            """
            SELECT COUNT(*) FROM sqlite_master
            WHERE type = 'table' AND name = 'course_meetings'
            """
        ) == 0)
    }

    @Test("An already migrated v4 database opens without a second migration")
    func v4OpensWithoutRepeatMigration() throws {
        let temporary = try LearningTemporaryDatabase(fileName: "already-v4.db")
        defer { temporary.cleanup() }
        try makeV3Database(at: temporary.databaseURL)
        let first = try MigrationCoordinator.prepareDatabase(at: temporary.databaseURL)
        #expect(first.strategy == .v3ToV4)

        let second = try MigrationCoordinator.prepareDatabase(at: temporary.databaseURL)
        #expect(second.strategy == .none)
        #expect(second.migrated == false)
        #expect(second.backupURL == nil)
        #expect(second.fromVersion == 4)
        #expect(second.toVersion == 4)
    }

    @Test("A fresh database is created at v4 with the learning tables present")
    func freshDatabaseIsV4() throws {
        let temporary = try LearningTemporaryDatabase(fileName: "fresh-v4.db")
        defer { temporary.cleanup() }
        let result = try MigrationCoordinator.prepareDatabase(at: temporary.databaseURL)
        #expect(result.strategy == .createV4)
        #expect(result.toVersion == 4)
        #expect(result.backupURL == nil)
        let tables = try learningTableNames(at: temporary.databaseURL)
        #expect(tables.isSuperset(of: ["course_meetings", "exams"]))
    }

    // MARK: - Course meetings

    @Test("Course meetings round-trip and overlap warnings never mutate")
    func meetingCRUDAndOverlapWarnings() throws {
        let fixture = try makeLearningSceneFixture(fileName: "meetings.db")
        defer { fixture.database.cleanup() }

        let first = try fixture.organization.createMeeting(
            learningMeetingDraft(
                courseID: fixture.course.id,
                weekday: 1,
                start: "08:00:00",
                end: "09:40:00"
            )
        )
        let second = try fixture.organization.createMeeting(
            learningMeetingDraft(
                courseID: fixture.course.id,
                weekday: 1,
                start: "09:00:00",
                end: "10:40:00"
            )
        )
        let unrelated = try fixture.organization.createMeeting(
            learningMeetingDraft(
                courseID: fixture.course.id,
                weekday: 3,
                start: "09:00:00",
                end: "10:40:00"
            )
        )

        #expect(first.uuid.versionNumber == 4)
        #expect(first.startTimeLocal == "08:00:00")

        // Overlap is a warning. Both clashes are reported and every meeting
        // still exists afterwards: the warning never merges or deletes.
        let collisions = try fixture.organization.meetingsOverlapping(
            learningMeetingDraft(
                courseID: fixture.course.id,
                weekday: 1,
                start: "09:30:00",
                end: "11:00:00"
            ),
            excludingID: nil
        )
        #expect(collisions.map(\.id) == [first.id, second.id])
        #expect(try fixture.organization.fetchMeetings(courseID: nil, includeDeleted: false).count == 3)

        // Excluding the meeting under edit stops it colliding with itself,
        // while a genuine clash is still reported.
        #expect(try fixture.organization.meetingsOverlapping(
            learningMeetingDraft(
                courseID: fixture.course.id,
                weekday: 1,
                start: "09:00:00",
                end: "10:40:00"
            ),
            excludingID: second.id
        ).map(\.id) == [first.id])
        #expect(try fixture.organization.meetingsOverlapping(
            learningMeetingDraft(
                courseID: fixture.course.id,
                weekday: 1,
                start: "09:00:00",
                end: "10:40:00"
            ),
            excludingID: first.id
        ).map(\.id) == [second.id])
        // A free slot and a different weekday never collide.
        #expect(try fixture.organization.meetingsOverlapping(
            learningMeetingDraft(
                courseID: fixture.course.id,
                weekday: 1,
                start: "12:00:00",
                end: "13:00:00"
            ),
            excludingID: nil
        ).isEmpty)
        #expect(try fixture.organization.meetingsOverlapping(
            learningMeetingDraft(
                courseID: fixture.course.id,
                weekday: 5,
                start: "09:00:00",
                end: "10:40:00"
            ),
            excludingID: nil
        ).isEmpty)

        var edited = second
        edited.startTimeLocal = "10:00:00"
        edited.endTimeLocal = "11:40:00"
        edited.location = "Room B-202"
        let saved = try fixture.organization.updateMeeting(edited)
        #expect(saved.uuid == second.uuid)
        #expect(saved.location == "Room B-202")
        // Moving the meeting cleared the clash it used to cause.
        #expect(try fixture.organization.meetingsOverlapping(
            learningMeetingDraft(
                courseID: fixture.course.id,
                weekday: 1,
                start: "08:00:00",
                end: "09:40:00"
            ),
            excludingID: first.id
        ).isEmpty)
        #expect(try fixture.organization.fetchMeetings(courseID: nil, includeDeleted: false).count == 3)

        #expect(try fixture.organization.fetchMeetings(weekday: 3, includeDeleted: false)
            .map(\.id) == [unrelated.id])
        #expect(try fixture.organization.fetchMeetings(courseID: fixture.course.id, includeDeleted: false)
            .count == 3)

        try fixture.organization.deleteMeeting(id: unrelated.id)
        #expect(try fixture.organization.fetchMeetings(courseID: nil, includeDeleted: false).count == 2)
        #expect(try fixture.organization.fetchMeetings(courseID: nil, includeDeleted: true).count == 3)
        let restored = try fixture.organization.restoreMeeting(id: unrelated.id)
        #expect(restored.deletedAt == nil)
        #expect(try fixture.organization.fetchMeetings(courseID: nil, includeDeleted: false).count == 3)
    }

    @Test("Course meetings reject an invalid weekday, clock, or interval")
    func meetingValidation() throws {
        let fixture = try makeLearningSceneFixture(fileName: "meeting-validation.db")
        defer { fixture.database.cleanup() }

        #expect(learningThrows(LearningSceneError.self) {
            try fixture.organization.createMeeting(
                learningMeetingDraft(
                    courseID: fixture.course.id,
                    weekday: 0,
                    start: "08:00:00",
                    end: "09:00:00"
                )
            )
        })
        #expect(learningThrows(LearningSceneError.self) {
            try fixture.organization.createMeeting(
                learningMeetingDraft(
                    courseID: fixture.course.id,
                    weekday: 8,
                    start: "08:00:00",
                    end: "09:00:00"
                )
            )
        })
        #expect(learningThrows(LearningSceneError.self) {
            try fixture.organization.createMeeting(
                learningMeetingDraft(
                    courseID: fixture.course.id,
                    weekday: 1,
                    start: "09:00:00",
                    end: "09:00:00"
                )
            )
        })
        #expect(learningThrows(LearningSceneError.self) {
            try fixture.organization.createMeeting(
                learningMeetingDraft(
                    courseID: fixture.course.id,
                    weekday: 1,
                    start: "10:00:00",
                    end: "09:00:00"
                )
            )
        })
        #expect(learningThrows(LearningSceneError.self) {
            try fixture.organization.createMeeting(
                learningMeetingDraft(
                    courseID: fixture.course.id,
                    weekday: 1,
                    start: "9:00",
                    end: "10:00:00"
                )
            )
        })
        #expect(learningThrows(LearningSceneError.self) {
            try fixture.organization.createMeeting(
                learningMeetingDraft(
                    courseID: fixture.course.id,
                    weekday: 1,
                    start: "08:00:00",
                    end: "09:00:00",
                    timezoneID: "Mars/Olympus_Mons"
                )
            )
        })
        #expect(try fixture.organization.fetchMeetings(courseID: nil, includeDeleted: true).isEmpty)
    }

    // MARK: - Exams

    @Test("Exams round-trip, order by local start, and never delete their review task")
    func examCRUDAndReviewTask() throws {
        let fixture = try makeLearningSceneFixture(fileName: "exams.db")
        defer { fixture.database.cleanup() }

        let midterm = try fixture.organization.createExam(.init(
            courseID: fixture.course.id,
            name: "Midterm 期中考",
            startsAtLocal: "2026-11-10 09:00:00",
            timezoneID: "Asia/Shanghai",
            location: "Hall 3",
            scope: "Chapters 1-5",
            notes: "Closed book"
        ))
        let final = try fixture.organization.createExam(.init(
            courseID: fixture.course.id,
            name: "Final 期末考",
            startsAtLocal: "2026-10-20 14:00:00",
            timezoneID: "Asia/Shanghai",
            status: .upcoming
        ))

        #expect(midterm.uuid.versionNumber == 4)
        #expect(midterm.status == .upcoming)
        #expect(final.id != midterm.id)
        // Local wall-time ordering, earliest first, regardless of creation order.
        #expect(try fixture.organization.fetchExams(courseID: nil, includeDeleted: false)
            .map(\.id) == [final.id, midterm.id])

        // The first call creates the review task; repeating it is idempotent.
        let firstLink = try fixture.tasks.createOrFetchReviewTask(forExam: midterm.id)
        #expect(firstLink.created)
        #expect(firstLink.assignment.title == "Review: Midterm 期中考")
        #expect(firstLink.assignment.priority == .high)
        #expect(firstLink.exam.linkedAssignmentID == firstLink.assignment.id)
        let dueDate = try #require(firstLink.assignment.dueDate)
        let examStart = try #require(midterm.startsAtUTC)
        #expect(abs(dueDate.timeIntervalSince(examStart) + 86_400) < 1)

        let secondLink = try fixture.tasks.createOrFetchReviewTask(forExam: midterm.id)
        #expect(secondLink.created == false)
        #expect(secondLink.assignment.id == firstLink.assignment.id)
        #expect(try fixture.organization.fetchExams(courseID: nil, includeDeleted: false)
            .first { $0.id == midterm.id }?.linkedAssignmentID == firstLink.assignment.id)

        // Statuses round-trip and keep the documented sort order.
        var completed = try #require(
            try fixture.organization.fetchExams(courseID: nil, includeDeleted: false)
                .first { $0.id == final.id }
        )
        completed.status = .completed
        let savedCompleted = try fixture.organization.updateExam(completed)
        #expect(savedCompleted.uuid == completed.uuid)
        #expect(savedCompleted.status == .completed)
        #expect(savedCompleted.linkedAssignmentID == nil)
        #expect(ExamStatus.upcoming.sortRank < ExamStatus.completed.sortRank)
        #expect(ExamStatus.completed.sortRank < ExamStatus.cancelled.sortRank)

        // Deleting the exam must not take the user's task with it.
        try fixture.organization.deleteExam(id: midterm.id)
        #expect(try fixture.organization.fetchExams(courseID: nil, includeDeleted: false)
            .map(\.id) == [final.id])
        let survivingTask = try #require(
            try fixture.tasks.fetchAll().first { $0.id == firstLink.assignment.id }
        )
        #expect(survivingTask.title == "Review: Midterm 期中考")

        let restoredExam = try fixture.organization.restoreExam(id: midterm.id)
        #expect(restoredExam.deletedAt == nil)
        #expect(restoredExam.linkedAssignmentID == firstLink.assignment.id)
    }

    @Test("Exams reject an invalid wall time, time zone, or empty name")
    func examValidation() throws {
        let fixture = try makeLearningSceneFixture(fileName: "exam-validation.db")
        defer { fixture.database.cleanup() }

        #expect(learningThrows(OrganizationRepositoryError.self) {
            try fixture.organization.createExam(.init(
                courseID: fixture.course.id,
                name: "  ",
                startsAtLocal: "2026-11-10 09:00:00",
                timezoneID: "Asia/Shanghai"
            ))
        })
        #expect(learningThrows(LearningSceneError.self) {
            try fixture.organization.createExam(.init(
                courseID: fixture.course.id,
                name: "Bad time",
                startsAtLocal: "2026-11-10 09:00:00Z",
                timezoneID: "Asia/Shanghai"
            ))
        })
        #expect(learningThrows(LearningSceneError.self) {
            try fixture.organization.createExam(.init(
                courseID: fixture.course.id,
                name: "Bad zone",
                startsAtLocal: "2026-11-10 09:00:00",
                timezoneID: "Mars/Olympus_Mons"
            ))
        })
        #expect(try fixture.organization.fetchExams(courseID: nil, includeDeleted: true).isEmpty)
    }

    // MARK: - Reminders

    @Test("Moving a deadline moves due-relative reminders and never fixed ones")
    func relativeReminderFollowsDeadline() throws {
        let fixture = try makeLearningSceneFixture(fileName: "relative-reminders.db")
        defer { fixture.database.cleanup() }

        let originalDue = Date(timeIntervalSince1970: 1_800_000_000)
        var task = try fixture.tasks.create(.init(
            courseName: fixture.course.name,
            title: "Problem set 3",
            dueDate: originalDue
        ))

        let fixed = try fixture.organization.createReminder(.init(
            assignmentID: task.id,
            triggerAtUTC: Date(timeIntervalSince1970: 1_790_000_000),
            leadMinutes: 0
        ))
        let relative = try fixture.organization.createReminder(.init(
            assignmentID: task.id,
            // The draft trigger is ignored for a due-relative reminder; the
            // stored deadline minus the lead time is authoritative.
            triggerAtUTC: Date(timeIntervalSince1970: 0),
            leadMinutes: 60,
            scheduleKind: .dueRelative
        ))
        #expect(fixed.scheduleKind == .fixed)
        #expect(relative.scheduleKind == .dueRelative)
        #expect(relative.isDueRelative)
        #expect(relative.triggerAtUTC == originalDue.addingTimeInterval(-3_600))

        task.dueDate = originalDue.addingTimeInterval(2 * 86_400)
        let moved = try fixture.tasks.update(task)

        let after = try fixture.organization.fetchReminders(
            assignmentID: task.id,
            includeDeleted: false
        )
        let fixedAfter = try #require(after.first { $0.id == fixed.id })
        let relativeAfter = try #require(after.first { $0.id == relative.id })
        let movedDueDate = try #require(moved.dueDate)
        #expect(fixedAfter.triggerAtUTC == fixed.triggerAtUTC)
        #expect(fixedAfter.scheduleKind == .fixed)
        #expect(relativeAfter.triggerAtUTC == movedDueDate.addingTimeInterval(-3_600))
        #expect(relativeAfter.isEnabled)

        // Removing the deadline disables the relative reminder instead of
        // deleting it, so the reason stays visible in the UI.
        task = moved
        task.dueDate = nil
        _ = try fixture.tasks.update(task)
        let withoutDue = try fixture.organization.fetchReminders(
            assignmentID: task.id,
            includeDeleted: false
        )
        let relativeDisabled = try #require(withoutDue.first { $0.id == relative.id })
        #expect(relativeDisabled.isEnabled == false)
        #expect(withoutDue.first { $0.id == fixed.id }?.triggerAtUTC == fixed.triggerAtUTC)
        #expect(withoutDue.count == 2)
    }

    @Test("A due-relative reminder cannot be created without a due date")
    func relativeReminderRequiresDueDate() throws {
        let fixture = try makeLearningSceneFixture(fileName: "no-due-date.db")
        defer { fixture.database.cleanup() }

        let task = try fixture.tasks.create(.init(
            courseName: fixture.course.name,
            title: "Reading notes"
        ))
        #expect(task.dueDate == nil)

        let error = learningCaughtError {
            try fixture.organization.createReminder(.init(
                assignmentID: task.id,
                triggerAtUTC: Date(),
                leadMinutes: 10,
                scheduleKind: .dueRelative
            ))
        }
        #expect(error as? LearningSceneError == .relativeReminderWithoutDueDate)

        #expect(LearningRules.relativeReminderDisabledReason(dueDate: nil) != nil)
        #expect(LearningRules.relativeReminderDisabledReason(dueDate: Date()) == nil)
        #expect(try fixture.organization.fetchReminders(
            assignmentID: task.id,
            includeDeleted: true
        ).isEmpty)

        // A fixed reminder on a task with no deadline is still allowed.
        let fixed = try fixture.organization.createReminder(.init(
            assignmentID: task.id,
            triggerAtUTC: Date(timeIntervalSince1970: 1_800_000_000)
        ))
        #expect(fixed.scheduleKind == .fixed)
    }

    @Test("Rescheduling recomputes relative reminders from the stored deadlines")
    func rescheduleRelativeReminders() throws {
        let fixture = try makeLearningSceneFixture(fileName: "reschedule.db")
        defer { fixture.database.cleanup() }

        let originalDue = Date(timeIntervalSince1970: 1_800_000_000)
        let task = try fixture.tasks.create(.init(
            courseName: fixture.course.name,
            title: "Lab report",
            dueDate: originalDue
        ))
        let relative = try fixture.organization.createReminder(.init(
            assignmentID: task.id,
            triggerAtUTC: Date(timeIntervalSince1970: 0),
            leadMinutes: 1_440,
            scheduleKind: .dueRelative
        ))
        let fixed = try fixture.organization.createReminder(.init(
            assignmentID: task.id,
            triggerAtUTC: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        #expect(relative.triggerAtUTC == originalDue.addingTimeInterval(-86_400))

        // `due_date` stores a local wall time in the row's own time zone, so
        // an external writer has to respect it. This moves the deadline the
        // way a sync or a manual edit would; rescheduling must pick it up.
        let storedZoneID = try learningScalarText(
            at: fixture.database.databaseURL,
            "SELECT timezone_id FROM assignments WHERE id = \(task.id)"
        )
        let zone = storedZoneID.flatMap { TimeZone(identifier: $0) } ?? .current
        let movedDue = originalDue.addingTimeInterval(-3 * 86_400)
        let movedText = LocalWallTime.string(from: movedDue, timeZone: zone)
        try learningWithSQLite(at: fixture.database.databaseURL) { database in
            try SQLiteSupport.configure(database)
            try SQLiteSupport.execute(
                "UPDATE assignments SET due_date = '\(movedText)' WHERE id = \(task.id)",
                on: database
            )
        }
        let expectedDue = try LocalWallTime.legacyDate(from: movedText, timeZone: zone)

        let rescheduled = try fixture.organization.rescheduleRelativeReminders()
        #expect(rescheduled.map(\.id) == [relative.id])
        #expect(rescheduled.first?.triggerAtUTC == expectedDue.addingTimeInterval(-86_400))
        #expect(try fixture.organization.fetchReminders(
            assignmentID: task.id,
            includeDeleted: false
        ).first { $0.id == fixed.id }?.triggerAtUTC == fixed.triggerAtUTC)

        // A relative reminder whose task lost its deadline is disabled, not
        // deleted, so the user can still see why it stopped firing.
        try learningWithSQLite(at: fixture.database.databaseURL) { database in
            try SQLiteSupport.configure(database)
            try SQLiteSupport.execute(
                "UPDATE assignments SET due_date = NULL WHERE id = \(task.id)",
                on: database
            )
        }
        let afterLoss = try fixture.organization.rescheduleRelativeReminders()
        #expect(afterLoss.map(\.id) == [relative.id])
        #expect(afterLoss.first?.isEnabled == false)
        #expect(try learningScalarInt(
            at: fixture.database.databaseURL,
            "SELECT COUNT(*) FROM reminders"
        ) == 2)
    }

    @Test("The schedule-kind discriminator matches the schema v4 check constraint")
    func scheduleKindMatchesSchema() throws {
        #expect(ReminderScheduleKind.fixed.rawValue == "fixed")
        #expect(ReminderScheduleKind.dueRelative.rawValue == "due_relative")
        #expect(ReminderScheduleKind.allCases.count == 2)
        #expect(RelativeReminderPreset.allCases.map(\.leadMinutes) == [10, 60, 1_440])
    }
}
