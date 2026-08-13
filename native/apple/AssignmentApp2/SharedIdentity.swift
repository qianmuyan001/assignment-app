import CryptoKit
import Foundation


enum SharedIdentityError: LocalizedError, Equatable {
    case invalidDatabaseIdentity(String)
    case invalidLegacyKey(String)
    case unsupportedEntity(String)
    case invalidAttachmentUUID(String)

    var errorDescription: String? {
        switch self {
        case .invalidDatabaseIdentity(let value):
            return "Database identity must be a canonical lowercase UUID v4: \(value)."
        case .invalidLegacyKey(let value):
            return "Legacy identity key is invalid: \(value)."
        case .unsupportedEntity(let value):
            return "Unsupported deterministic UUID entity: \(value)."
        case .invalidAttachmentUUID(let value):
            return "Attachment UUID must be canonical lowercase UUID v4: \(value)."
        }
    }
}


/// Cross-platform identity and normalization primitives mirrored by
/// `shared/schema_v3.py` and `shared/fixtures/task-organization-v3.json`.
enum SharedIdentity {
    static func canonicalName(_ value: String) -> String {
        let compatibility = (value as NSString).precomposedStringWithCompatibilityMapping
        let collapsed = compatibility
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    static func newUUID() -> UUID {
        UUID()
    }

    static func deterministicUUID(
        databaseInstanceUUID: UUID,
        entity: String,
        legacyKey: String
    ) throws -> UUID {
        guard databaseInstanceUUID.versionNumber == 4 else {
            throw SharedIdentityError.invalidDatabaseIdentity(
                databaseInstanceUUID.uuidString.lowercased()
            )
        }

        let normalizedEntity = entity.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedKey: String
        switch normalizedEntity {
        case "task":
            guard let id = Int64(legacyKey), id > 0 else {
                throw SharedIdentityError.invalidLegacyKey(legacyKey)
            }
            normalizedKey = String(id)
        case "course":
            guard !legacyKey.isEmpty else {
                throw SharedIdentityError.invalidLegacyKey(legacyKey)
            }
            normalizedKey = legacyKey
        default:
            throw SharedIdentityError.unsupportedEntity(entity)
        }

        var bytes = databaseInstanceUUID.byteArray
        bytes.append(contentsOf: Data("\(normalizedEntity):\(normalizedKey)".utf8))
        var digest = Array(Insecure.SHA1.hash(data: Data(bytes)).prefix(16))
        digest[6] = (digest[6] & 0x0f) | 0x50
        digest[8] = (digest[8] & 0x3f) | 0x80
        return UUID(bytes: digest)
    }

    static func attachmentRelativePath(for uuid: UUID) throws -> String {
        guard uuid.versionNumber == 4 else {
            throw SharedIdentityError.invalidAttachmentUUID(uuid.uuidString.lowercased())
        }
        return "attachments/\(uuid.uuidString.lowercased())"
    }
}


extension UUID {
    var canonicalString: String { uuidString.lowercased() }

    var versionNumber: Int {
        Int((byteArray[6] & 0xf0) >> 4)
    }

    fileprivate var byteArray: [UInt8] {
        let value = uuid
        return [
            value.0, value.1, value.2, value.3,
            value.4, value.5, value.6, value.7,
            value.8, value.9, value.10, value.11,
            value.12, value.13, value.14, value.15,
        ]
    }

    fileprivate init(bytes: [UInt8]) {
        precondition(bytes.count == 16)
        self.init(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
