import AppKit
import LimitGaugeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var service: UsageService!
    private var statusMenu: StatusMenu!
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
        statusMenu = StatusMenu(service: service)

        // Populate the cache so the first click has something to show at once.
        service.refreshIfStale()
    }

    private func serviceChanged() {
        store.save(snapshot: service.snapshot)
        store.save(plan: service.plan, fetchedAt: service.planFetchedAt)
        if let problem = service.problem {
            Log.fetch.error("usage fetch: \(problem.message, privacy: .public)")
        }
        statusMenu.update()
    }
}
