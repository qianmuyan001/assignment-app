import Foundation
import SQLite3
import Darwin


enum MigrationCoordinator {
    static func prepareDatabase(
        at databaseURL: URL,
        migrationFailureInjector: (() throws -> Void)? = nil,
        postCommitValidationFailureInjector: (() throws -> Void)? = nil,
        databaseInstanceUUID: UUID? = nil
    ) throws -> MigrationResult {
        SQLiteAssignmentRepository.preconditionSafeTestDatabaseURL(databaseURL)
        return try DatabaseMigrationLock.withExclusiveLock(for: databaseURL) {
            try prepareWhileLocked(
                at: databaseURL,
                migrationFailureInjector: migrationFailureInjector,
                postCommitValidationFailureInjector: postCommitValidationFailureInjector,
                databaseInstanceUUID: databaseInstanceUUID
            )
        }
    }
}


private extension MigrationCoordinator {
    struct DispatchState {
        let storedVersion: Int32
        let sourceVersion: Int32
        let hasAssignments: Bool
        let isFresh: Bool
    }

    struct DatabaseSnapshot {
        let storedVersion: Int32
        let fingerprint: String
    }

    struct CommittedOutcome {
        let result: MigrationResult
        let originalSnapshot: DatabaseSnapshot?
    }

    static func prepareWhileLocked(
        at databaseURL: URL,
        migrationFailureInjector: (() throws -> Void)?,
        postCommitValidationFailureInjector: (() throws -> Void)?,
        databaseInstanceUUID: UUID?
    ) throws -> MigrationResult {
        var writer: OpaquePointer? = try SQLiteSupport.open(databaseURL)
        var transactionActive = false
        var backupURL: URL?
        var originalSnapshot: DatabaseSnapshot?
        var committedOutcome: CommittedOutcome?

        // Transaction phase. Nothing after COMMIT belongs in this catch: a
        // post-commit failure must never rollback or close a released pointer.
        do {
            guard let activeWriter = writer else {
                throw DatabaseMigrationError("Could not open migration writer.")
            }
            try SQLiteSupport.configure(activeWriter)
            try SQLiteSupport.execute("BEGIN IMMEDIATE", on: activeWriter)
            transactionActive = true
            let state = try dispatchState(on: activeWriter)

            if state.sourceVersion == SQLiteSchemaV3.databaseVersion {
                try SQLiteSchemaV3.validate(on: activeWriter)
                try SQLiteSupport.execute("COMMIT", on: activeWriter)
                transactionActive = false
                committedOutcome = .init(
                    result: MigrationResult(
                        fromVersion: SQLiteSchemaV3.databaseVersion,
                        toVersion: SQLiteSchemaV3.databaseVersion,
                        migrated: false,
                        backupURL: nil,
                        strategy: .none
                    ),
                    originalSnapshot: nil
                )
            } else {
                if !state.isFresh {
                    let createdBackup = uniqueBackupURL(
                        for: databaseURL,
                        fromVersion: state.sourceVersion
                    )
                    let snapshot = try createOnlineBackup(
                        from: databaseURL,
                        to: createdBackup,
                        expectedStoredVersion: state.storedVersion,
                        sourceConnection: activeWriter
                    )
                    backupURL = createdBackup
                    originalSnapshot = snapshot
                }

                let strategy: MigrationStrategy
                switch state.sourceVersion {
                case 0 where state.isFresh:
                    try SQLiteAssignmentRepository.createV2SchemaInCurrentTransaction(
                        on: activeWriter
                    )
                    try SQLiteSchemaV3.migrateV2ToV3(
                        on: activeWriter,
                        databaseInstanceUUID: databaseInstanceUUID,
                        migrationFailureInjector: migrationFailureInjector
                    )
                    strategy = .createV3
                case 1:
                    let rebuilt = try SQLiteAssignmentRepository
                        .migrateV1ToV2InCurrentTransaction(on: activeWriter)
                    try SQLiteSchemaV3.migrateV2ToV3(
                        on: activeWriter,
                        databaseInstanceUUID: databaseInstanceUUID,
                        migrationFailureInjector: migrationFailureInjector
                    )
                    strategy = rebuilt ? .v1RebuildToV3 : .v1AdditiveToV3
                case 2:
                    try SQLiteSchemaV3.migrateV2ToV3(
                        on: activeWriter,
                        databaseInstanceUUID: databaseInstanceUUID,
                        migrationFailureInjector: migrationFailureInjector
                    )
                    strategy = .v2ToV3
                default:
                    throw DatabaseMigrationError(
                        "Unsupported database schema version \(state.storedVersion)."
                    )
                }

                try SQLiteSchemaV3.validate(on: activeWriter)
                try SQLiteSupport.execute("COMMIT", on: activeWriter)
                transactionActive = false
                committedOutcome = .init(
                    result: MigrationResult(
                        fromVersion: state.sourceVersion,
                        toVersion: SQLiteSchemaV3.databaseVersion,
                        migrated: true,
                        backupURL: backupURL,
                        strategy: strategy
                    ),
                    originalSnapshot: originalSnapshot
                )
            }
        } catch {
            let transactionError = error
            if transactionActive, let writer {
                try? SQLiteSupport.execute("ROLLBACK", on: writer)
                transactionActive = false
            }
            if let activeWriter = writer {
                sqlite3_close(activeWriter)
                writer = nil
            }

            guard let backupURL, let originalSnapshot else {
                throw DatabaseMigrationError(
                    "Fresh database creation or validation failed before any user data existed: "
                        + transactionError.localizedDescription
                )
            }
            do {
                _ = try ensureOriginalSnapshot(
                    originalSnapshot,
                    backupURL: backupURL,
                    databaseURL: databaseURL
                )
            } catch let restoreError {
                throw DatabaseMigrationError(
                    "Migration failed and automatic restore verification failed. "
                        + "The online backup remains at \(backupURL.path). "
                        + "Restore error: \(restoreError.localizedDescription)",
                    backupURL: backupURL
                )
            }
            throw DatabaseMigrationError(
                "Database migration failed; the original database was preserved or restored "
                    + "and verified against \(backupURL.lastPathComponent). Cause: "
                    + transactionError.localizedDescription,
                backupURL: backupURL
            )
        }

        if let activeWriter = writer {
            sqlite3_close(activeWriter)
            writer = nil
        }
        guard let committedOutcome else {
            throw DatabaseMigrationError("Migration committed without a recorded result.")
        }

        // Post-commit phase. This has no access to the transaction connection.
        // If a committed migration fails validation, restoration uses a new
        // connection and the Online Backup API, never rollback or file replace.
        do {
            try postCommitValidationFailureInjector?()
            try validateCommittedV3(at: databaseURL)
        } catch {
            guard let backupURL = committedOutcome.result.backupURL,
                  let snapshot = committedOutcome.originalSnapshot else {
                throw DatabaseMigrationError(
                    "Committed database failed post-commit validation: "
                        + error.localizedDescription
                )
            }
            do {
                _ = try ensureOriginalSnapshot(
                    snapshot,
                    backupURL: backupURL,
                    databaseURL: databaseURL,
                    forceRestore: true
                )
            } catch let restoreError {
                throw DatabaseMigrationError(
                    "Committed migration failed validation and original restoration failed. "
                        + "The online backup remains at \(backupURL.path). Restore error: "
                        + restoreError.localizedDescription,
                    backupURL: backupURL
                )
            }
            throw DatabaseMigrationError(
                "Committed migration failed post-commit validation; the original database "
                    + "was restored in place and verified. Cause: \(error.localizedDescription)",
                backupURL: backupURL
            )
        }
        return committedOutcome.result
    }

