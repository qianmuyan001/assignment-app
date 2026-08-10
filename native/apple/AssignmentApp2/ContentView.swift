import Foundation
import SwiftUI


enum AssignmentPreferenceKeys {
    static let displayMode = "assignmentApp.displayMode"
    static let theme = "assignmentApp.theme"
    static let sidebarDisplayStyle = "assignmentApp.sidebarDisplayStyle"
}


struct ContentView: View {
    @EnvironmentObject private var viewModel: AssignmentViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @AppStorage(AssignmentPreferenceKeys.displayMode)
    private var displayModeValue = DisplayMode.simple.rawValue
    @AppStorage(AssignmentPreferenceKeys.theme)
    private var themeValue = AppTheme.system.rawValue
    @AppStorage(AssignmentPreferenceKeys.sidebarDisplayStyle)
    private var sidebarDisplayStyleValue = SidebarDisplayStyle.expanded.rawValue

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var editorPresentation: TaskEditorPresentation?
    @State private var activeAlert: ContentAlert?
    @State private var searchPresentation: SearchPresentationState = .closed
    @State private var didApplyUITestOverrides = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            AssignmentSidebar(
                selection: $viewModel.selection,
                displayStyle: sidebarDisplayStyleBinding
            )
            .navigationSplitViewColumnWidth(
                min: sidebarDisplayStyle == .expanded ? 190 : 64,
                ideal: sidebarDisplayStyle.columnWidth,
                max: sidebarDisplayStyle == .expanded ? 300 : 76
            )
        } detail: {
            NavigationStack {
                if viewModel.selection == .settings {
                    settingsContent
                } else {
                    assignmentContent
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .focusedSceneValue(\.assignmentCommandActions, commandActions)
        .sheet(item: $editorPresentation, onDismiss: presentDeferredError) { presentation in
            editor(for: presentation)
        }
        .alert(item: $activeAlert, content: alert)
        .onAppear {
            applyUITestOverridesIfNeeded()
            presentDeferredError()
        }
        .onChange(of: viewModel.errorMessage) { _, message in
            guard editorPresentation == nil, let message else { return }
            activeAlert = .error(message)
        }
        .onChange(of: viewModel.selection) { _, _ in
            dismissSearchPreservingQuery()
        }
    }

    private var assignmentContent: some View {
        VStack(spacing: 0) {
            AssignmentFilterBar(
                status: $viewModel.statusFilter,
                course: $viewModel.courseFilter,
                priority: $viewModel.priorityFilter,
                sortOrder: $viewModel.sortOrder,
                courses: viewModel.courses,
                onClear: viewModel.clearFilters
            )

            Divider()

            assignmentResults
        }
        .navigationTitle(
            searchPresentation.isExpanded ? "" : viewModel.selection.title
        )
        .simultaneousGesture(
            TapGesture().onEnded {
                dismissSearchPreservingQuery()
            }
        )
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Reload", systemImage: "arrow.clockwise") {
                        viewModel.reload()
                    }
                    .help("Reload tasks")
                }

                Button(
                    displayMode == .simple ? "Quick Add" : "New Task",
                    systemImage: "plus"
                ) {
                    showNewTaskEditor()
                }
                .disabled(!viewModel.isWriteEnabled)
                .help(displayMode == .simple ? "Quick add a task" : "Add a task")

                SearchToolbar(
                    query: $viewModel.searchText,
                    presentation: $searchPresentation
                )
            }
        }
    }

    @ViewBuilder
    private var assignmentResults: some View {
        if viewModel.isLoading && viewModel.assignments.isEmpty {
            ProgressView("Loading tasks…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = viewModel.errorMessage,
                  viewModel.assignments.isEmpty {
            ContentUnavailableView {
                Label("Tasks Unavailable", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                if viewModel.isWriteEnabled {
                    Button("Try Again", systemImage: "arrow.clockwise") {
                        viewModel.reload()
                    }
                }
            }
        } else if viewModel.visibleAssignments.isEmpty {
            emptyState
        } else {
            assignmentList
        }
    }

    private var assignmentList: some View {
        List(viewModel.visibleAssignments) { assignment in
            AssignmentRow(
                assignment: assignment,
                displayMode: displayMode,
                onEdit: { showEditor(for: assignment) },
                onToggleCompletion: { viewModel.toggleCompletion(assignment) }
            )
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    viewModel.toggleCompletion(assignment)
                } label: {
                    Label(
                        assignment.status == .done ? "Restore" : "Done",
                        systemImage: assignment.status == .done
                            ? "arrow.uturn.backward"
                            : "checkmark"
                    )
                }
                .tint(assignment.status == .done ? .blue : .green)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    activeAlert = .delete(assignment)
                }

                Button("Edit", systemImage: "pencil") {
                    showEditor(for: assignment)
                }
                .tint(.blue)
            }
            .contextMenu {
                Button("Edit Task", systemImage: "pencil") {
                    showEditor(for: assignment)
                }

                Menu("Set Status", systemImage: "circle.dashed") {
                    ForEach(AssignmentStatus.allCases) { status in
                        Button {
                            viewModel.setStatus(status, for: assignment)
                        } label: {
                            Label(
                                status.title,
                                systemImage: assignment.status == status
                                    ? "checkmark"
                                    : status.systemImage
                            )
                        }
                    }
                }

                Divider()

                Button("Delete Task", systemImage: "trash", role: .destructive) {
                    activeAlert = .delete(assignment)
                }
            }
        }
        .listStyle(.inset)
        .refreshable {
            viewModel.reload()
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if dynamicTypeSize.isAccessibilitySize {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: emptyStateSystemImage)
                        .font(.title)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    Text(emptyStateTitle)
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)

                    Text(emptyStateDescription)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    emptyStateAction
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label(emptyStateTitle, systemImage: emptyStateSystemImage)
            } description: {
                Text(emptyStateDescription)
            } actions: {
                emptyStateAction
            }
        }
    }

    private var emptyStateTitle: String {
        viewModel.hasActiveFilters ? "No Matching Tasks" : viewModel.selection.emptyTitle
    }

    private var emptyStateSystemImage: String {
        viewModel.hasActiveFilters ? "magnifyingglass" : viewModel.selection.systemImage
    }

    private var emptyStateDescription: String {
        viewModel.hasActiveFilters
            ? "Change the search or filters to see more tasks."
            : viewModel.selection.emptyDescription
    }

    @ViewBuilder
    private var emptyStateAction: some View {
        if viewModel.hasActiveFilters {
            Button("Clear Search and Filters") {
                viewModel.clearFilters()
                searchPresentation = .closed
            }
            .buttonStyle(.borderedProminent)
        } else if viewModel.selection != .completed, viewModel.isWriteEnabled {
            Button(displayMode == .simple ? "Quick Add" : "Add Task") {
                showNewTaskEditor()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var settingsContent: some View {
        AssignmentSettingsView(
            displayMode: displayModeBinding,
            theme: themeBinding,
            databaseLocation: viewModel.databaseLocation.isEmpty
                ? "Unavailable"
                : viewModel.databaseLocation,
            onReload: viewModel.reload
        )
    }

    private var displayMode: DisplayMode {
        DisplayMode(rawValue: displayModeValue) ?? .simple
    }

    private var sidebarDisplayStyle: SidebarDisplayStyle {
        SidebarDisplayStyle(rawValue: sidebarDisplayStyleValue) ?? .expanded
    }

    private var sidebarDisplayStyleBinding: Binding<SidebarDisplayStyle> {
        Binding(
            get: { sidebarDisplayStyle },
            set: { sidebarDisplayStyleValue = $0.rawValue }
        )
    }

    private var displayModeBinding: Binding<DisplayMode> {
        Binding(
            get: { displayMode },
            set: { displayModeValue = $0.rawValue }
        )
    }

    private var themeBinding: Binding<AppTheme> {
        Binding(
            get: { AppTheme(rawValue: themeValue) ?? .system },
            set: { themeValue = $0.rawValue }
        )
    }

    private var commandActions: AssignmentCommandActions {
        AssignmentCommandActions(
            availability: AssignmentCommandAvailability(
                isWriteEnabled: viewModel.isWriteEnabled,
                isTaskDestination: viewModel.selection != .settings,
                isSearchExpanded: searchPresentation.isExpanded,
                isModalPresented: editorPresentation != nil || activeAlert != nil
            ),
            newTask: showNewTaskEditor,
            find: presentSearch,
            closeSearch: dismissSearchPreservingQuery,
            reload: viewModel.reload
        )
    }

    private func showNewTaskEditor() {
        guard viewModel.isWriteEnabled else {
            activeAlert = .error(
                viewModel.errorMessage ?? "The local task database is unavailable."
            )
            return
        }
        dismissSearchPreservingQuery()
        editorPresentation = TaskEditorPresentation(assignment: nil)
    }

    private func showEditor(for assignment: Assignment) {
        dismissSearchPreservingQuery()
        editorPresentation = TaskEditorPresentation(assignment: assignment)
    }

    private func editor(for presentation: TaskEditorPresentation) -> some View {
        TaskEditorView(
            assignment: presentation.assignment,
            displayMode: displayMode,
            onSave: { draft in
                if let assignment = presentation.assignment {
                    viewModel.update(assignment, with: draft)
                    return viewModel.errorMessage
                }

                return viewModel.add(draft) == nil
                    ? (viewModel.errorMessage ?? "The task could not be saved.")
                    : nil
            },
            onDelete: presentation.assignment == nil ? nil : { assignment in
                viewModel.delete(assignment)
                return viewModel.errorMessage
            }
        )
    }

    private func presentDeferredError() {
        guard let message = viewModel.errorMessage else { return }
        activeAlert = .error(message)
    }

    private func applyUITestOverridesIfNeeded() {
        guard !didApplyUITestOverrides else { return }
        didApplyUITestOverrides = true

        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-assignmentApp.uiTestSidebarCompact") {
            sidebarDisplayStyleValue = SidebarDisplayStyle.compact.rawValue
        } else if arguments.contains("-assignmentApp.uiTestSidebarExpanded") {
            sidebarDisplayStyleValue = SidebarDisplayStyle.expanded.rawValue
        }
        #endif
    }

    private func dismissSearchPreservingQuery() {
        guard searchPresentation.isExpanded else { return }
        var query = viewModel.searchText
        searchPresentation.handle(.dismissPreservingQuery, query: &query)
        viewModel.searchText = query
    }

    private func presentSearch() {
        guard viewModel.selection != .settings,
              editorPresentation == nil,
              activeAlert == nil else {
            return
        }
        var query = viewModel.searchText
        searchPresentation.handle(.present, query: &query)
        viewModel.searchText = query
    }

    private func alert(for alert: ContentAlert) -> Alert {
        switch alert {
        case .error(let message):
            return Alert(
                title: Text("Couldn’t Complete Action"),
                message: Text(message),
                dismissButton: .default(Text("OK"))
            )

        case .delete(let assignment):
            return Alert(
                title: Text("Delete this task?"),
                message: Text("“\(assignment.title)” will be removed from the local database."),
                primaryButton: .destructive(Text("Delete")) {
                    viewModel.delete(assignment)
                },
                secondaryButton: .cancel()
            )
        }
    }
}


private struct TaskEditorPresentation: Identifiable {
    let id = UUID()
    let assignment: Assignment?
}


private enum ContentAlert: Identifiable {
    case error(String)
    case delete(Assignment)

    var id: String {
        switch self {
        case .error(let message):
            return "error-\(message)"
        case .delete(let assignment):
            return "delete-\(assignment.id)"
        }
    }
}
