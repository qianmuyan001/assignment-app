import SwiftUI


extension AssignmentView {
    var systemImage: String {
        switch self {
        case .all:
            return "tray.full"
        case .today:
            return "sun.max"
        case .week:
            return "calendar"
        case .overdue:
            return "exclamationmark.triangle"
        case .completed:
            return "checkmark.circle"
        case .timetable:
            return "calendar.day.timeline.leading"
        case .exams:
            return "graduationcap"
        case .calendar:
            return "calendar.badge.clock"
        case .settings:
            return "gearshape"
        }
    }

    var emptyTitle: String {
        switch self {
        case .all:
            return "No tasks yet"
        case .today:
            return "Nothing due today"
        case .week:
            return "Nothing due this week"
        case .overdue:
            return "No overdue tasks"
        case .completed:
            return "No completed tasks"
        case .timetable:
            return "No classes scheduled"
        case .exams:
            return "No exams yet"
        case .calendar:
            return "No tasks on this day"
        case .settings:
            return ""
        }
    }

    var emptyDescription: String {
        switch self {
        case .all:
            return "Add a task to start planning your coursework."
        case .today:
            return "Tasks due today will appear here."
        case .week:
            return "Tasks due from Monday through Sunday will appear here."
        case .overdue:
            return "You are caught up. Unfinished tasks past their due time will appear here."
        case .completed:
            return "Tasks you finish will appear here."
        case .timetable:
            return "Add a weekly meeting to build your timetable."
        case .exams:
            return "Add an exam to track its date, place, and scope."
        case .calendar:
            return "Pick a day to see the tasks due on it, or add one right from the calendar."
        case .settings:
            return ""
        }
    }

    /// Empty-state text resolved through the app language. Both are read as
    /// plain `String` in `ContentView`, so they go through `L10n` rather than
    /// relying on a `LocalizedStringKey` literal.
    var localizedEmptyTitle: String { L10n.tr(emptyTitle) }

    var localizedEmptyDescription: String { L10n.tr(emptyDescription) }
}


extension AssignmentStatus {
    var systemImage: String {
        switch self {
        case .todo:
            return "circle"
        case .inProgress:
            return "circle.lefthalf.filled"
        case .done:
            return "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .todo:
            return .secondary
        case .inProgress:
            return .blue
        case .done:
            return .green
        }
    }
}


extension AssignmentPriority {
    var tint: Color {
        switch self {
        case .low:
            return .blue
        case .medium:
            return .orange
        case .high:
            return .red
        }
    }
}


extension AppTheme {
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}


struct AssignmentFilterBar: View {
    @Binding var status: AssignmentStatus?
    @Binding var course: String?
    @Binding var priority: AssignmentPriority?
    @Binding var sortOrder: AssignmentSortOrder
    let courses: [String]
    let onClear: () -> Void

    private var hasActiveFilters: Bool {
        status != nil || course != nil || priority != nil
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                Picker("Status", selection: $status) {
                    Text("All Statuses").tag(Optional<AssignmentStatus>.none)
                    ForEach(AssignmentStatus.allCases) { value in
                        Text(value.localizedTitle).tag(Optional(value))
                    }
                }
                .pickerStyle(.menu)

                Picker("Course", selection: $course) {
                    Text("All Courses").tag(Optional<String>.none)
                    ForEach(courses, id: \.self) { value in
                        Text(value).tag(Optional(value))
                    }
                }
                .pickerStyle(.menu)

                Picker("Priority", selection: $priority) {
                    Text("All Priorities").tag(Optional<AssignmentPriority>.none)
                    ForEach(AssignmentPriority.allCases) { value in
                        Text(value.localizedTitle).tag(Optional(value))
                    }
                }
                .pickerStyle(.menu)

                Picker("Sort", selection: $sortOrder) {
                    ForEach(AssignmentSortOrder.allCases) { value in
                        Text(value.localizedTitle).tag(value)
                    }
                }
                .pickerStyle(.menu)

                if hasActiveFilters {
                    Button("Clear Filters", systemImage: "line.3.horizontal.decrease.circle") {
                        onClear()
                    }
                    .buttonStyle(.borderless)
                }
            }
            .controlSize(.regular)
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .background(.bar)
    }
}


struct AssignmentRow: View {
    let assignment: Assignment
    let displayMode: DisplayMode
    let onEdit: () -> Void
    let onToggleCompletion: () -> Void

    private var projection: AssignmentProjection {
        TaskRules.project(assignment, for: displayMode)
    }

