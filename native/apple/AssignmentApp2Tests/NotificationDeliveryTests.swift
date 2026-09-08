import Foundation
import Testing
import UserNotifications
@testable import AssignmentApp2

/// Lock-protected test double: records the actual requests without touching macOS notifications.
private final class RecordingNotificationCenter: AssignmentNotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String: UNNotificationRequest] = [:]
    private var delivered: [String: UNNotificationRequest] = [:]
    private var additions = 0
    var status = AssignmentNotificationAuthorization.authorized
    var fails = false
    enum Failure: Error { case unavailable }
    func authorizationStatus() async -> AssignmentNotificationAuthorization { status }
    func requestAuthorization() async throws { if fails { throw Failure.unavailable } }
    func pendingNotificationRequests() async -> [UNNotificationRequest] { lock.withLock { Array(requests.values) } }
    func deliveredRequests() async -> [UNNotificationRequest] { lock.withLock { Array(delivered.values) } }
    func add(_ request: UNNotificationRequest) async throws {
        if fails { throw Failure.unavailable }
        lock.withLock { requests[request.identifier] = request; additions += 1 }
    }
    func removePendingNotificationRequests(withIdentifiers ids: [String]) { lock.withLock { for id in ids { requests[id] = nil } } }
    func removeDeliveredNotifications(withIdentifiers ids: [String]) { lock.withLock { for id in ids { delivered[id] = nil } } }
    func deliverPending() { lock.withLock { delivered = requests; requests = [:] } }
    var addCount: Int { lock.withLock { additions } }
}

