import Combine
import Foundation
import SwiftUI


// MARK: - Language model

/// The languages the Apple client ships with.
///
/// `system` follows the device language. The other cases are explicit
/// in-app choices that are persisted and restored on every launch.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english
    case simplifiedChinese

    var id: String { rawValue }

    /// `nil` means "use whatever the system prefers".
    var localeIdentifier: String? {
        switch self {
        case .system:
            return nil
        case .english:
            return "en"
        case .simplifiedChinese:
            return "zh-Hans"
        }
    }

    var locale: Locale? { localeIdentifier.map { Locale(identifier: $0) } }

    /// Effective locale. `system` resolves to the current system locale.
    var resolvedLocale: Locale {
        switch self {
        case .system:
            return .current
        case .english, .simplifiedChinese:
            return locale ?? .current
        }
    }

    /// Shown in the language picker. Each choice is named in its own language
    /// so a reader who cannot read the current interface can still find it.
    var displayName: String {
        switch self {
        case .system:
            return "Follow System"
        case .english:
            return "English"
        case .simplifiedChinese:
            return "简体中文"
        }
    }

    /// A short identifier used by the diagnostics summary.
    var diagnosticsName: String {
        switch self {
        case .system:
            return "system"
        case .english:
            return "en"
        case .simplifiedChinese:
            return "zh-Hans"
        }
    }
}


// MARK: - Localizable enum titles

/// Any type that exposes a stable English display title can be shown in the
/// selected language through `localizedTitle`.
///
/// The stored `title` stays English on purpose: it is the localization key,
/// never a value written to the database. Statuses and priorities are still
/// persisted as `todo`, `in_progress`, and `done` no matter what language is
/// on screen.
protocol LocalizableTitled {
    var title: String { get }
}

extension LocalizableTitled {
    /// The display title resolved through the app language.
    var localizedTitle: String { L10n.tr(title) }
}

extension AssignmentView: LocalizableTitled {}
extension AssignmentStatus: LocalizableTitled {}
extension AssignmentPriority: LocalizableTitled {}
extension AssignmentSortOrder: LocalizableTitled {}
extension DisplayMode: LocalizableTitled {}
extension AppTheme: LocalizableTitled {}
extension AssignmentNotificationAuthorization: LocalizableTitled {}
extension ExamStatus: LocalizableTitled {}
extension ExamSection.Kind: LocalizableTitled {}
extension TimetableScope: LocalizableTitled {}
extension LearningTimeZoneChoice: LocalizableTitled {}
extension ReminderScheduleKind: LocalizableTitled {}
extension RelativeReminderPreset: LocalizableTitled {}
extension ProjectStatus: LocalizableTitled {}
extension OrgTab: LocalizableTitled {}


// MARK: - Preference storage

/// Persistence seam behind `LanguagePreference`. The default implementation
/// uses `UserDefaults`; tests inject an in-memory or failing store.
protocol LanguagePreferenceStoring: AnyObject {
    func storedString(forKey key: String) -> String?
    func setStoredString(_ value: String?, forKey key: String) throws
    /// `AppleLanguages` is a string array, so it needs its own write path and
    /// its own read-back check.
    func setStoredStringArray(_ value: [String]?, forKey key: String) throws
}


/// `UserDefaults`-backed store. A write is followed by a read-back so a
/// value that did not survive is reported as a failure instead of being
/// assumed to have been persisted.
final class UserDefaultsLanguageStore: LanguagePreferenceStoring {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func storedString(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    func setStoredString(_ value: String?, forKey key: String) throws {
        defaults.set(value, forKey: key)
        guard defaults.synchronize() else {
            throw LanguagePreferenceError.writeFailed(key)
        }
        if let value, defaults.string(forKey: key) != value {
            throw LanguagePreferenceError.verificationFailed(key)
        }
    }

    func setStoredStringArray(_ value: [String]?, forKey key: String) throws {
        defaults.set(value, forKey: key)
        guard defaults.synchronize() else {
            throw LanguagePreferenceError.writeFailed(key)
        }
        if let value, defaults.stringArray(forKey: key) != value {
            throw LanguagePreferenceError.verificationFailed(key)
        }
    }
}


enum LanguagePreferenceError: LocalizedError, Equatable {
    case writeFailed(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let key):
            return L10n.tr("The language setting for “%@” could not be saved.", key)
        case .verificationFailed(let key):
            return L10n.tr("The language setting for “%@” did not persist.", key)
        }
    }
}