    private var validLink: URL? {
        guard displayMode == .professional,
              let value = projection.link?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let priority = projection.priority {
                Capsule()
                    .fill(priority.tint)
                    .frame(width: 4)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Button(action: onEdit) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(projection.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                courseLabel

                                Spacer(minLength: 6)

                                statusLabel
                            }
                            .fixedSize(horizontal: true, vertical: false)

                            VStack(alignment: .leading, spacing: 6) {
                                courseLabel
                                statusLabel
                            }
                        }
                        .font(.subheadline)

                        Label {
                            Text(dueText)
                        } icon: {
                            Image(systemName: projection.dueDate == nil ? "calendar.badge.minus" : "calendar")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                        if displayMode == .professional {
                            professionalDetails
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let validLink {
                    Link(destination: validLink) {
                        Label("Open source link", systemImage: "arrow.up.right.square")
                            .font(.subheadline)
                    }
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
            }

            Button(action: onToggleCompletion) {
                Image(systemName: assignment.status == .done
                      ? "arrow.uturn.backward.circle"
                      : "checkmark.circle")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .help(assignment.status == .done ? "Restore task" : "Mark task done")
            .accessibilityLabel(assignment.status == .done ? "Restore task" : "Mark task done")
        }
        .padding(.vertical, 5)
    }

    private var courseLabel: some View {
        Label(projection.courseName, systemImage: "book.closed")
            .fixedSize(horizontal: false, vertical: true)
    }

    private var statusLabel: some View {
        Label(projection.status.localizedTitle, systemImage: projection.status.systemImage)
            .foregroundStyle(projection.status.tint)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var professionalDetails: some View {
        if let description = projection.assignmentDescription,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let priority = projection.priority {
            Label(L10n.tr("%@ priority", priority.localizedTitle), systemImage: "flag.fill")
                .font(.caption)
                .foregroundStyle(priority.tint)
        }
    }

    private var dueText: String {
        guard let dueDate = projection.dueDate else {
            return "No due date"
        }
        return dueDate.formatted(date: .abbreviated, time: .shortened)
    }
}


struct AssignmentSettingsView: View {
    @Binding var displayMode: DisplayMode
    @Binding var theme: AppTheme
    let databaseLocation: String
    let notificationAuthorization: AssignmentNotificationAuthorization
    let onRequestNotifications: () -> Void
    let onRefreshNotifications: () -> Void
    let onReload: () -> Void
    let onReopenOnboarding: () -> Void
    /// Read at push time so the About page reports the counts the app holds
    /// right then, not the ones that were true when Settings opened.
    let makeAboutInfo: () -> AppVersionInfo
    let onCopyDiagnostics: (String) -> Void

    @EnvironmentObject private var languagePreference: LanguagePreference

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: languageSelection) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .accessibilityIdentifier("settings-language-picker")

                Text("The interface switches right away. System dialogs and notification text follow after the app is restarted.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Language")
            }

            Section {
                Picker("Task details", selection: $displayMode) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.localizedTitle).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(displayMode == .simple
                     ? "Simple mode keeps task rows and the editor focused on title, course, due time, and status. Hidden details remain saved."
                     : "Professional mode also shows descriptions, priorities, and source links.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Display Mode")
            }

            Section("Appearance") {
                Picker("Theme", selection: $theme) {
                    ForEach(AppTheme.allCases) { value in
                        Text(value.localizedTitle).tag(value)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Reminders") {
                LabeledContent("System notifications") {
                    Text(notificationAuthorization.localizedTitle)
                        .foregroundStyle(notificationAuthorization.canSchedule ? .green : .secondary)
                }

                if notificationAuthorization == .notDetermined {
                    Button(
                        "Allow Notifications",
                        systemImage: "bell.badge",
                        action: onRequestNotifications
                    )
                } else {
                    Button(
                        "Refresh Permission Status",
                        systemImage: "arrow.clockwise",
                        action: onRefreshNotifications
                    )
                }

                if notificationAuthorization == .denied {
                    Text("Notifications are denied in System Settings. Tasks and reminder records continue to work normally.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Local Data") {
                LabeledContent("Database") {
                    Text(databaseLocation)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }

                NavigationLink {
                    BackupCenterView(
                        databaseLocation: databaseLocation,
                        onReload: onReload
                    )
                } label: {
                    Label("Data & Backup", systemImage: "externaldrive.badge.timemachine")
                }
                .accessibilityIdentifier("settings-data-and-backup")

                NavigationLink {
                    AboutView(
                        info: makeAboutInfo(),
                        onCopyDiagnostics: onCopyDiagnostics
                    )
                } label: {
                    Label("About This App", systemImage: "info.circle")
                }
                .accessibilityIdentifier("settings-about")

                Button("Reload Tasks", systemImage: "arrow.clockwise", action: onReload)
            }

            Section("First Steps") {
                Button("Show the Introduction Again", action: onReopenOnboarding)
                    .accessibilityIdentifier("settings-reopen-onboarding")
            }

            if let notice = languagePreference.pendingRestartNotice {
                Section {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings-language-restart-notice")
                }
            }

            if let error = languagePreference.errorMessage {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("settings-language-error")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.tr("Settings"))
        .task {
            onRefreshNotifications()
        }
    }

    /// Writing through `select` keeps the stored value and the displayed one in
    /// lockstep: if persistence fails, the preference publishes an error and
    /// reverts instead of leaving the two out of sync.
    private var languageSelection: Binding<AppLanguage> {
        Binding(
            get: { languagePreference.language },
            set: { languagePreference.select($0) }
        )
    }
}
