import Foundation
import UserNotifications


enum AssignmentNotificationAuthorization: String, Equatable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
    case unavailable

    var title: String {
        switch self {
        case .notDetermined: return "Not requested"
        case .denied: return "Denied in System Settings"
        case .authorized: return "Allowed"
        case .provisional: return "Delivered quietly"
        case .ephemeral: return "Temporarily allowed"
        case .unavailable: return "Unavailable"
        }
    }

    var canSchedule: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined, .denied, .unavailable: return false
        }
    }
}


protocol AssignmentNotificationCenter: Sendable {
    func authorizationStatus() async -> AssignmentNotificationAuthorization
    func requestAuthorization() async throws
    func pendingNotificationRequests() async -> [UNNotificationRequest]
    func deliveredRequests() async -> [UNNotificationRequest]
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers: [String])
    func removeDeliveredNotifications(withIdentifiers: [String])
}

final class SystemAssignmentNotificationCenter: AssignmentNotificationCenter, @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()
    func authorizationStatus() async -> AssignmentNotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        @unknown default: return .unavailable
        }
    }
    func requestAuthorization() async throws { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
    func pendingNotificationRequests() async -> [UNNotificationRequest] { await center.pendingNotificationRequests() }
    func deliveredRequests() async -> [UNNotificationRequest] { await center.deliveredNotifications().map(\.request) }
    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
    func removePendingNotificationRequests(withIdentifiers ids: [String]) { center.removePendingNotificationRequests(withIdentifiers: ids) }
    func removeDeliveredNotifications(withIdentifiers ids: [String]) { center.removeDeliveredNotifications(withIdentifiers: ids) }
}

actor AssignmentNotificationScheduler {
    static let shared = AssignmentNotificationScheduler()
    private let center: any AssignmentNotificationCenter
    private static let identifierPrefix = "assignment-reminder-"
    // Serialize whole operations across awaits, including editor calls and lifecycle reconciliation.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(center: any AssignmentNotificationCenter = SystemAssignmentNotificationCenter()) { self.center = center }
    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
    func authorizationStatus() async -> AssignmentNotificationAuthorization { await center.authorizationStatus() }
    func requestAuthorization() async throws -> AssignmentNotificationAuthorization {
        try await center.requestAuthorization()
        return await authorizationStatus()
    }

    @discardableResult
    func schedule(reminder: TaskReminder, assignment: Assignment, now: Date = Date()) async throws -> AssignmentNotificationAuthorization {
        await acquire()
        defer { release() }
        let status = await authorizationStatus()
        try await update(reminder: reminder, assignment: assignment, now: now, status: status)
        return status
    }

    private func update(reminder: TaskReminder, assignment: Assignment, now: Date,
                        status: AssignmentNotificationAuthorization) async throws {
        let identifier = Self.identifier(for: reminder)
        guard status.canSchedule, reminder.isEnabled, reminder.deletedAt == nil,
              assignment.deletedAt == nil, assignment.status != .done, reminder.triggerAtUTC > now else {
            remove([identifier]); return
        }
        let content = UNMutableNotificationContent()
        content.title = assignment.title
        content.body = assignment.courseName
        if let due = assignment.dueDate {
            content.body += " · " + L10n.tr("Due") + " " + due.formatted(date: .abbreviated, time: .shortened)
        }
        content.sound = .default
        content.userInfo = ["assignmentUUID": assignment.uuid.uuidString.lowercased(),
                            "reminderUUID": reminder.uuid.uuidString.lowercased(),
                            "triggerAtUTC": reminder.triggerAtUTC.timeIntervalSince1970]
        let pending = await center.pendingNotificationRequests()
        if let existing = pending.first(where: { $0.identifier == identifier }),
           existing.content.title == content.title, existing.content.body == content.body,
           NSDictionary(dictionary: existing.content.userInfo).isEqual(to: content.userInfo) { return }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, reminder.triggerAtUTC.timeIntervalSince(now)), repeats: false)
        try await center.add(.init(identifier: identifier, content: content, trigger: trigger))
    }

    func cancel(reminder: TaskReminder) async {
        await acquire(); defer { release() }
        remove([Self.identifier(for: reminder)])
    }
    private func remove(_ identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
    func cancelAll(for assignment: Assignment) async {
        await acquire(); defer { release() }
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredRequests()
        remove(Array(Set((pending + delivered).filter {
            $0.identifier.hasPrefix(Self.identifierPrefix)
                && $0.content.userInfo["assignmentUUID"] as? String == assignment.uuid.uuidString.lowercased()
        }.map(\.identifier))))
    }
    func reconcile(assignments: [Assignment], repository: OrganizationRepository, now: Date = Date()) async throws -> AssignmentNotificationAuthorization {
        await acquire(); defer { release() }
        let status = await authorizationStatus()
        var desired: [(TaskReminder, Assignment)] = []
        var liveIDs = Set<String>()
        for assignment in assignments where assignment.deletedAt == nil && assignment.status != .done {
            for reminder in try repository.fetchReminders(assignmentID: assignment.id, includeDeleted: false)
                where reminder.isEnabled && reminder.deletedAt == nil {
                liveIDs.insert(Self.identifier(for: reminder))
                if reminder.triggerAtUTC > now { desired.append((reminder, assignment)) }
            }
        }
        let desiredIDs = status.canSchedule ? Set(desired.map { Self.identifier(for: $0.0) }) : []
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter {
            $0.hasPrefix(Self.identifierPrefix) && !desiredIDs.contains($0)
        })
        center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.identifier).filter {
            $0.hasPrefix(Self.identifierPrefix) && (!status.canSchedule || !liveIDs.contains($0))
        })
        for (reminder, assignment) in desired {
            try await update(reminder: reminder, assignment: assignment, now: now, status: status)
        }
        return status
    }
    private static func identifier(for reminder: TaskReminder) -> String {
        identifierPrefix + reminder.uuid.uuidString.lowercased()
    }
}
