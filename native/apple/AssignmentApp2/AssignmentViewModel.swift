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

    private let repository: AssignmentRepository?

    init(repository: AssignmentRepository? = nil) {
        if let repository {
            self.repository = repository
            databaseLocation = repository.databaseURL.path
        } else {
            do {
                let liveRepository = try SQLiteAssignmentRepository()
                self.repository = liveRepository
                databaseLocation = liveRepository.databaseURL.path
            } catch {
                self.repository = nil
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
        update(edited)
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
        } catch {
            errorMessage = error.localizedDescription
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
