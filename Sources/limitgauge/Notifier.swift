import Foundation
import LimitGaugeCore
import UserNotifications

/// Posts limit warnings through Notification Center.
@MainActor
final class Notifier: WarningDelivery {
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

    func deliver(_ limit: RateLimit, now: Date) async -> Bool {
        guard Settings.notificationsEnabled else { return false }
        let content = UNMutableNotificationContent()
        content.title = "\(limit.title) at \(limit.percent)%"
        content.body = ResetText.resets(at: limit.resetsAt, now: now)
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            Log.app.error("notification: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
