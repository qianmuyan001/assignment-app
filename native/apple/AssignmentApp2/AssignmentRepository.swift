import Foundation


protocol AssignmentRepository: AnyObject {
    var databaseURL: URL { get }

    func fetchAll() throws -> [Assignment]

    @discardableResult
    func create(_ draft: AssignmentDraft) throws -> Assignment

    @discardableResult
    func update(_ assignment: Assignment) throws -> Assignment

    func delete(id: Int64) throws

    @discardableResult
    func restore(id: Int64) throws -> Assignment

    @discardableResult
    func updateStatus(
        id: Int64,
        status: AssignmentStatus
    ) throws -> Assignment
}


/// Names describe the complete chain that produced the current version, so a
/// v2 database records that it also received the additive v4 upgrade.
/// Names describe the complete chain that produced the current version, so a
/// v2 database records that it also received the additive v4 upgrade.
enum MigrationStrategy: String, Equatable {
    /// Produced when the database was already at the current schema version.
    case none

    // Live strategies. Every `MigrationCoordinator` path ends at v4; there is
    // no v3-only exit.
    case createV4 = "create-v3+v3-v4-additive"
    case v2ToV4 = "v2-v3-additive+v3-v4-additive"
    case v1AdditiveToV4 = "v1-v2-additive+v2-v3-additive+v3-v4-additive"
    case v1RebuildToV4 = "v1-v2-rebuild+v2-v3-additive+v3-v4-additive"
    case v3ToV4 = "v3-v4-additive"

    // Retired strategies. Nothing calls the standalone v1-to-v2 entry point in
    // `SQLiteAssignmentRepository` any more: the app and the tests all go
    // through `MigrationCoordinator`. They stop at v2, so they are named for
    // what they actually do rather than for a version they never reach.
    case createV2 = "create-v2"
    case v1AdditiveToV2 = "v1-v2-additive"
    case v1RebuildToV2 = "v1-v2-rebuild"
}


struct MigrationResult: Equatable {
    let fromVersion: Int32
    let toVersion: Int32
    let migrated: Bool
    let backupURL: URL?
    let strategy: MigrationStrategy
}


struct DatabaseMigrationError: LocalizedError {
    let message: String
    let backupURL: URL?

    init(_ message: String, backupURL: URL? = nil) {
        self.message = message
        self.backupURL = backupURL
    }

    var errorDescription: String? { message }
}


enum AssignmentRepositoryError: LocalizedError {
    case validation(String)
    case open(String)
    case prepare(String)
    case execute(String)
    case notFound(Int64)
    case corruptData(String)
    case readOnlyAfterMigrationFailure

    var errorDescription: String? {
        switch self {
        case .validation(let message):
            return message
        case .open(let message):
            return "Could not open the task database: \(message)"
        case .prepare(let message):
            return "Could not prepare a database operation: \(message)"
        case .execute(let message):
            return "Could not complete a database operation: \(message)"
        case .notFound(let id):
            return "Task \(id) no longer exists."
        case .corruptData(let message):
            return "The task database contains invalid data: \(message)"
        case .readOnlyAfterMigrationFailure:
            return "Writes are disabled because the database migration did not complete."
        }
    }
}
