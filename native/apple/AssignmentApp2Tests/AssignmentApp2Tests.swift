import Foundation
import SQLite3
import Testing
@testable import AssignmentApp2


private enum TestSupportError: Error {
    case invalidFixtureDate(String)
    case sqlite(String)
    case missingValue(String)
}


private struct InjectedMigrationFailure: Error {}


private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.firstWeekday = 2
    return calendar
}


private func wallTime(_ value: String) throws -> Date {
    guard let date = try LocalWallTime.date(
        from: value,
        timeZone: TimeZone(secondsFromGMT: 0)!
    ) else {
        throw TestSupportError.invalidFixtureDate(value)
    }
    return date
}


private func makeAssignment(
    id: Int64,
    course: String = "Course",
    title: String,
    due: String? = nil,
    status: AssignmentStatus = .todo,
    priority: AssignmentPriority = .medium,
    description: String? = nil,
    link: String? = nil
) throws -> Assignment {
    Assignment(
        id: id,
        courseName: course,
        title: title,
        dueDate: try due.map(wallTime),
        assignmentDescription: description,
        link: link,
        status: status,
        priority: priority,
        createdAt: try wallTime("2026-08-01 00:00:00"),
        updatedAt: try wallTime("2026-08-01 00:00:00")
    )
}


/// Mirrors `shared/fixtures/task-conformance-v2.json`. Keeping the fixture
/// values explicit makes the Apple tests runnable in an isolated test bundle.
private func sharedFixtureTasks() throws -> [Assignment] {
    [
        try makeAssignment(
            id: 1,
            course: "Mathematics",
            title: "Problem set 3",
            due: "2026-08-04 10:00:00",
            status: .todo,
            priority: .high,
            description: "Complete questions 1-10.",
            link: "https://example.edu/math/3"
        ),
        try makeAssignment(
            id: 2,
            course: "Physics",
            title: "Lab notes",
            due: "2026-08-05 18:00:00",
            status: .inProgress,
            priority: .medium,
            description: "整理实验结果 / organize results"
        ),
        try makeAssignment(
            id: 3,
            course: "History",
            title: "Read chapter 8",
            due: "2026-08-05 09:00:00",
            status: .done,
            priority: .low
        ),
        try makeAssignment(
            id: 4,
            course: "English",
            title: "Essay draft",
            due: "2026-08-07 23:59:00",
            status: .todo,
            priority: .low,
            description: "Use apostrophe's, quotes \"like this\", and emoji 📚.",
            link: "https://example.edu/english?week=1&item=draft"
        ),
        try makeAssignment(
            id: 5,
            course: "Computer Science",
            title: "Compiler project",
            due: "2026-08-10 00:00:00",
            status: .todo,
            priority: .high,
            description: "Next natural week boundary."
        ),
        try makeAssignment(
            id: 6,
            course: "高等数学",
            title: "复习积分 & 极限",
            status: .todo,
            priority: .medium,
            description: "包含中文、emoji 🧮、换行\n与特殊字符 <>&.",
            link: "https://例子.测试/课程"
        ),
        try makeAssignment(
            id: 7,
            course: "Chemistry",
            title: "Old completed lab",
            due: "2026-08-01 08:00:00",
            status: .done,
            priority: .high,
            description: "A completed task is never overdue."
        ),
    ]
}


private final class TemporaryDatabase {
    let directoryURL: URL
    let databaseURL: URL

    init(fileName: String = "assignments.db") throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssignmentApp2Tests-\(UUID().uuidString)", isDirectory: true)
        databaseURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}


private func withSQLite<T>(
    at databaseURL: URL,
    _ body: (OpaquePointer) throws -> T
) throws -> T {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK,
          let database else {
        let message = database.map { String(cString: sqlite3_errmsg($0)) }
            ?? "Unable to open SQLite database."
        if let database {
            sqlite3_close(database)
        }
        throw TestSupportError.sqlite(message)
    }
    defer { sqlite3_close(database) }
    return try body(database)
}