@Suite("Notification scheduling and response lifecycle")
struct NotificationDeliveryTests {
    @Test func identicalReminderDoesNotRescheduleAcrossSchedulerRestart() async throws {
        try await withTemporarySQLiteDatabaseAsync { temporary in
            let tasks = try SQLiteAssignmentRepository(databaseURL: temporary.databaseURL)
            let org = try SQLiteOrganizationRepository(databaseURL: temporary.databaseURL)
            let task = try tasks.create(.init(courseName: "Math", title: "Prepare"))
            var reminder = try org.createReminder(.init(assignmentID: task.id, triggerAtUTC: Date().addingTimeInterval(3600)))
            let center = RecordingNotificationCenter()
            let scheduler = AssignmentNotificationScheduler(center: center)
            try await scheduler.schedule(reminder: reminder, assignment: task)
            try await AssignmentNotificationScheduler(center: center).schedule(reminder: reminder, assignment: task)
            #expect(center.addCount == 1)
            reminder.triggerAtUTC.addTimeInterval(600)
            try await scheduler.schedule(reminder: reminder, assignment: task)
            #expect(center.addCount == 2)
            #expect(await center.pendingNotificationRequests().count == 1)
        }
    }
    @Test func completionDeletionDisableAndPastTimeCancel() async throws {
        try await withTemporarySQLiteDatabaseAsync { temporary in
            let tasks = try SQLiteAssignmentRepository(databaseURL: temporary.databaseURL)
            let org = try SQLiteOrganizationRepository(databaseURL: temporary.databaseURL)
            let task = try tasks.create(.init(courseName: "Math", title: "Prepare"))
            let reminder = try org.createReminder(.init(assignmentID: task.id, triggerAtUTC: Date().addingTimeInterval(3600)))
            let center = RecordingNotificationCenter()
            let scheduler = AssignmentNotificationScheduler(center: center)
            for mode in 0..<4 {
                try await scheduler.schedule(reminder: reminder, assignment: task)
                var changedTask = task; var changedReminder = reminder
                if mode == 0 { changedTask.status = .done }
                if mode == 1 { changedTask.deletedAt = Date() }
                if mode == 2 { changedReminder.isEnabled = false }
                if mode == 3 { changedReminder.triggerAtUTC = .distantPast }
                try await scheduler.schedule(reminder: changedReminder, assignment: changedTask)
                #expect(await center.pendingNotificationRequests().isEmpty)
            }
        }
    }
    @Test func permissionChangeRemovesThenRestoresRequests() async throws {
        try await withTemporarySQLiteDatabaseAsync { temporary in
            let tasks = try SQLiteAssignmentRepository(databaseURL: temporary.databaseURL)
            let org = try SQLiteOrganizationRepository(databaseURL: temporary.databaseURL)
            let task = try tasks.create(.init(courseName: "Math", title: "Prepare"))
            _ = try org.createReminder(.init(assignmentID: task.id, triggerAtUTC: Date().addingTimeInterval(3600)))
            let center = RecordingNotificationCenter()
            let scheduler = AssignmentNotificationScheduler(center: center)
            _ = try await scheduler.reconcile(assignments: [task], repository: org)
            center.status = .denied
            #expect(try await scheduler.reconcile(assignments: [task], repository: org) == .denied)
            #expect(await center.pendingNotificationRequests().isEmpty)
            center.status = .authorized
            _ = try await scheduler.reconcile(assignments: [task], repository: org)
            #expect(await center.pendingNotificationRequests().count == 1)
            _ = try await scheduler.reconcile(assignments: [], repository: org)
            #expect(await center.pendingNotificationRequests().isEmpty)
        }
    }
    @Test func authorizationFailureIsNotHidden() async {
        let center = RecordingNotificationCenter(); center.fails = true
        do { _ = try await AssignmentNotificationScheduler(center: center).requestAuthorization(); Issue.record("Expected authorization error") }
        catch { #expect(error is RecordingNotificationCenter.Failure) }
    }
    @Test @MainActor func coldResponseWaitsUntilConsumedAndDeduplicates() {
        let router = AssignmentNotificationRouter()
        let task = UUID(); let reminder = UUID(); let date = Date()
        for _ in 0..<2 {
            router.receive(identifier: "assignment-reminder-" + reminder.uuidString.lowercased(), assignmentUUID: task.uuidString,
                           reminderUUID: reminder.uuidString, deliveryDate: date)
        }
        #expect(router.pending == [task])
        #expect(router.consumeNext() == task)
        #expect(router.consumeNext() == nil)
        router.receive(identifier: "assignment-reminder-" + reminder.uuidString.lowercased(), assignmentUUID: task.uuidString,
                       reminderUUID: reminder.uuidString, deliveryDate: date)
        #expect(router.pending.isEmpty)
    }
    @Test @MainActor func malformedOrUnrelatedResponsesAreIgnored() {
        let router = AssignmentNotificationRouter()
        router.receive(identifier: "unrelated", assignmentUUID: UUID().uuidString, reminderUUID: UUID().uuidString, deliveryDate: Date())
        router.receive(identifier: "assignment-reminder-invalid", assignmentUUID: "invalid", reminderUUID: "invalid", deliveryDate: Date())
        #expect(router.pending.isEmpty)
    }
    @Test @MainActor func unavailableDatabaseDefersAndMissingTaskResolvesOnce() {
        let router = AssignmentNotificationRouter(); let task = UUID(); let reminder = UUID()
        router.receive(identifier: "assignment-reminder-" + reminder.uuidString.lowercased(), assignmentUUID: task.uuidString,
                       reminderUUID: reminder.uuidString, deliveryDate: Date())
        #expect(router.resolve(availableTaskIDs: nil) == nil)
        #expect(router.pending == [task])
        #expect(router.resolve(availableTaskIDs: []) == .missing)
        #expect(router.resolve(availableTaskIDs: [task]) == nil)
    }

    @Test func concurrentDuplicateRequestsAndSchedulingFailure() async throws {
        try await withTemporarySQLiteDatabaseAsync { temporary in
            let tasks = try SQLiteAssignmentRepository(databaseURL: temporary.databaseURL)
            let org = try SQLiteOrganizationRepository(databaseURL: temporary.databaseURL)
            let task = try tasks.create(.init(courseName: "Math", title: "Prepare"))
            var reminder = try org.createReminder(.init(assignmentID: task.id, triggerAtUTC: Date().addingTimeInterval(3600)))
            let center = RecordingNotificationCenter()
            let scheduler = AssignmentNotificationScheduler(center: center)
            let original = reminder
            async let first = scheduler.schedule(reminder: original, assignment: task)
            async let second = scheduler.schedule(reminder: original, assignment: task)
            _ = try await (first, second)
            #expect(center.addCount == 1)
            center.fails = true
            reminder.triggerAtUTC.addTimeInterval(60)
            do { try await scheduler.schedule(reminder: reminder, assignment: task); Issue.record("Expected add error") }
            catch { #expect(error is RecordingNotificationCenter.Failure) }
            #expect(center.addCount == 1)
        }
    }

    @Test func deletedTaskCancelsDeliveredNotifications() async throws {
        try await withTemporarySQLiteDatabaseAsync { temporary in
            let tasks = try SQLiteAssignmentRepository(databaseURL: temporary.databaseURL)
            let org = try SQLiteOrganizationRepository(databaseURL: temporary.databaseURL)
            let task = try tasks.create(.init(courseName: "Math", title: "Prepare"))
            let reminder = try org.createReminder(.init(assignmentID: task.id, triggerAtUTC: Date().addingTimeInterval(3600)))
            let center = RecordingNotificationCenter()
            let scheduler = AssignmentNotificationScheduler(center: center)
            try await scheduler.schedule(reminder: reminder, assignment: task)
            center.deliverPending()
            #expect(await center.deliveredRequests().count == 1)
            await scheduler.cancelAll(for: task)
            #expect(await center.deliveredRequests().isEmpty)
        }
    }

}
