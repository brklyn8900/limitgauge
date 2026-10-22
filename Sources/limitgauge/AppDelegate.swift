import AppKit
import LimitGaugeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var service: UsageService!
    private var statusMenu: StatusMenu!
    private var poller: Poller!
    private var settingsWindow: SettingsWindow!
    private let notifier = Notifier()

    func applicationDidFinishLaunching(_ notification: Notification) {
        service = UsageService(
            readToken: { () async throws(CredentialError) -> AccessToken in
                try await ClaudeCodeCredentials().read()
            },
            fetcher: UsageAPI(),
            store: SnapshotStore(),
            delivery: notifier,
            thresholds: { Settings.thresholds }
        )
        poller = Poller { [weak self] in self?.service.refresh(.poll) }
        settingsWindow = SettingsWindow(
            notifier: notifier,
            scopedLimitName: { [weak self] in self?.service.snapshot?.limit(.weeklyScoped)?.scopeName },
            onChange: { [weak self] in self?.service.settingsChanged() }
        )
        statusMenu = StatusMenu(service: service) { [weak self] in self?.settingsWindow.show() }
        service.onChange = { [weak self] in self?.serviceChanged() }

        service.refresh(.launch)
        Task {
            // A warning that waited for permission goes out once it is granted.
            if await notifier.requestAuthorizationIfEnabled() { service.settingsChanged() }
        }
    }

    private func serviceChanged() {
        statusMenu.update()
        poller.schedule(at: service.nextPoll)
    }
}
