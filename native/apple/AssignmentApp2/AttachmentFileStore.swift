import CryptoKit
import Foundation


enum AttachmentFileStoreError: LocalizedError, Equatable {
    case invalidStoragePath
    case unsafeStorageRoot
    case payloadMissing(String)
    case payloadIsNotARegularFile
    case metadataIdentityMismatch

    var errorDescription: String? {
        switch self {
        case .invalidStoragePath:
            return L10n.tr(LocalizationCatalogKey.attachmentPathInvalid.rawValue)
        case .unsafeStorageRoot:
            return L10n.tr(LocalizationCatalogKey.attachmentRootUnsafe.rawValue)
        case .payloadMissing(let name):
            return L10n.tr(LocalizationCatalogKey.attachmentPayloadMissing.rawValue, name)
        case .payloadIsNotARegularFile:
            return L10n.tr(LocalizationCatalogKey.attachmentNotRegularFile.rawValue)
        case .metadataIdentityMismatch:
            return L10n.tr(LocalizationCatalogKey.attachmentIdentityMismatch.rawValue)
        }
    }
}


struct AttachmentReconciliationResult: Equatable {
    let removedOrphanCount: Int
    let missingPayloadNames: [String]
}


/// Owns attachment payloads. The database remains metadata-only and stores the
/// immutable `attachments/<UUID>` key shared by every platform.
final class AttachmentFileStore {
    private let fileManager: FileManager
    private let dataRoot: URL
    private let attachmentsRoot: URL
    private let stagingRoot: URL
    private let presentationsRoot: URL

    init(databaseURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        dataRoot = databaseURL.deletingLastPathComponent().standardizedFileURL
        attachmentsRoot = dataRoot.appendingPathComponent("attachments", isDirectory: true)
        stagingRoot = dataRoot.appendingPathComponent(".attachment-staging", isDirectory: true)
        presentationsRoot = dataRoot.appendingPathComponent(
            ".attachment-presentations",
            isDirectory: true
        )
    }

