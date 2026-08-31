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


actor AssignmentNotificationScheduler {
    static let shared = AssignmentNotificationScheduler()

    private let center: UNUserNotificationCenter
    private static let identifierPrefix = "assignment-reminder-"

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus() async -> AssignmentNotificationAuthorization {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        @unknown default: return .unavailable
        }
    }

    func requestAuthorization() async throws -> AssignmentNotificationAuthorization {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
        return await authorizationStatus()
    }

    @discardableResult
    func schedule(
        reminder: TaskReminder,
        assignment: Assignment,
        now: Date = Date()
    ) async throws -> AssignmentNotificationAuthorization {
        let status = await authorizationStatus()
        let identifier = Self.identifier(for: reminder)
        guard status.canSchedule,
              reminder.isEnabled,
              reminder.deletedAt == nil,
              assignment.deletedAt == nil,
              assignment.status != .done,
              reminder.triggerAtUTC > now else {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            return status
        }

        let content = UNMutableNotificationContent()
        content.title = assignment.title
        var details = assignment.courseName
        if let dueDate = assignment.dueDate {
            details += " · Due " + dueDate.formatted(date: .abbreviated, time: .shortened)
        }
        content.body = details
        content.sound = .default
        content.userInfo = [
            "assignmentUUID": assignment.uuid.uuidString.lowercased(),
            "reminderUUID": reminder.uuid.uuidString.lowercased(),
        ]

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, reminder.triggerAtUTC.timeIntervalSince(now)),
            repeats: false
        )
        try await center.add(.init(
            identifier: identifier,
            content: content,
            trigger: trigger
        ))
        return status
    }

    func cancel(reminder: TaskReminder) {
        let identifier = Self.identifier(for: reminder)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    func cancelAll(for assignment: Assignment) async {
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        let assignmentUUID = assignment.uuid.uuidString.lowercased()
        let pendingIdentifiers = pending.compactMap { request -> String? in
            guard request.identifier.hasPrefix(Self.identifierPrefix),
                  request.content.userInfo["assignmentUUID"] as? String == assignmentUUID else {
                return nil
            }
            return request.identifier
        }
        let deliveredIdentifiers = delivered.compactMap { notification -> String? in
            let request = notification.request
            guard request.identifier.hasPrefix(Self.identifierPrefix),
                  request.content.userInfo["assignmentUUID"] as? String == assignmentUUID else {
                return nil
            }
            return request.identifier
        }
        center.removePendingNotificationRequests(withIdentifiers: pendingIdentifiers)
        center.removeDeliveredNotifications(
            withIdentifiers: Array(Set(pendingIdentifiers + deliveredIdentifiers))
        )
    }

    func reconcile(
        assignments: [Assignment],
        repository: OrganizationRepository,
        now: Date = Date()
    ) async throws -> AssignmentNotificationAuthorization {
        let status = await authorizationStatus()
        var desired: [(TaskReminder, Assignment)] = []
        for assignment in assignments where assignment.deletedAt == nil {
            let reminders = try repository.fetchReminders(
                assignmentID: assignment.id,
                includeDeleted: false
            )
            for reminder in reminders where reminder.isEnabled
                && reminder.triggerAtUTC > now
                && assignment.status != .done {
                desired.append((reminder, assignment))
            }
        }

        let desiredIDs = Set(desired.map { Self.identifier(for: $0.0) })
        let pending = await center.pendingNotificationRequests()
        let obsolete = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) && !desiredIDs.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: obsolete)
        center.removeDeliveredNotifications(withIdentifiers: obsolete)

        guard status.canSchedule else { return status }
        for (reminder, assignment) in desired {
            _ = try await schedule(reminder: reminder, assignment: assignment, now: now)
        }
        return status
    }

    private static func identifier(for reminder: TaskReminder) -> String {
        identifierPrefix + reminder.uuid.uuidString.lowercased()
    }
}
