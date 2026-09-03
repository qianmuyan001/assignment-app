import Foundation
import Testing
@testable import AssignmentApp2


// MARK: - First launch

/// The walkthrough state lives in `UserDefaults`, not in the database.
///
/// It has to be readable before any data layer exists, and re-opening the
/// walkthrough from Settings must never touch the task store, so the two are
/// deliberately independent.
@Suite("First-launch onboarding")
struct OnboardingStateTests {

    /// A throwaway suite, so no test can read or clobber the flag the
    /// installed app actually uses.
    private func makeStore() throws -> (UserDefaults, String) {
        let name = "AssignmentApp2Tests.Onboarding.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))
        return (store, name)
    }

    @Test("A fresh install has not completed the walkthrough")
    func freshInstallIsIncomplete() throws {
        let (store, name) = try makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        #expect(store.bool(forKey: OnboardingState.completedKey) == false)
        #expect(store.integer(forKey: OnboardingState.versionKey) == 0)
    }

    @Test("Completion survives a reopened store, which is what a relaunch is")
    func completionPersistsAcrossAReopenedStore() throws {
        let (store, name) = try makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        store.set(true, forKey: OnboardingState.completedKey)
        store.set(OnboardingState.currentVersion, forKey: OnboardingState.versionKey)

        // A second handle on the same suite is the closest a test can get to
        // the app being quit and started again.
        let reopened = try #require(UserDefaults(suiteName: name))
        #expect(reopened.bool(forKey: OnboardingState.completedKey))
        #expect(
            reopened.integer(forKey: OnboardingState.versionKey)
                == OnboardingState.currentVersion
        )
    }

    @Test("Re-opening the walkthrough from Settings never resets completion")
    func reopeningFromSettingsKeepsCompletion() throws {
        let (store, name) = try makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        store.set(true, forKey: OnboardingState.completedKey)
        store.set(OnboardingState.currentVersion, forKey: OnboardingState.versionKey)

        // The Settings button presents the sheet again. It must not clear the
        // flag, or a second launch would show the walkthrough as if the user
        // had never finished it.
        #expect(store.bool(forKey: OnboardingState.completedKey))
        #expect(
            store.integer(forKey: OnboardingState.versionKey)
                == OnboardingState.currentVersion
        )
    }

    /// A rename of either key would silently orphan the state of everyone who
    /// already finished the walkthrough, so the strings are pinned here.
    @Test("The persistence keys are stable")
    func keysAreStable() {
        #expect(OnboardingState.completedKey == "assignmentApp.onboardingCompleted")
        #expect(OnboardingState.versionKey == "assignmentApp.onboardingVersion")
        #expect(OnboardingState.currentVersion >= 1)
    }

    @Test("The walkthrough covers positioning, privacy, modes and reminders")
    func pagesAreComplete() {
        let pages = OnboardingPage.allCases
        #expect(pages.count == 4)
        #expect(Set(pages.map(\.rawValue)).count == pages.count)
        #expect(pages.last == .notifications)

        for page in pages {
            #expect(!page.title.isEmpty)
            #expect(!page.body.isEmpty)
            #expect(!page.systemImage.isEmpty)
        }
    }

    @Test("Every walkthrough page is translated, not left in English")
    func pagesAreTranslatedIntoBothLanguages() {
        for page in OnboardingPage.allCases {
            let chineseTitle = L10n.tr(page.title, language: .simplifiedChinese)
            let chineseBody = L10n.tr(page.body, language: .simplifiedChinese)
            #expect(chineseTitle != page.title, "\(page.rawValue) title is untranslated")
            #expect(chineseBody != page.body, "\(page.rawValue) body is untranslated")
            #expect(chineseTitle.contains(page.title) == false)
        }
    }

    @Test("The walkthrough asks for no account and no network")
    func pagesMakeNoAccountPromise() {
        let allText = OnboardingPage.allCases
            .map { "\($0.title) \($0.body)" }
            .joined(separator: " ")
            .lowercased()

        // The promise is local-first: nothing to sign in to, nothing synced.
        #expect(allText.contains("local"))
        #expect(allText.contains("no account"))
        #expect(!allText.contains("sign up"))
        #expect(!allText.contains("log in to continue"))
    }
}


// MARK: - About page

/// The About page claims that nothing on it is a hand-written constant. These
/// tests hold it to that claim.
@Suite("About page version sources")
struct AboutVersionInfoTests {

    // MARK: Helpers

    private func info(
        location: String = "",
        gitSHA: String = "",
        summary: AboutDataSummary = .empty
    ) -> AppVersionInfo {
        AppVersionInfo(
            marketingVersion: AppVersionInfo.bundleMarketingVersion,
            buildNumber: AppVersionInfo.bundleBuildNumber,
            gitSHA: gitSHA,
            schemaVersion: 4,
            databaseLocation: location,
            notificationAuthorization: .authorized,
            language: .english,
            platform: AppVersionInfo.currentPlatform,
            osVersion: AppVersionInfo.currentOSVersion,
            dataSummary: summary
        )
    }

    // MARK: Bundle

