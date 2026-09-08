import Foundation
import SQLite3
import Testing


/// Paths owned by one synchronous test scope. Repositories must be created
/// inside `withTemporarySQLiteDatabase`, so they are destroyed before cleanup.
struct TemporarySQLiteDatabase {
    let directoryURL: URL
    let databaseURL: URL

    var root: URL { directoryURL }
    var attachmentsRoot: URL {
        directoryURL.appendingPathComponent("attachments", isDirectory: true)
    }
}


func withTemporarySQLiteDatabase(
    fileName: String = "assignments.db",
    _ body: (TemporarySQLiteDatabase) throws -> Void
) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "AssignmentApp2SQLiteTests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record(error, "Could not remove temporary SQLite test directory: \(directory.path)")
        }
    }

    // A cleanup defer in the caller would run while its repository locals (or
    // a fixture containing them) were still alive. Return from the entire body
    // and drain Foundation's temporary objects before unlinking SQLite files.
    try autoreleasepool {
        try body(.init(
            directoryURL: directory,
            databaseURL: directory.appendingPathComponent(fileName, isDirectory: false)
        ))
    }
}


/// A leaked statement must fail the test, while still releasing its resources
/// so even a failing test does not unlink a database with an open connection.
func closeTestSQLiteConnection(_ database: OpaquePointer) {
    let firstStatement = sqlite3_next_stmt(database, nil)
    #expect(firstStatement == nil, "SQLite test helper left an unfinalized statement")
    while let statement = sqlite3_next_stmt(database, nil) {
        sqlite3_finalize(statement)
    }
    let result = sqlite3_close(database)
    #expect(result == SQLITE_OK, "SQLite test connection did not close cleanly")
}

/// Async repositories stay inside the awaited body; none may escape it.
func withTemporarySQLiteDatabaseAsync(_ body: (TemporarySQLiteDatabase) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AssignmentApp2AsyncTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        do { try FileManager.default.removeItem(at: directory) }
        catch { Issue.record(error, "Could not remove async SQLite fixture") }
    }
    try await body(.init(directoryURL: directory, databaseURL: directory.appendingPathComponent("assignments.db")))
}
