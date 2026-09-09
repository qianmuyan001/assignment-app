import Combine
import Foundation


@MainActor
final class AssignmentViewModel: ObservableObject {
    @Published private(set) var assignments: [Assignment] = [] { didSet { updateProjection(); updateCourses() } }
    @Published var selection: AssignmentView = .all { didSet { updateProjection() } }
    @Published var searchText = "" { didSet { updateProjection() } }
    @Published var statusFilter: AssignmentStatus? { didSet { updateProjection() } }
    @Published var courseFilter: String? { didSet { updateProjection() } }
    @Published var priorityFilter: AssignmentPriority? { didSet { updateProjection() } }
    @Published var sortOrder: AssignmentSortOrder = .dueDate {
        didSet {
            preferences.set(sortOrder.rawValue, forKey: "assignmentApp.taskSortOrder")
            updateProjection()
        }
    }
    @Published private(set) var visibleAssignments: [Assignment] = []
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var feedbackMessage: String?
    private static let runtimePreferences: UserDefaults = {
        #if DEBUG
        if SQLiteAssignmentRepository.isRunningUnderXCTest {
            return UserDefaults(suiteName: "com.qianmuyan.assignmentapp.tests." + UUID().uuidString.lowercased())!
        }
        #endif
        return .standard
    }()
    private let preferences: UserDefaults
    private var reloadTask: Task<Void, Never>?
    private var mutationRevision = 0
    private var reloadGeneration = 0
    private let fetchOperation: (@Sendable () throws -> [Assignment])?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var hasLoadedAssignments = false
    @Published private(set) var databaseLocation = ""
    @Published private(set) var organizationCourses: [Course] = []
    @Published private(set) var organizationProjects: [AssignmentProject] = []
    @Published private(set) var organizationTags: [AssignmentTag] = []
    @Published private(set) var notificationAuthorization: AssignmentNotificationAuthorization = .unavailable

    private let repository: AssignmentRepository?
    let organizationRepository: OrganizationRepository?
    /// Concrete repository behind `repository`. The Phase 3A learning scenes
    /// need its exam review-task entry point, which is not part of the
    /// platform-neutral `AssignmentRepository` contract.
    private(set) var sqliteRepository: SQLiteAssignmentRepository?
    /// The learning-scene half of the organization repository. It is the same
    /// object, reached through a second protocol so the timetable and exam
    /// pages stay independent of the general organization surface.
    var learningRepository: LearningSceneRepository? {
        organizationRepository as? LearningSceneRepository
    }
    /// Course meetings and exams. It reads and writes through the same
    /// repository as the task list, so no second data path exists.
    let learningStore: LearningSceneStore
    private var notificationOperationTask: Task<Void, Never>?
    private var storeSubscription: AnyCancellable?

    init(repository: AssignmentRepository? = nil, preferences: UserDefaults? = nil,
         fetchOperation: (@Sendable () throws -> [Assignment])? = nil) {
        self.preferences = preferences ?? Self.runtimePreferences
        // Every dependency is resolved into a local first, so the stored
        // properties — including the learning store that needs both
        // repositories — can be assigned exactly once on every path.
        let resolvedRepository: AssignmentRepository?
        let resolvedSQLite: SQLiteAssignmentRepository?
        let resolvedOrganization: OrganizationRepository?
        var resolvedLocation = ""
        var startupError: String?

        if let repository {
            resolvedRepository = repository
            resolvedSQLite = repository as? SQLiteAssignmentRepository
            resolvedLocation = repository.databaseURL.path
            resolvedOrganization = (repository as? SQLiteAssignmentRepository)
                .flatMap { try? SQLiteOrganizationRepository(databaseURL: $0.databaseURL) }
        } else {
            do {
                let liveRepository = try SQLiteAssignmentRepository()
                resolvedRepository = liveRepository
                resolvedSQLite = liveRepository
                resolvedLocation = liveRepository.databaseURL.path
                resolvedOrganization = try? SQLiteOrganizationRepository(
                    databaseURL: liveRepository.databaseURL
                )
            } catch {
                resolvedRepository = nil
                resolvedSQLite = nil
                resolvedOrganization = nil
                startupError = error.localizedDescription
            }
        }

        self.fetchOperation = fetchOperation ?? resolvedSQLite.map { sqlite in
            { @Sendable in try sqlite.fetchAll() }
        }
        self.repository = resolvedRepository
        sqliteRepository = resolvedSQLite
        organizationRepository = resolvedOrganization
        databaseLocation = resolvedLocation
        errorMessage = startupError
        learningStore = LearningSceneStore(
            learningRepository: resolvedOrganization as? LearningSceneRepository,
            organizationRepository: resolvedOrganization,
            assignmentRepository: resolvedSQLite
        )

        // A new Review Task is an ordinary task; the task pages reload so it
        // shows up there too.
        learningStore.onDidMutate = { [weak self] in
            self?.reload()
        }
        // The learning store is a separate observable object, so its changes
        // have to reach the views that observe this one — the Today overview
        // reads meetings and exams through it.
        storeSubscription = learningStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }

