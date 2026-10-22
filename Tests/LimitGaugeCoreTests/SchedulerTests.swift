import Foundation
import Testing
@testable import LimitGaugeCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let sessionReset = now.addingTimeInterval(3600)
private let weekReset = now.addingTimeInterval(36 * 3600)

private func snap(session: Int, week: Int, fable: Int, fetchedAt: Date = now) -> UsageSnapshot {
    UsageSnapshot(limits: [
        RateLimit(kind: .session, percent: session, resetsAt: sessionReset),
        RateLimit(kind: .weeklyAll, percent: week, resetsAt: weekReset),
        RateLimit(kind: .weeklyScoped, percent: fable, resetsAt: weekReset, scopeName: "Fable"),
    ], fetchedAt: fetchedAt)
}

private func streak(_ count: Int, at date: Date, _ problem: UsageProblem = .offline) -> FailureStreak {
    FailureStreak(problem: problem, count: count, lastAttempt: date)
}

@Suite struct PollSchedulerTests {
    let t = WarningThresholds.default // 80 / 85 / 80

    @Test func intervalBands() {
        #expect(PollScheduler.interval(for: 41) == 60 * 60)
        #expect(PollScheduler.interval(for: 40) == 30 * 60)
        #expect(PollScheduler.interval(for: 15) == 30 * 60)
        #expect(PollScheduler.interval(for: 14) == 10 * 60)
        #expect(PollScheduler.interval(for: 1) == 10 * 60)
    }

    @Test func leastHeadroomAmongLimitsBelowThreshold() {
        // Headrooms 50, 15, 40: the week picks 30 min.
        #expect(PollScheduler.nextPoll(snapshot: snap(session: 30, week: 70, fable: 40), failures: nil, thresholds: t) == now + 30 * 60)
        #expect(PollScheduler.nextPoll(snapshot: snap(session: 10, week: 20, fable: 10), failures: nil, thresholds: t) == now + 60 * 60)
        #expect(PollScheduler.nextPoll(snapshot: snap(session: 70, week: 20, fable: 10), failures: nil, thresholds: t) == now + 10 * 60)
    }

    /// A limit past its threshold leaves the pace whether or not its warning was delivered, so
    /// an undelivered warning cannot hold polling at ten minutes.
    @Test func pastLimitLeavesThePace() {
        let s = UsageSnapshot(limits: [
            RateLimit(kind: .session, percent: 90, resetsAt: now + 5 * 3600),
            RateLimit(kind: .weeklyAll, percent: 20, resetsAt: weekReset),
        ], fetchedAt: now)
        #expect(PollScheduler.nextPoll(snapshot: s, failures: nil, thresholds: t) == now + 60 * 60)
    }

    /// One look a minute after a past limit's window resets, if that is sooner than the pace.
    @Test func pastLimitsResetPullsThePollIn() {
        let s = UsageSnapshot(limits: [RateLimit(kind: .session, percent: 90, resetsAt: now + 20 * 60)], fetchedAt: now)
        #expect(PollScheduler.nextPoll(snapshot: s, failures: nil, thresholds: t) == now + 21 * 60)
    }

    @Test func nothingBeforeTheFirstAttempt() {
        #expect(PollScheduler.nextPoll(snapshot: nil, failures: nil, thresholds: t) == nil)
    }

    @Test func failureWithoutSnapshotBacksOff() {
        #expect(PollScheduler.nextPoll(snapshot: nil, failures: streak(1, at: now), thresholds: t) == now + 10 * 60)
    }

    /// A stale snapshot's pace is in the past; the backoff from the attempt decides.
    @Test func failureWithStaleSnapshotBacksOffFromTheAttempt() {
        let old = snap(session: 70, week: 20, fable: 10, fetchedAt: now - 3 * 3600)
        #expect(PollScheduler.nextPoll(snapshot: old, failures: streak(1, at: now), thresholds: t) == now + 10 * 60)
    }

