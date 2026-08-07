import Foundation
import XCTest


final class AssignmentApp2UITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchesWithAnIsolatedDatabase() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AssignmentApp2UITests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let app = XCUIApplication()
        app.launchEnvironment["ASSIGNMENT_DB_PATH"] = directoryURL
            .appendingPathComponent("assignments.db")
            .path
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        let quickAddExists = app.buttons["Quick Add"].waitForExistence(timeout: 5)
        XCTAssertTrue(quickAddExists || app.buttons["New Task"].exists)
    }
}
