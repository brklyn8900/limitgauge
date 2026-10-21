import AppKit
import LimitGaugeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var service: UsageService!
    private var statusMenu: StatusMenu!
    private var poller: Poller!
    private var settingsWindow: SettingsWindow!
    private let notifier = Notifier()
    private let store = SnapshotStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let persisted = store.loadPlan()
        service = UsageService(
            fetcher: UsageAPI(),
            snapshot: store.loadSnapshot(),
            plan: persisted?.0,
            planFetchedAt: persisted?.1
        )
        service.onChange = { [weak self] in self?.serviceChanged() }
        settingsWindow = SettingsWindow(
            notifier: notifier,
            scopedLimitName: { [weak self] in self?.service.snapshot?.limit(.weeklyScoped)?.scopeName },
            onChange: { [weak self] in self?.settingsChanged() }
        )
        statusMenu = StatusMenu(service: service) { [weak self] in self?.settingsWindow.show() }
        poller = Poller(service: service)

        notifier.requestAuthorizationIfEnabled()
        poller.reschedule(fired: Settings.firedWarnings)
        // Populate the cache so the first click has something to show at once.
        service.refreshIfStale()
    }

    private func serviceChanged() {
        store.save(snapshot: service.snapshot)
        store.save(plan: service.plan, fetchedAt: service.planFetchedAt)
        if !service.isRefreshing { evaluateWarnings() }
        statusMenu.update()
    }

    /// Posts new warnings and reschedules the poll from the fresh snapshot.
    private func evaluateWarnings() {
        guard let snapshot = service.snapshot else { return }
        let outcome = WarningTracker.evaluate(snapshot: snapshot, thresholds: Settings.thresholds, fired: Settings.firedWarnings)
        Settings.firedWarnings = outcome.fired
        notifier.post(outcome.toNotify, now: Date())
        poller.reschedule(fired: outcome.fired)
    }

    private func settingsChanged() {
        // A lowered threshold can put a limit past it right away; a raised one re-arms it.
        if let snapshot = service.snapshot {
            let past = snapshot.limits.filter { Settings.thresholds.isPast($0) }.map { WarningKey($0) }
            Settings.firedWarnings = Settings.firedWarnings.intersection(past)
        }
        evaluateWarnings()
        statusMenu.update()
    }
}
