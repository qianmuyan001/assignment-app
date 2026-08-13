import CryptoKit
import Foundation
import SQLite3


enum DatabaseLogicalFingerprint {
    private struct ColumnMetadata {
        let name: String
        let primaryKeyPosition: Int
    }

    static func capture(on database: OpaquePointer) throws -> String {
        var payload = "user_version=\(try SQLiteSupport.scalarInt("PRAGMA user_version", on: database))\n"
        payload += try rows(
            """
            SELECT type, name, tbl_name, ifnull(sql, '<NULL>')
            FROM sqlite_master
            WHERE name NOT LIKE 'sqlite_%'
            ORDER BY type, name
            """,
            on: database
        )

        let tableStatement = try SQLiteSupport.prepare(
            """
            SELECT name FROM sqlite_master
            WHERE type = 'table'
              AND (name NOT LIKE 'sqlite_%' OR name = 'sqlite_sequence')
            ORDER BY name
            """,
            on: database
        )
        defer { sqlite3_finalize(tableStatement) }
        var result = sqlite3_step(tableStatement)
        while result == SQLITE_ROW {
            guard let table = SQLiteSupport.text(tableStatement, 0) else {
                throw DatabaseMigrationError("Could not fingerprint a table name.")
            }
            let metadata = try columnMetadata(for: table, on: database)
            let columns = metadata.map(\.name)
            payload += "table=\(table)|columns=\(columns.joined(separator: ","))\n"
            let expressions = metadata.flatMap { column -> [String] in
                let quoted = SQLiteSupport.quoteIdentifier(column.name)
                return ["typeof(\(quoted))", "quote(\(quoted))"]
            }.joined(separator: ", ")
            let primaryKey = metadata
                .filter { $0.primaryKeyPosition > 0 }
                .sorted { $0.primaryKeyPosition < $1.primaryKeyPosition }
            let order: String
            if primaryKey.isEmpty {
                // Rowid is deterministic for ordinary tables. WITHOUT ROWID
                // tables always have a declared primary key and therefore use
                // the branch above; never assume an `id` column exists.
                order = " ORDER BY rowid"
            } else {
                order = " ORDER BY " + primaryKey
                    .map { SQLiteSupport.quoteIdentifier($0.name) }
                    .joined(separator: ", ")
            }
            payload += try rows(
                "SELECT \(expressions) FROM \(SQLiteSupport.quoteIdentifier(table))\(order)",
                on: database
            )
            result = sqlite3_step(tableStatement)
        }
        guard result == SQLITE_DONE else {
            throw DatabaseMigrationError(String(cString: sqlite3_errmsg(database)))
        }
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func columnMetadata(
        for table: String,
        on database: OpaquePointer
    ) throws -> [ColumnMetadata] {
        let statement = try SQLiteSupport.prepare(
            "PRAGMA table_info(\(SQLiteSupport.quoteIdentifier(table)))",
            on: database
        )
        defer { sqlite3_finalize(statement) }
        var columns: [ColumnMetadata] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let name = SQLiteSupport.text(statement, 1) else {
                throw DatabaseMigrationError("Could not fingerprint a column name in \(table).")
            }
            columns.append(
                .init(
                    name: name,
                    primaryKeyPosition: Int(sqlite3_column_int(statement, 5))
                )
            )
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE, !columns.isEmpty else {
            throw DatabaseMigrationError(
                "Could not read deterministic column metadata for \(table)."
            )
        }
        return columns
    }

    private static func rows(_ sql: String, on database: OpaquePointer) throws -> String {
        let statement = try SQLiteSupport.prepare(sql, on: database)
        defer { sqlite3_finalize(statement) }
        var output = ""
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            for column in 0..<sqlite3_column_count(statement) {
                if column > 0 { output.append("|") }
                if let value = SQLiteSupport.text(statement, column) {
                    output += "\(value.utf8.count):\(value)"
                } else {
                    output += "<NULL>"
                }
            }
            output.append("\n")
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw DatabaseMigrationError(String(cString: sqlite3_errmsg(database)))
        }
        return output
    }
}
