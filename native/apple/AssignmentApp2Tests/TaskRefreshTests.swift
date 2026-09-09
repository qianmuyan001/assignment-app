import Foundation
import Testing
@testable import AssignmentApp2

/// A deterministic hand-off, not a sleep: capture the first database snapshot,
/// let the main actor mutate or request another refresh, then release the read.
private final class ReadGate: @unchecked Sendable {
    let repository: SQLiteAssignmentRepository
    private let lock = NSLock()
    private let releaseFirst = DispatchSemaphore(value: 0)
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var calls = 0
    private var shouldFail = false
    init(_ repository: SQLiteAssignmentRepository) { self.repository = repository }
    var count: Int { lock.withLock { calls } }
    func fail(_ value: Bool) { lock.withLock { shouldFail = value } }
    func fetch() throws -> [Assignment] {
        let state = lock.withLock { calls += 1; return (calls, shouldFail) }
        if state.1 { throw NSError(domain: "RefreshTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Read failed"]) }
        let snapshot = try repository.fetchAll()
        if state.0 == 1 {
            let continuation = lock.withLock { started = true; let result = waiter; waiter = nil; return result }
            continuation?.resume()
            releaseFirst.wait()
        }
        return snapshot
    }
    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock { if started { return true }; waiter = continuation; return false }
            if resume { continuation.resume() }
        }
    }
    func release() { releaseFirst.signal() }
}

@MainActor struct TaskRefreshTests {
    @Test func overlappingRequestsShareOneReadAndKeepFilters() async throws {
        try await withTemporarySQLiteDatabaseAsync { temporary in
            let repo = try SQLiteAssignmentRepository(databaseURL: temporary.databaseURL)
            _ = try repo.create(AssignmentDraft(courseName: "Course", title: "Example"))
            let gate = ReadGate(repo); defer { gate.release() }
            let model = AssignmentViewModel(repository: repo, fetchOperation: { try gate.fetch() })
            await gate.waitUntilStarted()
            model.searchText = "Example"; model.priorityFilter = .medium
            model.reload(); model.reload()
            #expect(model.isLoading)
            gate.release(); await model.refresh()
            #expect(gate.count == 1)
            #expect(!model.isLoading)
            #expect(model.searchText == "Example")
            #expect(model.priorityFilter == .medium)
            #expect(model.assignments.count == 1)
            await model.stopBackgroundWork()
        }
    }
    @Test func inFlightSnapshotCannotOverwriteNewlySavedTask() async throws {
        try await withTemporarySQLiteDatabaseAsync { temporary in
            let repo = try SQLiteAssignmentRepository(databaseURL: temporary.databaseURL)
            let gate = ReadGate(repo); defer { gate.release() }
            let model = AssignmentViewModel(repository: repo, fetchOperation: { try gate.fetch() })
            await gate.waitUntilStarted()
            let created = try #require(model.add(AssignmentDraft(courseName: "Course", title: "New")))
            gate.release(); await model.refresh()
            #expect(model.assignments.map(\.id) == [created.id])
            #expect(gate.count == 2)
            await model.stopBackgroundWork()
        }
    }
    @Test func failedReadPreservesSnapshotAndRetryClearsTheError() async throws {
        try await withTemporarySQLiteDatabaseAsync { temporary in
            let repo = try SQLiteAssignmentRepository(databaseURL: temporary.databaseURL)
            _ = try repo.create(AssignmentDraft(courseName: "Course", title: "Keep me"))
            let gate = ReadGate(repo); defer { gate.release() }
            let model = AssignmentViewModel(repository: repo, fetchOperation: { try gate.fetch() })
            await gate.waitUntilStarted(); gate.release(); await model.refresh()
            let before = model.assignments
            gate.fail(true); await model.refresh()
            #expect(model.assignments == before)
            #expect(model.errorMessage == "Read failed")
            #expect(!model.isLoading)
            gate.fail(false); await model.refresh()
            #expect(model.errorMessage == nil)
            #expect(model.assignments == before)
            await model.stopBackgroundWork()
        }
    }
}