    /// Far from every threshold, a fresh snapshot's hourly pace wins over the 10-minute retry.
    @Test func failureNeverPollsFasterThanSuccess() {
        let fresh = snap(session: 10, week: 20, fable: 10)
        #expect(PollScheduler.nextPoll(snapshot: fresh, failures: streak(1, at: now + 60), thresholds: t) == now + 60 * 60)
    }

    @Test func backoffByClass() {
        #expect((1...6).map { PollScheduler.backoff(.transient, afterFailures: $0) / 60 } == [10, 20, 40, 60, 60, 60])
        #expect((1...3).map { PollScheduler.backoff(.rateLimited, afterFailures: $0) / 60 } == [30, 60, 60])
        #expect((1...3).map { PollScheduler.backoff(.needsUser, afterFailures: $0) / 60 } == [60, 60, 60])
    }

    @Test func problemsMapToRetryClasses() {
        #expect(UsageProblem.server(429).retry == .rateLimited)
        #expect(UsageProblem.server(503).retry == .transient)
        #expect(UsageProblem.offline.retry == .transient)
        #expect(UsageProblem.keychainLocked.retry == .needsUser)
        #expect(UsageProblem.keychainDenied.retry == .needsUser)
        #expect(UsageProblem.keychainTimedOut.retry == .needsUser)
        #expect(UsageProblem.tokenRejected.retry == .needsUser)
        #expect(UsageProblem.noCredentials.retry == .needsUser)
    }

    /// The loop guard as a property: no input yields a due time within a minute of the last
    /// attempt.
    @Test func neverWithinAMinuteOfTheLastAttempt() {
        let problems: [UsageProblem] = [.offline, .server(429), .server(503), .tokenRejected, .keychainDenied]
        for session in stride(from: 0, through: 100, by: 5) {
            for reset in [-3600.0, -1, 0, 1, 59, 61, 600, 18000] {
                let s = UsageSnapshot(limits: [RateLimit(kind: .session, percent: session, resetsAt: now + reset)], fetchedAt: now)
                let streaks = [nil] + problems.flatMap { p in [streak(1, at: now, p), streak(9, at: now, p)] }
                for failures in streaks {
                    let due = PollScheduler.nextPoll(snapshot: s, failures: failures, thresholds: t)
                    #expect(due.map { $0.timeIntervalSince(now) >= 60 } == true)
                }
            }
        }
    }
}

@Suite struct WarningTrackerTests {
    let t = WarningThresholds.default

    /// Due until delivered; the caller marks it fired, and then it is due no more.
    @Test func firesOncePerWindow() {
        let s = snap(session: 85, week: 20, fable: 10)
        let first = WarningTracker.evaluate(snapshot: s, thresholds: t, fired: [], at: now)
        #expect(first.due.map(\.kind) == [.session])
        #expect(first.fired.isEmpty)

        let delivered: Set<WarningKey> = [WarningKey(s.limits[0])]
        let again = WarningTracker.evaluate(snapshot: snap(session: 95, week: 20, fable: 10), thresholds: t, fired: delivered, at: now)
        #expect(again.due.isEmpty)
        #expect(again.fired == delivered)
    }

    @Test func newWindowRearms() {
        let s = snap(session: 85, week: 20, fable: 10)
        let delivered: Set<WarningKey> = [WarningKey(s.limits[0])]

        var next = s
        next.limits[0].resetsAt = sessionReset.addingTimeInterval(5 * 3600)
        next.limits[0].percent = 82
        let second = WarningTracker.evaluate(snapshot: next, thresholds: t, fired: delivered, at: now)
        #expect(second.due.map(\.kind) == [.session])
        // The old window's key is gone.
        #expect(second.fired.isEmpty)
    }

    @Test func belowThresholdFiresNothing() {
        let out = WarningTracker.evaluate(snapshot: snap(session: 79, week: 84, fable: 79), thresholds: t, fired: [], at: now)
        #expect(out.due.isEmpty)
        #expect(out.fired.isEmpty)
    }