    func importFile(
        from sourceURL: URL,
        assignmentID: Int64,
        mimeType: String?,
        repository: OrganizationRepository
    ) throws -> AttachmentMetadata {
        try prepareDirectories()
        let fileName = sourceURL.lastPathComponent
        let uuid = UUID()
        let destination = try payloadURL(for: uuid)
        let staged = stagingRoot
            .appendingPathComponent("\(UUID().uuidString.lowercased()).partial")

        do {
            try fileManager.copyItem(at: sourceURL, to: staged)
            let values = try inspectRegularFile(at: staged)
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw AttachmentFileStoreError.metadataIdentityMismatch
            }
            try fileManager.moveItem(at: staged, to: destination)

            do {
                let metadata = try repository.createAttachmentMetadata(.init(
                    assignmentID: assignmentID,
                    fileName: fileName,
                    mimeType: mimeType,
                    byteSize: values.byteSize,
                    sha256: values.sha256,
                    uuid: uuid
                ))
                guard metadata.uuid == uuid,
                      metadata.relativePath == "attachments/\(uuid.uuidString.lowercased())" else {
                    throw AttachmentFileStoreError.metadataIdentityMismatch
                }
                return metadata
            } catch {
                try? fileManager.removeItem(at: destination)
                throw error
            }
        } catch {
            try? fileManager.removeItem(at: staged)
            throw error
        }
    }

    func payloadURL(for attachment: AttachmentMetadata) throws -> URL {
        let expected = "attachments/\(attachment.uuid.uuidString.lowercased())"
        guard attachment.relativePath == expected else {
            throw AttachmentFileStoreError.invalidStoragePath
        }
        let url = try payloadURL(for: attachment.uuid)
        guard fileManager.fileExists(atPath: url.path) else {
            throw AttachmentFileStoreError.payloadMissing(attachment.fileName)
        }
        _ = try inspectRegularFile(at: url)
        return url
    }

    func presentationURL(for attachment: AttachmentMetadata) throws -> URL {
        let payload = try payloadURL(for: attachment)
        try prepareDirectories()
        let fileName = attachment.fileName
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              !fileName.contains("/"),
              !fileName.contains("\\") else {
            throw AttachmentFileStoreError.invalidStoragePath
        }
        let directory = presentationsRoot.appendingPathComponent(
            attachment.uuid.uuidString.lowercased(),
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let directoryValues = try directory.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true else {
            throw AttachmentFileStoreError.unsafeStorageRoot
        }
        let destination = directory.appendingPathComponent(fileName).standardizedFileURL
        guard destination.deletingLastPathComponent() == directory.standardizedFileURL else {
            throw AttachmentFileStoreError.invalidStoragePath
        }
        if fileManager.fileExists(atPath: destination.path) {
            _ = try inspectRegularFile(at: destination)
            return destination
        }
        let staged = directory.appendingPathComponent(".\(UUID().uuidString).partial")
        do {
            try fileManager.copyItem(at: payload, to: staged)
            try fileManager.moveItem(at: staged, to: destination)
        } catch {
            try? fileManager.removeItem(at: staged)
            throw error
        }
        return destination
    }

    func deleteFileAndMetadata(
        _ attachment: AttachmentMetadata,
        repository: OrganizationRepository
    ) throws {
        try prepareDirectories()
        let source = try payloadURL(for: attachment.uuid)
        let staged = stagingRoot
            .appendingPathComponent("\(attachment.uuid.uuidString.lowercased()).deleted")
        let hadPayload = fileManager.fileExists(atPath: source.path)

        if hadPayload {
            _ = try inspectRegularFile(at: source)
            if fileManager.fileExists(atPath: staged.path) {
                try fileManager.removeItem(at: staged)
            }
            try fileManager.moveItem(at: source, to: staged)
        }

        do {
            try repository.deleteAttachmentMetadata(id: attachment.id)
            if hadPayload {
                // The database delete is already committed. A cleanup failure
                // must not make the UI believe the metadata still exists;
                // reconciliation removes the tombstone on the next launch.
                try? fileManager.removeItem(at: staged)
            }
            let presentationDirectory = presentationsRoot.appendingPathComponent(
                attachment.uuid.uuidString.lowercased(),
                isDirectory: true
            )
            try? fileManager.removeItem(at: presentationDirectory)
        } catch {
            if hadPayload, fileManager.fileExists(atPath: staged.path) {
                try? fileManager.moveItem(at: staged, to: source)
            }
            throw error
        }
    }

    func reconcile(activeAttachments: [AttachmentMetadata]) throws -> AttachmentReconciliationResult {
        try prepareDirectories()
        let activeNames = Set(activeAttachments.map { $0.uuid.uuidString.lowercased() })
        try reconcileStaging(activeNames: activeNames)
        try reconcilePresentations(activeNames: activeNames)
        var missing: [String] = []
        for attachment in activeAttachments {
            let url = try payloadURL(for: attachment.uuid)
            if !fileManager.fileExists(atPath: url.path) {
                missing.append(attachment.fileName)
            }
        }

        var removed = 0
        for candidate in try fileManager.contentsOfDirectory(
            at: attachmentsRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) {
            guard UUID(uuidString: candidate.lastPathComponent) != nil,
                  !activeNames.contains(candidate.lastPathComponent.lowercased()) else {
                continue
            }
            let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try fileManager.removeItem(at: candidate)
            removed += 1
        }

        return .init(
            removedOrphanCount: removed,
            missingPayloadNames: missing.sorted()
        )
    }

    private func reconcileStaging(activeNames: Set<String>) throws {
        let candidates = try fileManager.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for candidate in candidates {
            let name = candidate.lastPathComponent
            if name.hasSuffix(".partial") {
                let values = try candidate.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ])
                if values.isRegularFile == true || values.isSymbolicLink == true {
                    try fileManager.removeItem(at: candidate)
                }
                continue
            }
            guard name.hasSuffix(".deleted") else { continue }
            let uuidText = String(name.dropLast(".deleted".count))
            guard let uuid = UUID(uuidString: uuidText),
                  uuid.uuidString.lowercased() == uuidText else { continue }
            let values = try candidate.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                if values.isSymbolicLink == true {
                    try fileManager.removeItem(at: candidate)
                }
                continue
            }
            let destination = try payloadURL(for: uuid)
            if activeNames.contains(uuidText),
               !fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: candidate, to: destination)
            } else {
                try fileManager.removeItem(at: candidate)
            }
        }
    }

    private func reconcilePresentations(activeNames: Set<String>) throws {
        for candidate in try fileManager.contentsOfDirectory(
            at: presentationsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) {
            let name = candidate.lastPathComponent.lowercased()
            guard let uuid = UUID(uuidString: name),
                  uuid.uuidString.lowercased() == name,
                  !activeNames.contains(name) else { continue }
            let values = try candidate.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            if values.isDirectory == true || values.isSymbolicLink == true {
                try fileManager.removeItem(at: candidate)
            }
        }
    }

    private func prepareDirectories() throws {
        try fileManager.createDirectory(
            at: attachmentsRoot,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: presentationsRoot,
            withIntermediateDirectories: true
        )
        for root in [attachmentsRoot, stagingRoot, presentationsRoot] {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw AttachmentFileStoreError.unsafeStorageRoot
            }
        }
    }

    private func payloadURL(for uuid: UUID) throws -> URL {
        let candidate = attachmentsRoot
            .appendingPathComponent(uuid.uuidString.lowercased(), isDirectory: false)
            .standardizedFileURL
        guard candidate.deletingLastPathComponent() == attachmentsRoot.standardizedFileURL else {
            throw AttachmentFileStoreError.invalidStoragePath
        }
        return candidate
    }

    private func inspectRegularFile(at url: URL) throws -> (byteSize: Int64, sha256: String) {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw AttachmentFileStoreError.payloadIsNotARegularFile
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (Int64(values.fileSize ?? 0), digest)
    }
}
