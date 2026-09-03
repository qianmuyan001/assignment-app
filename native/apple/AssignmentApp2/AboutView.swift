import SwiftUI


/// The About & Version page.
///
/// Every fact comes from `AppVersionInfo`, which reads the built bundle and
/// the live repository. Nothing on this page is a hand-written constant, so it
/// cannot drift from the binary it ships inside.
struct AboutView: View {
    let info: AppVersionInfo
    let onCopyDiagnostics: (String) -> Void

    @State private var copyConfirmation: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("Assignment App"))
                        .font(.title2.bold())

                    Text(info.versionDisplay)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            L10n.tr("Version %@", info.versionDisplay)
                        )
                }
                .padding(.vertical, 4)
            }

            Section(L10n.tr("Build")) {
                row(
                    L10n.tr("Version"),
                    value: info.marketingVersion,
                    id: "about-marketing-version"
                )
                row(
                    L10n.tr("Build Number"),
                    value: info.buildNumber,
                    id: "about-build-number"
                )

                // A shipped binary embeds no revision: the packaging script
                // injects it for test builds only.
                if info.isTestBuild {
                    row(
                        L10n.tr("Git Revision"),
                        value: info.gitSHA,
                        id: "about-git-sha"
                    )
                }

                row(
                    L10n.tr("Database Schema"),
                    value: "\(info.schemaVersion)",
                    id: "about-schema-version"
                )
                row(
                    L10n.tr("Platform"),
                    value: info.platform,
                    id: "about-platform"
                )
                row(
                    L10n.tr("System Version"),
                    value: info.osVersion,
                    id: "about-os-version"
                )
                row(
                    L10n.tr("Language"),
                    value: info.language.displayName,
                    id: "about-language"
                )
            }

            Section(L10n.tr("Data")) {
                row(
                    L10n.tr("Tasks"),
                    value: "\(info.dataSummary.taskCount)"
                )
                row(
                    L10n.tr("Courses"),
                    value: "\(info.dataSummary.courseCount)"
                )
                row(
                    L10n.tr("Meetings"),
                    value: "\(info.dataSummary.meetingCount)"
                )
                row(
                    L10n.tr("Exams"),
                    value: "\(info.dataSummary.examCount)"
                )
                row(
                    L10n.tr("Attachments"),
                    value: "\(info.dataSummary.attachmentCount)"
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("Database Location"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text(info.databaseLocation.isEmpty
                         ? L10n.tr("Unavailable")
                         : info.databaseLocation)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            Section(L10n.tr("Notifications")) {
                row(
                    L10n.tr("Permission"),
                    value: info.notificationAuthorization.localizedTitle
                )

                if info.notificationAuthorization == .denied {
                    Text(L10n.tr("Notifications are denied in System Settings. Tasks and reminder records continue to work normally."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(L10n.tr("Privacy")) {
                Text(L10n.tr("Assignment App is local-first. Tasks, attachments, and backups stay inside this app’s container on this device. There is no account, no sync, and no analytics."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.tr("Diagnostics")) {
                Button(L10n.tr("Copy Diagnostics Summary")) {
                    let text = DiagnosticsSummary.make(info: info)
                    onCopyDiagnostics(text)
                    copyConfirmation =
                        DiagnosticsSummary.containsOnlySafeFields(text, info: info)
                        ? L10n.tr("Copied. No task text or file paths are included.")
                        : L10n.tr("The summary could not be verified, so nothing was copied.")
                }
                .accessibilityIdentifier("about-copy-diagnostics")

                if let copyConfirmation {
                    Text(copyConfirmation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("about-copy-confirmation")
                }

                Text(L10n.tr("The summary contains counts and versions only. It never includes task titles, descriptions, attachment contents, or personal file paths."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if BundledChangelog.isAvailable {
                Section(L10n.tr("Changelog")) {
                    changelog
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.tr("About"))
    }

    @ViewBuilder
    private var changelog: some View {
        ScrollView {
            Text(BundledChangelog.text)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        }
        .frame(minHeight: 180, maxHeight: 320)
        .accessibilityIdentifier("about-changelog")
    }

    private func row(_ label: String, value: String, id: String? = nil) -> some View {
        HStack {
            Text(label)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
        .accessibilityIdentifier(id ?? "about-row")
    }
}