    @Test func severalAtOnce() {
        let out = WarningTracker.evaluate(snapshot: snap(session: 80, week: 85, fable: 80), thresholds: t, fired: [], at: now)
        #expect(out.due.count == 3)
    }

    /// A limit whose window has reset since the fetch is unknown and never due.
    @Test func limitPastItsResetIsNotDue() {
        let s = snap(session: 90, week: 20, fable: 10)
        let out = WarningTracker.evaluate(snapshot: s, thresholds: t, fired: [], at: sessionReset.addingTimeInterval(1))
        #expect(out.due.isEmpty)
    }

    @Test func scopedKeysIncludeTheScope() {
        let a = RateLimit(kind: .weeklyScoped, percent: 1, resetsAt: weekReset, scopeName: "Fable")
        let b = RateLimit(kind: .weeklyScoped, percent: 1, resetsAt: weekReset, scopeName: "Opus")
        #expect(WarningKey(a) != WarningKey(b))
    }
}

@Suite struct WarningKeyTests {
    /// The endpoint shifts `resets_at` by under a second between fetches in one window. Both
    /// values were captured from the live endpoint on 2026-10-21.
    @Test func jitteredResetsShareAKey() throws {
        let a = try #require(ISO8601.date("2026-10-21T21:10:00.462+00:00"))
        let b = try #require(ISO8601.date("2026-10-21T21:09:59.776+00:00"))
        let first = WarningKey(RateLimit(kind: .weeklyScoped, percent: 83, resetsAt: a, scopeName: "Fable"))
        let second = WarningKey(RateLimit(kind: .weeklyScoped, percent: 83, resetsAt: b, scopeName: "Fable"))
        #expect(first == second)
    }

    @Test func aDifferentWindowIsADifferentKey() {
        let a = WarningKey(RateLimit(kind: .session, percent: 90, resetsAt: weekReset))
        let b = WarningKey(RateLimit(kind: .session, percent: 90, resetsAt: weekReset.addingTimeInterval(5 * 3600)))
        #expect(a != b)
    }

    /// Keys saved before rounding existed decode rounded, so the upgrade does not repeat a
    /// warning already posted in the current window.
    @Test func keysPersistedBeforeRoundingDecodeRounded() throws {
        let raw = try #require(ISO8601.date("2026-10-21T21:10:00.462+00:00"))
        let json = try JSONEncoder().encode(LegacyKey(kind: "session", resetsAt: raw))
        let decoded = try JSONDecoder().decode(WarningKey.self, from: json)
        #expect(decoded == WarningKey(RateLimit(kind: .session, percent: 90, resetsAt: raw)))
        #expect(decoded.resetsAt.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0)
    }
}

/// A key as the synthesized encoder wrote it before rounding.
private struct LegacyKey: Encodable {
    var kind: String
    var resetsAt: Date
}

@Suite struct WarningDotTests {
    let t = WarningThresholds.default

    /// The dot goes out by itself at the first reset of a past limit, which during a failure
    /// streak can be up to an hour before the next refresh redraws it (ADR-0005 point 4).
    @Test func dotGoesOutAtTheEarliestPastReset() {
        let s = UsageSnapshot(limits: [
            RateLimit(kind: .session, percent: 90, resetsAt: now + 20 * 60),
            RateLimit(kind: .weeklyAll, percent: 95, resetsAt: weekReset),
            RateLimit(kind: .weeklyScoped, percent: 10, resetsAt: now + 5 * 60, scopeName: "Fable"),
        ], fetchedAt: now)
        #expect(t.earliestPastReset(in: s, at: now) == now + 20 * 60)
        #expect(t.earliestPastReset(in: s, at: now + 20 * 60) == weekReset)
    }

    @Test func noPastLimitNoRedraw() {
        #expect(t.earliestPastReset(in: snap(session: 10, week: 20, fable: 10), at: now) == nil)
    }
}
