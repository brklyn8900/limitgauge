import AppKit
import LimitGaugeCore

/// Background polls for warnings only (ADR-0002). Every fetch, from any trigger, restarts
/// the clock; the interval comes from the least headroom. No timer fires during sleep; on
/// wake the poller fetches if the next poll is overdue.
@MainActor
final class Poller {
    private let service: UsageService
    private var timer: Timer?
    private var nextDue: Date?
    private var observer: NSObjectProtocol?

    init(service: UsageService) {
        self.service = service
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
    }

    /// Called after every service change. Reschedules from the snapshot's fetch time.
    func reschedule(fired: Set<WarningKey>) {
        timer?.invalidate()
        let interval = PollScheduler.nextInterval(snapshot: service.snapshot, thresholds: Settings.thresholds, fired: fired)
        let from = service.snapshot?.fetchedAt ?? Date()
        let due = max(from.addingTimeInterval(interval), Date().addingTimeInterval(5))
        nextDue = due
        let t = Timer(fire: due, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        t.tolerance = min(60, interval / 10)
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Log.poll.debug("next poll in \(Int(due.timeIntervalSinceNow)) s")
    }

    private func fire() {
        Log.poll.info("background poll")
        service.refresh()
    }

    private func didWake() {
        guard let nextDue, nextDue <= Date() else { return }
        Log.poll.info("poll overdue after wake")
        service.refresh()
    }
}
