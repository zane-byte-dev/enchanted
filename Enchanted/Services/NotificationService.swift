//
//  NotificationService.swift
//  Enchanted
//

import Foundation
import UserNotifications

final class NotificationService: NSObject, @unchecked Sendable {
    static let shared = NotificationService()

    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
        center.delegate = self
    }

    func prepare() {
        Task { _ = await notificationsAllowed() }
    }

    func notifyConversationFinished(conversationID: UUID, title: String, failed: Bool) {
        let conversationTitle = Self.trimmed(title, maxLength: 80)

        Task {
            guard await notificationsAllowed() else { return }

            let content = UNMutableNotificationContent()
            content.title = failed ? String(localized: "Task needs attention") : String(localized: "Task complete")
            content.body = failed
                ? String(localized: "\(conversationTitle) finished with an error.")
                : String(localized: "\(conversationTitle) is done.")
            content.sound = .default
            content.threadIdentifier = conversationID.uuidString
            content.userInfo = ["conversationID": conversationID.uuidString]

            let request = UNNotificationRequest(
                identifier: "conversation-\(conversationID.uuidString)-\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    private func notificationsAllowed() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private static func trimmed(_ value: String, maxLength: Int) -> String {
        let collapsed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard !collapsed.isEmpty else { return String(localized: "Conversation") }
        guard collapsed.count > maxLength else { return collapsed }
        return String(collapsed.prefix(maxLength)).trimmingCharacters(in: .whitespaces) + "..."
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard
            let idString = response.notification.request.content.userInfo["conversationID"] as? String,
            let conversationID = UUID(uuidString: idString)
        else { return }

        await MainActor.run {
            ConversationStore.shared.openConversation(id: conversationID)
        }
    }
}
