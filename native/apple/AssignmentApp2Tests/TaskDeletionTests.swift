import Foundation
import Testing
@testable import AssignmentApp2

@MainActor struct TaskDeletionTests {
    @Test func cancellationNeverWritesAndBothEntrypointsShareTarget() {
        let state = TaskDeletionState()
        state.request(id: 42, anchor: .row)
        state.cancel()
        var writes = 0
        #expect(!state.confirm { _ in writes += 1; return nil })
        #expect(writes == 0)
        state.request(id: 43, anchor: .editor)
        #expect(state.targetID == 43)
        #expect(state.anchor == .editor)
    }
    @Test func failureRetainsTargetAndRetryDeletesOnlyThePersistentIDOnce() {
        let state = TaskDeletionState()
        state.request(id: 42, anchor: .row)
        var attempted: Int64?
        let failed = state.confirm { id in attempted = id; return "Disk full" }
        #expect(!failed)
        #expect(attempted == 42)
        #expect(state.targetID == 42)
        #expect(state.errorMessage == "Disk full")
        var deleted: [Int64] = []
        #expect(state.confirm { deleted.append($0); return nil })
        #expect(!state.confirm { deleted.append($0); return nil })
        #expect(deleted == [42])
        #expect(state.targetID == nil)
    }
}
