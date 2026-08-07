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
        case .settings:
            return ""
        }
    }
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


struct AssignmentSidebar: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Binding var selection: AssignmentView
    @Binding var columnVisibility: NavigationSplitViewVisibility

    var body: some View {
        List {
            Section("Tasks") {
                ForEach(AssignmentView.allCases.filter { $0 != .settings }) { view in
                    sidebarRow(for: view)
                }
            }

            Section {
                sidebarRow(for: .settings)
            }
        }
        .navigationTitle("Assignments")
        .listStyle(.sidebar)
    }

    private func sidebarRow(for view: AssignmentView) -> some View {
        Button {
            selection = view
            if horizontalSizeClass == .compact {
                columnVisibility = .detailOnly
            }
        } label: {
            Label(view.title, systemImage: view.systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selection == view ? Color.accentColor : Color.primary)
        .listRowBackground(
            selection == view ? Color.accentColor.opacity(0.12) : Color.clear
        )
        .accessibilityAddTraits(selection == view ? .isSelected : [])
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
                        Text(value.title).tag(Optional(value))
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
                        Text(value.title).tag(Optional(value))
                    }
                }
                .pickerStyle(.menu)

                Picker("Sort", selection: $sortOrder) {
                    ForEach(AssignmentSortOrder.allCases) { value in
                        Text(value.title).tag(value)
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

                        HStack(spacing: 8) {
                            Label(projection.courseName, systemImage: "book.closed")
                                .lineLimit(2)

                            Spacer(minLength: 6)

                            Label(projection.status.title, systemImage: projection.status.systemImage)
                                .foregroundStyle(projection.status.tint)
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
                    .lineLimit(1)
                }
            }

            Button(action: onToggleCompletion) {
                Image(systemName: assignment.status == .done
                      ? "arrow.uturn.backward.circle"
                      : "checkmark.circle")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help(assignment.status == .done ? "Restore task" : "Mark task done")
            .accessibilityLabel(assignment.status == .done ? "Restore task" : "Mark task done")
        }
        .padding(.vertical, 5)
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
            Label("\(priority.title) priority", systemImage: "flag.fill")
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
    let onReload: () -> Void

    var body: some View {
        Form {
            Section {
                Picker("Task details", selection: $displayMode) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
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
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Local Data") {
                LabeledContent("Database") {
                    Text(databaseLocation)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }

                Button("Reload Tasks", systemImage: "arrow.clockwise", action: onReload)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