enum LanguagePreferenceKeys {
    static let language = "assignmentApp.language"
    static let appleLanguages = "AppleLanguages"
}


/// Owns the app-language choice.
///
/// Changing `language` refreshes every SwiftUI view immediately through
/// `.environment(\.locale, …)`. `AppleLanguages` is written at the same time
/// so strings that come from outside SwiftUI — system dialogs, notification
/// content, and open/save panels — follow the same choice after a restart.
@MainActor
final class LanguagePreference: ObservableObject {
    @Published private(set) var language: AppLanguage
    @Published var errorMessage: String?
    /// Raised whenever a change needs a restart to take effect everywhere.
    @Published private(set) var pendingRestartNotice: String?

    static let shared = LanguagePreference()

    private let store: LanguagePreferenceStoring

    init(store: LanguagePreferenceStoring = UserDefaultsLanguageStore()) {
        self.store = store
        if let raw = store.storedString(forKey: LanguagePreferenceKeys.language),
           let restored = AppLanguage(rawValue: raw) {
            language = restored
        } else {
            language = .system
        }
    }

    /// Applies `candidate`.
    ///
    /// The published value is updated first so the interface refreshes
    /// immediately. If persistence fails the previous value is restored and an
    /// error is published; the app is never left showing one language while
    /// another is stored.
    func select(_ candidate: AppLanguage) {
        let previous = language
        guard candidate != previous else { return }

        language = candidate
        errorMessage = nil

        do {
            try store.setStoredString(
                candidate.rawValue,
                forKey: LanguagePreferenceKeys.language
            )
            // `nil` clears the override so "Follow System" really does follow
            // the system again.
            try store.setStoredStringArray(
                candidate.localeIdentifier.map { [$0] },
                forKey: LanguagePreferenceKeys.appleLanguages
            )
            pendingRestartNotice = candidate == .system
                ? nil
                : L10n.tr(
                    "The interface has switched. Restart the app so system dialogs and notification text use the same language.",
                    language: candidate
                )
        } catch {
            language = previous
            errorMessage = error.localizedDescription
            pendingRestartNotice = nil
        }
    }

    func clearError() {
        errorMessage = nil
    }
}


// MARK: - Lookup

/// Resolves localized strings outside the SwiftUI environment.
///
/// SwiftUI views use `LocalizedStringKey`, which reads the environment locale
/// and needs no help. Model-layer text — validation messages, notification
/// bodies, diagnostics — has no environment, so it resolves the language's
/// `.lproj` bundle explicitly.
enum L10n {
    /// The language currently chosen in the app, read straight from
    /// `UserDefaults` so it is correct on any thread.
    static var currentLanguage: AppLanguage {
        guard let raw = UserDefaults.standard.string(
            forKey: LanguagePreferenceKeys.language
        ), let language = AppLanguage(rawValue: raw) else {
            return .system
        }
        return language
    }

    /// The one place a string is actually resolved.
    ///
    /// It exists under its own name because a variadic overload cannot call
    /// `tr(_:language:)` safely: Swift resolves `tr(key, language: x)` to the
    /// variadic form with an empty argument list rather than to the plain
    /// lookup, which recursed until the stack ran out.
    private static func lookup(_ key: String, language: AppLanguage?) -> String {
        let language = language ?? currentLanguage
        let bundle = Self.bundle(for: language)
        let value = bundle.localizedString(forKey: key, value: nil, table: nil)
        // `localizedString(forKey:value:table:)` returns the key verbatim when
        // no translation exists. That is the intended English fallback.
        return value.isEmpty ? key : value
    }