    static func dispatchState(on database: OpaquePointer) throws -> DispatchState {
        let storedVersion = Int32(try SQLiteSupport.scalarInt("PRAGMA user_version", on: database))
        let hasAssignments = try SQLiteSupport.tableExists("assignments", on: database)
        let tableCount = try SQLiteSupport.scalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
            on: database
        )
        guard storedVersion >= 0, storedVersion <= SQLiteSchemaV3.databaseVersion else {
            throw DatabaseMigrationError(
                "Database schema version \(storedVersion) is newer than supported version 3."
            )
        }

        if storedVersion == 0, !hasAssignments {
            guard tableCount == 0 else {
                throw DatabaseMigrationError(
                    "An unversioned database without assignments contains unknown tables."
                )
            }
            return .init(
                storedVersion: 0,
                sourceVersion: 0,
                hasAssignments: false,
                isFresh: true
            )
        }
        guard hasAssignments else {
            throw DatabaseMigrationError(
                "Database user_version \(storedVersion) is missing the assignments table."
            )
        }
        let sourceVersion: Int32 = storedVersion == 0 ? 1 : storedVersion
        guard [1, 2, 3].contains(sourceVersion) else {
            throw DatabaseMigrationError("Unsupported database schema version \(storedVersion).")
        }
        return .init(
            storedVersion: storedVersion,
            sourceVersion: sourceVersion,
            hasAssignments: true,
            isFresh: false
        )
    }

    static func createOnlineBackup(
        from databaseURL: URL,
        to backupURL: URL,
        expectedStoredVersion: Int32,
        sourceConnection: OpaquePointer
    ) throws -> DatabaseSnapshot {
        let partialURL = backupURL.appendingPathExtension("partial")
        guard !FileManager.default.fileExists(atPath: backupURL.path) else {
            throw DatabaseMigrationError("Refusing to overwrite an existing migration backup.")
        }
        try cleanupTemporarySQLiteFamily(at: partialURL)

        do {
            // The Online Backup is created before deep logical fingerprinting.
            // Thus a legal extension table can never fail before SQLite has
            // produced a transactionally-consistent candidate backup.
            let reader = try SQLiteSupport.open(
                databaseURL,
                flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            )
            do {
                try SQLiteSupport.configure(reader, writable: false)
                try SQLiteSupport.onlineBackup(
                    from: reader,
                    to: partialURL,
                    standaloneDestination: true
                )
                sqlite3_close(reader)
            } catch {
                sqlite3_close(reader)
                throw error
            }

            let backupFingerprint = try validatedSnapshot(
                at: partialURL,
                expectedStoredVersion: expectedStoredVersion
            ).fingerprint
            let sourceFingerprint = try DatabaseLogicalFingerprint.capture(on: sourceConnection)
            guard backupFingerprint == sourceFingerprint else {
                throw DatabaseMigrationError("Online backup fingerprint verification failed.")
            }

            // DELETE-mode standalone backups must have no dependent sidecars.
            try cleanupTemporarySQLiteSidecars(at: partialURL)
            let renameResult = partialURL.path.withCString { source in
                backupURL.path.withCString { destination in
                    Darwin.rename(source, destination)
                }
            }
            guard renameResult == 0 else {
                throw DatabaseMigrationError(
                    "Could not atomically publish migration backup: "
                        + String(cString: strerror(errno))
                )
            }
            return .init(
                storedVersion: expectedStoredVersion,
                fingerprint: sourceFingerprint
            )
        } catch {
            try? cleanupTemporarySQLiteFamily(at: partialURL)
            throw error
        }
    }

    static func restoreOnlineBackup(from backupURL: URL, to databaseURL: URL) throws {
        let source = try SQLiteSupport.open(
            backupURL,
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        )
        defer { sqlite3_close(source) }
        try SQLiteSupport.configure(source, writable: false)

        let destination = try SQLiteSupport.open(
            databaseURL,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        )
        defer { sqlite3_close(destination) }
        try SQLiteSupport.configure(destination)
        let journalMode = try SQLiteSupport.scalarText("PRAGMA journal_mode", on: destination)?
            .lowercased()
        try SQLiteSupport.onlineBackup(from: source, to: destination)
        guard try SQLiteSupport.scalarText("PRAGMA journal_mode", on: destination)?
            .lowercased() == journalMode else {
            throw DatabaseMigrationError(
                "Live Online Backup restoration changed the destination journal mode."
            )
        }
    }

    static func validateCommittedV3(at databaseURL: URL) throws {
        let validation = try SQLiteSupport.open(
            databaseURL,
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        )
        defer { sqlite3_close(validation) }
        try SQLiteSupport.configure(validation, writable: false)
        try SQLiteSchemaV3.validate(on: validation)
    }

    static func ensureOriginalSnapshot(
        _ snapshot: DatabaseSnapshot,
        backupURL: URL,
        databaseURL: URL,
        forceRestore: Bool = false
    ) throws -> Bool {
        if !forceRestore,
           (try? validatedSnapshot(
               at: databaseURL,
               expectedStoredVersion: snapshot.storedVersion,
               expectedFingerprint: snapshot.fingerprint
           )) != nil {
            return false
        }

        try restoreOnlineBackup(from: backupURL, to: databaseURL)
        _ = try validatedSnapshot(
            at: databaseURL,
            expectedStoredVersion: snapshot.storedVersion,
            expectedFingerprint: snapshot.fingerprint
        )
        return true
    }

    @discardableResult
    static func validatedSnapshot(
        at databaseURL: URL,
        expectedStoredVersion: Int32,
        expectedFingerprint: String? = nil
    ) throws -> DatabaseSnapshot {
        let database = try SQLiteSupport.open(
            databaseURL,
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        )
        defer { sqlite3_close(database) }
        try SQLiteSupport.configure(database, writable: false)

        let actualVersion = Int32(
            try SQLiteSupport.scalarInt("PRAGMA user_version", on: database)
        )
        guard actualVersion == expectedStoredVersion else {
            throw DatabaseMigrationError(
                "Snapshot user_version \(actualVersion) does not match "
                    + "\(expectedStoredVersion)."
            )
        }
        guard try SQLiteSupport.scalarText("PRAGMA integrity_check", on: database) == "ok" else {
            throw DatabaseMigrationError("Snapshot integrity_check failed.")
        }
        guard try SQLiteSupport.scalarInt(
            "SELECT COUNT(*) FROM pragma_foreign_key_check",
            on: database
        ) == 0 else {
            throw DatabaseMigrationError("Snapshot foreign_key_check failed.")
        }
        let fingerprint = try DatabaseLogicalFingerprint.capture(on: database)
        if let expectedFingerprint, fingerprint != expectedFingerprint {
            throw DatabaseMigrationError("Snapshot logical fingerprint does not match.")
        }
        return .init(storedVersion: actualVersion, fingerprint: fingerprint)
    }

    static func cleanupTemporarySQLiteFamily(at databaseURL: URL) throws {
        for url in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
            URL(fileURLWithPath: databaseURL.path + "-journal"),
        ] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func cleanupTemporarySQLiteSidecars(at databaseURL: URL) throws {
        for url in [
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
            URL(fileURLWithPath: databaseURL.path + "-journal"),
        ] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func uniqueBackupURL(for databaseURL: URL, fromVersion: Int32) -> URL {
        let stamp = DatabaseTimestamp.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return databaseURL.deletingLastPathComponent().appendingPathComponent(
            "\(databaseURL.lastPathComponent).v\(fromVersion)-to-v3.\(stamp)."
                + "\(UUID().canonicalString).backup",
            isDirectory: false
        )
    }
}
