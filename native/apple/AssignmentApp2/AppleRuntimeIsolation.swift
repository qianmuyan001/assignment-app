import Foundation


/// Internal Catalyst packages retain this identity even when opened later in Finder.
/// A malformed identity or unexpected sandbox must fail before any database opens.
enum AppleRuntimeIsolation {
    static let bundlePrefix = "com.qianmuyan.assignmentapp.rcsmoke."
    static let uiTestTokenArgument = "-assignmentApp.testDatabaseToken"

    enum IsolationError: Error {
        case invalidIdentity
        case unexpectedContainer
        case invalidTestToken
    }

    static func packagedDatabaseURL(bundleIdentifier: String, home: URL) throws -> URL? {
        guard bundleIdentifier.hasPrefix(bundlePrefix) else { return nil }
        let token = String(bundleIdentifier.dropFirst(bundlePrefix.count))
        guard let uuid = UUID(uuidString: token), uuid.uuidString.lowercased() == token else {
            throw IsolationError.invalidIdentity
        }
        let resolvedHome = home.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedHome.lastPathComponent == "Data",
              resolvedHome.deletingLastPathComponent().lastPathComponent == bundleIdentifier,
              resolvedHome.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Containers" else {
            throw IsolationError.unexpectedContainer
        }
        let database = resolvedHome.appendingPathComponent(
            "Library/Application Support/AssignmentApp2/assignments.db"
        ).standardizedFileURL
        guard database.resolvingSymlinksInPath().path.hasPrefix(resolvedHome.path + "/") else {
            throw IsolationError.unexpectedContainer
        }
        return database
    }

    #if DEBUG
    static func uiTestDatabaseURL(arguments: [String], temporaryDirectory: URL) throws -> URL? {
        guard let index = arguments.firstIndex(of: uiTestTokenArgument) else { return nil }
        guard arguments.filter({ $0 == uiTestTokenArgument }).count == 1,
              arguments.indices.contains(index + 1),
              let uuid = UUID(uuidString: arguments[index + 1]) else {
            throw IsolationError.invalidTestToken
        }
        let root = temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent("assignment-app-ui-" + uuid.uuidString.lowercased())
            .appendingPathComponent("assignments.db")
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
            throw IsolationError.unexpectedContainer
        }
        return url
    }
    #endif
}