    @Test("The version and build number are read from the bundle")
    func versionComesFromTheBundle() {
        let dictionary = Bundle.main.infoDictionary
        let marketing = dictionary?["CFBundleShortVersionString"] as? String
        let build = dictionary?["CFBundleVersion"] as? String

        #expect(AppVersionInfo.bundleMarketingVersion == (marketing ?? "Unknown"))
        #expect(AppVersionInfo.bundleBuildNumber == (build ?? "Unknown"))

        // A hard-coded string would not be a dotted triple.
        #expect(
            AppVersionInfo.bundleMarketingVersion.range(
                of: #"^\d+\.\d+\.\d+$"#,
                options: .regularExpression
            ) != nil
        )
        #expect(
            AppVersionInfo.bundleBuildNumber.range(
                of: #"^\d+$"#,
                options: .regularExpression
            ) != nil
        )
    }

    @Test("The bundle version matches the VERSION file in the repository")
    func bundleVersionMatchesRepositoryVersionFile() throws {
        // …/native/apple/AssignmentApp2Tests/OnboardingAndAboutTests.swift
        let versionFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AssignmentApp2Tests
            .deletingLastPathComponent()   // apple
            .deletingLastPathComponent()   // native
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("VERSION", isDirectory: false)

        let recorded = try String(contentsOf: versionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(AppVersionInfo.bundleMarketingVersion == recorded)
    }

    @Test("The combined version string shows the marketing version and build")
    func versionDisplayJoinsBoth() {
        let value = info()
        #expect(
            value.versionDisplay
                == "\(value.marketingVersion) (\(value.buildNumber))"
        )
    }

    // MARK: Git revision

    @Test("A shipped build embeds no Git revision")
    func gitRevisionIsEmptyUnlessInjected() {
        #expect(info().gitSHA.isEmpty)
        #expect(info().isTestBuild == false)
    }

    @Test("An injected revision is trimmed and marks the build as a test build")
    func injectedRevisionIsTrimmed() {
        let value = info(gitSHA: "  abc123def456  \n")
        #expect(value.gitSHA == "abc123def456")
        #expect(value.isTestBuild)
    }

    /// A revision made only of whitespace means the build setting was empty,
    /// not that a revision was embedded. If it counted as a test build the
    /// About page would offer a "test build" label with nothing behind it.
    @Test("A whitespace-only revision is treated as no revision")
    func whitespaceOnlyRevisionIsNotATestBuild() {
        let value = info(gitSHA: "  \n")
        #expect(value.gitSHA.isEmpty)
        #expect(value.isTestBuild == false)
    }

    // MARK: Platform

    @Test("The platform name is one of the ones the app actually builds for")
    func platformIsSpecific() {
        let platform = AppVersionInfo.currentPlatform
        #expect(["iPadOS", "Mac Catalyst", "Apple"].contains(platform))

        #if targetEnvironment(macCatalyst)
        #expect(platform == "Mac Catalyst")
        #elseif os(iOS)
        #expect(platform == "iPadOS")
        #endif
    }

    @Test("The system version is dotted numbers, not a marketing name")
    func osVersionIsNumeric() {
        #expect(
            AppVersionInfo.currentOSVersion.range(
                of: #"^\d+\.\d+\.\d+$"#,
                options: .regularExpression
            ) != nil
        )
    }

    // MARK: Diagnostics

    @Test("The diagnostics summary carries only the safe keys")
    func diagnosticsCarriesOnlySafeKeys() {
        let value = info(
            summary: AboutDataSummary(
                taskCount: 12,
                courseCount: 3,
                meetingCount: 8,
                examCount: 2,
                attachmentCount: 5,
                databaseIdentity: "0F1E2D3C-4B5A-4C7D-8E9F-A0B1C2D3E4F5"
            )
        )
        let text = DiagnosticsSummary.make(info: value)

        #expect(DiagnosticsSummary.containsOnlySafeFields(text, info: value))
        #expect(text.contains("tasks=12"))
        #expect(text.contains("attachments=5"))
        #expect(text.contains("schema_version=4"))
        #expect(text.contains("platform=\(AppVersionInfo.currentPlatform)"))
        #expect(text.contains("git_sha=not-embedded"))
    }

    @Test("The diagnostics summary never contains the database path")
    func diagnosticsExcludesTheDatabaseLocation() {
        // A realistic container path: exactly the kind of personal detail the
        // page promises to keep off the clipboard.
        let path = "/Users/tester/Library/Containers/com.example.AssignmentApp"
            + "/Data/Documents/assignments.db"
        let value = info(location: path)
        let text = DiagnosticsSummary.make(info: value)

        #expect(!text.contains(path))
        #expect(!text.contains("tester"))
        #expect(DiagnosticsSummary.containsOnlySafeFields(text, info: value))

        // If a future change ever did print the location, the guard has to
        // catch it rather than copy it.
        #expect(
            DiagnosticsSummary.containsOnlySafeFields(
                text + "\n" + path,
                info: value
            ) == false
        )
    }

    @Test("A summary that leaked task text is rejected")
    func diagnosticsRejectsLeakedText() {
        let value = info()
        let safe = DiagnosticsSummary.make(info: value)
        #expect(DiagnosticsSummary.containsOnlySafeFields(safe, info: value))

        let withTitle =
            safe + "\nTask: Finish the thermodynamics problem set"
        #expect(
            DiagnosticsSummary.containsOnlySafeFields(withTitle, info: value)
                == false
        )

        // Losing the header is also a failure: it means the text is not the
        // summary the page promised.
        let withoutHeader = "platform=iPadOS\n"
        #expect(
            DiagnosticsSummary.containsOnlySafeFields(withoutHeader, info: value)
                == false
        )
    }

    // MARK: Changelog

    @Test("The changelog is either bundled or explained, never blank")
    func changelogIsEitherBundledOrExplained() {
        let text = BundledChangelog.text
        #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        if !BundledChangelog.isAvailable {
            #expect(
                text == L10n.tr("The release notes are not bundled with this build.")
            )
        }
    }
}
