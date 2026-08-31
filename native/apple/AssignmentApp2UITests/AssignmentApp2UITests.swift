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

    /// Real smoke test of the Phase 3A pages: a meeting and an exam are created
    /// through the actual UI, a Review Task is requested twice, and every step
    /// is captured. It runs against a throwaway database.
    @MainActor
    func testLearningScenesSmoke() throws {
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

        // MARK: Timetable

        let timetable = app.buttons["sidebar-timetable"]
        XCTAssertTrue(timetable.waitForExistence(timeout: 10), "Timetable sidebar item")
        XCTAssertEqual(timetable.label, "Timetable")
        timetable.tap()

        // The empty state and the toolbar both offer "Add Meeting", so the
        // toolbar one is addressed through its navigation bar.
        let timetableBar = app.navigationBars["Timetable"]
        XCTAssertTrue(timetableBar.waitForExistence(timeout: 5))
        XCTAssertTrue(timetableBar.buttons["Add Meeting"].exists)
        capture("ipad-timetable-empty", app: app)

        timetableBar.buttons["Add Meeting"].tap()
        // The sheet starts in "create a course" mode when the database has no
        // courses yet, and in picker mode otherwise. Both paths are supported
        // here so the step does not depend on leftover state.
        let newCourse = app.buttons["Add a New Course"]
        if newCourse.waitForExistence(timeout: 3) {
            newCourse.tap()
        }
        let courseField = app.textFields["Course name"]
        XCTAssertTrue(courseField.waitForExistence(timeout: 5), "Course name field")
        courseField.tap()
        courseField.typeText("Physics")
        capture("ipad-meeting-editor", app: app)

        app.buttons["Save"].tap()

        let meetingTitle = app.staticTexts["Physics"]
        XCTAssertTrue(meetingTitle.waitForExistence(timeout: 5), "Saved meeting appears")
        capture("ipad-timetable-week", app: app)

        // The Today scope is a real switch, not a filter of the same list.
        app.segmentedControls.buttons["Today"].tap()
        XCTAssertTrue(meetingTitle.waitForExistence(timeout: 5))
        capture("ipad-timetable-today", app: app)
        app.segmentedControls.buttons["Week"].tap()

        // MARK: Exams

        let exams = app.buttons["sidebar-exams"]
        XCTAssertTrue(exams.waitForExistence(timeout: 5))
        XCTAssertEqual(exams.label, "Exams")
        exams.tap()
        let examsBar = app.navigationBars["Exams"]
        XCTAssertTrue(examsBar.waitForExistence(timeout: 5))
        XCTAssertTrue(examsBar.buttons["Add Exam"].exists)
        capture("ipad-exams-empty", app: app)

        examsBar.buttons["Add Exam"].tap()
        // "Physics" already exists, so the editor opens in picker mode and the
        // explicit affordance must be present. Typing the same name again must
        // reuse that course instead of creating a second one.
        let examCourse = app.buttons["Add a New Course"]
        XCTAssertTrue(
            examCourse.waitForExistence(timeout: 5),
            "Existing courses leave the picker branch in place"
        )
        examCourse.tap()
        let nameField = app.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Exam name field")
        nameField.tap()
        nameField.typeText("Midterm")
        let examCourseField = app.textFields["Course name"]
        XCTAssertTrue(examCourseField.waitForExistence(timeout: 5), "Exam course field")
        examCourseField.tap()
        examCourseField.typeText("Physics")
        capture("ipad-exam-editor", app: app)

        app.buttons["Save"].tap()

        let examTitle = app.staticTexts["Midterm"]
        XCTAssertTrue(examTitle.waitForExistence(timeout: 5), "Saved exam appears")
        capture("ipad-exams-after-add", app: app)

        // MARK: Review task, requested twice

        let reviewButton = app.buttons["Add Review Task"]
        XCTAssertTrue(reviewButton.waitForExistence(timeout: 5))
        reviewButton.tap()

        let createdAlert = app.alerts["Review Task Created"]
        XCTAssertTrue(createdAlert.waitForExistence(timeout: 5), "First request creates it")
        capture("ipad-review-task-created", app: app)
        app.alerts.buttons["OK"].tap()

        XCTAssertTrue(
            app.staticTexts["Review task linked"].waitForExistence(timeout: 5),
            "The exam row shows the existing link"
        )
        XCTAssertFalse(app.buttons["Add Review Task"].exists, "No second task is offered")

        // MARK: Today overview

        let today = app.buttons["sidebar-today"]
        XCTAssertTrue(today.waitForExistence(timeout: 5))
        today.tap()
        XCTAssertTrue(app.staticTexts["Classes Today"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Exams Soon"].waitForExistence(timeout: 5))
        capture("ipad-today-overview", app: app)

        // MARK: Orientation

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.staticTexts["Classes Today"].waitForExistence(timeout: 5))
        capture("ipad-landscape-today-overview", app: app)

        timetable.tap()
        XCTAssertTrue(app.staticTexts["Physics"].waitForExistence(timeout: 5))
        capture("ipad-landscape-timetable", app: app)

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.staticTexts["Physics"].waitForExistence(timeout: 5))
        capture("ipad-portrait-timetable", app: app)
    }

    @MainActor
    private func capture(_ name: String, app: XCUIApplication) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        // `xcresulttool export attachments` drops the attachment name, so the
        // named copy is written directly and is what the report links to.
        guard let directory = Self.screenshotDirectory else { return }
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL = directory.appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: fileURL)
    }

    /// Resolved once and printed, because the UI test runner is sandboxed and
    /// the in-tree path is not always writable from the test process.
    private static let screenshotDirectory: URL? = {
        let manager = FileManager.default
        var candidates: [URL] = []

        if let override = ProcessInfo.processInfo
            .environment["ASSIGNMENT_UI_SCREENSHOT_DIR"],
           !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }

        candidates.append(
            URL(fileURLWithPath: #filePath)  // AssignmentApp2UITests.swift
                .deletingLastPathComponent() // AssignmentApp2UITests
                .deletingLastPathComponent() // AssignmentApp2
                .deletingLastPathComponent() // apple
                .deletingLastPathComponent() // native
                .appendingPathComponent("artifacts/apple/phase3a-ipad-ui", isDirectory: true)
        )
        candidates.append(
            manager.temporaryDirectory
                .appendingPathComponent("assignment-app-ui-screenshots", isDirectory: true)
        )

        for candidate in candidates {
            do {
                try manager.createDirectory(at: candidate, withIntermediateDirectories: true)
                let probe = candidate.appendingPathComponent(".writable-probe")
                try Data("ok".utf8).write(to: probe)
                try? manager.removeItem(at: probe)
                print("AssignmentApp2UITests screenshots: \(candidate.path)")
                return candidate
            } catch {
                print("AssignmentApp2UITests screenshots unavailable at \(candidate.path): \(error)")
            }
        }
        return nil
    }()
}
