import CryptoKit
import Foundation
import SQLite3


// MARK: - Manifest

/// One attachment payload inside a backup.
struct BackupAttachmentEntry: Codable, Equatable, Identifiable {
    let uuid: String
    let fileName: String
    let byteSize: Int64
    let sha256: String

    var id: String { uuid }
}


/// The manifest written into every `.assignmentbackup` package.
///
/// It is the authority for every preflight check: the package is rejected
/// unless the payloads on disk match what the manifest promises.
struct BackupManifest: Codable, Equatable {
    static let supportedFormatVersion = 1

    let formatVersion: Int
    let createdAtUTC: String
    let schemaVersion: Int32
    let databaseIdentity: String
    let databaseFileName: String
    let databaseByteSize: Int64
    let databaseSHA256: String
    let attachmentCount: Int
    let attachments: [BackupAttachmentEntry]
    let appVersion: String
    let buildNumber: String
    let platform: String
}


/// What a backup contains, read out of the database during preflight.
struct BackupDataSummary: Equatable {
    let taskCount: Int
    let courseCount: Int
    let meetingCount: Int
    let examCount: Int
    let attachmentCount: Int
    let completedTaskCount: Int
    let schemaVersion: Int32
    let databaseIdentity: String
    let createdAtUTC: String
}


/// The result of a preflight inspection.
struct BackupPreflight: Equatable {
    let packageURL: URL
    let manifest: BackupManifest
    let summary: BackupDataSummary
}


/// The outcome of a successful restore.
struct BackupRestoreOutcome: Equatable {
    let safetyBackupURL: URL
    let summary: BackupDataSummary
    /// `true` when the app reopened the database itself and no restart is
    /// needed. `false` means the process still holds the old database and the
    /// user has to relaunch before the new data is visible.
    let requiresRestart: Bool
}


// MARK: - Errors

enum BackupError: LocalizedError, Equatable {
    case packageNotFound(String)
    case manifestMissing
    case manifestUnreadable(String)
    case unsupportedFormatVersion(Int)
    case newerSchemaVersion(backup: Int32, supported: Int32)
    case databasePayloadMissing
    case databaseSizeMismatch(expected: Int64, actual: Int64)
    case databaseChecksumMismatch
    case databaseUnreadable(String)
    case integrityCheckFailed(String)
    case foreignKeyViolations(Int)
    case schemaVersionMismatch(manifest: Int32, file: Int32)
    case identityMissing
    case identityNotUUIDv4(String)
    case invalidEntityUUID(table: String, value: String)
    case attachmentPayloadMissing(String)
    case attachmentSizeMismatch(String)
    case attachmentChecksumMismatch(String)
    case attachmentNotRegularFile(String)
    case exportDestinationExists(String)
    case stagingFailed(String)
    case replaceFailed(String)
    case rollbackFailed(String)
    case postRestoreVerificationFailed(String)
    case databaseUnavailable