        // Initialization is a read, not a user preference change. Initializing
        // the wrapper directly avoids triggering the persistence observer.
        _sortOrder = Published(initialValue: AssignmentSortOrder(rawValue:
            self.preferences.string(forKey: "assignmentApp.taskSortOrder") ?? "") ?? .dueDate)
        if resolvedRepository != nil {
            reload()
        }
    }

    /// Everything the About page reports.
    ///
    /// Counts come from the live repositories rather than a cached copy, so the
    /// page cannot describe a state the app is not actually in. A repository
    /// that failed to open contributes zeroes instead of an error, because the
    /// page's job is to explain the failure, not to add one.
    func makeVersionInfo() -> AppVersionInfo {
        let schema = sqliteRepository.flatMap { try? $0.schemaVersion } ?? 0
        let identity = sqliteRepository.flatMap { try? $0.databaseIdentity } ?? ""
        let attachments =
            (try? organizationRepository?.fetchAllAttachments(includeDeleted: false).count) ?? 0

        return AppVersionInfo(
            marketingVersion: AppVersionInfo.bundleMarketingVersion,
            buildNumber: AppVersionInfo.bundleBuildNumber,
            gitSHA: AppVersionInfo.bundleGitSHA,
            schemaVersion: schema,
            databaseLocation: databaseLocation,
            notificationAuthorization: notificationAuthorization,
            language: L10n.currentLanguage,
            platform: AppVersionInfo.currentPlatform,
            osVersion: AppVersionInfo.currentOSVersion,
            dataSummary: AboutDataSummary(
                taskCount: assignments.count,
                courseCount: organizationCourses.count,
                meetingCount: learningStore.meetings.count,
                examCount: learningStore.exams.count,
                attachmentCount: attachments,
                databaseIdentity: identity
            )
        )
    }

    private func updateProjection() {
        visibleAssignments = TaskRules.apply(
            to: assignments,
            view: selection,
            searchQuery: searchText,
            status: statusFilter,
            course: courseFilter,
            priority: priorityFilter,
            sortOrder: sortOrder
        )
    }

    @Published private(set) var courses: [String] = []

    private func updateCourses() {
        var seen: Set<String> = []
        courses = assignments
            .map(\.courseName)
            .filter { course in
                let key = course
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard !key.isEmpty, !seen.contains(key) else { return false }
                seen.insert(key)
                return true
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var hasActiveFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || statusFilter != nil
            || courseFilter?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || priorityFilter != nil
    }

    var isWriteEnabled: Bool { repository != nil }

    /// What the Today page summarises: today's classes, nearby exams, tasks due
    /// today, and overdue tasks.
    var todayOverview: TodayOverview {
        LearningScenePlanner.todayOverview(
            meetings: learningStore.meetings,
            exams: learningStore.exams,
            assignments: assignments
        )
    }

    /// Coalesce callers and read the lock-protected SQLite repository off the
    /// main actor. A write during the read invalidates its snapshot, not the UI.
    func reload() {
        guard reloadTask == nil, let repository else { return }
        guard let fetchOperation else {
            // Non-SQLite repositories (including lightweight test doubles).
            do { assignments = try repository.fetchAll(); hasLoadedAssignments = true }
            catch { errorMessage = error.localizedDescription }
            return
        }
        isLoading = true
        reloadGeneration += 1
        let generation = reloadGeneration
        reloadTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let revision = self?.mutationRevision else { return }
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try fetchOperation() }
                }.value
                guard !Task.isCancelled, let self,
                      self.reloadGeneration == generation else { return }
                if revision != self.mutationRevision { continue }
                switch result {
                case .success(let snapshot):
                    if self.assignments != snapshot { self.assignments = snapshot }
                    else { self.updateProjection() } // Day boundaries may have changed.
                    self.hasLoadedAssignments = true
                    self.errorMessage = nil
                    self.reloadOrganization()
                    self.learningStore.reload()
                    self.reconcileNotifications()
                    self.lastRefreshedAt = Date()
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
                self.isLoading = false
                self.reloadTask = nil
                return
            }
        }
    }

    func refresh() async {
        reload()
        await reloadTask?.value
    }

    func cancelReload() {
        reloadGeneration += 1
        reloadTask?.cancel()
        reloadTask = nil
        isLoading = false
    }

    func stopBackgroundWork() async {
        let read = reloadTask
        cancelReload()
        await read?.value
        notificationOperationTask?.cancel()
        await notificationOperationTask?.value
        notificationOperationTask = nil
    }

    func clearFeedback() { feedbackMessage = nil }

    func reloadOrganization() {
        guard let orgRepo = organizationRepository else { return }
        do {
            organizationCourses = try orgRepo.fetchCourses(includeDeleted: false)
            organizationProjects = try orgRepo.fetchProjects(
                courseID: nil,
                includeDeleted: false
            )
            organizationTags = try orgRepo.fetchTags(includeDeleted: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func add(_ draft: AssignmentDraft) -> Assignment? {
        guard let repository else {
            errorMessage = AssignmentRepositoryError
                .readOnlyAfterMigrationFailure
                .localizedDescription
            return nil
        }
        do {
            let assignment = try repository.create(draft)
            mutationRevision += 1
            assignments.append(assignment)
            errorMessage = nil
            feedbackMessage = visibleAssignments.contains(where: { $0.id == assignment.id })
                ? L10n.tr("Task added") : L10n.tr("Task saved. It is hidden by the current view or filters.")
            return assignment
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func update(_ assignment: Assignment) {
        guard let repository else {
            errorMessage = AssignmentRepositoryError
                .readOnlyAfterMigrationFailure
                .localizedDescription
            return
        }
        do {
            let updated = try repository.update(assignment)
            replace(updated)
            errorMessage = nil
            reconcileNotifications()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func update(_ assignment: Assignment, with draft: AssignmentDraft) {
        var edited = assignment
        edited.courseName = draft.courseName
        edited.title = draft.title
        edited.dueDate = draft.dueDate
        edited.assignmentDescription = draft.assignmentDescription.nilIfBlank
        edited.link = draft.link.nilIfBlank
        edited.status = draft.status
        edited.priority = draft.priority
        edited.sourceName = draft.sourceName.nilIfBlank
        edited.sourceType = draft.sourceType.nilIfBlank
        edited.sourceFile = draft.sourceFile.nilIfBlank
        edited.sourceURL = draft.sourceURL.nilIfBlank
        edited.projectID = draft.projectID
        update(edited)
    }

    /// Links the professional-only organization records (project + tags) after
    /// an assignment has been created or updated. Course is resolved by name in
    /// the assignment repository; here we reconcile the remaining links.
    func applyOrganization(assignmentID: Int64, draft: AssignmentDraft) {
        guard let orgRepo = organizationRepository else { return }

        if let current = assignments.first(where: { $0.id == assignmentID }),
           current.projectID != draft.projectID {
            var edited = current
            edited.projectID = draft.projectID
            update(edited)
        }

        do {
            let existingLinks = try orgRepo.fetchTagLinks(
                assignmentID: assignmentID,
                includeDeleted: false
            ).map(\.tagID)
            let desired = Set(draft.tagIDs)
            let current = Set(existingLinks)
            for tagID in desired.subtracting(current) {
                _ = try orgRepo.attachTag(tagID, to: assignmentID)
            }
            for tagID in current.subtracting(desired) {
                try orgRepo.detachTag(tagID, from: assignmentID)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ assignment: Assignment) {
        errorMessage = deleteTask(id: assignment.id)
    }

    /// Resolve the live target by persistent ID; never delete a stale row index.
    @discardableResult
    func deleteTask(id: Int64) -> String? {
        guard let repository else {
            return AssignmentRepositoryError.readOnlyAfterMigrationFailure.localizedDescription
        }
        guard let assignment = assignments.first(where: { $0.id == id }) else {
            return L10n.tr("This task is no longer available.")
        }
        do {
            try repository.delete(id: id)
            mutationRevision += 1
            assignments.removeAll { $0.id == id }
            feedbackMessage = L10n.tr("Task deleted")
            replaceNotificationOperation {
                await AssignmentNotificationScheduler.shared.cancelAll(for: assignment)
            }
            return nil
        } catch { return error.localizedDescription }
    }

    func setStatus(_ status: AssignmentStatus, for assignment: Assignment) {
        guard let repository else {
            errorMessage = AssignmentRepositoryError
                .readOnlyAfterMigrationFailure
                .localizedDescription
            return
        }
        do {
            let updated = try repository.updateStatus(id: assignment.id, status: status)
            replace(updated)
            errorMessage = nil
            reconcileNotifications()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshNotificationAuthorization() {
        reconcileNotifications()
    }

    func requestNotificationAuthorization() {
        Task {
            do {
                notificationAuthorization = try await AssignmentNotificationScheduler.shared
                    .requestAuthorization()
                reconcileNotifications()
            } catch {
                errorMessage = error.localizedDescription
                notificationAuthorization = await AssignmentNotificationScheduler.shared
                    .authorizationStatus()
            }
        }
    }

    private func reconcileNotifications() {
        guard let organizationRepository else { return }
        // Due-relative reminders are derived from the task deadlines currently
        // in the database. Recomputing them here means a deadline or time-zone
        // change moves them before the scheduler reads them back.
        recalculateRelativeReminders()
        let snapshot = assignments
        replaceNotificationOperation {
            do {
                self.notificationAuthorization = try await AssignmentNotificationScheduler.shared
                    .reconcile(assignments: snapshot, repository: organizationRepository)
            } catch {
                self.errorMessage = "Reminders could not be reconciled: \(error.localizedDescription)"
            }
        }
    }

    /// Recomputes every reminder marked `.dueRelative` from the deadlines
    /// stored in `assignments`. Fixed reminders — including every row migrated
    /// from Schema v3 — are never touched.
    private func recalculateRelativeReminders() {
        guard let learningRepository else { return }
        do {
            _ = try learningRepository.rescheduleRelativeReminders()
        } catch {
            errorMessage = "Due-relative reminders could not be recalculated: "
                + error.localizedDescription
        }
    }

    private func replaceNotificationOperation(
        _ operation: @escaping @MainActor () async -> Void
    ) {
        let predecessor = notificationOperationTask
        predecessor?.cancel()
        notificationOperationTask = Task { @MainActor in
            await predecessor?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    func toggleCompletion(_ assignment: Assignment) {
        setStatus(assignment.status == .done ? .todo : .done, for: assignment)
    }

    func clearFilters() {
        searchText = ""
        statusFilter = nil
        courseFilter = nil
        priorityFilter = nil
    }

    func clearError() {
        errorMessage = nil
    }

    private func replace(_ assignment: Assignment) {
        mutationRevision += 1
        guard let index = assignments.firstIndex(where: { $0.id == assignment.id }) else {
            assignments.append(assignment)
            return
        }
        assignments[index] = assignment
    }
}


private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
