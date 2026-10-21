import AppKit
import LimitGaugeCore

/// Holds the one-shot timer for the next background poll (ADR-0002). It computes nothing:
/// the due time comes from `UsageService.nextPoll`. No timer fires during sleep; on wake the
/// poller polls if the due time has passed.
@MainActor
final class Poller {
    private let poll: @MainActor () -> Void
    private var timer: Timer?
    private var due: Date?
    private var observer: NSObjectProtocol?

    init(poll: @escaping @MainActor () -> Void) {
        self.poll = poll
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
    }

    /// Arms the timer for `due`; nil disarms. An unchanged due time is a no-op.
    func schedule(at due: Date?) {
        guard due != self.due else { return }
        timer?.invalidate()
        timer = nil
        self.due = due
        guard let due else { return }
        let fire = max(due, Date().addingTimeInterval(5))
        let t = Timer(fire: fire, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        t.tolerance = min(60, max(0, fire.timeIntervalSinceNow) / 10)
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Log.poll.debug("next poll in \(Int(fire.timeIntervalSinceNow)) s")
    }

    private func fire() {
        // Forget the due time, so the next schedule(at:) always re-arms.
        timer = nil
        due = nil
        Log.poll.info("background poll")
        poll()
    }

    private func didWake() {
        guard let due, due <= Date() else { return }
        Log.poll.info("poll overdue after wake")
        fire()
    }
}