private func executeSQL(at databaseURL: URL, _ sql: String) throws {
    try withSQLite(at: databaseURL) { database in
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw TestSupportError.sqlite(message)
        }
    }
}


private func scalarInt(at databaseURL: URL, sql: String) throws -> Int64 {
    try withSQLite(at: databaseURL) { database in
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw TestSupportError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw TestSupportError.missingValue(sql)
        }
        return sqlite3_column_int64(statement, 0)
    }
}


private func scalarText(at databaseURL: URL, sql: String) throws -> String {
    try withSQLite(at: databaseURL) { database in
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw TestSupportError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else {
            throw TestSupportError.missingValue(sql)
        }
        return String(cString: text)
    }
}


private func tableColumns(at databaseURL: URL) throws -> [String] {
    try withSQLite(at: databaseURL) { database in
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "PRAGMA table_info(assignments)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement else {
            throw TestSupportError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 1) {
                result.append(String(cString: text))
            }
        }
        return result
    }
}


private func createV1Database(at databaseURL: URL) throws {
    try executeSQL(
        at: databaseURL,
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
            source_name VARCHAR(255),
            source_type VARCHAR(80),
            source_file VARCHAR(1000),
            source_url VARCHAR(1000),
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
            CHECK (status IN ('not_started', 'in_progress', 'completed'))
        );
        INSERT INTO assignments (
            id, course_name, title, due_date, description, link, status,
            source_url, created_at, updated_at
        ) VALUES (
            41,
            '语文 / English',
            'Legacy''s "special" task 📚',
            '2026-08-05 18:30:00',
            '保留 <>& and emoji 🧪',
            'https://example.test/?a=1&b=二',
            'completed',
            'https://例子.测试/source',
            '2026-08-01 01:02:03',
            '2026-08-02 04:05:06'
        );
        INSERT INTO assignments (
            id, course_name, title, due_date, status, created_at, updated_at
        ) VALUES (
            42,
            'Physics',
            'Legacy todo',
            NULL,
            'not_started',
            '2026-08-01 01:02:03',
            '2026-08-02 04:05:06'
        );
        PRAGMA user_version = 0;
        """
    )
}


@Suite("Shared task rules")
struct SharedTaskRuleTests {
    @Test("Today uses a half-open local-day range and includes completed tasks")
    func todayCalculation() throws {
        let now = try wallTime("2026-08-05 12:00:00")
        let tasks = [
            try makeAssignment(id: 1, title: "Start", due: "2026-08-05 00:00:00"),
            try makeAssignment(
                id: 2,
                title: "Completed today",
                due: "2026-08-05 23:59:59",
                status: .done
            ),
            try makeAssignment(id: 3, title: "Boundary", due: "2026-08-06 00:00:00"),
        ]

        let ids = TaskRules.tasks(tasks, in: .today, now: now, calendar: utcCalendar()).map(\.id)
        #expect(ids == [1, 2])
    }

    @Test("This week is the natural Monday week with an excluded next-Monday boundary")
    func naturalWeekCalculation() throws {
        let now = try wallTime("2026-08-05 12:00:00")
        let tasks = [
            try makeAssignment(id: 1, title: "Monday", due: "2026-08-03 00:00:00"),
            try makeAssignment(id: 2, title: "Sunday", due: "2026-08-09 23:59:59"),
            try makeAssignment(id: 3, title: "Next Monday", due: "2026-08-10 00:00:00"),
        ]

        let bounds = TaskRules.weekBounds(containing: now, calendar: utcCalendar())
        let expectedStart = try wallTime("2026-08-03 00:00:00")
        let expectedEnd = try wallTime("2026-08-10 00:00:00")
        #expect(bounds.lowerBound == expectedStart)
        #expect(bounds.upperBound == expectedEnd)
        #expect(
            TaskRules.tasks(tasks, in: .week, now: now, calendar: utcCalendar()).map(\.id)
                == [1, 2]
        )
    }

    @Test("Overdue compares the full deadline with now")
    func overdueCalculation() throws {
        let now = try wallTime("2026-08-05 12:00:00")
        let before = try makeAssignment(id: 1, title: "Before", due: "2026-08-05 11:59:59")
        let equal = try makeAssignment(id: 2, title: "Equal", due: "2026-08-05 12:00:00")

        #expect(TaskRules.matchesView(before, view: .overdue, now: now))
        #expect(!TaskRules.matchesView(equal, view: .overdue, now: now))
    }

    @Test("Completed tasks never appear as overdue")
    func completedIsNotOverdue() throws {
        let assignment = try makeAssignment(
            id: 1,
            title: "Already done",
            due: "2026-08-01 08:00:00",
            status: .done
        )

        #expect(
            !TaskRules.matchesView(
                assignment,
                view: .overdue,
                now: try wallTime("2026-08-05 12:00:00")
            )
        )
    }

    @Test("A task without a due date stays out of all date smart lists")
    func missingDueDateHandling() throws {
        let assignment = try makeAssignment(id: 1, title: "Someday", status: .done)
        let now = try wallTime("2026-08-05 12:00:00")

        #expect(!TaskRules.matchesView(assignment, view: .today, now: now))
        #expect(!TaskRules.matchesView(assignment, view: .week, now: now))
        #expect(!TaskRules.matchesView(assignment, view: .overdue, now: now))
        #expect(TaskRules.matchesView(assignment, view: .all, now: now))
        #expect(TaskRules.matchesView(assignment, view: .completed, now: now))
    }

    @Test("Due-date sort is ascending with missing due dates last")
    func dueDateSort() throws {
        let tasks = [
            try makeAssignment(id: 3, title: "No due"),
            try makeAssignment(id: 2, title: "Later", due: "2026-08-06 12:00:00"),
            try makeAssignment(id: 1, title: "Sooner", due: "2026-08-05 12:00:00"),
        ]

        #expect(TaskRules.sort(tasks, by: .dueDate).map(\.id) == [1, 2, 3])
    }

    @Test("Priority sort is high, medium, low with due-date tie breaking")
    func prioritySort() throws {
        let tasks = [
            try makeAssignment(
                id: 1,
                title: "Low",
                due: "2026-08-01 00:00:00",
                priority: .low
            ),
            try makeAssignment(
                id: 2,
                title: "High later",
                due: "2026-08-03 00:00:00",
                priority: .high
            ),
            try makeAssignment(
                id: 3,
                title: "Medium",
                due: "2026-08-02 00:00:00",
                priority: .medium
            ),
            try makeAssignment(
                id: 4,
                title: "High sooner",
                due: "2026-08-02 00:00:00",
                priority: .high
            ),
        ]

        #expect(TaskRules.sort(tasks, by: .priority).map(\.id) == [4, 2, 3, 1])
    }

    @Test("Search matches title case-insensitively")
    func searchTitle() throws {
        let tasks = try sharedFixtureTasks()
        #expect(TaskRules.search(tasks, query: "  PROBLEM set ").map(\.id) == [1])
    }

    @Test("Search matches course case-insensitively")
    func searchCourse() throws {
        let tasks = try sharedFixtureTasks()
        #expect(TaskRules.search(tasks, query: " physics ").map(\.id) == [2])
    }

    @Test("Search matches descriptions containing Chinese text")
    func searchDescription() throws {
        let tasks = try sharedFixtureTasks()
        #expect(TaskRules.search(tasks, query: "整理实验").map(\.id) == [2])
    }

    @Test("Status, course, and priority filters combine with logical AND")
    func filtersCombineWithAnd() throws {
        let tasks = try sharedFixtureTasks()

        #expect(TaskRules.filter(tasks, status: .done).map(\.id) == [3, 7])
        #expect(TaskRules.filter(tasks, course: " physics ").map(\.id) == [2])
        #expect(TaskRules.filter(tasks, priority: .high).map(\.id) == [1, 5, 7])

        let result = TaskRules.filter(
            tasks,
            status: .todo,
            course: " mathematics ",
            priority: .high
        )
        #expect(result.map(\.id) == [1])
    }

    @Test("Simple and professional modes are projections over one unchanged record")
    func displayModeProjectionDoesNotLoseData() throws {
        let assignment = try sharedFixtureTasks()[0]
        let original = assignment
        let simple = TaskRules.project(assignment, for: .simple)
        let professional = TaskRules.project(assignment, for: .professional)

        #expect(simple.assignmentDescription == nil)
        #expect(simple.priority == nil)
        #expect(simple.link == nil)
        #expect(professional.assignmentDescription == original.assignmentDescription)
        #expect(professional.priority == original.priority)
        #expect(professional.link == original.link)
        #expect(assignment == original)
    }

    @Test("Offset-bearing due dates are rejected rather than shifted")
    func offsetBearingDueDateIsRejected() {
        #expect(throws: AssignmentDataError.self) {
            _ = try LocalWallTime.date(from: "2026-08-05T12:00:00+08:00")
        }
        #expect(throws: AssignmentDataError.self) {
            _ = try LocalWallTime.date(from: "2026-08-05T04:00:00Z")
        }
    }

    @Test("Apple smart lists match every shared fixture view")
    func sharedFixtureViews() throws {
        let tasks = try sharedFixtureTasks()
        let now = try wallTime("2026-08-05 12:00:00")
        let expected: [AssignmentView: [Int64]] = [
            .all: [1, 2, 3, 4, 5, 6, 7],
            .today: [2, 3],
            .week: [1, 2, 3, 4],
            .overdue: [1],
            .completed: [3, 7],
        ]

        for (view, expectedIDs) in expected {
            let actual = TaskRules.tasks(
                tasks,
                in: view,
                now: now,
                calendar: utcCalendar()
            ).map(\.id)
            #expect(actual == expectedIDs)
        }
    }

    @Test("Apple sort orders match the shared fixture")
    func sharedFixtureSorts() throws {
        let tasks = try sharedFixtureTasks()
        #expect(TaskRules.sort(tasks, by: .dueDate).map(\.id) == [7, 1, 3, 2, 4, 5, 6])
        #expect(TaskRules.sort(tasks, by: .priority).map(\.id) == [7, 1, 5, 2, 6, 3, 4])
    }
}


@Suite("SQLite repository and migration")
struct SQLiteRepositoryTests {
    @Test("Adding a task persists every editable field with legacy status storage")
    func addTask() throws {
        let temporary = try TemporaryDatabase()
        defer { temporary.cleanup() }
        let repository = try SQLiteAssignmentRepository(databaseURL: temporary.databaseURL)
        let dueDate = try LocalWallTime.date(from: "2026-08-08 16:30:00")

        let created = try repository.create(
            AssignmentDraft(
                courseName: "  Physics  ",
                title: "  Wave lab  ",
                dueDate: dueDate,
                assignmentDescription: "Initial notes 🧪",
                link: "https://example.test/lab?a=1&b=二",
                status: .todo,
                priority: .high
            )
        )

        #expect(created.id > 0)
        #expect(created.courseName == "Physics")
        #expect(created.title == "Wave lab")
        #expect(created.assignmentDescription == "Initial notes 🧪")
        #expect(created.link == "https://example.test/lab?a=1&b=二")
        #expect(created.status == .todo)
        #expect(created.priority == .high)
        let persistedAssignments = try repository.fetchAll()
        #expect(persistedAssignments == [created])
        #expect(
            try scalarText(
                at: temporary.databaseURL,
                sql: "SELECT status FROM assignments WHERE id = \(created.id)"
            ) == "not_started"
        )
    }

    @Test("Editing a task preserves its identity and replaces editable values")
    func editTask() throws {
        let temporary = try TemporaryDatabase()
        defer { temporary.cleanup() }
        let repository = try SQLiteAssignmentRepository(databaseURL: temporary.databaseURL)
        var assignment = try repository.create(
            AssignmentDraft(courseName: "Physics", title: "Wave lab")
        )
        let originalID = assignment.id

        assignment.courseName = "计算机科学"
        assignment.title = "Updated compiler's \"parser\" 📚"
        assignment.assignmentDescription = "Edited <>&\n第二行"
        assignment.link = "https://例子.测试/?q=值&n=2"
        assignment.priority = .low
        assignment.status = .inProgress
        let updated = try repository.update(assignment)

        #expect(updated.id == originalID)
        #expect(updated.courseName == "计算机科学")
        #expect(updated.title == "Updated compiler's \"parser\" 📚")
        #expect(updated.assignmentDescription == "Edited <>&\n第二行")
        #expect(updated.link == "https://例子.测试/?q=值&n=2")
        #expect(updated.priority == .low)
        #expect(updated.status == .inProgress)
    }

    @Test("Deleting a task removes only the selected row")
    func deleteTask() throws {
        let temporary = try TemporaryDatabase()
        defer { temporary.cleanup() }
        let repository = try SQLiteAssignmentRepository(databaseURL: temporary.databaseURL)
        let first = try repository.create(
            AssignmentDraft(courseName: "Math", title: "Delete me")
        )
        let second = try repository.create(
            AssignmentDraft(courseName: "History", title: "Keep me")
        )

        try repository.delete(id: first.id)

        let remainingIDs = try repository.fetchAll().map(\.id)
        #expect(remainingIDs == [second.id])
        #expect(
            try scalarInt(at: temporary.databaseURL, sql: "SELECT COUNT(*) FROM assignments")
                == 1
        )
    }

    @Test("Changing todo to done stores completed and exposes completed time")
    func markDone() throws {
        let temporary = try TemporaryDatabase()
        defer { temporary.cleanup() }
        let repository = try SQLiteAssignmentRepository(databaseURL: temporary.databaseURL)
        let created = try repository.create(
            AssignmentDraft(courseName: "Math", title: "Finish me", status: .todo)
        )

        let completed = try repository.updateStatus(id: created.id, status: .done)

        #expect(completed.status == .done)
        #expect(completed.completedAt != nil)
        #expect(
            try scalarText(
                at: temporary.databaseURL,
                sql: "SELECT status FROM assignments WHERE id = \(created.id)"
            ) == "completed"
        )
    }

    @Test("Changing done back to todo clears the derived completed time")
    func restoreTodo() throws {
        let temporary = try TemporaryDatabase()
        defer { temporary.cleanup() }
        let repository = try SQLiteAssignmentRepository(databaseURL: temporary.databaseURL)
        let created = try repository.create(
            AssignmentDraft(courseName: "Math", title: "Restore me", status: .done)
        )

        let restored = try repository.updateStatus(id: created.id, status: .todo)

        #expect(restored.status == .todo)
        #expect(restored.completedAt == nil)
        #expect(
            try scalarText(
                at: temporary.databaseURL,
                sql: "SELECT status FROM assignments WHERE id = \(created.id)"
            ) == "not_started"
        )
    }

    @Test("A user_version zero v1 database migrates without losing IDs or status meaning")
    func migrateV1DataAndStatuses() throws {
        let temporary = try TemporaryDatabase(fileName: "legacy.db")
        defer { temporary.cleanup() }
        try createV1Database(at: temporary.databaseURL)

        let repository = try SQLiteAssignmentRepository(databaseURL: temporary.databaseURL)
        let assignments = try repository.fetchAll()

        #expect(try repository.schemaVersion == 2)
        #expect(repository.lastMigrationResult.fromVersion == 1)
        #expect(repository.lastMigrationResult.toVersion == 2)
        #expect(repository.lastMigrationResult.migrated)
        #expect(assignments.map(\.id) == [41, 42])
        #expect(assignments.map(\.status) == [.done, .todo])
        #expect(assignments.allSatisfy { $0.priority == .medium })
    }

    @Test("Migration creates a readable standalone backup before schema changes")
    func migrationCreatesBackup() throws {
        let temporary = try TemporaryDatabase(fileName: "legacy.db")
        defer { temporary.cleanup() }
        try createV1Database(at: temporary.databaseURL)

        let repository = try SQLiteAssignmentRepository(databaseURL: temporary.databaseURL)
        guard let backupURL = repository.lastMigrationResult.backupURL else {
            Issue.record("Migration did not report its backup URL.")
            return
        }

        let backupColumns = try tableColumns(at: backupURL)
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        #expect(try scalarInt(at: backupURL, sql: "PRAGMA user_version") == 0)
        #expect(!backupColumns.contains("priority"))
        #expect(
            try scalarText(
                at: backupURL,
                sql: "SELECT title FROM assignments WHERE id = 41"
            ) == "Legacy's \"special\" task 📚"
        )
    }

    @Test("Injected migration failure throws, restores v1, and leaves the backup recoverable")
    func failedMigrationRestoresOriginal() throws {
        let temporary = try TemporaryDatabase(fileName: "legacy.db")
        defer { temporary.cleanup() }
        try createV1Database(at: temporary.databaseURL)
        var injectorRan = false
        var migrationError: DatabaseMigrationError?

        do {
            _ = try SQLiteAssignmentRepository(
                databaseURL: temporary.databaseURL,
                migrationFailureInjector: {
                    injectorRan = true
                    throw InjectedMigrationFailure()
                }
            )
            Issue.record("Migration unexpectedly succeeded after fault injection.")
        } catch let error as DatabaseMigrationError {
            migrationError = error
        } catch {
            Issue.record("Unexpected migration error type: \(error)")
        }

        let restoredColumns = try tableColumns(at: temporary.databaseURL)
        #expect(injectorRan)
        #expect(migrationError != nil)
        #expect(migrationError?.errorDescription?.contains("restored") == true)
        #expect(try scalarInt(at: temporary.databaseURL, sql: "PRAGMA user_version") == 0)
        #expect(!restoredColumns.contains("priority"))
        #expect(
            try scalarText(
                at: temporary.databaseURL,
                sql: "SELECT title FROM assignments WHERE id = 41"
            ) == "Legacy's \"special\" task 📚"
        )
        if let backupURL = migrationError?.backupURL {
            #expect(FileManager.default.fileExists(atPath: backupURL.path))
            #expect(try scalarInt(at: backupURL, sql: "PRAGMA user_version") == 0)
        } else {
            Issue.record("Migration failure did not preserve a backup URL.")
        }
    }

    @Test("Chinese, emoji, newlines, quotes, and URL characters survive migration")
    func specialCharactersSurviveMigration() throws {
        let temporary = try TemporaryDatabase(fileName: "legacy.db")
        defer { temporary.cleanup() }
        try createV1Database(at: temporary.databaseURL)

        let repository = try SQLiteAssignmentRepository(databaseURL: temporary.databaseURL)
        guard let assignment = try repository.fetchAll().first(where: { $0.id == 41 }) else {
            Issue.record("Migrated Unicode fixture is missing.")
            return
        }

        #expect(assignment.courseName == "语文 / English")
        #expect(assignment.title == "Legacy's \"special\" task 📚")
        #expect(assignment.assignmentDescription == "保留 <>& and emoji 🧪")
        #expect(assignment.link == "https://example.test/?a=1&b=二")
        #expect(assignment.sourceURL == "https://例子.测试/source")
    }

    @Test("A fresh database is v2 and enforces the medium priority default")
    func databaseV2VersionAndPriorityDefault() throws {
        let temporary = try TemporaryDatabase()
        defer { temporary.cleanup() }
        let repository = try SQLiteAssignmentRepository(databaseURL: temporary.databaseURL)

        try executeSQL(
            at: temporary.databaseURL,
            """
            INSERT INTO assignments (course_name, title)
            VALUES ('Biology', 'Default priority');
            """
        )

        let v2Columns = try tableColumns(at: temporary.databaseURL)
        #expect(try repository.schemaVersion == 2)
        #expect(SQLiteAssignmentRepository.databaseVersion == 2)
        #expect(v2Columns.contains("priority"))
        #expect(
            try scalarText(
                at: temporary.databaseURL,
                sql: "SELECT priority FROM assignments WHERE title = 'Default priority'"
            ) == "medium"
        )
        #expect(
            try scalarText(
                at: temporary.databaseURL,
                sql: "SELECT status FROM assignments WHERE title = 'Default priority'"
            ) == "not_started"
        )
    }
}
