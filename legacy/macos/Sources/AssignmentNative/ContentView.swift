import SwiftUI


struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 250)
        } detail: {
            detail
        }
        .background(.ultraThinMaterial)
        .alert(
            "Assignment App",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var sidebar: some View {
        List(selection: $model.selection) {
            Section {
                Label("Assignments", systemImage: "checklist")
                    .font(.headline)
                    .padding(.vertical, 6)
            }

            Section("Workspace") {
                ForEach(SidebarSelection.allCases.filter { $0 != .settings }) { item in
                    Label(item.title, systemImage: item.systemImage)
                        .tag(item)
                }
            }

            Section {
                Label(
                    model.aiAvailable ? "Local AI ready" : "Local AI offline",
                    systemImage: model.aiAvailable
                        ? "bolt.horizontal.circle.fill"
                        : "bolt.slash.circle"
                )
                .foregroundStyle(model.aiAvailable ? .green : .secondary)

                Label(SidebarSelection.settings.title, systemImage: "gearshape")
                    .tag(SidebarSelection.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 7) {
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
                Text("Local database")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection ?? .all {
        case .sources:
            SourceConnectorView()
        case .settings:
            SettingsView()
        default:
            AssignmentDashboardView()
        }
    }
}


struct AssignmentDashboardView: View {
    @EnvironmentObject private var model: AppModel
    @State private var assignmentPendingDeletion: Assignment?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.visibleAssignments.isEmpty {
                ContentUnavailableView(
                    "Nothing here",
                    systemImage: "checkmark.circle",
                    description: Text("Connect a source or choose another view.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.visibleAssignments) { assignment in
                            AssignmentRow(
                                assignment: assignment,
                                onComplete: { model.markCompleted(assignment) },
                                onDelete: { assignmentPendingDeletion = assignment }
                            )
                        }
                    }
                    .padding(22)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            "Delete this assignment?",
            isPresented: Binding(
                get: { assignmentPendingDeletion != nil },
                set: { if !$0 { assignmentPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let assignmentPendingDeletion {
                    model.delete(assignmentPendingDeletion)
                }
                assignmentPendingDeletion = nil
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text((model.selection ?? .all).title)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("\(model.visibleAssignments.count) assignments")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.selection = .sources
                } label: {
                    Label("Connect Source", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            TextField("Search assignments, courses, or sources", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
        }
        .padding(22)
    }
}


struct AssignmentRow: View {
    let assignment: Assignment
    let onComplete: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 3)
                .fill(accent)
                .frame(width: 5)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(assignment.courseName.uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(accent)
                    Spacer()
                    statusBadge
                }

                Text(assignment.title)
                    .font(.headline)

                if let dueDate = assignment.dueDate {
                    Text(dueDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline)
                        .foregroundStyle(dueColor)
                } else {
                    Text("No due date")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let description = assignment.assignmentDescription,
                   !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack {
                    Label(
                        assignment.sourceName ?? "Manual",
                        systemImage: "arrow.up.right"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    if assignment.status != .completed {
                        Button("Done", action: onComplete)
                            .buttonStyle(.bordered)
                    }
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.quaternary, lineWidth: 1)
        }
    }

    private var statusBadge: some View {
        Text(assignment.status.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(accent)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(accent.opacity(0.12), in: Capsule())
    }

    private var accent: Color {
        if assignment.status == .completed { return .green }
        if let dueDate = assignment.dueDate, dueDate < Date() { return .red }
        if assignment.status == .inProgress { return .blue }
        return .purple
    }

    private var dueColor: Color {
        guard assignment.status != .completed else { return .secondary }
        if let dueDate = assignment.dueDate, dueDate < Date() { return .red }
        return .secondary
    }
}


struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Local AI") {
                TextField("Endpoint", text: $model.aiEndpoint)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Label(
                        model.aiAvailable ? "Ready" : "Offline",
                        systemImage: model.aiAvailable ? "checkmark.circle.fill" : "xmark.circle"
                    )
                    .foregroundStyle(model.aiAvailable ? .green : .secondary)
                    Spacer()
                    Button("Check Connection") {
                        Task { await model.applyAIEndpoint() }
                    }
                }
                Text("Only localhost and loopback endpoints are accepted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Database") {
                Text(model.databaseLocation)
                    .textSelection(.enabled)
                    .font(.caption.monospaced())
            }

            Section("Privacy") {
                Label("Passwords stay in macOS Keychain", systemImage: "key.fill")
                Label("Course content stays on this Mac", systemImage: "lock.shield.fill")
                Label("AI cannot control the login browser", systemImage: "hand.raised.fill")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