    var errorDescription: String? {
        switch self {
        case .packageNotFound(let name):
            return L10n.tr("The backup “%@” could not be found.", name)
        case .manifestMissing:
            return L10n.tr("This backup has no manifest, so it cannot be verified.")
        case .manifestUnreadable(let detail):
            return L10n.tr("The backup manifest could not be read: %@", detail)
        case .unsupportedFormatVersion(let version):
            return L10n.tr(
                "This backup uses format version %lld, which this version of the app cannot read.",
                version
            )
        case .newerSchemaVersion(let backup, let supported):
            return L10n.tr(
                "This backup was made by a newer version of the app (database schema %lld; this app supports %lld). Update the app before restoring it.",
                backup,
                supported
            )
        case .databasePayloadMissing:
            return L10n.tr("The backup is missing its database file.")
        case .databaseSizeMismatch(let expected, let actual):
            return L10n.tr(
                "The backup database is %lld bytes but the manifest records %lld bytes.",
                actual,
                expected
            )
        case .databaseChecksumMismatch:
            return L10n.tr(
                "The backup database does not match its recorded SHA-256. The file was changed or damaged after the backup was made."
            )
        case .databaseUnreadable(let detail):
            return L10n.tr("The backup database could not be opened: %@", detail)
        case .integrityCheckFailed(let detail):
            return L10n.tr("The backup database failed an integrity check: %@", detail)
        case .foreignKeyViolations(let count):
            return L10n.tr("The backup database contains %lld broken references.", count)
        case .schemaVersionMismatch(let manifest, let file):
            return L10n.tr(
                "The backup database is schema version %lld but the manifest records %lld.",
                file,
                manifest
            )
        case .identityMissing:
            return L10n.tr("The backup database has no database identity row.")
        case .identityNotUUIDv4(let value):
            return L10n.tr("The backup database identity is not a UUID v4: %@", value)
        case .invalidEntityUUID(let table, let value):
            return L10n.tr("The backup database has an invalid UUID in %@: %@", table, value)
        case .attachmentPayloadMissing(let name):
            return L10n.tr("The backup is missing the attachment payload for “%@”.", name)
        case .attachmentSizeMismatch(let name):
            return L10n.tr("The attachment “%@” does not match the size in the manifest.", name)
        case .attachmentChecksumMismatch(let name):
            return L10n.tr("The attachment “%@” does not match its recorded SHA-256.", name)
        case .attachmentNotRegularFile(let name):
            return L10n.tr("The attachment payload for “%@” is not a regular file.", name)
        case .exportDestinationExists(let name):
            return L10n.tr(
                "“%@” already exists. The backup was exported under a new name instead of replacing it.",
                name
            )
        case .stagingFailed(let detail):
            return L10n.tr("The restore could not be prepared: %@", detail)
        case .replaceFailed(let detail):
            return L10n.tr("The restore could not replace the current database: %@", detail)
        case .rollbackFailed(let detail):
            return L10n.tr(
                "The restore failed and the original data could not be put back automatically: %@",
                detail
            )
        case .postRestoreVerificationFailed(let detail):
            return L10n.tr("The restored database did not verify: %@", detail)
        case .databaseUnavailable:
            return L10n.tr("The local database is unavailable, so no backup operation can run.")
        }
    }
}


// MARK: - Package layout

/// The on-disk shape of a `.assignmentbackup` package.
enum BackupLayout {
    static let packageExtension = "assignmentbackup"
    static let manifestName = "manifest.json"
    static let databaseName = "database.sqlite"
    static let attachmentsDirectory = "attachments"

    static func manifestURL(in package: URL) -> URL {
        package.appendingPathComponent(manifestName, isDirectory: false)
    }

    static func databaseURL(in package: URL) -> URL {
        package.appendingPathComponent(databaseName, isDirectory: false)
    }

    static func attachmentsURL(in package: URL) -> URL {
        package.appendingPathComponent(attachmentsDirectory, isDirectory: true)
    }

    static func attachmentURL(in package: URL, uuid: String) -> URL {
        attachmentsURL(in: package).appendingPathComponent(uuid, isDirectory: false)
    }
}


// MARK: - Checksums

enum FileChecksum {
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func regularFileSize(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw BackupError.attachmentNotRegularFile(url.lastPathComponent)
        }
        return Int64(values.fileSize ?? 0)
    }
}


// MARK: - Coordinator

/// Creates, verifies, exports, imports, and restores `.assignmentbackup`
/// packages.
///
/// A package is a directory containing `manifest.json`, a standalone SQLite
/// database, and an `attachments` directory. The database and its attachments
/// always travel together: a package whose attachments are incomplete is
/// rejected rather than restored partially.
///
/// Every restore stages into a temporary directory, verifies the staged copy,
/// keeps a rollback copy of the live data, swaps with
/// `FileManager.replaceItemAt`, verifies again, and rolls back on any failure.
final class BackupCoordinator {
    /// Highest schema version this build understands.
    static let supportedSchemaVersion: Int32 = 4

    let databaseURL: URL

    private let fileManager: FileManager
    private let now: () -> Date

    init(
        databaseURL: URL,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.databaseURL = databaseURL.standardizedFileURL
        self.fileManager = fileManager
        self.now = now
    }

    // MARK: Paths

    var dataRoot: URL {
        databaseURL.deletingLastPathComponent().standardizedFileURL
    }

    var attachmentsRoot: URL {
        dataRoot.appendingPathComponent("attachments", isDirectory: true)
    }

    var backupsRoot: URL {
        dataRoot.appendingPathComponent("Backups", isDirectory: true)
    }

