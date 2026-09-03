import Foundation
import Testing
@testable import AssignmentApp2


/// The two catalogs, read straight out of the built bundle.
///
/// Reading the files rather than going through `L10n` means a key that is
/// missing from one language is caught even if no code path looks it up yet.
///
/// The build compiles `.strings` sources into property lists, so what ships is
/// a plist, not the UTF-8 source. Parsing the shipped form is also the more
/// honest test: it proves the file the app actually loads is complete.
private struct StringsCatalog {
    let entries: [String: String]

    init(locale: String) throws {
        guard let url = Bundle.main.url(
            forResource: "Localizable",
            withExtension: "strings",
            subdirectory: nil,
            localization: locale
        ) else {
            throw CatalogError.missingCatalog(locale)
        }
        entries = try Self.parse(url)
    }

    static func parse(_ url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        guard let dictionary = object as? [String: Any] else {
            throw CatalogError.parseFailure
        }
        var entries: [String: String] = [:]
        for (key, value) in dictionary {
            // `plutil` keeps a value that was written as a non-string as-is;
            // every entry in these catalogs is text.
            guard let text = value as? String else {
                throw CatalogError.parseFailure
            }
            entries[key] = text
        }
        return entries
    }
}

private enum CatalogError: Error {
    case missingCatalog(String)
    case parseFailure
}


@Suite("Localization catalogs")
struct LocalizationCatalogTests {

    @Test("Both language catalogs are bundled with the app")
    func bothCatalogsAreBundled() throws {
        let english = try StringsCatalog(locale: "en")
        let chinese = try StringsCatalog(locale: "zh-Hans")

        #expect(!english.entries.isEmpty)
        #expect(!chinese.entries.isEmpty)
    }

    @Test("English and Simplified Chinese hold exactly the same keys")
    func keyParity() throws {
        let english = try StringsCatalog(locale: "en")
        let chinese = try StringsCatalog(locale: "zh-Hans")

        let onlyEnglish = Set(english.entries.keys).subtracting(chinese.entries.keys)
        let onlyChinese = Set(chinese.entries.keys).subtracting(english.entries.keys)

        #expect(onlyEnglish.isEmpty, "Missing from zh-Hans: \(onlyEnglish.sorted())")
        #expect(onlyChinese.isEmpty, "Missing from en: \(onlyChinese.sorted())")
    }

    @Test("No catalog entry is empty in either language")
    func noEmptyValues() throws {
        for locale in ["en", "zh-Hans"] {
            let catalog = try StringsCatalog(locale: locale)
            let empty = catalog.entries.filter { $0.value.isEmpty }.map(\.key)
            #expect(empty.isEmpty, "Empty values in \(locale): \(empty.sorted())")
        }
    }

    /// A translation that drops or reorders a `%@` would crash or swap two
    /// values at runtime, and no compiler warning would catch it.
    @Test("Every translation keeps the same format specifiers as its key")
    func formatSpecifierParity() throws {
        let pattern = try NSRegularExpression(
            pattern: "%(?:\\d+\\$)?(?:\\.\\d+)?[@dfslL]+|%\\d+\\$"
        )
        let english = try StringsCatalog(locale: "en")
        let chinese = try StringsCatalog(locale: "zh-Hans")

        func specifiers(in text: String) -> [String] {
            let range = NSRange(text.startIndex..., in: text)
            return pattern.matches(in: text, range: range).compactMap { match in
                Range(match.range, in: text).map { String(text[$0]) }
            }
        }

        var mismatches: [String] = []
        for (key, value) in chinese.entries {
            let expected = specifiers(in: key)
            let actual = specifiers(in: value)
            if expected.sorted() != actual.sorted() {
                mismatches.append("\(key) → \(value)")
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")

        // Sanity check: the catalog really does contain positional formats, so
        // the test above is not vacuously passing against an empty set.
        #expect(english.entries.keys.contains { specifiers(in: $0).count > 1 })
    }

    /// Brand names and a handful of technical terms are the only entries that
    /// are legitimately identical in both languages.
    @Test("Chinese differs from English everywhere except the intentional exceptions")
    func chineseIsActuallyTranslated() throws {
        let allowedIdentical: Set<String> = [
            "Assignment App",
            "English",
            "Schema",
        ]
        let chinese = try StringsCatalog(locale: "zh-Hans")

        // Only prose is checked; a one-word key that is identical by chance
        // (a proper noun, an abbreviation) is not a translation gap.
        let identical = chinese.entries
            .filter { $0.value == $0.key }
            .filter { $0.key.split(separator: " ").count >= 2 }
            .map(\.key)

        #expect(
            Set(identical).subtracting(allowedIdentical).isEmpty,
            "Untranslated: \(Set(identical).subtracting(allowedIdentical).sorted())"
        )
    }
}


@Suite("Programmatic localization")
struct LocalizationLookupTests {

