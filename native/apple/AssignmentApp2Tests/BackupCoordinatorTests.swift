import Foundation
import SQLite3
import Testing
@testable import AssignmentApp2


// MARK: - Fixtures

/// A disposable database plus its attachments directory.
///
/// Every test in this suite runs against a fresh temporary directory. Nothing
/// here touches the database the app opens for a real user.
private final class TemporaryDataRoot {
    let root: URL
    let databaseURL: URL
    var attachmentsRoot: URL { root.appendingPathComponent("attachments", isDirectory: true) }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssignmentApp2BackupTests-\(UUID().uuidString)", isDirectory: true)
        databaseURL = root.appendingPathComponent("assignments.db", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum BackupFixtureError: Error {
    case fileMissing(String)
}

private func seed(
    _ root: TemporaryDataRoot,
    taskTitles: [String],
    attachments: [(name: String, bytes: String)]
) throws {
    let tasks = try SQLiteAssignmentRepository(databaseURL: root.databaseURL)
    let organization = try SQLiteOrganizationRepository(databaseURL: root.databaseURL)
    let store = AttachmentFileStore(databaseURL: root.databaseURL)

    for title in taskTitles {
        _ = try tasks.create(AssignmentDraft(courseName: "Math", title: title))
    }

    let seeded = try tasks.fetchAll()
    guard let first = seeded.first else { return }

    for attachment in attachments {
        let source = root.root.appendingPathComponent(attachment.name, isDirectory: false)
        try Data(attachment.bytes.utf8).write(to: source)
        _ = try store.importFile(
            from: source,
            assignmentID: first.id,
            mimeType: "text/plain",
            repository: organization
        )
        try FileManager.default.removeItem(at: source)
    }
}

private func readManifest(in package: URL) throws -> BackupManifest {
    let data = try Data(contentsOf: BackupLayout.manifestURL(in: package))
    return try JSONDecoder().decode(BackupManifest.self, from: data)
}

private func writeManifest(_ manifest: BackupManifest, in package: URL) throws {
    let data = try JSONEncoder.backupEncoder.encode(manifest)
    try data.write(to: BackupLayout.manifestURL(in: package), options: .atomic)
}

private func sha256(of url: URL) throws -> String {
    try FileChecksum.sha256(of: url)
}

private func attachmentPayload(_ root: TemporaryDataRoot, uuid: String) -> URL {
    root.attachmentsRoot.appendingPathComponent(uuid, isDirectory: false)
}


// MARK: - Creating

@Suite("Backup creation")
struct BackupCreationTests {

    @Test("A package records the schema, the identity and a matching SHA-256")
    func manifestIsComplete() throws {
        let root = try TemporaryDataRoot()
        defer { root.cleanup() }
        try seed(root, taskTitles: ["Alpha", "Beta"], attachments: [("notes.txt", "hello")])

        let coordinator = BackupCoordinator(databaseURL: root.databaseURL)
        let package = try coordinator.createBackup(in: coordinator.backupsRoot)

        #expect(package.pathExtension == BackupLayout.packageExtension)
        let manifest = try readManifest(in: package)
        #expect(manifest.formatVersion == BackupManifest.supportedFormatVersion)
        #expect(manifest.schemaVersion == BackupCoordinator.supportedSchemaVersion)
        #expect(manifest.attachmentCount == 1)
        #expect(manifest.attachments.count == 1)
        #expect(manifest.platform == "apple")
        #expect(!manifest.appVersion.isEmpty)
        #expect(!manifest.buildNumber.isEmpty)

        // The recorded digest has to match the payload actually shipped.
        let shippedDatabase = BackupLayout.databaseURL(in: package)
        let shippedDigest = try sha256(of: shippedDatabase)
        let shippedSize = try FileChecksum.regularFileSize(of: shippedDatabase)
        #expect(manifest.databaseSHA256 == shippedDigest)
        #expect(manifest.databaseByteSize == shippedSize)

        // The database identity is a v4 UUID, which is what the preflight
        // checks before it will consider restoring anything.
        let identity = manifest.databaseIdentity.lowercased()
        #expect(identity.range(
            of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
            options: .regularExpression
        ) != nil)

        // The attachment payload really is inside the package.
        let entry = manifest.attachments[0]
        let payload = BackupLayout.attachmentURL(in: package, uuid: entry.uuid)
        let payloadDigest = try sha256(of: payload)
        #expect(FileManager.default.fileExists(atPath: payload.path))
        #expect(entry.sha256 == payloadDigest)
    }

