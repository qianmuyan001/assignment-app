import Foundation
import Testing
@testable import AssignmentApp2


@Suite("Apple runtime data isolation")
struct AppleRuntimeIsolationTests {
    private let token = "ad4b52ca-8ac6-4fc6-8f51-883ee23c5ef9"

    @Test func productionIdentityDoesNotSelectTestStorage() throws {
        #expect(try AppleRuntimeIsolation.packagedDatabaseURL(
            bundleIdentifier: "com.qianmuyan.assignmentapp", home: URL(fileURLWithPath: "/private/tmp")
        ) == nil)
    }

    @Test func internalPackageUsesOnlyItsOwnContainer() throws {
        let identifier = AppleRuntimeIsolation.bundlePrefix + token
        let home = URL(fileURLWithPath: "/private/tmp/Library/Containers/\(identifier)/Data")
        let url = try #require(try AppleRuntimeIsolation.packagedDatabaseURL(bundleIdentifier: identifier, home: home))
        #expect(url.path == home.path + "/Library/Application Support/AssignmentApp2/assignments.db")
    }

    @Test func internalPackageRejectsProductionOrUnsandboxedHome() {
        for home in ["/Users/test", "/private/tmp/Library/Containers/com.qianmuyan.assignmentapp/Data"] {
            #expect(throws: AppleRuntimeIsolation.IsolationError.self) {
                try AppleRuntimeIsolation.packagedDatabaseURL(
                    bundleIdentifier: AppleRuntimeIsolation.bundlePrefix + token,
                    home: URL(fileURLWithPath: home)
                )
            }
        }
    }

    @Test func malformedInternalIdentityFailsClosed() {
        #expect(throws: AppleRuntimeIsolation.IsolationError.self) {
            try AppleRuntimeIsolation.packagedDatabaseURL(
                bundleIdentifier: AppleRuntimeIsolation.bundlePrefix + "invalid",
                home: URL(fileURLWithPath: "/private/tmp")
            )
        }
    }

    @Test func uiTokenCreatesUniqueAppOwnedPath() throws {
        let root = URL(fileURLWithPath: "/private/tmp").standardizedFileURL.resolvingSymlinksInPath()
        let first = try #require(try AppleRuntimeIsolation.uiTestDatabaseURL(
            arguments: ["app", AppleRuntimeIsolation.uiTestTokenArgument, token], temporaryDirectory: root
        ))
        let second = try #require(try AppleRuntimeIsolation.uiTestDatabaseURL(
            arguments: ["app", AppleRuntimeIsolation.uiTestTokenArgument, UUID().uuidString], temporaryDirectory: root
        ))
        #expect(first.path == root.path + "/assignment-app-ui-\(token)/assignments.db")
        #expect(first != second)
    }

    @Test func missingMalformedOrRepeatedUITokenFailsClosed() {
        let flag = AppleRuntimeIsolation.uiTestTokenArgument
        for arguments in [[flag], [flag, "../../assignments.db"], [flag, token, flag, token]] {
            #expect(throws: AppleRuntimeIsolation.IsolationError.self) {
                try AppleRuntimeIsolation.uiTestDatabaseURL(arguments: arguments, temporaryDirectory: URL(fileURLWithPath: "/private/tmp"))
            }
        }
    }
}

@Suite("Stable upgrade identity")
struct UpgradeIdentityTests {
    @Test func usesStableInternalContainer() throws {
        let id = AppleRuntimeIsolation.upgradeBundleIdentifier
        let home = URL(fileURLWithPath: "/private/tmp/Library/Containers/\(id)/Data")
        #expect(try AppleRuntimeIsolation.packagedDatabaseURL(bundleIdentifier: id, home: home)?.path.hasPrefix(home.path + "/") == true)
    }
    @Test func malformedReservedIdentityCannotFallBack() {
        for id in ["com.qianmuyan.assignmentapp.rcsmoke", "com.qianmuyan.assignmentapp.internal.typo"] {
            #expect(throws: AppleRuntimeIsolation.IsolationError.self) {
                try AppleRuntimeIsolation.packagedDatabaseURL(bundleIdentifier: id, home: URL(fileURLWithPath: "/private/tmp"))
            }
        }
    }
}
