import Foundation
import LimitGaugeCore
import UserNotifications

/// Posts limit warnings through Notification Center.
@MainActor
final class Notifier {
    private let center = UNUserNotificationCenter.current()

    /// Asks for permission once. Notifications are on by default (proposal, Warnings).
    func requestAuthorizationIfEnabled() {
        guard Settings.notificationsEnabled else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Log.app.error("notification authorization: \(error.localizedDescription, privacy: .public)")
            } else {
                Log.app.info("notification authorization granted: \(granted)")
            }
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func post(_ limits: [RateLimit], now: Date) {
        guard Settings.notificationsEnabled, !limits.isEmpty else { return }
        for limit in limits {
            let content = UNMutableNotificationContent()
            content.title = "\(limit.title) at \(limit.percent)%"
            content.body = ResetText.resets(at: limit.resetsAt, now: now)
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request) { error in
                if let error {
                    Log.app.error("notification: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
