import Combine
import Foundation


@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var assignments: [Assignment] = []
    @Published var selection: SidebarSelection? = .all
    @Published var searchText = ""
    @Published var errorMessage: String?
    @Published var isParsing = false
    @Published var aiAvailable = false
    @Published var aiEndpoint = "http://127.0.0.1:8080"
    @Published private(set) var databaseLocation = ""

    private let database: AssignmentDatabase?
    private let aiParser = LocalAIParser()

    init() {
        do {
            let database = try AssignmentDatabase()
            self.database = database
            databaseLocation = database.url.path
            reload()
        } catch {
            database = nil
            errorMessage = error.localizedDescription
        }

        Task {
            await checkAI()
        }
    }

    var visibleAssignments: [Assignment] {
        assignments.filter { assignment in
            matchesSelection(assignment) && matchesSearch(assignment)
        }
    }

    func reload() {
        guard let database else { return }
        do {
            assignments = try database.fetchAssignments()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markCompleted(_ assignment: Assignment) {
        guard let database else { return }
        do {
            try database.updateStatus(id: assignment.id, status: .completed)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ assignment: Assignment) {
        guard let database else { return }
        do {
            try database.delete(id: assignment.id)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func parse(
        page: CapturedPage,
        sourceName: String,
        courseHint: String
    ) async throws -> [AssignmentCandidate] {
        isParsing = true
        defer { isParsing = false }
        let candidates = try await aiParser.parse(
            page: page,
            sourceName: sourceName,
            courseHint: courseHint
        )
        return candidates.map { candidate in
            var resolved = candidate
            if resolved.sourceName?.isEmpty != false {
                resolved.sourceName = sourceName
            }
            if resolved.sourceURL?.isEmpty != false {
                resolved.sourceURL = page.url
            }
            if resolved.courseName?.isEmpty != false, !courseHint.isEmpty {
                resolved.courseName = courseHint
            }
            return resolved
        }
    }

    @discardableResult
    func importCandidates(
        _ candidates: [AssignmentCandidate],
        sourceName: String,
        courseHint: String,
        sourceURL: String
    ) -> Int {
        guard let database else { return 0 }
        do {
            let count = try database.insertCandidates(
                candidates,
                fallbackCourse: courseHint,
                sourceName: sourceName,
                sourceURL: sourceURL
            )
            reload()
            return count
        } catch {
            errorMessage = error.localizedDescription
            return 0
        }
    }

    func applyAIEndpoint() async {
        do {
            try await aiParser.updateEndpoint(aiEndpoint)
            await checkAI()
        } catch {
            aiAvailable = false
            errorMessage = error.localizedDescription
        }
    }

    func checkAI() async {
        aiAvailable = await aiParser.isAvailable()
    }

    private func matchesSelection(_ assignment: Assignment) -> Bool {
        let calendar = Calendar.current
        let now = Date()
        switch selection ?? .all {
        case .all:
            return true
        case .today:
            guard let dueDate = assignment.dueDate else { return false }
            return calendar.isDate(dueDate, inSameDayAs: now)
        case .week:
            guard assignment.status != .completed,
                  let dueDate = assignment.dueDate,
                  let weekEnd = calendar.date(byAdding: .day, value: 7, to: now) else {
                return false
            }
            return dueDate >= calendar.startOfDay(for: now) && dueDate <= weekEnd
        case .completed:
            return assignment.status == .completed
        case .sources:
            return assignment.sourceName?.isEmpty == false
                || assignment.sourceURL?.isEmpty == false
        case .settings:
            return false
        }
    }

    private func matchesSearch(_ assignment: Assignment) -> Bool {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let haystack = [
            assignment.courseName,
            assignment.title,
            assignment.assignmentDescription ?? "",
            assignment.sourceName ?? "",
        ].joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(needle)
    }
}

