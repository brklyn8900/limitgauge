import Foundation
import Testing
@testable import LimitGaugeCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func snapshot(at date: Date, percent: Int = 10) -> UsageSnapshot {
    UsageSnapshot(limits: [RateLimit(kind: .session, percent: percent, resetsAt: date.addingTimeInterval(3600))],
                  fetchedAt: date)
}

/// The review's first critical bug: after a failed fetch the next poll came 5 to 65 seconds
/// later, forever, and with no snapshot polling stopped.
@MainActor
@Suite struct PollingAfterFailureTests {
    /// Today: no snapshot, so no due time, so no poll ever again.
    @Test func failureWithoutSnapshotSchedulesARetry() async {
        let rig = Rig(readToken: failing(.notFound))
        #expect(await rig.service.refresh(.poll).value == .failed(.noCredentials))
        #expect(rig.service.nextPoll == t0.addingTimeInterval(60 * 60))      // needs the user: hourly
    }

    /// Today: due = the old snapshot's fetch time plus its interval, hours in the past.
    @Test func failureWithStaleSnapshotBacksOffFromTheAttempt() async {
        let rig = Rig(usage: [.failure(.transport(URLError(.notConnectedToInternet)))],
                      seed: snapshot(at: t0.addingTimeInterval(-3 * 3600)))
        #expect(await rig.service.refresh(.poll).value == .failed(.offline))
        #expect(rig.service.nextPoll == t0.addingTimeInterval(10 * 60))      // transient: 10 min
        #expect(rig.service.snapshot?.fetchedAt == t0.addingTimeInterval(-3 * 3600))
    }

    @Test func consecutiveFailuresBackOffAndASuccessResetsIt() async {
        let clock = TestClock(t0)
        let rig = Rig(usage: [.failure(.httpStatus(503)), .failure(.httpStatus(503)), .success(snapshot(at: t0.addingTimeInterval(1800)))],
                      seed: snapshot(at: t0.addingTimeInterval(-3 * 3600)), clock: clock)
        _ = await rig.service.refresh(.poll).value
        #expect(rig.service.nextPoll == t0.addingTimeInterval(600))
        clock.advance(600)
        _ = await rig.service.refresh(.poll).value
        #expect(rig.service.nextPoll == t0.addingTimeInterval(600 + 1200))   // second failure: 20 min
        clock.advance(1200)
        #expect(await rig.service.refresh(.poll).value == .fetched)
        #expect(rig.service.problem == nil)
        #expect(rig.service.nextPoll == t0.addingTimeInterval(1800 + 3600))  // back to headroom pacing
    }

    @Test func rateLimitWaitsHalfAnHourThenAnHour() async {
        let clock = TestClock(t0)
        let rig = Rig(usage: [.failure(.httpStatus(429)), .failure(.httpStatus(429))], clock: clock)
        _ = await rig.service.refresh(.poll).value
        #expect(rig.service.nextPoll == t0.addingTimeInterval(30 * 60))
        clock.advance(30 * 60)
        _ = await rig.service.refresh(.poll).value
        #expect(rig.service.nextPoll == t0.addingTimeInterval(90 * 60))
    }

    /// The two-minute cache measures from the last attempt, so a failing endpoint is not
    /// asked again on every menu open.
    @Test func menuOpenWithinTwoMinutesOfAFailureIsSkipped() async {
        let clock = TestClock(t0)
        let rig = Rig(clock: clock)                                           // fetcher answers 599
        _ = await rig.service.refresh(.poll).value
        clock.advance(60)
        #expect(await rig.service.refresh(.menuOpen).value == .skipped)
        clock.advance(61)
        #expect(await rig.service.refresh(.menuOpen).value == .failed(.server(599)))
        #expect(rig.fetcher.usageTokens.count == 2)
    }

    /// A dead token costs one rejected request, not one per poll. Menu open still sends it.
    @Test func pollDoesNotResendARejectedToken() async {
        let clock = TestClock(t0)
        let rig = Rig(usage: [.failure(.unauthorized), .failure(.unauthorized)], readToken: reading("dead"), clock: clock)
        #expect(await rig.service.refresh(.poll).value == .failed(.tokenRejected))
        clock.advance(3600)
        #expect(await rig.service.refresh(.poll).value == .failed(.tokenRejected))
        #expect(rig.fetcher.usageTokens == ["dead"])
        clock.advance(121)
        #expect(await rig.service.refresh(.menuOpen).value == .failed(.tokenRejected))
        #expect(rig.fetcher.usageTokens == ["dead", "dead"])
    }
}
