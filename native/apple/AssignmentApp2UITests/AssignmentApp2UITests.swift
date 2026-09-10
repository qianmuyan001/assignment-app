import Foundation
import XCTest
import UIKit


final class AssignmentApp2UITests: XCTestCase {
    /// The walkthrough is a first-launch overlay. Every other assertion in this
    /// suite should describe the app, not whether this happens to be the
    /// device's first run, so each launch opts out explicitly.
    static let skipOnboardingArgument = "-assignmentApp.uiTestSkipOnboarding"

    /// The language is stored in `UserDefaults`, which survives on a
    /// long-lived simulator between runs *and* between suites. Every launch
    /// pins English so a choice made by an earlier test cannot decide what a
    /// later one sees.
    static let englishLanguageArgument = "-assignmentApp.uiTestLanguage:english"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchesWithAnIsolatedDatabase() throws {
        let app = isolatedApplication()
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.buttons["add-task"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testTaskCreationFixedHeadingAndAnchoredDeletion() throws {
        let app = isolatedApplication()
        app.launch()
        let heading = app.staticTexts["fixed-task-title"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        for title in ["Z first", "A second"] {
            app.buttons["add-task"].tap()
            let titleField = app.textFields["task-editor-title"]
            XCTAssertTrue(titleField.waitForExistence(timeout: 5))
            XCTAssertFalse(app.segmentedControls.buttons["Done"].exists)
            titleField.tap(); titleField.typeText(title)
            let course = app.textFields["task-editor-course"]
            course.tap(); course.typeText("Course")
            app.buttons["Save"].tap()
            XCTAssertTrue(app.buttons["task-title-1"].waitForExistence(timeout: 5))
        }
        let first = app.buttons["task-title-1"]
        let second = app.buttons["task-title-2"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertLessThan(first.frame.minY, second.frame.minY)
        let headingFrame = heading.frame
        first.swipeDown()
        XCTAssertEqual(heading.frame.minY, headingFrame.minY, accuracy: 1)
        app.buttons["reload-tasks"].tap()
        XCTAssertTrue(app.staticTexts["refresh-completed"].waitForExistence(timeout: 5))
        XCTAssertLessThan(first.frame.minY, second.frame.minY)
        second.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        let confirm = app.buttons["confirm-delete-task"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        capture("task-delete-anchored", app: app)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(second.exists)
        second.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(first.exists)
        XCTAssertFalse(second.waitForExistence(timeout: 1))
        capture("task-list-after-delete", app: app)
    }

    @MainActor
    func testSidebarAndSearchStateSmoke() throws {
        let app = isolatedApplication(arguments: ["-assignmentApp.uiTestSidebarExpanded"])
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
        let app = isolatedApplication(arguments: [
            "-assignmentApp.uiTestSidebarCompact",
            "-assignmentApp.uiTestDynamicTypeAccessibility5",
        ])
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
    func testFloatingActionSafeAreaMargins() throws {
        let app = isolatedApplication(arguments: ["-assignmentApp.uiTestMeasureChrome"])
        app.launch()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let button = app.buttons["add-task"]
            let viewport = app.otherElements["task-action-safe-area"]
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            XCTAssertTrue(viewport.waitForExistence(timeout: 5))
            let aligned = NSPredicate { _, _ in
                abs((viewport.frame.maxX - button.frame.maxX) -
                    (viewport.frame.maxY - button.frame.maxY)) <= 1
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: aligned, object: nil)], timeout: 5), .completed)
            let right = viewport.frame.maxX - button.frame.maxX
            let bottom = viewport.frame.maxY - button.frame.maxY
            let logicalWidth = try XCTUnwrap(Double(viewport.value as? String ?? ""))
            let scale = logicalWidth / viewport.frame.width
            XCTAssertGreaterThanOrEqual(button.frame.width * scale, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height * scale, 44)
            XCTAssertEqual(right * scale, 24, accuracy: 1)
            XCTAssertEqual(bottom * scale, 24, accuracy: 1)
            let closeup = button.screenshot()
            let attachment = XCTAttachment(screenshot: closeup)
            attachment.name = "visual-add-button-closeup"
            attachment.lifetime = .keepAlways
            add(attachment)
            if let directory = Self.screenshotDirectory {
                try closeup.pngRepresentation.write(to: directory.appendingPathComponent("visual-add-button-closeup.png"))
            }
            XCTAssertTrue(app.windows.firstMatch.frame.contains(viewport.frame))
            print("VISUAL_SAFE_AREA orientation=\(orientation.rawValue) window=\(app.windows.firstMatch.frame) viewport=\(viewport.frame) button=\(button.frame) trailing=\(right) bottom=\(bottom)")
            capture(orientation == .portrait ? "visual-ipad-portrait" : "visual-ipad-landscape", app: app)
        }
    }

    @MainActor
    func testCompactOverlaySelectionCloseAndSearch() throws {
        let app = isolatedApplication(arguments: ["-assignmentApp.uiTestCompactNavigation", "-assignmentApp.uiTestSidebarExpanded"])
        app.launch()
        let open = app.buttons["compact-sidebar-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        let close = app.buttons["compact-sidebar-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        app.buttons["sidebar-today"].tap()
        XCTAssertTrue(close.exists, "Selecting a destination must keep the drawer open")
        XCTAssertTrue(app.buttons["sidebar-today"].isSelected)
        capture("visual-compact-sidebar-open", app: app)
        close.tap()
        capture("visual-compact-sidebar-closed", app: app)
        XCTAssertTrue(waitForDisappearance(of: close, timeout: 5))
        XCTAssertTrue(app.staticTexts["fixed-task-title"].exists)
        open.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(waitForDisappearance(of: close, timeout: 5))
        app.buttons["search-toggle"].tap()
        let search = app.textFields["search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        app.buttons["search-close"].tap()
        XCTAssertTrue(waitForDisappearance(of: search, timeout: 5))
        XCTAssertTrue(app.staticTexts["fixed-task-title"].exists)
    }

#if targetEnvironment(macCatalyst)
    /// The installed iPad runtime accepts XCTest's key request but does not
    /// deliver Escape to the app. Desktop keyboard coverage runs on Catalyst.
    @MainActor
    func testCompactOverlayEscapeKeyboard() throws {
        let app = isolatedApplication(arguments: ["-assignmentApp.uiTestCompactNavigation"])
        app.launch()
        XCTAssertTrue(app.buttons["compact-sidebar-open"].waitForExistence(timeout: 10))
        app.buttons["compact-sidebar-open"].tap()
        let close = app.buttons["compact-sidebar-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForDisappearance(of: close, timeout: 5))
        XCTAssertTrue(app.buttons["compact-sidebar-open"].isHittable)
        capture("visual-catalyst-escape-closed", app: app)
    }
#endif

    /// Exercise the production width predicate without changing device settings.
    /// A live search field catches accidental destruction of the detail stack.
    @MainActor
    func testResponsiveSidebarRetainsSearchAndSelection() throws {
        let app = isolatedApplication(arguments: ["-assignmentApp.uiTestResponsiveLayout",
                                                  "-assignmentApp.uiTestSidebarExpanded"])
        app.launch()
        let today = app.buttons["sidebar-today"]
        XCTAssertTrue(today.waitForExistence(timeout: 10))
        today.tap()
        app.buttons["search-toggle"].tap()
        let field = app.textFields["search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("physics")
        for _ in 0..<2 {
            app.buttons["test-resize-layout"].tap()
            let open = app.buttons["compact-sidebar-open"]
            XCTAssertTrue(open.waitForExistence(timeout: 5))
            XCTAssertEqual(field.value as? String, "physics")
            open.tap()
            let close = app.buttons["compact-sidebar-close"]
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            close.tap()
            XCTAssertTrue(waitForDisappearance(of: close, timeout: 5))
            app.buttons["test-resize-layout"].tap()
            XCTAssertTrue(today.waitForExistence(timeout: 5))
            XCTAssertEqual(field.value as? String, "physics")
        }
        capture("responsive-sidebar-search-retained", app: app)
    }

    @MainActor
    func testGlassPressCanCancelAndActivateOnce() throws {
        let app = isolatedApplication()
        app.launch()
        let add = app.buttons["add-task"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        let start = add.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let outside = start.withOffset(CGVector(dx: -150, dy: -100))
        // Hold exposes the native pressed glass in the simulator recording;
        // sliding away must cancel, rather than invoking the editor early.
        start.press(forDuration: 1, thenDragTo: outside)
        XCTAssertFalse(app.textFields["task-editor-title"].exists)
        XCTAssertTrue(add.isHittable)
        add.tap()
        XCTAssertTrue(app.textFields["task-editor-title"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5))
    }

    @MainActor
    func testCompactOverlayEdgeDrag() throws {
        let app = isolatedApplication(arguments: ["-assignmentApp.uiTestCompactNavigation", "-assignmentApp.uiTestSidebarExpanded"])
        app.launch()
        XCTAssertTrue(app.buttons["compact-sidebar-open"].waitForExistence(timeout: 10))
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.3))
            .press(forDuration: 0, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.3)))
        let close = app.buttons["compact-sidebar-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3))
            .press(forDuration: 0, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.3)))
        XCTAssertTrue(waitForDisappearance(of: close, timeout: 5))
    }

    @MainActor
    func testVisualAccessibilityVariantsAndDisplayModes() throws {
        let app = isolatedApplication(arguments: ["-assignmentApp.uiTestSidebarExpanded", "visual-reduce-transparency", "visual-reduce-motion", "visual-increase-contrast", "visual-dark"])
        app.launch()
        XCTAssertTrue(app.buttons["add-task"].waitForExistence(timeout: 10))
        capture("visual-dark-opaque-contrast", app: app)
        app.buttons["sidebar-settings"].tap()
        let professional = app.segmentedControls.buttons["Professional"]
        XCTAssertTrue(professional.waitForExistence(timeout: 5))
        professional.tap()
        app.buttons["sidebar-all"].tap()
        app.buttons["add-task"].tap()
        XCTAssertTrue(app.textFields["task-editor-title"].waitForExistence(timeout: 5))
        capture("visual-professional-editor", app: app)
        app.buttons["Cancel"].tap()
        app.buttons["sidebar-settings"].tap()
        app.segmentedControls.buttons["Simple"].tap()
        app.buttons["sidebar-all"].tap()
        app.buttons["add-task"].tap()
        XCTAssertTrue(app.textFields["task-editor-title"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.segmentedControls.buttons["Done"].exists)
        capture("visual-simple-editor", app: app)
        app.buttons["Cancel"].tap()
    }

    /// Real smoke test of the Phase 3A pages: a meeting and an exam are created
    /// through the actual UI, a Review Task is requested twice, and every step
    /// is captured. It runs against a throwaway database.
    @MainActor
    func testLearningScenesSmoke() throws {
        let app = isolatedApplication(arguments: ["-assignmentApp.uiTestSidebarExpanded"])
        // Hosted macOS runners report GMT. Exercise the default device-zone
        // path under that exact environment instead of hiding the CI failure
        // by selecting a different zone in the editor.
        app.launchEnvironment["TZ"] = "GMT"
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
        assertEditorSaved("New Meeting", app: app)

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
        assertEditorSaved("New Exam", app: app)

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

    // MARK: - Apple Foundation pages

    /// Walks the four surfaces added by the Foundation RC — the first-run
    /// walkthrough, the task calendar, the backup centre and the about page —
    /// and switches the interface language through the real picker.
    ///
    /// The skip path is forced and asserted here; the separate walkthrough
    /// test advances all pages and checks completion survives a restart.
    @MainActor
    func testFoundationPagesSmoke() throws {
        let app = isolatedApplication(
            arguments: [
                "-assignmentApp.uiTestSidebarExpanded",
                "-assignmentApp.uiTestResetOnboarding",
                "-assignmentApp.uiTestShowOnboarding",
            ],
            skipOnboarding: false
        )
        app.launch()

        let skip = app.buttons["onboarding-skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 10), "First-run walkthrough offers Skip")
        skip.tap()
        XCTAssertTrue(waitForDisappearance(of: skip, timeout: 5), "Walkthrough can be skipped")

        // MARK: Task calendar

        let calendar = app.buttons["sidebar-calendar"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 5), "Calendar sidebar item")
        XCTAssertEqual(calendar.label, "Calendar")
        calendar.tap()

        XCTAssertTrue(app.buttons["calendar-today"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["calendar-previous-month"].exists)
        XCTAssertTrue(app.buttons["calendar-next-month"].exists)
        XCTAssertTrue(app.switches["calendar-show-completed"].exists)
        capture("ipad-calendar-month", app: app)

        // The month grid must survive a jump in both directions and come back.
        app.buttons["calendar-next-month"].tap()
        app.buttons["calendar-next-month"].tap()
        XCTAssertTrue(app.buttons["calendar-today"].exists)
        capture("ipad-calendar-two-months-ahead", app: app)
        app.buttons["calendar-previous-month"].tap()
        app.buttons["calendar-previous-month"].tap()
        app.buttons["calendar-today"].tap()
        XCTAssertTrue(app.buttons["calendar-today"].waitForExistence(timeout: 5))

        // MARK: Backup centre

        let settings = app.buttons["sidebar-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()

        let dataAndBackup = app.buttons["settings-data-and-backup"]
        XCTAssertTrue(dataAndBackup.waitForExistence(timeout: 5), "Data & Backup entry")
        dataAndBackup.tap()

        let createBackup = app.buttons["backup-create"]
        XCTAssertTrue(createBackup.waitForExistence(timeout: 5), "Backup centre")
        XCTAssertTrue(app.buttons["backup-import"].exists)
        XCTAssertTrue(app.staticTexts["backup-empty"].waitForExistence(timeout: 5))
        capture("ipad-backup-empty", app: app)

        createBackup.tap()
        // `BackupPackageRow` collapses its contents into a single accessibility
        // element (`children: .ignore`), so it surfaces as `otherElements`.
        let backupItem = app.otherElements["backup-item"]
        XCTAssertTrue(backupItem.waitForExistence(timeout: 20), "Backup is created and listed")
        capture("ipad-backup-created", app: app)

        // MARK: About

        // Pop the detail navigation back to the Settings root through its
        // real back button. Re-selecting Settings from the sidebar keeps the
        // current selection and therefore does not reset the stack.
        let backupBar = app.navigationBars["Data & Backup"]
        XCTAssertTrue(backupBar.waitForExistence(timeout: 5))
        backupBar.buttons.element(boundBy: 0).tap()

        let about = app.buttons["settings-about"]
        XCTAssertTrue(about.waitForExistence(timeout: 5), "About entry")
        about.tap()

        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 5), "About page is pushed")

        // The About list is longer than the detail pane, and SwiftUI `List`
        // only materialises the rows it is about to draw. An identifier below
        // the fold is therefore absent from the accessibility snapshot rather
        // than broken: it has to be scrolled to, the way a person reaches it.
        let copyDiagnostics = app.buttons["about-copy-diagnostics"]
        XCTAssertTrue(reveal(copyDiagnostics, in: app), "Diagnostics action on the About page")
        copyDiagnostics.tap()
        XCTAssertTrue(
            reveal(app.staticTexts["about-copy-confirmation"], in: app),
            "Diagnostics copy confirms without exposing task content"
        )
        capture("ipad-about-diagnostics", app: app)

        // `changelog` is a SwiftUI `ScrollView`, so it is exposed as
        // `scrollViews` rather than `otherElements`.
        let changelog = app.scrollViews["about-changelog"]
        XCTAssertTrue(reveal(changelog, in: app), "Changelog section on the About page")
        capture("ipad-about", app: app)

        // MARK: Language switch

        // Same reset as above; tapping Settings alone keeps the About stack.
        let settingsBar = app.navigationBars["About"]
        XCTAssertTrue(settingsBar.waitForExistence(timeout: 5))
        settingsBar.buttons.element(boundBy: 0).tap()

        let settingsForLanguage = app.buttons["sidebar-settings"]
        XCTAssertTrue(settingsForLanguage.waitForExistence(timeout: 5))
        settingsForLanguage.tap()

        let languagePicker = app.buttons["settings-language-picker"]
        XCTAssertTrue(languagePicker.waitForExistence(timeout: 5), "Language picker")
        languagePicker.tap()

        let chinese = app.buttons["简体中文"]
        XCTAssertTrue(chinese.waitForExistence(timeout: 5), "Simplified Chinese option")
        chinese.tap()

        // The interface follows the selection without a restart.
        let chineseSettings = app.navigationBars["设置"]
        if !chineseSettings.waitForExistence(timeout: 5) {
            attachHierarchy(of: app, named: "after-language-switch")
        }
        XCTAssertTrue(chineseSettings.exists, "Settings title is localized")
        capture("ipad-settings-chinese", app: app)

        let chineseCalendar = app.buttons["sidebar-calendar"]
        XCTAssertTrue(chineseCalendar.waitForExistence(timeout: 5))
        XCTAssertEqual(chineseCalendar.label, "日历")

        XCTAssertTrue(app.buttons["sidebar-settings"].waitForExistence(timeout: 5))
        app.buttons["sidebar-settings"].tap()
        XCTAssertTrue(app.buttons["settings-about"].waitForExistence(timeout: 5))
        app.buttons["settings-about"].tap()
        let chineseChangelog = app.scrollViews["about-changelog"]
        XCTAssertTrue(reveal(chineseChangelog, in: app), "Changelog is bundled in the Chinese build too")
        capture("ipad-about-chinese", app: app)
    }

    /// The walkthrough is a first-launch overlay, so every other suite skips
    /// it and none of them can say whether it works. This one forces it open,
    /// walks each page, finishes it, and then relaunches to prove the
    /// completion actually persisted — the three things a person would check
    /// by hand.
    @MainActor
    func testOnboardingWalkthroughSmoke() throws {
        let app = isolatedApplication(
            arguments: [
                "-assignmentApp.uiTestResetOnboarding",
                "-assignmentApp.uiTestShowOnboarding",
            ],
            skipOnboarding: false
        )
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))

        // The walkthrough is detected by its controls, not by a container
        // identifier: SwiftUI copies a container's identifier onto everything
        // it hosts, so the view deliberately names its controls instead.
        let advance = app.buttons["onboarding-advance"]
        if !advance.waitForExistence(timeout: 10) {
            attachHierarchy(of: app, named: "onboarding-missing")
        }
        XCTAssertTrue(advance.exists, "Walkthrough opens")

        // A first launch offers "Skip"; a revisit from Settings offers
        // "Close". Resetting above is what makes this the former, and the
        // distinction is worth asserting because skipping is what writes the
        // completion flag for a brand-new user.
        XCTAssertTrue(
            app.buttons["onboarding-skip"].exists,
            "A first launch offers Skip rather than Close"
        )
        capture("ipad-onboarding-skip-offered", app: app)

        // A TabView page is a ScrollView, which the accessibility snapshot
        // exposes as `scrollViews` rather than `otherElements`.
        let pages = ["welcome", "privacy", "modes", "notifications"]
        for (index, page) in pages.enumerated() {
            let identifier = "onboarding-page-\(page)"
            let pageView = app.scrollViews[identifier]
            if !pageView.waitForExistence(timeout: 5) {
                attachHierarchy(of: app, named: "onboarding-\(page)")
            }
            XCTAssertTrue(pageView.exists, "Walkthrough shows the \(page) page")
            capture("ipad-onboarding-\(page)", app: app)

            XCTAssertTrue(advance.exists, "Walkthrough has a next action on \(page)")

            if page == "notifications" {
                // The only page carrying an action of its own. Permission is
                // offered here and never demanded: refusing it must not block
                // finishing the walkthrough, which is why this test does not
                // tap it.
                XCTAssertTrue(
                    app.buttons["onboarding-allow-notifications"].exists,
                    "Notification permission is offered on its own page"
                )
                XCTAssertEqual(advance.label, "Get Started", "The last page ends the walkthrough")
            } else {
                XCTAssertEqual(advance.label, "Next", "\(page) is not the last page")
            }

            // Back is offered from the second page onwards — the welcome page
            // has nothing to step back to, and asserting it there would be
            // asserting a bug rather than a behaviour.
            if index > 0 {
                XCTAssertTrue(
                    app.buttons["onboarding-back"].exists,
                    "\(page) can be stepped back from"
                )
            }

            if index < pages.count - 1 {
                advance.tap()
            }
        }

        // Finishing is what writes the completion flag, so the page order
        // above and the relaunch below are the same assertion seen from both
        // ends.
        advance.tap()
        XCTAssertTrue(
            waitForDisappearance(of: advance, timeout: 5),
            "Finishing the walkthrough dismisses it"
        )
        XCTAssertTrue(
            app.buttons["sidebar-settings"].waitForExistence(timeout: 10),
            "Finishing the walkthrough lands on the app itself"
        )

        // MARK: Completion survives a restart

        app.terminate()
        // Both flags go: leaving the reset behind would clear the completion
        // this test just finished proving, and leaving the force behind would
        // show the walkthrough regardless of what was persisted.
        app.launchArguments.removeAll {
            $0 == "-assignmentApp.uiTestShowOnboarding"
                || $0 == "-assignmentApp.uiTestResetOnboarding"
        }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertFalse(
            advance.waitForExistence(timeout: 5),
            "The walkthrough does not reappear once it has been completed"
        )

        // MARK: The same walkthrough in Simplified Chinese

        app.terminate()
        app.launchArguments.removeAll { $0.hasPrefix("-assignmentApp.uiTestLanguage:") }
        app.launchArguments += [
            "-assignmentApp.uiTestResetOnboarding",
            "-assignmentApp.uiTestShowOnboarding",
            "-assignmentApp.uiTestLanguage:simplifiedChinese"
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))

        XCTAssertTrue(advance.waitForExistence(timeout: 10), "Walkthrough reopens from the test flag")
        XCTAssertTrue(
            app.staticTexts["作业管理，不添噪音"].waitForExistence(timeout: 5),
            "The welcome page is localized"
        )
        XCTAssertEqual(
            app.buttons["onboarding-advance"].label,
            "下一步",
            "The next action is localized"
        )
        capture("ipad-onboarding-chinese", app: app)
    }

    /// A failed save keeps its editor and raises a validation alert. Wait for
    /// either outcome, then report the actual alert rather than timing out on
    /// a list row that cannot exist yet.
    @MainActor
    private func assertEditorSaved(_ title: String, app: XCUIApplication) {
        let editor = app.navigationBars[title]
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !editor.exists || app.alerts.firstMatch.exists
            },
            object: app
        )
        let result = XCTWaiter.wait(for: [settled], timeout: 10)
        if result != .completed || editor.exists || app.alerts.firstMatch.exists {
            attachHierarchy(of: app, named: "save-failed-\(title)")
        }
        XCTAssertEqual(result, .completed, "Saving the editor reaches a visible outcome")
        XCTAssertFalse(app.alerts.firstMatch.exists, "Saving must not raise a validation alert")
        XCTAssertFalse(editor.exists, "A successful save dismisses the editor")
    }

    /// Each test gets a UUID namespace inside the app's own temporary directory.
    /// The runner never deletes an app database while its process is alive.
    /// CI removes the whole disposable simulator only after shutting it down.
    @MainActor
    private func isolatedApplication(
        arguments: [String] = [],
        skipOnboarding: Bool = true
    ) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        let token = UUID().uuidString
        app.launchArguments = [
            "-assignmentApp.testDatabaseToken", token,
            Self.englishLanguageArgument,
        ] + arguments
        if skipOnboarding { app.launchArguments.append(Self.skipOnboardingArgument) }
        print("ASSIGNMENT_UI_DATABASE_TOKEN \(token)")
        addTeardownBlock { @MainActor in
            app.terminate()
            XCTAssertTrue(
                app.wait(for: .notRunning, timeout: 10),
                "The application must exit before disposable simulator cleanup"
            )
            XCUIDevice.shared.orientation = .portrait
        }
        return app
    }

    /// Polls instead of using `wait(for:)`, because `continueAfterFailure` is
    /// off and an expired expectation would abort the whole walkthrough.
    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return !element.exists
    }

    /// Scrolls the frontmost scrollable surface downwards until `element`
    /// enters the accessibility snapshot.
    ///
    /// SwiftUI `List` only materialises the rows it is about to draw, so
    /// content below the fold is legitimately absent from the snapshot rather
    /// than broken. `waitForExistence` cannot reach it — it has to be scrolled
    /// to, exactly as a person would. The hierarchy is attached on failure so
    /// a missing identifier can be told apart from a missing view.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 8) -> Bool {
        for _ in 0..<attempts {
            if element.exists { return true }
            if app.tables.firstMatch.exists {
                app.tables.firstMatch.swipeUp()
            } else if app.collectionViews.firstMatch.exists {
                app.collectionViews.firstMatch.swipeUp()
            } else if app.scrollViews.firstMatch.exists {
                app.scrollViews.firstMatch.swipeUp()
            } else {
                attachHierarchy(of: app, named: "no-scrollable-surface")
                return false
            }
        }
        if !element.exists { attachHierarchy(of: app, named: "reveal-failed") }
        return element.exists
    }

    private func attachHierarchy(of app: XCUIApplication, named name: String) {
        print("ASSIGNMENT_HIERARCHY_BEGIN \(name)")
        print(app.debugDescription)
        print("ASSIGNMENT_HIERARCHY_END \(name)")
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
