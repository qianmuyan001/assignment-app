import Foundation
import SQLite3
import Darwin


enum MigrationCoordinator {
    static func prepareDatabase(
        at databaseURL: URL,
        migrationFailureInjector: (() throws -> Void)? = nil,
        postCommitValidationFailureInjector: (() throws -> Void)? = nil,
        postRollbackFailureInjector: (() throws -> Void)? = nil,
        databaseInstanceUUID: UUID? = nil
    ) throws -> MigrationResult {
        SQLiteAssignmentRepository.preconditionSafeTestDatabaseURL(databaseURL)
        return try DatabaseMigrationLock.withExclusiveLock(for: databaseURL) {
            try prepareWhileLocked(
                at: databaseURL,
                migrationFailureInjector: migrationFailureInjector,
                postCommitValidationFailureInjector: postCommitValidationFailureInjector,
                postRollbackFailureInjector: postRollbackFailureInjector,
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

    struct DatabaseSnapshot: Equatable {
        let storedVersion: Int32
        let fingerprint: String
    }

    struct CommittedOutcome {
        let result: MigrationResult
        /// Logical state produced by this coordinator while it still owned the
        /// SQLite write transaction. After COMMIT it is evidence for error
        /// classification only; it must never authorize a non-atomic restore.
        let candidateSnapshot: DatabaseSnapshot
    }

    static func prepareWhileLocked(
        at databaseURL: URL,
        migrationFailureInjector: (() throws -> Void)?,
        postCommitValidationFailureInjector: (() throws -> Void)?,
        postRollbackFailureInjector: (() throws -> Void)?,
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

            if state.sourceVersion == SQLiteSchemaV4.databaseVersion {
                try SQLiteSchemaV4.validate(on: activeWriter)
                let candidateSnapshot = try snapshot(on: activeWriter)
                try SQLiteSupport.execute("COMMIT", on: activeWriter)
                transactionActive = false
                committedOutcome = .init(
                    result: MigrationResult(
                        fromVersion: SQLiteSchemaV4.databaseVersion,
                        toVersion: SQLiteSchemaV4.databaseVersion,
                        migrated: false,
                        backupURL: nil,
                        strategy: .none
                    ),
                    candidateSnapshot: candidateSnapshot
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

                // Every path establishes v3 first, then layers the additive v4
                // upgrade inside the same transaction. There is no v3-only exit.
                let strategy: MigrationStrategy
                switch state.sourceVersion {
                case 0 where state.isFresh:
                    try SQLiteAssignmentRepository.createV2SchemaInCurrentTransaction(
                        on: activeWriter
                    )
                    try migrateThroughV3(
                        on: activeWriter,
                        databaseInstanceUUID: databaseInstanceUUID,
                        migrationFailureInjector: migrationFailureInjector
                    )
                    strategy = .createV4
                case 1:
                    let rebuilt = try SQLiteAssignmentRepository
                        .migrateV1ToV2InCurrentTransaction(on: activeWriter)
                    try migrateThroughV3(
                        on: activeWriter,
                        databaseInstanceUUID: databaseInstanceUUID,
                        migrationFailureInjector: migrationFailureInjector
                    )
                    strategy = rebuilt ? .v1RebuildToV4 : .v1AdditiveToV4
                case 2:
                    try migrateThroughV3(
                        on: activeWriter,
                        databaseInstanceUUID: databaseInstanceUUID,
                        migrationFailureInjector: migrationFailureInjector
                    )
                    strategy = .v2ToV4
                case 3:
                    try SQLiteSchemaV4.migrateV3ToV4(
                        on: activeWriter,
                        migrationFailureInjector: migrationFailureInjector
                    )
                    strategy = .v3ToV4
                default:
                    throw DatabaseMigrationError(
                        "Unsupported database schema version \(state.storedVersion)."
                    )
                }

                try SQLiteSchemaV4.validate(on: activeWriter)
                let candidateSnapshot = try snapshot(on: activeWriter)
                try SQLiteSupport.execute("COMMIT", on: activeWriter)
                transactionActive = false
                committedOutcome = .init(
                    result: MigrationResult(
                        fromVersion: state.sourceVersion,
                        toVersion: SQLiteSchemaV4.databaseVersion,
                        migrated: true,
                        backupURL: backupURL,
                        strategy: strategy
                    ),
                    candidateSnapshot: candidateSnapshot
                )
            }
        } catch {
            let transactionError = error
            var rollbackError: Error?
            if transactionActive, let writer {
                do {
                    try SQLiteSupport.execute("ROLLBACK", on: writer)
                } catch {
                    rollbackError = error
                }
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

            // Exercise the real cross-process boundary in tests: SQLite's lock
            // has been released and the migration connection is closed, while
            // an independent writer may legitimately commit.
            do {
                try postRollbackFailureInjector?()
            } catch {
                throw DatabaseMigrationError(
                    "Migration failed and the post-rollback verification hook failed. The live "
                        + "database was preserved and the online backup remains at "
                        + "\(backupURL.path). Hook error: \(error.localizedDescription)",
                    backupURL: backupURL
                )
            }

            do {
                try verifyTransactionRollback(
                    originalSnapshot: originalSnapshot,
                    backupURL: backupURL,
                    databaseURL: databaseURL,
                    rollbackError: rollbackError
                )
            } catch let recoveryError as DatabaseMigrationError {
                throw recoveryError
            } catch let verificationError {
                throw DatabaseMigrationError(
                    "Migration failed and rollback verification failed. The live database was "
                        + "preserved to avoid overwriting a possible external commit. The online "
                        + "backup remains at \(backupURL.path). Verification error: "
                        + verificationError.localizedDescription,
                    backupURL: backupURL
                )
            }
            throw DatabaseMigrationError(
                "Database migration failed; SQLite rolled back the transaction and the original "
                    + "database snapshot was verified. Cause: "
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

        // Post-commit phase. SQLite's write lock is no longer held. Even when
        // the live fingerprint still equals our candidate, a later Online
        // Backup restore would have a TOCTOU window in which an external writer
        // could commit and then be overwritten. This phase is read-only and
        // fails closed.
        do {
            try postCommitValidationFailureInjector?()
            try validateCommittedSchema(at: databaseURL)
        } catch {
            guard let backupURL = committedOutcome.result.backupURL else {
                throw DatabaseMigrationError(
                    "Committed database failed post-commit validation. The live database was "
                        + "preserved and writes remain disabled for this startup. Cause: "
                        + error.localizedDescription
                )
            }
            let matchesCandidate = (try? validatedSnapshot(
                at: databaseURL,
                expectedStoredVersion: committedOutcome.candidateSnapshot.storedVersion,
                expectedFingerprint: committedOutcome.candidateSnapshot.fingerprint
            )) != nil
            throw DatabaseMigrationError(
                matchesCandidate
                    ? "Committed migration failed post-commit validation. The exact committed "
                        + "candidate was preserved; automatic restore was not attempted because "
                        + "SQLite's write lock had already been released. Writes remain disabled "
                        + "for this startup and the online backup remains at \(backupURL.path). "
                        + "Cause: \(error.localizedDescription)"
                    : "Committed migration failed post-commit validation and the live database "
                        + "no longer matches this attempt's committed candidate. A possible "
                        + "external change was preserved; writes remain disabled for this startup "
                        + "and the online backup remains at \(backupURL.path). Cause: "
                        + error.localizedDescription,
                backupURL: backupURL
            )
        }
        return committedOutcome.result
    }

    /// Establishes v3 and then the additive v4 upgrade without committing
    /// between the two stages, so a half-migrated database can never be visible.
    static func migrateThroughV3(
        on database: OpaquePointer,
        databaseInstanceUUID: UUID?,
        migrationFailureInjector: (() throws -> Void)?
    ) throws {
        try SQLiteSchemaV3.migrateV2ToV3(
            on: database,
            databaseInstanceUUID: databaseInstanceUUID,
            migrationFailureInjector: migrationFailureInjector
        )
        try SQLiteSchemaV4.migrateV3ToV4(
            on: database,
            migrationFailureInjector: migrationFailureInjector
        )
    }

    static func dispatchState(on database: OpaquePointer) throws -> DispatchState {
        let storedVersion = Int32(try SQLiteSupport.scalarInt("PRAGMA user_version", on: database))
        let hasAssignments = try SQLiteSupport.tableExists("assignments", on: database)
        let tableCount = try SQLiteSupport.scalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
            on: database
        )
        guard storedVersion >= 0, storedVersion <= SQLiteSchemaV4.databaseVersion else {
            throw DatabaseMigrationError(
                "Database schema version \(storedVersion) is newer than supported version "
                    + "\(SQLiteSchemaV4.databaseVersion)."
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
        // Version 4 is listed so an already-migrated database opens instead of
        // being rejected. The caller short-circuits it before the switch.
        guard [1, 2, 3, 4].contains(sourceVersion) else {
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

    /// Read-only post-commit check. `SQLiteSchemaV4.validate` re-runs the whole
    /// version-agnostic v3 contract first, so this also proves the committed
    /// database kept every v3 object and value intact.
    static func validateCommittedSchema(at databaseURL: URL) throws {
        let validation = try SQLiteSupport.open(
            databaseURL,
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        )
        defer { sqlite3_close(validation) }
        try SQLiteSupport.configure(validation, writable: false)
        try SQLiteSchemaV4.validate(on: validation)
    }

    /// Verification after ROLLBACK is deliberately read-only. Once ROLLBACK
    /// releases SQLite's lock, even an exact fingerprint cannot safely authorize
    /// a later restore: another process could commit between check and write.
    static func verifyTransactionRollback(
        originalSnapshot: DatabaseSnapshot,
        backupURL: URL,
        databaseURL: URL,
        rollbackError: Error?
    ) throws {
        let live: DatabaseSnapshot
        do {
            live = try validatedSnapshot(
                at: databaseURL,
                expectedStoredVersion: originalSnapshot.storedVersion
            )
        } catch {
            throw DatabaseMigrationError(
                "Migration failed after rollback, and the live database could not be verified "
                    + "as a healthy original-version snapshot. It was preserved because SQLite's "
                    + "lock had already been released; writes remain disabled for this startup. "
                    + "The online backup remains at \(backupURL.path). Verification error: "
                    + error.localizedDescription,
                backupURL: backupURL
            )
        }

        guard live.fingerprint == originalSnapshot.fingerprint else {
            throw DatabaseMigrationError(
                "Migration failed after rollback, but the live database contains a healthy "
                    + "external change. It was preserved to avoid losing that commit; no "
                    + "post-lock restore was attempted and writes remain disabled for "
                    + "this startup. The online backup remains at \(backupURL.path).",
                backupURL: backupURL
            )
        }

        if let rollbackError {
            throw DatabaseMigrationError(
                "SQLite reported a rollback error even though the original database snapshot "
                    + "was verified. The live database was preserved and writes remain disabled "
                    + "for this startup. The online backup remains at \(backupURL.path). "
                    + "Rollback error: \(rollbackError.localizedDescription)",
                backupURL: backupURL
            )
        }
    }

    static func snapshot(on database: OpaquePointer) throws -> DatabaseSnapshot {
        .init(
            storedVersion: Int32(
                try SQLiteSupport.scalarInt("PRAGMA user_version", on: database)
            ),
            fingerprint: try DatabaseLogicalFingerprint.capture(on: database)
        )
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
            "\(databaseURL.lastPathComponent).v\(fromVersion)-to-v4.\(stamp)."
                + "\(UUID().canonicalString).backup",
            isDirectory: false
        )
    }
}
