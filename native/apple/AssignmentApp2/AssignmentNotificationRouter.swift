import Foundation
import Combine
import UIKit
import UserNotifications

/// The launch delegate records responses before SwiftUI creates its database stack.
/// Queue entries are consumed only after a successful database load and when no editor is open.
@MainActor
final class AssignmentNotificationRouter: ObservableObject {
    static let shared = AssignmentNotificationRouter()
    @Published private(set) var pending: [UUID] = []
    private var received = Set<String>()

    func receive(identifier: String, assignmentUUID: String?, reminderUUID: String?, deliveryDate: Date) {
        guard let assignmentUUID, let task = UUID(uuidString: assignmentUUID),
              let reminderUUID, let reminder = UUID(uuidString: reminderUUID),
              identifier == "assignment-reminder-" + reminder.uuidString.lowercased() else { return }
        let event = identifier + ":" + String(deliveryDate.timeIntervalSince1970)
        guard received.insert(event).inserted else { return }
        pending.append(task)
    }

    enum Resolution: Equatable { case task(UUID), missing }
    func resolve(availableTaskIDs: Set<UUID>?) -> Resolution? {
        guard let availableTaskIDs, let target = consumeNext() else { return nil }
        return availableTaskIDs.contains(target) ? .task(target) : .missing
    }

    func consumeNext() -> UUID? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }
}

final class AssignmentNotificationAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else {
            completionHandler()
            return
        }
        let request = response.notification.request
        let task = request.content.userInfo["assignmentUUID"] as? String
        let reminder = request.content.userInfo["reminderUUID"] as? String
        let date = response.notification.date
        Task { @MainActor in
            AssignmentNotificationRouter.shared.receive(identifier: request.identifier,
                assignmentUUID: task, reminderUUID: reminder, deliveryDate: date)
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
