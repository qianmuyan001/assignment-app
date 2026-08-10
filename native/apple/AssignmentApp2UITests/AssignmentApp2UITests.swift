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

    @MainActor
    func testSidebarAndSearchStateSmoke() throws {
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
        app.launchArguments.append("-assignmentApp.uiTestSidebarExpanded")
        app.launchEnvironment["ASSIGNMENT_DB_PATH"] = directoryURL
            .appendingPathComponent("assignments.db")
            .path
        app.launch()

        let today = app.buttons["sidebar-today"]
        XCTAssertTrue(today.waitForExistence(timeout: 10))
        today.tap()
        capture("ipad-expanded-today", app: app)

        let styleToggle = app.buttons["sidebar-style-toggle"]
        XCTAssertTrue(
            styleToggle.waitForExistence(timeout: 5),
            "Selecting a task category must not hide the sidebar."
        )
        styleToggle.tap()

        let compactStyleToggle = app.buttons["sidebar-style-toggle"]
        let compactStyleApplied = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@",
                "Show Sidebar Labels"
            ),
            object: compactStyleToggle
        )
        wait(for: [compactStyleApplied], timeout: 5)

        let compactAll = app.buttons["sidebar-all"]
        XCTAssertTrue(compactAll.waitForExistence(timeout: 5))
        XCTAssertEqual(compactAll.label, "All Tasks")
        capture("ipad-compact", app: app)

        let searchToggle = app.buttons["search-toggle"]
        XCTAssertTrue(searchToggle.waitForExistence(timeout: 5))
        searchToggle.tap()

        let searchField = app.textFields["search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.typeText("physics")
        capture("ipad-search-expanded", app: app)

        let closeSearch = app.buttons["search-close"]
        XCTAssertTrue(closeSearch.waitForExistence(timeout: 5))
        closeSearch.tap()

        XCTAssertFalse(searchField.waitForExistence(timeout: 1))
        XCTAssertTrue(app.staticTexts["Today"].waitForExistence(timeout: 5))
        XCTAssertTrue(styleToggle.exists)
        capture("ipad-search-restored", app: app)

        #if targetEnvironment(macCatalyst)
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        XCTAssertTrue(styleToggle.exists, "Command-F must not hide the sidebar.")
        searchField.typeText("history")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(searchField.waitForExistence(timeout: 1))
        XCTAssertTrue(app.staticTexts["Today"].waitForExistence(timeout: 5))

        searchToggle.tap()
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        XCTAssertTrue((searchField.value as? String)?.contains("history") == true)
        app.typeKey(.escape, modifierFlags: [])
        #else
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(styleToggle.waitForExistence(timeout: 5))
        XCTAssertTrue(searchToggle.exists)
        capture("ipad-landscape-compact", app: app)
        XCUIDevice.shared.orientation = .portrait
        #endif
    }

    @MainActor
    func testCompactSidebarAccessibilityAtLargestTextAndRapidRetarget() throws {
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
        app.launchArguments += [
            "-assignmentApp.uiTestSidebarCompact",
            "-assignmentApp.uiTestDynamicTypeAccessibility5",
        ]
        app.launchEnvironment["ASSIGNMENT_DB_PATH"] = directoryURL
            .appendingPathComponent("assignments.db")
            .path
        app.launch()

        let destinations = [
            ("sidebar-all", "All Tasks"),
            ("sidebar-today", "Today"),
            ("sidebar-week", "This Week"),
            ("sidebar-overdue", "Overdue"),
            ("sidebar-completed", "Completed"),
            ("sidebar-settings", "Settings"),
        ]

        for (identifier, label) in destinations {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.waitForExistence(timeout: 10), identifier)
            XCTAssertEqual(button.label, label)
            XCTAssertTrue(button.isHittable, identifier)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, identifier)
        }

        app.buttons["sidebar-today"].tap()
        app.buttons["sidebar-week"].tap()
        app.buttons["sidebar-overdue"].tap()

        XCTAssertTrue(app.buttons["sidebar-overdue"].isSelected)
        XCTAssertTrue(app.buttons["sidebar-style-toggle"].isHittable)
        XCTAssertEqual(
            app.buttons["sidebar-style-toggle"].label,
            "Show Sidebar Labels"
        )
        capture("ipad-compact-accessibility-xxxl", app: app)
    }

    @MainActor
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
