import Foundation
import LimitGaugeCore
import UserNotifications

/// Posts limit warnings through Notification Center.
@MainActor
final class Notifier: NSObject, WarningDelivery, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    /// Created before launch finishes, as Notification Center requires of its delegate.
    override init() {
        super.init()
        center.delegate = self
    }

    /// Without this, macOS silences a notification while limitgauge is the frontmost app, as
    /// it is while Settings is open, yet `add` still succeeds and the warning counts as fired
    /// (ADR-0005 point 2).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        Log.app.info("notification presented while limitgauge is frontmost")
        return [.banner, .sound]
    }

    /// Asks for permission once. Notifications are on by default (proposal, Warnings). True
    /// if notifications are allowed.
    @discardableResult
    func requestAuthorizationIfEnabled() async -> Bool {
        guard Settings.notificationsEnabled else { return false }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            Log.app.info("notification authorization granted: \(granted)")
            return granted
        } catch {
            Log.app.error("notification authorization: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// False, without touching Notification Center, when limitgauge's switch is off or macOS
    /// has not allowed notifications; the service keeps the warning due (ADR-0005). Whether
    /// `add` fails when notifications are denied is unverified, so the status is checked first.
    func deliver(_ limit: RateLimit, identifier: String, now: Date) async -> Bool {
        guard Settings.notificationsEnabled else { return false }
        switch await authorizationStatus() {
        case .authorized, .provisional: break
        default: return false
        }
        let content = UNMutableNotificationContent()
        content.title = "\(limit.title) at \(limit.percent)%"
        content.body = ResetText.resets(at: limit.resetsAt, now: now)
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            Log.app.error("notification: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
