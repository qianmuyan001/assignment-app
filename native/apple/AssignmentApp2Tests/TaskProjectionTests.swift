import Foundation
import Testing
@testable import AssignmentApp2

@MainActor struct TaskProjectionTests {
    @Test func persistedSortAndDatabaseReloadKeepUndatedCreationOrder() async throws {
        try await withTemporarySQLiteDatabaseAsync { temporary in
            let repo = try SQLiteAssignmentRepository(databaseURL: temporary.databaseURL)
            let first = try repo.create(AssignmentDraft(courseName: "Course", title: "Z first"))
            let second = try repo.create(AssignmentDraft(courseName: "Course", title: "A second"))
            let suite = "AssignmentUITest-" + UUID().uuidString
            let prefs = try #require(UserDefaults(suiteName: suite))
            defer { prefs.removePersistentDomain(forName: suite) }
            let model = AssignmentViewModel(repository: repo, preferences: prefs)
            await model.refresh()
            #expect(model.visibleAssignments.map(\.id) == [first.id, second.id])
            model.sortOrder = .priority
            await model.stopBackgroundWork()
            let reopened = AssignmentViewModel(repository: repo, preferences: prefs)
            await reopened.refresh()
            #expect(reopened.sortOrder == .priority)
            #expect(reopened.visibleAssignments.map(\.id) == [first.id, second.id])
            var edited = first; edited.title = "A new title"
            reopened.update(edited)
            await reopened.refresh()
            #expect(reopened.visibleAssignments.map(\.id) == [first.id, second.id])
            reopened.searchText = "Does not match"
            _ = reopened.add(AssignmentDraft(courseName: "Course", title: "Hidden"))
            #expect(reopened.visibleAssignments.isEmpty)
            #expect(reopened.feedbackMessage == L10n.tr("Task saved. It is hidden by the current view or filters."))
            await reopened.stopBackgroundWork()
        }
    }

    @Test func renderReadsReuseTheProjectionWhileFilterChangesInvalidateIt() async throws {
        try await withTemporarySQLiteDatabaseAsync { temporary in
            let repo = try SQLiteAssignmentRepository(databaseURL: temporary.databaseURL)
            let tasks = (1...5_000).map { i in
                Assignment(id: Int64(i), courseName: "Course", title: "Task \(i)",
                           createdAt: Date(timeIntervalSince1970: Double(5_000 - i)))
            }
            let model = AssignmentViewModel(repository: repo, fetchOperation: { tasks })
            await model.refresh()
            let clock = ContinuousClock()
            let cachedStart = clock.now
            var cachedCount = 0
            for _ in 0..<50 { cachedCount += model.visibleAssignments.count }
            let cached = cachedStart.duration(to: clock.now)
            let uncachedStart = clock.now
            var computedCount = 0
            for _ in 0..<50 { computedCount += TaskRules.apply(to: tasks, view: .all).count }
            let computed = uncachedStart.duration(to: clock.now)
            #expect(cachedCount == computedCount)
            #expect(model.visibleAssignments.first?.id == 5_000)
            model.searchText = "Task 4999"
            #expect(model.visibleAssignments.map(\.id) == [4_999])
            print("UI_PROJECTION_BENCHMARK tasks=5000 reads=50 cached=\(cached) recomputed=\(computed)")
            await model.stopBackgroundWork()
        }
    }
}

private final class ObservedPreferences: UserDefaults, @unchecked Sendable {
    var writes = 0
    override func set(_ value: Any?, forKey defaultName: String) {
        writes += 1
        super.set(value, forKey: defaultName)
    }
}

@MainActor struct TaskPreferenceIsolationTests {
    @Test func initializationReadsPreferencesWithoutWritingThem() async throws {
        try await withTemporarySQLiteDatabaseAsync { temporary in
            let suite = "AssignmentUITest-" + UUID().uuidString
            let prefs = try #require(ObservedPreferences(suiteName: suite))
            defer { prefs.removePersistentDomain(forName: suite) }
            prefs.set(AssignmentSortOrder.priority.rawValue, forKey: "assignmentApp.taskSortOrder")
            let writes = prefs.writes
            let repo = try SQLiteAssignmentRepository(databaseURL: temporary.databaseURL)
            let model = AssignmentViewModel(repository: repo, preferences: prefs)
            await model.refresh()
            #expect(prefs.writes == writes)
            #expect(model.sortOrder == .priority)
            model.sortOrder = .dueDate
            #expect(prefs.writes == writes + 1)
            await model.stopBackgroundWork()
        }
    }
}