    @Test("Every model-layer catalog key resolves in both languages")
    func catalogKeysResolve() {
        for key in LocalizationCatalogKey.allCases {
            let english = L10n.tr(key.rawValue, language: .english)
            let chinese = L10n.tr(key.rawValue, language: .simplifiedChinese)
            #expect(!english.isEmpty, "Empty English for \(key.rawValue)")
            #expect(!chinese.isEmpty, "Empty Chinese for \(key.rawValue)")
            #expect(english == key.rawValue, "English must stay the source key: \(key.rawValue)")
        }
    }

    @Test("Statuses and priorities display localized text but persist stable values")
    func databaseValuesAreNeverLocalized() {
        // The display title is localized…
        for status in AssignmentStatus.allCases {
            #expect(!status.localizedTitle.isEmpty)
        }
        for priority in AssignmentPriority.allCases {
            #expect(!priority.localizedTitle.isEmpty)
        }

        // …but what reaches SQLite is the platform-neutral storage value, in
        // every language the app can be switched to.
        let storageValues = Set(AssignmentStatus.allCases.map(\.storageValue))
        #expect(storageValues == ["not_started", "in_progress", "completed"])
        #expect(Set(AssignmentPriority.allCases.map(\.rawValue)) == ["low", "medium", "high"])

        // No display string may be a storage token: if a localized title ever
        // leaked into a status column, a round-trip through the database would
        // silently change the meaning of the row.
        for language in [AppLanguage.english, AppLanguage.simplifiedChinese] {
            for status in AssignmentStatus.allCases {
                let text = L10n.tr(status.title, language: language)
                #expect(!storageValues.contains(text))
                #expect(text != status.storageValue)
            }
            for priority in AssignmentPriority.allCases {
                let text = L10n.tr(priority.title, language: language)
                #expect(!storageValues.contains(text))
            }
        }
    }

    @Test("Enum display titles resolve through the selected language")
    func enumTitlesFollowLanguage() {
        let chineseTitle = L10n.tr(AssignmentStatus.inProgress.title, language: .simplifiedChinese)
        let englishTitle = L10n.tr(AssignmentStatus.inProgress.title, language: .english)
        #expect(englishTitle == "In Progress")
        #expect(chineseTitle != englishTitle)
    }

    @Test("A failing store reverts the language instead of stranding the UI")
    @MainActor
    func failedPersistenceReverts() {
        let store = FailingLanguageStore()
        let preference = LanguagePreference(store: store)

        #expect(preference.language == .system)
        preference.select(.simplifiedChinese)

        // The published value rolled back because the write did not stick.
        #expect(preference.language == .system)
        #expect(preference.errorMessage != nil)
        #expect(preference.pendingRestartNotice == nil)
    }

    @Test("A successful change persists and raises a restart notice")
    @MainActor
    func successfulChangePersists() {
        let store = InMemoryLanguageStore()
        let preference = LanguagePreference(store: store)

        preference.select(.simplifiedChinese)

        #expect(preference.language == .simplifiedChinese)
        #expect(store.storedString(forKey: LanguagePreferenceKeys.language) == "simplifiedChinese")
        #expect(store.array(forKey: LanguagePreferenceKeys.appleLanguages) == ["zh-Hans"])
        #expect(preference.errorMessage == nil)
        #expect(preference.pendingRestartNotice != nil)

        // Choosing "Follow System" clears the AppleLanguages override so the
        // device language is really followed again.
        preference.select(.system)
        #expect(preference.language == .system)
        #expect(store.array(forKey: LanguagePreferenceKeys.appleLanguages) == nil)
        #expect(preference.pendingRestartNotice == nil)
    }
}


// MARK: - Test doubles

private final class InMemoryLanguageStore: LanguagePreferenceStoring {
    private var strings: [String: String] = [:]
    private var arrays: [String: [String]] = [:]

    func storedString(forKey key: String) -> String? { strings[key] }

    func setStoredString(_ value: String?, forKey key: String) throws {
        if let value { strings[key] = value } else { strings.removeValue(forKey: key) }
    }

    func setStoredStringArray(_ value: [String]?, forKey key: String) throws {
        if let value { arrays[key] = value } else { arrays.removeValue(forKey: key) }
    }

    func array(forKey key: String) -> [String]? { arrays[key] }
}

private final class FailingLanguageStore: LanguagePreferenceStoring {
    func storedString(forKey key: String) -> String? { nil }
    func setStoredString(_ value: String?, forKey key: String) throws {
        throw LanguagePreferenceError.writeFailed(key)
    }
    func setStoredStringArray(_ value: [String]?, forKey key: String) throws {
        throw LanguagePreferenceError.writeFailed(key)
    }
}