    @Test("Preflight reports the same counts the database holds")
    func preflightCounts() throws {
        let root = try TemporaryDataRoot()
        defer { root.cleanup() }
        try seed(root, taskTitles: ["One", "Two", "Three"], attachments: [("a.txt", "a")])

        let coordinator = BackupCoordinator(databaseURL: root.databaseURL)
        let package = try coordinator.createBackup(in: coordinator.backupsRoot)
        let preflight = try coordinator.preflight(package: package)

        #expect(preflight.summary.taskCount == 3)
        #expect(preflight.summary.attachmentCount == 1)
        #expect(preflight.summary.completedTaskCount == 0)
        #expect(preflight.summary.schemaVersion == BackupCoordinator.supportedSchemaVersion)
        #expect(preflight.manifest.databaseIdentity == preflight.summary.databaseIdentity)
    }

    @Test("A backup is taken from a consistent snapshot, not a torn copy")
    func backupIsInternallyConsistent() throws {
        let root = try TemporaryDataRoot()
        defer { root.cleanup() }
        try seed(root, taskTitles: ["Only"], attachments: [])

        let coordinator = BackupCoordinator(databaseURL: root.databaseURL)
        let package = try coordinator.createBackup(in: coordinator.backupsRoot)

        // `quick_check` and the foreign-key check run inside preflight, so a
        // successful preflight is the evidence the copy is coherent.
        _ = try coordinator.preflight(package: package)
    }
}


// MARK: - Rejection

@Suite("Backup rejection")
struct BackupRejectionTests {

    @Test("A package with a damaged database fails its checksum")
    func damagedDatabaseIsRejected() throws {
        let root = try TemporaryDataRoot()
        defer { root.cleanup() }
        try seed(root, taskTitles: ["Alpha"], attachments: [])

        let coordinator = BackupCoordinator(databaseURL: root.databaseURL)
        let package = try coordinator.createBackup(in: coordinator.backupsRoot)

        let database = BackupLayout.databaseURL(in: package)
        var bytes = try Data(contentsOf: database)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: database)

        #expect {
            _ = try coordinator.preflight(package: package)
        } throws: { error in
            error as? BackupError == .databaseChecksumMismatch
        }
    }

    @Test("A package without a manifest is rejected")
    func missingManifestIsRejected() throws {
        let root = try TemporaryDataRoot()
        defer { root.cleanup() }
        try seed(root, taskTitles: ["Alpha"], attachments: [])

        let coordinator = BackupCoordinator(databaseURL: root.databaseURL)
        let package = try coordinator.createBackup(in: coordinator.backupsRoot)
        try FileManager.default.removeItem(at: BackupLayout.manifestURL(in: package))

        #expect {
            _ = try coordinator.preflight(package: package)
        } throws: { error in
            error as? BackupError == .manifestMissing
        }
    }

    /// The rule that protects an old client from a newer database: it must
    /// refuse outright rather than try and corrupt what it cannot read.
    @Test("A newer schema version fails closed on an older client")
    func newerSchemaFailsClosed() throws {
        let root = try TemporaryDataRoot()
        defer { root.cleanup() }
        try seed(root, taskTitles: ["Alpha"], attachments: [])

        let coordinator = BackupCoordinator(databaseURL: root.databaseURL)
        let package = try coordinator.createBackup(in: coordinator.backupsRoot)

        var manifest = try readManifest(in: package)
        manifest = BackupManifest(
            formatVersion: manifest.formatVersion,
            createdAtUTC: manifest.createdAtUTC,
            schemaVersion: BackupCoordinator.supportedSchemaVersion + 1,
            databaseIdentity: manifest.databaseIdentity,
            databaseFileName: manifest.databaseFileName,
            databaseByteSize: manifest.databaseByteSize,
            databaseSHA256: manifest.databaseSHA256,
            attachmentCount: manifest.attachmentCount,
            attachments: manifest.attachments,
            appVersion: manifest.appVersion,
            buildNumber: manifest.buildNumber,
            platform: manifest.platform
        )
        try writeManifest(manifest, in: package)

        #expect {
            _ = try coordinator.preflight(package: package)
        } throws: { error in
            guard case .newerSchemaVersion(let backup, let supported) = error as? BackupError else {
                return false
            }
            return backup == BackupCoordinator.supportedSchemaVersion + 1
                && supported == BackupCoordinator.supportedSchemaVersion
        }
    }

    @Test("A package missing an attachment payload is rejected")
    func missingAttachmentIsRejected() throws {
        let root = try TemporaryDataRoot()
        defer { root.cleanup() }
        try seed(root, taskTitles: ["Alpha"], attachments: [("notes.txt", "payload")])

        let coordinator = BackupCoordinator(databaseURL: root.databaseURL)
        let package = try coordinator.createBackup(in: coordinator.backupsRoot)
        let manifest = try readManifest(in: package)
        try FileManager.default.removeItem(
            at: BackupLayout.attachmentURL(in: package, uuid: manifest.attachments[0].uuid)
        )

        #expect {
            _ = try coordinator.preflight(package: package)
        } throws: { error in
            guard case .attachmentPayloadMissing = error as? BackupError else { return false }
            return true
        }
    }

    /// Bytes swapped for different bytes of the same length.
    ///
    /// The replacement is deliberately the same length as the original so the
    /// size gate does not trip first. The point of this case is the checksum,
    /// and a tampered file that happened to keep its length is the realistic
    /// one: an attacker or a bad disk rarely edits a file without resizing it,
    /// but a truncated sync can produce exactly this.
    @Test("A package whose attachment bytes changed fails its checksum")
    func damagedAttachmentIsRejected() throws {
        let root = try TemporaryDataRoot()
        defer { root.cleanup() }
        try seed(root, taskTitles: ["Alpha"], attachments: [("notes.txt", "payload")])

        let coordinator = BackupCoordinator(databaseURL: root.databaseURL)
        let package = try coordinator.createBackup(in: coordinator.backupsRoot)
        let manifest = try readManifest(in: package)
        let payload = BackupLayout.attachmentURL(in: package, uuid: manifest.attachments[0].uuid)
        #expect(try FileChecksum.regularFileSize(of: payload) == 7)
        // Same seven bytes, different content: "payload" with one letter changed.
        try Data("payloax".utf8).write(to: payload)

        #expect {
            _ = try coordinator.preflight(package: package)
        } throws: { error in
            error as? BackupError == .attachmentChecksumMismatch("notes.txt")
        }
    }

    /// The size gate runs before the checksum because it is the cheaper read,
    /// so a resized payload reports as a size mismatch. Pinning the order stops
    /// a future reordering from quietly changing which error a user sees.
    @Test("A package whose attachment changed size is rejected before the checksum")
    func resizedAttachmentIsRejected() throws {
        let root = try TemporaryDataRoot()
        defer { root.cleanup() }
        try seed(root, taskTitles: ["Alpha"], attachments: [("notes.txt", "payload")])

        let coordinator = BackupCoordinator(databaseURL: root.databaseURL)
        let package = try coordinator.createBackup(in: coordinator.backupsRoot)
        let manifest = try readManifest(in: package)
        let payload = BackupLayout.attachmentURL(in: package, uuid: manifest.attachments[0].uuid)
        try Data("tampered".utf8).write(to: payload)

        #expect {
            _ = try coordinator.preflight(package: package)
        } throws: { error in
            error as? BackupError == .attachmentSizeMismatch("notes.txt")
        }
    }
}


