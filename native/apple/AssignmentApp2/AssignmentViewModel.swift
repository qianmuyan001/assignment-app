import Combine
import Foundation


@MainActor
final class AssignmentViewModel: ObservableObject {
    @Published private(set) var assignments: [Assignment] = []
    @Published var selection: AssignmentView = .all
    @Published var searchText = ""
    @Published var statusFilter: AssignmentStatus?
    @Published var courseFilter: String?
    @Published var priorityFilter: AssignmentPriority?
    @Published var sortOrder: AssignmentSortOrder = .dueDate
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var databaseLocation = ""
    @Published private(set) var organizationCourses: [Course] = []
    @Published private(set) var organizationProjects: [AssignmentProject] = []
    @Published private(set) var organizationTags: [AssignmentTag] = []
    @Published private(set) var notificationAuthorization: AssignmentNotificationAuthorization = .unavailable

    private let repository: AssignmentRepository?
    let organizationRepository: OrganizationRepository?
    private var notificationOperationTask: Task<Void, Never>?

    init(repository: AssignmentRepository? = nil) {
        if let repository {
            self.repository = repository
            databaseLocation = repository.databaseURL.path
            if let sqlite = repository as? SQLiteAssignmentRepository {
                organizationRepository = try? SQLiteOrganizationRepository(databaseURL: sqlite.databaseURL)
            } else {
                organizationRepository = nil
            }
        } else {
            do {
                let liveRepository = try SQLiteAssignmentRepository()
                self.repository = liveRepository
                databaseLocation = liveRepository.databaseURL.path
                organizationRepository = try? SQLiteOrganizationRepository(databaseURL: liveRepository.databaseURL)
            } catch {
                self.repository = nil
                organizationRepository = nil
                errorMessage = error.localizedDescription
            }
        }

        if self.repository != nil {
            reload()
        }
    }

    var visibleAssignments: [Assignment] {
        TaskRules.apply(
            to: assignments,
            view: selection,
            searchQuery: searchText,
            status: statusFilter,
            course: courseFilter,
            priority: priorityFilter,
            sortOrder: sortOrder
        )
    }

    var courses: [String] {
        var seen: Set<String> = []
        return assignments
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

    func reload() {
        guard let repository else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            assignments = try repository.fetchAll()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        reloadOrganization()
        reconcileNotifications()
    }

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
            assignments.append(assignment)
            errorMessage = nil
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
        guard let repository else {
            errorMessage = AssignmentRepositoryError
                .readOnlyAfterMigrationFailure
                .localizedDescription
            return
        }
        do {
            try repository.delete(id: assignment.id)
            assignments.removeAll { $0.id == assignment.id }
            errorMessage = nil
            replaceNotificationOperation {
                await AssignmentNotificationScheduler.shared.cancelAll(for: assignment)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
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
        Task {
            let status = await AssignmentNotificationScheduler.shared.authorizationStatus()
            notificationAuthorization = status
        }
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
