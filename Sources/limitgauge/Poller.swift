import AppKit
import LimitGaugeCore

/// Holds the one-shot timer for the next background poll (ADR-0002). It computes nothing:
/// the due time comes from `UsageService.nextPoll`, which is always at least a minute after
/// the last attempt, so a due time in the past fires once and moves on.
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
            // A timer's clock pauses during sleep, so its fire date slips by the sleep's length.
            // Re-arming at the same date fixes that, and a date that passed during sleep fires
            // at once (ADR-0002 point 5).
            MainActor.assumeIsolated { self?.rearm() }
        }
    }

    func schedule(at due: Date?) {
        guard due != self.due else { return }
        timer?.invalidate()
        timer = nil
        self.due = due
        guard let due else { return }
        let t = Timer(fire: due, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        t.tolerance = min(60, max(0, due.timeIntervalSinceNow) / 10)
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Log.poll.debug("next poll in \(Int(due.timeIntervalSinceNow)) s")
    }

    private func fire() {
        // Forget the due time, so the next schedule(at:) always re-arms.
        timer = nil
        due = nil
        Log.poll.info("background poll")
        poll()
    }

    private func rearm() {
        let due = self.due
        self.due = nil
        schedule(at: due)
    }
}
