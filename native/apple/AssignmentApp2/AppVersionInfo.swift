import Foundation
#if canImport(UIKit)
import UIKit
#endif


/// Where the About page gets every fact it shows.
///
/// Nothing here is a hand-written constant: the version, build number, and
/// embedded Git revision come from the built bundle, and the schema version
/// and data location come from the live repository.
struct AppVersionInfo: Equatable {
    let marketingVersion: String
    let buildNumber: String
    let gitSHA: String
    let schemaVersion: Int32
    let databaseLocation: String
    let notificationAuthorization: AssignmentNotificationAuthorization
    let language: AppLanguage
    let platform: String
    let osVersion: String
    let dataSummary: AboutDataSummary

    /// Normalizes the embedded revision on the way in.
    ///
    /// The build setting that carries the SHA is a shell substitution, so it
    /// arrives with whatever whitespace the command left behind. Trimming here
    /// rather than at the one read site keeps `isTestBuild` honest too: a
    /// whitespace-only value means no revision was embedded, not a test build
    /// whose revision happens to be blank.
    init(
        marketingVersion: String,
        buildNumber: String,
        gitSHA: String,
        schemaVersion: Int32,
        databaseLocation: String,
        notificationAuthorization: AssignmentNotificationAuthorization,
        language: AppLanguage,
        platform: String,
        osVersion: String,
        dataSummary: AboutDataSummary
    ) {
        self.marketingVersion = marketingVersion
        self.buildNumber = buildNumber
        self.gitSHA = gitSHA.trimmingCharacters(in: .whitespacesAndNewlines)
        self.schemaVersion = schemaVersion
        self.databaseLocation = databaseLocation
        self.notificationAuthorization = notificationAuthorization
        self.language = language
        self.platform = platform
        self.osVersion = osVersion
        self.dataSummary = dataSummary
    }

    /// The value read straight from the bundle, used by tests to prove the
    /// About page is not reporting a hard-coded string.
    static var current: AppVersionInfo {
        AppVersionInfo(
            marketingVersion: bundleMarketingVersion,
            buildNumber: bundleBuildNumber,
            gitSHA: bundleGitSHA,
            schemaVersion: 0,
            databaseLocation: "",
            notificationAuthorization: .unavailable,
            language: .system,
            platform: Self.currentPlatform,
            osVersion: Self.currentOSVersion,
            dataSummary: .empty
        )
    }

    static var bundleMarketingVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "Unknown"
    }

    static var bundleBuildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "Unknown"
    }

    /// Empty on release builds. The packaging script injects it for test
    /// builds only, so a shipped binary carries no source-control detail.
    static var bundleGitSHA: String {
        ((Bundle.main.infoDictionary?["AssignmentGitSHA"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isTestBuild: Bool { !gitSHA.isEmpty }

    var versionDisplay: String {
        "\(marketingVersion) (\(buildNumber))"
    }

    static var currentPlatform: String {
        #if targetEnvironment(macCatalyst)
        return "Mac Catalyst"
        #elseif os(iOS)
        return "iPadOS"
        #else
        return "Apple"
        #endif
    }

    static var currentOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}


struct AboutDataSummary: Equatable {
    let taskCount: Int
    let courseCount: Int
    let meetingCount: Int
    let examCount: Int
    let attachmentCount: Int
    let databaseIdentity: String

    static var empty: AboutDataSummary {
        AboutDataSummary(
            taskCount: 0,
            courseCount: 0,
            meetingCount: 0,
            examCount: 0,
            attachmentCount: 0,
            databaseIdentity: ""
        )
    }
}


/// The text the About page can put on the clipboard.
///
/// It deliberately contains no task titles, no descriptions, no attachment
/// names or contents, and no file paths. Counts and versions only.
enum DiagnosticsSummary {
    static func make(info: AppVersionInfo) -> String {
        let lines = [
            "Assignment App \(info.marketingVersion) (\(info.buildNumber))",
            "platform=\(info.platform)",
            "os=\(info.osVersion)",
            "git_sha=" + (info.isTestBuild ? info.gitSHA : "not-embedded"),
            "schema_version=\(info.schemaVersion)",
            "language=\(info.language.diagnosticsName)",
            "notifications=\(info.notificationAuthorization.rawValue)",
            "tasks=\(info.dataSummary.taskCount)",
            "courses=\(info.dataSummary.courseCount)",
            "meetings=\(info.dataSummary.meetingCount)",
            "exams=\(info.dataSummary.examCount)",
            "attachments=\(info.dataSummary.attachmentCount)",
            "database_identity=" + (info.dataSummary.databaseIdentity.isEmpty
                ? "unavailable"
                : info.dataSummary.databaseIdentity),
        ]
        return lines.joined(separator: "\n")
    }

    /// The only line prefixes `make` is allowed to emit. Anything else — a
    /// task title, an attachment name, or a home directory path — fails the
    /// check.
    private static let allowedPrefixes = [
        "Assignment App ",
        "platform=",
        "os=",
        "git_sha=",
        "schema_version=",
        "language=",
        "notifications=",
        "tasks=",
        "courses=",
        "meetings=",
        "exams=",
        "attachments=",
        "database_identity=",
    ]

    /// Guards the promise above. Used by the About view and covered by a test.
    ///
    /// The check is structural rather than a blacklist: every line must carry
    /// one of the known safe keys, and the database location — the one personal
    /// detail `AppVersionInfo` holds — must not appear anywhere.
    static func containsOnlySafeFields(_ text: String, info: AppVersionInfo) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.hasPrefix("Assignment App ") == true else { return false }

        for line in lines.dropFirst() {
            guard allowedPrefixes.contains(where: { line.hasPrefix($0) }) else {
                return false
            }
        }

        let location = info.databaseLocation.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !location.isEmpty && text.contains(location) { return false }

        return true
    }
}


/// The bundled release notes.
enum BundledChangelog {
    static var text: String {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return L10n.tr("The release notes are not bundled with this build.")
        }
        return text
    }

    static var isAvailable: Bool {
        Bundle.main.url(forResource: "CHANGELOG", withExtension: "md") != nil
    }
}


/// Puts the diagnostics summary on the system pasteboard.
///
/// `UIPasteboard` is the right call on both platforms: Mac Catalyst runs the
/// full UIKit stack, and `NSPasteboard` is AppKit-only and marked unavailable
/// there even though a Catalyst binary can still import AppKit.
enum DiagnosticsClipboard {
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}
