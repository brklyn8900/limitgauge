import Foundation
import Testing
@testable import LimitGaugeCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let sessionReset = now.addingTimeInterval(3600)
private let weekReset = now.addingTimeInterval(36 * 3600)

private func snap(session: Int, week: Int, fable: Int) -> UsageSnapshot {
    UsageSnapshot(limits: [
        RateLimit(kind: .session, percent: session, resetsAt: sessionReset),
        RateLimit(kind: .weeklyAll, percent: week, resetsAt: weekReset),
        RateLimit(kind: .weeklyScoped, percent: fable, resetsAt: weekReset, scopeName: "Fable"),
    ], fetchedAt: now)
}

@Suite struct PollSchedulerTests {
    let t = WarningThresholds.default // 80 / 85 / 80

    @Test func intervalBands() {
        #expect(PollScheduler.interval(for: 41) == 60 * 60)
        #expect(PollScheduler.interval(for: 40) == 30 * 60)
        #expect(PollScheduler.interval(for: 15) == 30 * 60)
        #expect(PollScheduler.interval(for: 14) == 10 * 60)
        #expect(PollScheduler.interval(for: -5) == 10 * 60)
    }

    @Test func leastHeadroomWins() {
        // Headrooms 50, 15, 40: the week picks 30 min.
        #expect(PollScheduler.nextInterval(snapshot: snap(session: 30, week: 70, fable: 40), thresholds: t, fired: []) == 30 * 60)
        // All far.
        #expect(PollScheduler.nextInterval(snapshot: snap(session: 10, week: 20, fable: 10), thresholds: t, fired: []) == 60 * 60)
        // Session close.
        #expect(PollScheduler.nextInterval(snapshot: snap(session: 70, week: 20, fable: 10), thresholds: t, fired: []) == 10 * 60)
    }

    @Test func firedLimitsAreExcluded() {
        let s = snap(session: 90, week: 20, fable: 10)
        #expect(PollScheduler.nextInterval(snapshot: s, thresholds: t, fired: []) == 10 * 60)
        let fired: Set<WarningKey> = [WarningKey(s.limits[0])]
        #expect(PollScheduler.nextInterval(snapshot: s, thresholds: t, fired: fired) == 60 * 60)
    }

    @Test func noSnapshotIsHourly() {
        #expect(PollScheduler.nextInterval(snapshot: nil, thresholds: t, fired: []) == 60 * 60)
    }
}

@Suite struct WarningTrackerTests {
    let t = WarningThresholds.default

    @Test func firesOncePerWindow() {
        let s = snap(session: 85, week: 20, fable: 10)
        let first = WarningTracker.evaluate(snapshot: s, thresholds: t, fired: [])
        #expect(first.toNotify.map(\.kind) == [.session])
        #expect(first.fired.count == 1)

        let again = WarningTracker.evaluate(snapshot: snap(session: 95, week: 20, fable: 10), thresholds: t, fired: first.fired)
        #expect(again.toNotify.isEmpty)
        #expect(again.fired == first.fired)
    }

    @Test func newWindowRearms() {
        let s = snap(session: 85, week: 20, fable: 10)
        let first = WarningTracker.evaluate(snapshot: s, thresholds: t, fired: [])

        var next = s
        next.limits[0].resetsAt = sessionReset.addingTimeInterval(5 * 3600)
        next.limits[0].percent = 82
        let second = WarningTracker.evaluate(snapshot: next, thresholds: t, fired: first.fired)
        #expect(second.toNotify.map(\.kind) == [.session])
        // The old window's key is gone, the new one is in.
        #expect(second.fired.count == 1)
        #expect(!second.fired.contains(WarningKey(s.limits[0])))
    }

    @Test func belowThresholdFiresNothing() {
        let out = WarningTracker.evaluate(snapshot: snap(session: 79, week: 84, fable: 79), thresholds: t, fired: [])
        #expect(out.toNotify.isEmpty)
        #expect(out.fired.isEmpty)
    }

    @Test func severalAtOnce() {
        let out = WarningTracker.evaluate(snapshot: snap(session: 80, week: 85, fable: 80), thresholds: t, fired: [])
        #expect(out.toNotify.count == 3)
        #expect(out.fired.count == 3)
    }

    @Test func scopedKeysIncludeTheScope() {
        let a = RateLimit(kind: .weeklyScoped, percent: 1, resetsAt: weekReset, scopeName: "Fable")
        let b = RateLimit(kind: .weeklyScoped, percent: 1, resetsAt: weekReset, scopeName: "Opus")
        #expect(WarningKey(a) != WarningKey(b))
    }
}