    /// Where a package chosen from outside the app is copied to before it is
    /// inspected. Working on an app-owned copy means the security scope on the
    /// user's file can be released as soon as the copy finishes.
    var importedRoot: URL {
        backupsRoot.appendingPathComponent("Imported", isDirectory: true)
    }

    private var stagingRoot: URL {
        dataRoot.appendingPathComponent(".restore-staging", isDirectory: true)
    }

    private var rollbackRoot: URL {
        dataRoot.appendingPathComponent(".restore-rollback", isDirectory: true)
    }

    // MARK: Create

    /// Writes a complete package into `directory`.
    ///
    /// The database is captured with the SQLite online backup API from a
    /// read-only connection, so the copy is transactionally consistent even
    /// while the app keeps writing.
    @discardableResult
    func createBackup(in directory: URL) throws -> URL {
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            throw BackupError.databaseUnavailable
        }

        let package = try makeUniquePackage(in: directory, base: defaultPackageName)
        try fileManager.createDirectory(at: package, withIntermediateDirectories: true)

        do {
            let stagedDatabase = try captureDatabase()
            defer { try? fileManager.removeItem(at: stagedDatabase) }

            let databaseByteSize = try FileChecksum.regularFileSize(of: stagedDatabase)
            let databaseSHA256 = try FileChecksum.sha256(of: stagedDatabase)

            try fileManager.moveItem(at: stagedDatabase, to: BackupLayout.databaseURL(in: package))

            let identity = try readIdentity(at: BackupLayout.databaseURL(in: package))
            let attachments = try copyAttachments(into: package)

            let manifest = BackupManifest(
                formatVersion: BackupManifest.supportedFormatVersion,
                createdAtUTC: DatabaseTimestamp.string(from: now()),
                schemaVersion: try schemaVersion(at: BackupLayout.databaseURL(in: package)),
                databaseIdentity: identity,
                databaseFileName: databaseURL.lastPathComponent,
                databaseByteSize: databaseByteSize,
                databaseSHA256: databaseSHA256,
                attachmentCount: attachments.count,
                attachments: attachments,
                appVersion: AppVersionInfo.current.marketingVersion,
                buildNumber: AppVersionInfo.current.buildNumber,
                platform: "apple"
            )

            let data = try JSONEncoder.backupEncoder.encode(manifest)
            try data.write(to: BackupLayout.manifestURL(in: package), options: .atomic)
            return package
        } catch {
            try? fileManager.removeItem(at: package)
            throw error
        }
    }

    /// Copies the current database and attachments into `Backups/` so a user
    /// can get back to where they were before a restore.
    @discardableResult
    func createSafetyBackup() throws -> URL {
        try fileManager.createDirectory(at: backupsRoot, withIntermediateDirectories: true)
        return try createBackup(in: backupsRoot)
    }

    // MARK: Export

    /// Copies an existing package to a user-chosen directory.
    ///
    /// An existing item with the same name is never replaced; a numeric suffix
    /// is added instead.
    func export(package: URL, to directory: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: package.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw BackupError.packageNotFound(package.lastPathComponent)
        }

        let destination = try makeUniquePackage(in: directory, base: package.lastPathComponent)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.copyItem(at: package, to: destination)
        return destination
    }

    /// `true` when exporting to `directory` would collide with `name`.
    func exportWouldOverwrite(name: String, in directory: URL) -> Bool {
        fileManager.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    // MARK: Import

    /// Copies a package the user picked into `Backups/Imported/`.
    ///
    /// The copy is made inside the caller's security scope; everything after
    /// this point — preflight, restore — reads the app-owned copy, so the
    /// user's original file is never the thing being restored from.
    ///
    /// An existing item with the same name is never replaced; a numeric suffix
    /// is added instead.
    func stageExternalPackage(_ package: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: package.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw BackupError.packageNotFound(package.lastPathComponent)
        }
        try fileManager.createDirectory(at: importedRoot, withIntermediateDirectories: true)
        let destination = try makeUniquePackage(
            in: importedRoot,
            base: package.lastPathComponent
        )
        try fileManager.copyItem(at: package, to: destination)
        return destination
    }

    // MARK: Preflight

    /// Inspects a package without touching the live data.
    func preflight(package: URL) throws -> BackupPreflight {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: package.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw BackupError.packageNotFound(package.lastPathComponent)
        }

        let manifest = try readManifest(in: package)
        try verify(databaseIn: package, against: manifest)
        try verify(attachmentsIn: package, against: manifest)
        let summary = try summarize(databaseIn: package, manifest: manifest)
        return BackupPreflight(packageURL: package, manifest: manifest, summary: summary)
    }

    // MARK: Restore

    /// Replaces the live database and attachments with `package`.
    ///
    /// The caller must have released every open SQLite connection first.
    /// `requiresRestart` reports whether the app managed to reopen the new
    /// database itself.
    @discardableResult
    func restore(
        package: URL,
        canReopenDatabase: Bool
    ) throws -> BackupRestoreOutcome {
        let preflight = try preflight(package: package)
        let safety = try createSafetyBackup()
        return try performRestore(
            preflight: preflight,
            safetyBackupURL: safety,
            canReopenDatabase: canReopenDatabase
        )
    }

    private func performRestore(
        preflight: BackupPreflight,
        safetyBackupURL: URL,
        canReopenDatabase: Bool
    ) throws -> BackupRestoreOutcome {
        let package = preflight.packageURL
        let manifest = preflight.manifest
        let token = UUID().uuidString.lowercased()
        let staging = stagingRoot.appendingPathComponent(token, isDirectory: true)
        let rollback = rollbackRoot.appendingPathComponent(token, isDirectory: true)

        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: rollback, withIntermediateDirectories: true)
        } catch {
            throw BackupError.stagingFailed(error.localizedDescription)
        }

        // 1. Stage and re-verify the incoming data.
        let stagedDatabase = staging.appendingPathComponent(
            databaseURL.lastPathComponent,
            isDirectory: false
        )
        let stagedAttachments = staging.appendingPathComponent("attachments", isDirectory: true)

        do {
            try fileManager.copyItem(
                at: BackupLayout.databaseURL(in: package),
                to: stagedDatabase
            )
            try verify(databaseIn: staging, databaseName: stagedDatabase.lastPathComponent, against: manifest)

            try fileManager.createDirectory(at: stagedAttachments, withIntermediateDirectories: true)
            for entry in manifest.attachments {
                try fileManager.copyItem(
                    at: BackupLayout.attachmentURL(in: package, uuid: entry.uuid),
                    to: stagedAttachments.appendingPathComponent(entry.uuid, isDirectory: false)
                )
            }
            try verify(attachmentsAt: stagedAttachments, against: manifest)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }

        // 2. Keep a rollback copy of everything that is about to be replaced.
        let rollbackDatabase = rollback.appendingPathComponent(
            databaseURL.lastPathComponent,
            isDirectory: false
        )
        let rollbackAttachments = rollback.appendingPathComponent("attachments", isDirectory: true)
        var didReplaceDatabase = false
        var didReplaceAttachments = false

        func rollBack() throws {
            if didReplaceDatabase, fileManager.fileExists(atPath: rollbackDatabase.path) {
                try restoreFile(from: rollbackDatabase, to: databaseURL)
            }
            if didReplaceAttachments, fileManager.fileExists(atPath: rollbackAttachments.path) {
                try restoreDirectory(from: rollbackAttachments, to: attachmentsRoot)
            }
        }

        do {
            if fileManager.fileExists(atPath: databaseURL.path) {
                try fileManager.copyItem(at: databaseURL, to: rollbackDatabase)
            }
            if fileManager.fileExists(atPath: attachmentsRoot.path) {
                try fileManager.copyItem(at: attachmentsRoot, to: rollbackAttachments)
            }

            // 3. WAL sidecars must go, or the old journal is replayed into the
            //    restored database.
            removeJournalSidecars(for: databaseURL)

            // 4. Atomic swap.
            try replaceOrInstall(
                original: databaseURL,
                with: stagedDatabase,
                isDirectory: false,
                rollbackCopy: rollbackDatabase
            )
            didReplaceDatabase = true

            try replaceOrInstall(
                original: attachmentsRoot,
                with: stagedAttachments,
                isDirectory: true,
                rollbackCopy: rollbackAttachments
            )
            didReplaceAttachments = true

            // 5. Verify the live database once more before declaring success.
            do {
                try verify(
                    databaseIn: dataRoot,
                    databaseName: databaseURL.lastPathComponent,
                    against: manifest
                )
            } catch {
                try rollBack()
                throw error
            }
        } catch {
            do {
                try rollBack()
            } catch {
                throw BackupError.rollbackFailed(error.localizedDescription)
            }
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: rollback)
            throw error
        }

        try? fileManager.removeItem(at: staging)
        try? fileManager.removeItem(at: rollback)
        return BackupRestoreOutcome(
            safetyBackupURL: safetyBackupURL,
            summary: preflight.summary,
            requiresRestart: !canReopenDatabase
        )
    }

    // MARK: Maintenance

    /// Removes leftover staging and rollback directories from earlier runs.
    func pruneTemporaryDirectories() {
        for root in [stagingRoot, rollbackRoot] {
            guard let children = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children {
                try? fileManager.removeItem(at: child)
            }
        }
    }

    // MARK: - Private helpers

    private var defaultPackageName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "assignment-backup-\(formatter.string(from: now())).\(BackupLayout.packageExtension)"
    }

    private func makeUniquePackage(in directory: URL, base: String) throws -> URL {
        let candidate = directory.appendingPathComponent(base, isDirectory: true)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }

        let baseName = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        for suffix in 2...999 {
            let name = ext.isEmpty
                ? "\(baseName)-\(suffix)"
                : "\(baseName)-\(suffix).\(ext)"
            let next = directory.appendingPathComponent(name, isDirectory: true)
            if !fileManager.fileExists(atPath: next.path) {
                return next
            }
        }
        return directory.appendingPathComponent(
            "\(baseName)-\(UUID().uuidString.lowercased())" + (ext.isEmpty ? "" : ".\(ext)"),
            isDirectory: true
        )
    }

    private func captureDatabase() throws -> URL {
        let source = try SQLiteSupport.open(
            databaseURL,
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        )
        defer { sqlite3_close(source) }

        let staging = stagingRoot.appendingPathComponent(
            "capture-\(UUID().uuidString.lowercased()).sqlite",
            isDirectory: false
        )
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        do {
            try SQLiteSupport.onlineBackup(
                from: source,
                to: staging,
                standaloneDestination: true
            )
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        return staging
    }

    private func copyAttachments(into package: URL) throws -> [BackupAttachmentEntry] {
        let destination = BackupLayout.attachmentsURL(in: package)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let children = (try? fileManager.contentsOfDirectory(
            at: attachmentsRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var entries: [BackupAttachmentEntry] = []
        for child in children where UUID(uuidString: child.lastPathComponent) != nil {
            let values = try child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let byteSize = try FileChecksum.regularFileSize(of: child)
            let checksum = try FileChecksum.sha256(of: child)
            let target = destination.appendingPathComponent(
                child.lastPathComponent,
                isDirectory: false
            )
            try fileManager.copyItem(at: child, to: target)
            entries.append(
                BackupAttachmentEntry(
                    uuid: child.lastPathComponent,
                    fileName: metadataFileName(for: child.lastPathComponent) ?? child.lastPathComponent,
                    byteSize: byteSize,
                    sha256: checksum
                )
            )
        }
        return entries.sorted { $0.uuid < $1.uuid }
    }

    /// Attachment file names live in the database, but a backup must be
    /// verifiable from the package alone. The manifest falls back to the
    /// payload UUID when the metadata row cannot be read.
    private func metadataFileName(for uuidText: String) -> String? {
        guard let database = try? SQLiteSupport.open(
            databaseURL,
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        ) else { return nil }
        defer { sqlite3_close(database) }
        guard SQLiteSupport.tableExistsIfPresent("attachments", on: database),
              let statement = try? SQLiteSupport.prepare(
                  "SELECT file_name FROM attachments WHERE uuid = ? LIMIT 1",
                  on: database
              ) else { return nil }
        defer { sqlite3_finalize(statement) }
        SQLiteSupport.bind(uuidText, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return SQLiteSupport.text(statement, 0)
    }

    private func readManifest(in package: URL) throws -> BackupManifest {
        let url = BackupLayout.manifestURL(in: package)
        guard fileManager.fileExists(atPath: url.path) else {
            throw BackupError.manifestMissing
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BackupError.manifestUnreadable(error.localizedDescription)
        }
        do {
            let manifest = try JSONDecoder().decode(BackupManifest.self, from: data)
            guard manifest.formatVersion <= BackupManifest.supportedFormatVersion else {
                throw BackupError.unsupportedFormatVersion(manifest.formatVersion)
            }
            guard manifest.schemaVersion <= Self.supportedSchemaVersion else {
                throw BackupError.newerSchemaVersion(
                    backup: manifest.schemaVersion,
                    supported: Self.supportedSchemaVersion
                )
            }
            return manifest
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.manifestUnreadable(error.localizedDescription)
        }
    }

    private func verify(
        databaseIn package: URL,
        databaseName: String = BackupLayout.databaseName,
        against manifest: BackupManifest
    ) throws {
        let url = package.appendingPathComponent(databaseName, isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else {
            throw BackupError.databasePayloadMissing
        }
        let byteSize = try FileChecksum.regularFileSize(of: url)
        guard byteSize == manifest.databaseByteSize else {
            throw BackupError.databaseSizeMismatch(
                expected: manifest.databaseByteSize,
                actual: byteSize
            )
        }
        let checksum = try FileChecksum.sha256(of: url)
        guard checksum == manifest.databaseSHA256 else {
            throw BackupError.databaseChecksumMismatch
        }

        let database: OpaquePointer
        do {
            database = try SQLiteSupport.open(
                url,
                flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            )
        } catch {
            throw BackupError.databaseUnreadable(error.localizedDescription)
        }
        defer { sqlite3_close(database) }

        let integrity = (try? SQLiteSupport.scalarText("PRAGMA quick_check", on: database)) ?? "unknown"
        guard integrity.lowercased() == "ok" else {
            throw BackupError.integrityCheckFailed(integrity)
        }

        let violations = (try? SQLiteSupport.scalarInt(
            "SELECT COUNT(*) FROM pragma_foreign_key_check",
            on: database
        )) ?? -1
        guard violations == 0 else {
            throw BackupError.foreignKeyViolations(Int(violations))
        }

        let version = (try? Self.userVersion(on: database)) ?? -1
        guard version == manifest.schemaVersion else {
            throw BackupError.schemaVersionMismatch(manifest: manifest.schemaVersion, file: version)
        }

        _ = try readIdentity(on: database)
        try validateUUIDs(on: database)
    }

    private func verify(attachmentsIn package: URL, against manifest: BackupManifest) throws {
        try verify(attachmentsAt: BackupLayout.attachmentsURL(in: package), against: manifest)
    }

    private func verify(attachmentsAt root: URL, against manifest: BackupManifest) throws {
        for entry in manifest.attachments {
            let url = root.appendingPathComponent(entry.uuid, isDirectory: false)
            guard fileManager.fileExists(atPath: url.path) else {
                throw BackupError.attachmentPayloadMissing(entry.fileName)
            }
            let byteSize = try FileChecksum.regularFileSize(of: url)
            guard byteSize == entry.byteSize else {
                throw BackupError.attachmentSizeMismatch(entry.fileName)
            }
            let checksum = try FileChecksum.sha256(of: url)
            guard checksum == entry.sha256 else {
                throw BackupError.attachmentChecksumMismatch(entry.fileName)
            }
        }
    }

    private func summarize(databaseIn package: URL, manifest: BackupManifest) throws -> BackupDataSummary {
        let url = BackupLayout.databaseURL(in: package)
        let database = try SQLiteSupport.open(
            url,
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        )
        defer { sqlite3_close(database) }

        func count(_ table: String, where clause: String = "1=1") -> Int {
            guard SQLiteSupport.tableExistsIfPresent(table, on: database),
                  let value = try? SQLiteSupport.scalarInt(
                      "SELECT COUNT(*) FROM \(table) WHERE \(clause)",
                      on: database
                  ) else { return 0 }
            return Int(value)
        }

        return BackupDataSummary(
            taskCount: count("assignments", where: "deleted_at IS NULL"),
            courseCount: count("courses", where: "deleted_at IS NULL"),
            meetingCount: count("course_meetings", where: "deleted_at IS NULL"),
            examCount: count("exams", where: "deleted_at IS NULL"),
            attachmentCount: manifest.attachmentCount,
            completedTaskCount: count(
                "assignments",
                where: "deleted_at IS NULL AND status = 'completed'"
            ),
            schemaVersion: manifest.schemaVersion,
            databaseIdentity: manifest.databaseIdentity,
            createdAtUTC: manifest.createdAtUTC
        )
    }

    private func readIdentity(at url: URL) throws -> String {
        let database = try SQLiteSupport.open(
            url,
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        )
        defer { sqlite3_close(database) }
        return try readIdentity(on: database)
    }

    private func readIdentity(on database: OpaquePointer) throws -> String {
        let statement = try SQLiteSupport.prepare(
            "SELECT singleton, instance_uuid FROM database_identity",
            on: database
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_int64(statement, 0) == 1,
              let text = SQLiteSupport.text(statement, 1),
              let uuid = UUID(uuidString: text),
              uuid.canonicalString == text,
              uuid.versionNumber == 4 else {
            throw BackupError.identityMissing
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw BackupError.identityMissing
        }
        if UUID(uuidString: text) == nil || uuid.versionNumber != 4 {
            throw BackupError.identityNotUUIDv4(text)
        }
        return text
    }

    private func validateUUIDs(on database: OpaquePointer) throws {
        for table in ["assignments", "courses"] {
            guard SQLiteSupport.tableExistsIfPresent(table, on: database) else { continue }
            let statement = try SQLiteSupport.prepare(
                "SELECT uuid FROM \(table)",
                on: database
            )
            defer { sqlite3_finalize(statement) }
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                if let text = SQLiteSupport.text(statement, 0),
                   UUID(uuidString: text) == nil {
                    throw BackupError.invalidEntityUUID(table: table, value: text)
                }
                result = sqlite3_step(statement)
            }
        }
    }

    private func schemaVersion(at url: URL) throws -> Int32 {
        let database = try SQLiteSupport.open(
            url,
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        )
        defer { sqlite3_close(database) }
        return try Self.userVersion(on: database)
    }

    private static func userVersion(on database: OpaquePointer) throws -> Int32 {
        Int32(try SQLiteSupport.scalarInt("PRAGMA user_version", on: database))
    }

    private func removeJournalSidecars(for url: URL) {
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if fileManager.fileExists(atPath: sidecar.path) {
                try? fileManager.removeItem(at: sidecar)
            }
        }
    }

    private func replaceOrInstall(
        original: URL,
        with staged: URL,
        isDirectory: Bool,
        rollbackCopy: URL
    ) throws {
        if fileManager.fileExists(atPath: original.path) {
            do {
                _ = try fileManager.replaceItemAt(original, withItemAt: staged)
            } catch {
                // `replaceItemAt` fails across volumes. Both paths live in the
                // data root, so this only happens if the container moved; the
                // rollback copy makes the manual fallback possible.
                throw BackupError.replaceFailed(error.localizedDescription)
            }
            return
        }

        do {
            if isDirectory {
                try fileManager.createDirectory(
                    at: original,
                    withIntermediateDirectories: true
                )
                for child in try fileManager.contentsOfDirectory(
                    at: staged,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) {
                    try fileManager.copyItem(
                        at: child,
                        to: original.appendingPathComponent(child.lastPathComponent)
                    )
                }
            } else {
                try fileManager.copyItem(at: staged, to: original)
            }
        } catch {
            throw BackupError.replaceFailed(error.localizedDescription)
        }
        _ = rollbackCopy
    }

    private func restoreFile(from backup: URL, to original: URL) throws {
        removeJournalSidecars(for: original)
        if fileManager.fileExists(atPath: original.path) {
            try fileManager.removeItem(at: original)
        }
        try fileManager.copyItem(at: backup, to: original)
    }

    private func restoreDirectory(from backup: URL, to original: URL) throws {
        if fileManager.fileExists(atPath: original.path) {
            try fileManager.removeItem(at: original)
        }
        try fileManager.copyItem(at: backup, to: original)
    }
}


// MARK: - Support extensions

extension JSONEncoder {
    static var backupEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}


extension SQLiteSupport {
    /// `tableExists` that reports `false` instead of throwing when the
    /// connection cannot answer — used while inspecting untrusted backups.
    static func tableExistsIfPresent(_ name: String, on database: OpaquePointer) -> Bool {
        (try? tableExists(name, on: database)) ?? false
    }
}