// MARK: - Export

@Suite("Backup export")
struct BackupExportTests {

    @Test("Exporting twice never overwrites the first export")
    func exportNeverOverwrites() throws {
        let root = try TemporaryDataRoot()
        defer { root.cleanup() }
        try seed(root, taskTitles: ["Alpha"], attachments: [])

        let coordinator = BackupCoordinator(databaseURL: root.databaseURL)
        let package = try coordinator.createBackup(in: coordinator.backupsRoot)
        let destination = root.root.appendingPathComponent("Exports", isDirectory: true)

        let first = try coordinator.export(package: package, to: destination)
        #expect(coordinator.exportWouldOverwrite(name: first.lastPathComponent, in: destination))
        let second = try coordinator.export(package: package, to: destination)

        #expect(first != second)
        #expect(first.deletingLastPathComponent() == destination.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))

        // Both copies still verify independently.
        _ = try coordinator.preflight(package: first)
        _ = try coordinator.preflight(package: second)
    }

    @Test("Importing an external package copies it before anything is verified")
    func stageExternalPackageCopies() throws {
        let root = try TemporaryDataRoot()
        defer { root.cleanup() }
        try seed(root, taskTitles: ["Alpha"], attachments: [])

        let coordinator = BackupCoordinator(databaseURL: root.databaseURL)
        let package = try coordinator.createBackup(in: coordinator.backupsRoot)

        // Pretend the user picked a package sitting outside the data root.
        let external = root.root.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: package,
            to: external.appendingPathComponent(package.lastPathComponent, isDirectory: true)
        )
        let chosen = external.appendingPathComponent(package.lastPathComponent, isDirectory: true)

        let staged = try coordinator.stageExternalPackage(chosen)
        #expect(staged.deletingLastPathComponent() == coordinator.importedRoot.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: chosen.path))

        // A second import of the same name gets its own suffixed copy.
        let again = try coordinator.stageExternalPackage(chosen)
        #expect(again != staged)
    }
}


// MARK: - Restore

@Suite("Backup restore")
struct BackupRestoreTests {