    /// Resolves a key without interpreting it as a format string.
    ///
    /// The formatting overloads below require at least one argument, which is
    /// what keeps the two families from overlapping. When the variadic form
    /// accepted an empty list it silently won calls like `tr(key, language: x)`,
    /// and every key holding `%@` came back rendered as `(null)`.
    static func tr(_ key: String, language: AppLanguage? = nil) -> String {
        lookup(key, language: language)
    }

    /// Resolves a key as an `NSString` format string in the current language.
    static func tr(_ formatKey: String, _ first: CVarArg, _ rest: CVarArg...) -> String {
        withVaList([first] + rest) { arguments in
            NSString(format: lookup(formatKey, language: nil), arguments: arguments) as String
        }
    }

    /// Resolves a key as an `NSString` format string in an explicit language.
    ///
    /// This is the entry point for text that is assembled outside a SwiftUI
    /// view, such as notification bodies, where no `LocalizedStringKey`
    /// environment is available.
    static func tr(
        _ formatKey: String,
        language: AppLanguage,
        _ first: CVarArg,
        _ rest: CVarArg...
    ) -> String {
        withVaList([first] + rest) { arguments in
            NSString(
                format: lookup(formatKey, language: language),
                arguments: arguments
            ) as String
        }
    }

    /// The `.lproj` bundle for one language, or `.main` for `system`.
    static func bundle(for language: AppLanguage) -> Bundle {
        guard let identifier = language.localeIdentifier,
              let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }

    /// `true` when the string resolved to something other than the key.
    static func isTranslated(_ key: String, language: AppLanguage) -> Bool {
        tr(key, language: language) != key
    }
}


// MARK: - Catalog keys used outside SwiftUI

/// Every key that is looked up programmatically rather than through
/// `LocalizedStringKey`. `LocalizationTests` asserts that each one resolves in
/// both English and Simplified Chinese, which keeps the model layer from
/// drifting into an untranslated state that no compiler warning would catch.
enum LocalizationCatalogKey: String, CaseIterable, Identifiable {
    // Task and course validation
    case missingTitle = "Enter a task title."
    case missingCourse = "Enter a course."
    case titleTooLong = "The title must be 255 characters or fewer."
    case courseTooLong = "The course must be 120 characters or fewer."
    case linkTooLong = "Links and file paths must be 1,000 characters or fewer."
    case sourceNameTooLong = "The source name must be 255 characters or fewer."
    case sourceTypeTooLong = "The source type must be 80 characters or fewer."
    case unsupportedStatus = "Unsupported task status: %@."
    case unsupportedPriority = "Unsupported task priority: %@."
    case invalidLocalWallTime = "Invalid local date and time: %@."
    case offsetBearingDueDate = "Task due dates must not contain a timezone or UTC offset: %@."

    // Repository
    case openFailed = "Could not open the task database: %@"
    case prepareFailed = "Could not prepare a database operation: %@"
    case executeFailed = "Could not complete a database operation: %@"
    case taskNotFound = "Task %lld no longer exists."
    case corruptData = "The task database contains invalid data: %@"
    case readOnlyAfterMigrationFailure =
        "Writes are disabled because the database migration did not complete."

    // Attachments
    case attachmentPathInvalid = "The attachment storage path is invalid."
    case attachmentRootUnsafe = "The attachment storage directory is not safe to use."
    case attachmentPayloadMissing = "The file for “%@” is missing from local storage."
    case attachmentNotRegularFile = "The attachment payload is not a regular local file."
    case attachmentIdentityMismatch =
        "The attachment database identity does not match its payload."

    // Notifications
    case notificationDuePrefix = "Due"
    case notificationReminderTitle = "Reminder"

    // View model
    case remindersNotReconciled = "Reminders could not be reconciled: %@"
    case relativeRemindersNotRecalculated =
        "Due-relative reminders could not be recalculated: %@"

    var id: String { rawValue }
}
