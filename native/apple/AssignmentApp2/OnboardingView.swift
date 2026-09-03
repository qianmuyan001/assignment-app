import SwiftUI


/// Persists whether the first-launch walkthrough has been completed.
///
/// Deliberately separate from the database: the walkthrough must be skippable
/// before any data layer exists, and re-opening it from Settings must not
/// touch the task store.
enum OnboardingState {
    static let completedKey = "assignmentApp.onboardingCompleted"
    static let versionKey = "assignmentApp.onboardingVersion"

    /// Bump when a page changes enough to be worth showing again.
    static let currentVersion = 1
}


/// The first-launch walkthrough.
///
/// Four short pages, no account, no network. It can be skipped at any point
/// and re-opened from Settings, so it never stands between a user and their
/// tasks.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss

    let isReopenedFromSettings: Bool
    let onRequestNotifications: () -> Void
    let onFinish: () -> Void

    @State private var page: OnboardingPage = .welcome

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer(minLength: 0)

                if !isReopenedFromSettings {
                    Button(L10n.tr("Skip")) {
                        finish()
                    }
                    .accessibilityIdentifier("onboarding-skip")
                } else {
                    Button(L10n.tr("Close")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("onboarding-close")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            TabView(selection: $page) {
                ForEach(OnboardingPage.allCases) { item in
                    pageView(item)
                        .tag(item)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Divider()

            HStack(spacing: 12) {
                if page != .welcome {
                    Button(L10n.tr("Back")) {
                        step(-1)
                    }
                    .accessibilityIdentifier("onboarding-back")
                }

                Spacer(minLength: 0)

                Button(page == OnboardingPage.allCases.last
                       ? L10n.tr("Get Started")
                       : L10n.tr("Next")) {
                    if page == OnboardingPage.allCases.last {
                        finish()
                    } else {
                        step(1)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding-advance")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(minWidth: 520, minHeight: 560)
        // Deliberately no identifier on the container. SwiftUI copies a
        // container's `accessibilityIdentifier` onto every element it hosts —
        // with one set here, the skip, back and advance buttons, the page
        // indicator and the paging collection view all reported the same
        // identifier and none of their own, which left the walkthrough's
        // controls individually unaddressable for VoiceOver and UI tests.
        // Naming the controls instead of the container keeps each one distinct.
    }

    private func pageView(_ item: OnboardingPage) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 54))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)

                Text(item.localizedTitle)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)

                Text(item.localizedBody)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if item == .notifications {
                    Button(L10n.tr("Allow Notifications")) {
                        onRequestNotifications()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("onboarding-allow-notifications")
                }
            }
            .frame(maxWidth: 460)
            .padding(32)
        }
        .accessibilityIdentifier("onboarding-page-\(item.rawValue)")
    }

    private func step(_ delta: Int) {
        guard let index = OnboardingPage.allCases.firstIndex(of: page) else { return }
        let next = index + delta
        guard OnboardingPage.allCases.indices.contains(next) else { return }
        page = OnboardingPage.allCases[next]
    }

    private func finish() {
        onFinish()
        dismiss()
    }
}


enum OnboardingPage: String, CaseIterable, Identifiable {
    case welcome
    case privacy
    case modes
    case notifications

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .welcome: return "checklist"
        case .privacy: return "lock.shield"
        case .modes: return "slider.horizontal.3"
        case .notifications: return "bell.badge"
        }
    }

    var title: String {
        switch self {
        case .welcome: return "Assignments, without the noise"
        case .privacy: return "Your data stays on this device"
        case .modes: return "Two ways to work"
        case .notifications: return "Reminders, only if you want them"
        }
    }

    var localizedTitle: String { L10n.tr(title) }

    var body: String {
        switch self {
        case .welcome:
            return "Assignment App keeps coursework in one place: tasks, a weekly timetable, and exams. Everything is local, so it works with no account and no connection."
        case .privacy:
            return "Tasks, attachments, and backups are stored in this app’s own container on this device. Nothing is uploaded, and there is no sign-in. You decide when to export a backup, and where it goes."
        case .modes:
            return "Simple mode shows only title, course, due time, and status. Professional mode adds descriptions, priorities, source links, projects, and tags. Switching modes never discards anything — hidden details stay saved."
        case .notifications:
            return "Reminders are optional. If you allow notifications, the app can fire one at a fixed time or a set lead time before a due date. Denying permission keeps every task and reminder record intact; you just will not see a banner."
        }
    }

    var localizedBody: String { L10n.tr(body) }
}