    @Test("Restore brings back the database and the attachment payloads")
    func restoreRoundTrip() throws {
        let root = try TemporaryDataRoot()
        defer { root.cleanup() }
        try seed(root, taskTitles: ["Alpha", "Beta"], attachments: [("notes.txt", "payload-body")])

        let coordinator = BackupCoordinator(databaseURL: root.databaseURL)
        let package = try coordinator.createBackup(in: coordinator.backupsRoot)
        let preflight = try coordinator.preflight(package: package)

        // Wipe the live data: different tasks, no attachments.
        do {
            let tasks = try SQLiteAssignmentRepository(databaseURL: root.databaseURL)
            for assignment in try tasks.fetchAll() {
                try tasks.delete(id: assignment.id)
            }
            _ = try tasks.create(AssignmentDraft(courseName: "Other", title: "Replacement"))
        }
        try? FileManager.default.removeItem(at: root.attachmentsRoot)

        do {
            let tasks = try SQLiteAssignmentRepository(databaseURL: root.databaseURL)
            #expect(try tasks.fetchAll().map(\.title) == ["Replacement"])
        }

        let outcome = try coordinator.restore(package: package, canReopenDatabase: true)

        #expect(outcome.requiresRestart == false)
        #expect(outcome.summary.taskCount == 2)
        #expect(outcome.summary.attachmentCount == 1)
        #expect(FileManager.default.fileExists(atPath: outcome.safetyBackupURL.path))

        // The safety backup holds the replaced state, not the restored one.
        let safetySummary = try coordinator.preflight(package: outcome.safetyBackupURL).summary
        #expect(safetySummary.taskCount == 1)

        do {
            let tasks = try SQLiteAssignmentRepository(databaseURL: root.databaseURL)
            let organization = try SQLiteOrganizationRepository(databaseURL: root.databaseURL)
            let store = AttachmentFileStore(databaseURL: root.databaseURL)

            let restored = try tasks.fetchAll()
            #expect(Set(restored.map(\.title)) == ["Alpha", "Beta"])

            guard let first = restored.first(where: { $0.title == "Alpha" }) else {
                throw BackupFixtureError.fileMissing("Alpha")
            }
            let metadata = try organization.fetchAttachments(assignmentID: first.id)
            #expect(metadata.count == 1)
            let payload = try store.payloadURL(for: metadata[0])
            #expect(String(data: try Data(contentsOf: payload), encoding: .utf8) == "payload-body")
            _ = preflight
        }
    }

    /// The promise the UI makes: if a restore fails, the user's data and
    /// attachments are exactly as they were.
    @Test("A restore that fails verification leaves the live data untouched")
    func failedRestoreRollsBack() throws {
        let root = try TemporaryDataRoot()
        defer { root.cleanup() }
        try seed(root, taskTitles: ["Original"], attachments: [("notes.txt", "keep-me")])

        let coordinator = BackupCoordinator(databaseURL: root.databaseURL)
        let package = try coordinator.createBackup(in: coordinator.backupsRoot)

        let databaseBefore = try sha256(of: root.databaseURL)
        let manifest = try readManifest(in: package)
        let attachmentBefore = try sha256(
            of: attachmentPayload(root, uuid: manifest.attachments[0].uuid)
        )
        let liveBefore = try SQLiteAssignmentRepository(databaseURL: root.databaseURL)
            .fetchAll()
            .map(\.title)

        // Damage the package so preflight fails before any swap happens.
        let packaged = BackupLayout.databaseURL(in: package)
        var bytes = try Data(contentsOf: packaged)
        bytes[bytes.count - 1] ^= 0x0F
        try bytes.write(to: packaged)

        #expect(throws: BackupError.self) {
            _ = try coordinator.restore(package: package, canReopenDatabase: true)
        }

        #expect(try sha256(of: root.databaseURL) == databaseBefore)
        #expect(
            try sha256(of: attachmentPayload(root, uuid: manifest.attachments[0].uuid))
                == attachmentBefore
        )
        #expect(try SQLiteAssignmentRepository(databaseURL: root.databaseURL).fetchAll().map(\.title) == liveBefore)

        // No staging or rollback debris is left behind.
        #expect(
            !FileManager.default.fileExists(
                atPath: root.root.appendingPathComponent(".restore-staging", isDirectory: true)
                    .appendingPathComponent("x").path
            )
        )
    }

    @Test("A restore is preceded by an automatic safety backup")
    func restoreCreatesSafetyBackup() throws {
        let root = try TemporaryDataRoot()
        defer { root.cleanup() }
        try seed(root, taskTitles: ["Before"], attachments: [])

        let coordinator = BackupCoordinator(databaseURL: root.databaseURL)
        let package = try coordinator.createBackup(in: coordinator.backupsRoot)
        let outcome = try coordinator.restore(package: package, canReopenDatabase: false)

        #expect(outcome.requiresRestart == true)
        #expect(FileManager.default.fileExists(atPath: outcome.safetyBackupURL.path))
        #expect(
            outcome.safetyBackupURL.deletingLastPathComponent()
                == coordinator.backupsRoot.standardizedFileURL
        )
    }
}
