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


enum MigrationStrategy: String, Equatable {
    case none
    case createV3 = "create-v3"
    case v2ToV3 = "v2-v3-additive"
    case v1AdditiveToV3 = "v1-v2-additive+v2-v3-additive"
    case v1RebuildToV3 = "v1-v2-rebuild+v2-v3-additive"
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
