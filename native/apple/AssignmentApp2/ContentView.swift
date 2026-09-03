import Foundation
import SwiftUI


enum AssignmentPreferenceKeys {
    static let displayMode = "assignmentApp.displayMode"
    static let theme = "assignmentApp.theme"
    static let sidebarDisplayStyle = "assignmentApp.sidebarDisplayStyle"
    static let calendarShowsCompleted = "assignmentApp.calendarShowsCompleted"
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
    @State private var isShowingOnboarding = false
    @AppStorage(OnboardingState.completedKey)
    private var didCompleteOnboarding = false

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
                } else if viewModel.selection.isDedicatedPage {
                    dedicatedContent
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
        .sheet(isPresented: $isShowingOnboarding) {
            OnboardingView(
                isReopenedFromSettings: didCompleteOnboarding,
                onRequestNotifications: viewModel.requestNotificationAuthorization,
                onFinish: {
                    didCompleteOnboarding = true
                    UserDefaults.standard.set(
                        OnboardingState.currentVersion,
                        forKey: OnboardingState.versionKey
                    )
                    isShowingOnboarding = false
                }
            )
            // No identifier is stamped on the sheet either, for the reason
            // given in `OnboardingView`: one set on a container is copied onto
            // everything the container hosts, which drowns out the identifiers
            // of the controls inside it.
        }
        .onAppear {
            applyUITestOverridesIfNeeded()
            presentDeferredError()
        }
        .task {
            // First launch only. `didCompleteOnboarding` is written the moment
            // the walkthrough ends — skipped or not — so it never reappears on
            // its own afterwards.
            //
            // The UI-test flags are read at the point of use so the decision
            // is atomic with the work that depends on it. A walkthrough that
            // has already been completed can also be forced back open from
            // Settings, so tests that only need the post-onboarding surface
            // do not have to depend on simulator history.
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            let environment = ProcessInfo.processInfo.environment
            if arguments.contains("-assignmentApp.uiTestSkipOnboarding") { return }
            // `UserDefaults` outlive both a test run and the simulator itself,
            // so once the walkthrough has been completed anywhere on a
            // long-lived device the first-launch path — the one real users
            // actually get — becomes unreachable. This drops the flag before
            // the decision below is taken, so a test can stand in the shoes of
            // a person opening the app for the first time.
            if arguments.contains("-assignmentApp.uiTestResetOnboarding") {
                didCompleteOnboarding = false
            }
            let forced = arguments.contains("-assignmentApp.uiTestShowOnboarding")
                || environment["ASSIGNMENT_UI_FORCE_ONBOARDING"] == "1"
            #else
            let forced = false
            #endif
            guard forced || !didCompleteOnboarding else { return }
            isShowingOnboarding = true
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
            searchPresentation.isExpanded ? "" : viewModel.selection.localizedTitle
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
        } else if viewModel.visibleAssignments.isEmpty
                    && viewModel.selection != .today {
            emptyState
        } else {
            // Today always renders the list, even with no tasks: the overview
            // card at the top is the page's reason to exist, and it carries the
            // "nothing due today" hint itself.
            assignmentList
        }
    }

    private var assignmentList: some View {
        List {
            if viewModel.selection == .today {
                Section {
                    TodayOverviewCard(
                        overview: viewModel.todayOverview,
                        displayMode: displayMode,
                        courseName: { viewModel.learningStore.courseName($0) },
                        onOpenTask: { showEditor(for: $0) },
                        onShowTimetable: { viewModel.selection = .timetable },
                        onShowExams: { viewModel.selection = .exams },
                        onShowOverdue: { viewModel.selection = .overdue }
                    )
                }
            }

            Section {
                ForEach(viewModel.visibleAssignments) { assignment in
                    row(for: assignment)
                }
            }
        }
        .listStyle(.inset)
        .refreshable {
            viewModel.reload()
        }
    }

    private func row(for assignment: Assignment) -> some View {
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
                                status.localizedTitle,
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
        viewModel.hasActiveFilters
        ? L10n.tr("No Matching Tasks")
        : viewModel.selection.localizedEmptyTitle
    }

    private var emptyStateSystemImage: String {
        viewModel.hasActiveFilters ? "magnifyingglass" : viewModel.selection.systemImage
    }

    private var emptyStateDescription: String {
        viewModel.hasActiveFilters
            ? L10n.tr("Change the search or filters to see more tasks.")
            : viewModel.selection.localizedEmptyDescription
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

    /// Pages that own their own content and never borrow the task list, so they
    /// are routed before `assignmentContent`.
    ///
    /// The calendar belongs here even though it is a task view: it groups
    /// assignments by civil day through `CalendarPlanner` instead of rendering
    /// `viewModel.visibleAssignments`. Both paths read the same repository
    /// snapshot, so the calendar and the Today list can never disagree about
    /// the same database.
    @ViewBuilder
    private var dedicatedContent: some View {
        switch viewModel.selection {
        case .timetable:
            TimetableView(
                store: viewModel.learningStore,
                displayMode: displayMode,
                isWriteEnabled: viewModel.isWriteEnabled
            )
        case .exams:
            ExamListView(
                store: viewModel.learningStore,
                displayMode: displayMode,
                isWriteEnabled: viewModel.isWriteEnabled
            )
        case .calendar:
            TaskCalendarView(
                assignments: viewModel.assignments,
                displayMode: displayMode,
                isWriteEnabled: viewModel.isWriteEnabled,
                onOpenTask: { showEditor(for: $0) },
                onQuickAdd: { showNewTaskEditor(dueDate: $0) }
            )
        case .all, .today, .week, .overdue, .completed, .settings:
            assignmentContent
        }
    }

    private var settingsContent: some View {
        AssignmentSettingsView(
            displayMode: displayModeBinding,
            theme: themeBinding,
            databaseLocation: viewModel.databaseLocation.isEmpty
                ? "Unavailable"
                : viewModel.databaseLocation,
            notificationAuthorization: viewModel.notificationAuthorization,
            onRequestNotifications: viewModel.requestNotificationAuthorization,
            onRefreshNotifications: viewModel.refreshNotificationAuthorization,
            onReload: viewModel.reload,
            onReopenOnboarding: { isShowingOnboarding = true },
            makeAboutInfo: viewModel.makeVersionInfo,
            onCopyDiagnostics: DiagnosticsClipboard.copy
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
                isTaskDestination: !viewModel.selection.isDedicatedPage,
                isSearchExpanded: searchPresentation.isExpanded,
                isModalPresented: editorPresentation != nil || activeAlert != nil
            ),
            newTask: { showNewTaskEditor() },
            find: presentSearch,
            closeSearch: dismissSearchPreservingQuery,
            reload: viewModel.reload
        )
    }

    private func showNewTaskEditor(dueDate: Date? = nil) {
        guard viewModel.isWriteEnabled else {
            activeAlert = .error(
                viewModel.errorMessage ?? "The local task database is unavailable."
            )
            return
        }
        dismissSearchPreservingQuery()
        editorPresentation = TaskEditorPresentation(assignment: nil, initialDueDate: dueDate)
    }

    private func showEditor(for assignment: Assignment) {
        dismissSearchPreservingQuery()
        editorPresentation = TaskEditorPresentation(assignment: assignment)
    }

    private func editor(for presentation: TaskEditorPresentation) -> some View {
        let assignment = presentation.assignment
        let initialTagIDs: [Int64] = assignment.flatMap { target in
            viewModel.organizationRepository.flatMap { repo in
                (try? repo.fetchTagLinks(assignmentID: target.id, includeDeleted: false))?
                    .map(\.tagID)
            }
        } ?? []

        return TaskEditorView(
            assignment: assignment,
            displayMode: displayMode,
            onSave: { draft in
                if let assignment = assignment {
                    viewModel.update(assignment, with: draft)
                    if viewModel.errorMessage == nil {
                        viewModel.applyOrganization(assignmentID: assignment.id, draft: draft)
                    }
                    return viewModel.errorMessage
                }

                guard let created = viewModel.add(draft) else {
                    return viewModel.errorMessage ?? "The task could not be saved."
                }
                viewModel.applyOrganization(assignmentID: created.id, draft: draft)
                return viewModel.errorMessage
            },
            onDelete: assignment == nil ? nil : { assignment in
                viewModel.delete(assignment)
                return viewModel.errorMessage
            },
            organizationRepository: viewModel.organizationRepository,
            courses: viewModel.organizationCourses,
            projects: viewModel.organizationProjects,
            tags: viewModel.organizationTags,
            initialCourseID: assignment?.courseID,
            initialProjectID: assignment?.projectID,
            initialTagIDs: initialTagIDs,
            initialDueDate: presentation.initialDueDate
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
        // The onboarding flags are deliberately handled in the `.task` that
        // decides whether to present the sheet, not here.
        #endif
    }

    private func dismissSearchPreservingQuery() {
        guard searchPresentation.isExpanded else { return }
        var query = viewModel.searchText
        searchPresentation.handle(.dismissPreservingQuery, query: &query)
        viewModel.searchText = query
    }

    private func presentSearch() {
        guard !viewModel.selection.isDedicatedPage,
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
                message: Text(L10n.tr("“%@” will be removed from the local database.", assignment.title)),
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
    /// Seeded by the calendar's quick add so a task created from a day cell
    /// starts on that day instead of "no due date".
    let initialDueDate: Date?

    init(assignment: Assignment?, initialDueDate: Date? = nil) {
        self.assignment = assignment
        self.initialDueDate = initialDueDate
    }
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
