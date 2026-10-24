import AppKit
import LimitGaugeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var service: UsageService!
    private var codexService: UsageService!
    private var statusMenu: StatusMenu!
    private var poller: Poller!
    private var codexPoller: Poller!
    private var settingsWindow: SettingsWindow!
    private var shortcut: GlobalShortcut!
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
        codexService = UsageService(
            readCodex: { () async throws(CodexUsageError) -> CodexUsageReading in
                try await CodexUsageReader().read()
            },
            store: SnapshotStore(namespace: "codex"),
            delivery: notifier,
            thresholds: { Settings.codexThresholds }
        )
        codexPoller = Poller { [weak self] in self?.codexService.refresh(.poll) }
        poller = Poller { [weak self] in self?.service.refresh(.poll) }
        shortcut = GlobalShortcut { [weak self] in self?.statusMenu?.toggleMenu() }
        shortcut.apply(Settings.keyboardShortcut)
        settingsWindow = SettingsWindow(
            notifier: notifier,
            shortcut: shortcut,
            scopedLimitName: { [weak self] in self?.service.snapshot?.limit(.weeklyScoped)?.scopeName },
            onChange: { [weak self] in
                self?.service.reevaluateWarnings()
                self?.codexService.reevaluateWarnings()
            }
        )
        statusMenu = StatusMenu(service: service, codexService: codexService) { [weak self] in self?.settingsWindow.show() }
        statusMenu.onTrackingChange = { [weak self] tracking in self?.shortcut.setMenuTracking(tracking) }
        service.onChange = { [weak self] in self?.serviceChanged() }
        codexService.onChange = { [weak self] in self?.serviceChanged() }

        service.refresh(.launch)
        codexService.refresh(.launch)
        Task {
            if await notifier.requestAuthorizationIfEnabled() {
                service.reevaluateWarnings()
                codexService.reevaluateWarnings()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcut.stop()
    }

    private func serviceChanged() {
        statusMenu.updateIconAndOpenRows()
        poller.schedule(at: service.nextPoll)
        codexPoller.schedule(at: codexService.nextPoll)
    }
}
