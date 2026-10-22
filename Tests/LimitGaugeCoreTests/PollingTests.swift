import Foundation
import Synchronization
import Testing
@testable import LimitGaugeCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func snapshot(at date: Date, percent: Int = 10) -> UsageSnapshot {
    UsageSnapshot(limits: [RateLimit(kind: .session, percent: percent, resetsAt: date.addingTimeInterval(3600))],
                  fetchedAt: date)
}

/// Polling after failures (ADR-0002 point 3): every failure is followed by exactly one poll,
/// backed off from the attempt, never seconds later and never not at all.
@MainActor
@Suite struct PollingAfterFailureTests {
    @Test func failureWithoutSnapshotSchedulesARetry() async {
        let rig = Rig(readToken: failing(.notFound))
        #expect(await rig.service.refresh(.poll).value == .failed(.noCredentials))
        #expect(rig.service.nextPoll == t0.addingTimeInterval(60 * 60))
    }

    @Test func failureWithStaleSnapshotBacksOffFromTheAttempt() async {
        let rig = Rig(usage: [.failure(.transport(URLError(.notConnectedToInternet)))],
                      seed: snapshot(at: t0.addingTimeInterval(-3 * 3600)))
        #expect(await rig.service.refresh(.poll).value == .failed(.offline))
        #expect(rig.service.nextPoll == t0.addingTimeInterval(10 * 60))
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
        #expect(rig.service.nextPoll == t0.addingTimeInterval(600 + 1200))
        clock.advance(1200)
        #expect(await rig.service.refresh(.poll).value == .fetched)
        #expect(rig.service.problem == nil)
        #expect(rig.service.nextPoll == t0.addingTimeInterval(1800 + 3600))
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

    @Test func noPollIsDueWhileARefreshRuns() async throws {
        let rig = Rig(usage: [.success(snapshot(at: t0))], readToken: { () async throws(CredentialError) -> AccessToken in
            try? await Task.sleep(for: .milliseconds(100))
            return AccessToken("a")
        }, seed: snapshot(at: t0.addingTimeInterval(-2 * 3600)))
        var dueAtStart: [Date?] = []
        rig.onChange { service in if service.isRefreshing { dueAtStart.append(service.nextPoll) } }
        _ = await rig.service.refresh(.poll).value
        #expect(dueAtStart == [nil])
        #expect(rig.service.nextPoll == t0.addingTimeInterval(3600))
    }

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

    @Test(arguments: [CredentialError.refused(exitCode: 36), .refused(exitCode: 51), .refused(exitCode: 128), .timedOut])
    func pollDoesNotRerunARefusedRead(error: CredentialError) async {
        let clock = TestClock(t0)
        let reads = Mutex(0)
        let rig = Rig(readToken: { () async throws(CredentialError) -> AccessToken in
            reads.withLock { $0 += 1 }
            throw error
        }, clock: clock)
        let problem = RefreshFailure(error).problem
        #expect(await rig.service.refresh(.poll).value == .failed(problem))
        #expect(rig.service.nextPoll == t0.addingTimeInterval(60 * 60))
        clock.advance(3600)
        #expect(await rig.service.refresh(.poll).value == .failed(problem))
        #expect(reads.withLock { $0 } == 1)
        clock.advance(121)
        #expect(await rig.service.refresh(.menuOpen).value == .failed(problem))
        #expect(reads.withLock { $0 } == 2)
    }

    @Test func successAfterARefusalLetsPollsReadAgain() async {
        let clock = TestClock(t0)
        let reads = Mutex(0)
        let rig = Rig(usage: [.success(snapshot(at: t0)), .success(snapshot(at: t0))],
                      readToken: { () async throws(CredentialError) -> AccessToken in
            if reads.withLock({ $0 += 1; return $0 }) == 1 { throw .refused(exitCode: 51) }
            return AccessToken("a")
        }, clock: clock)
        _ = await rig.service.refresh(.poll).value
        #expect(await rig.service.refresh(.refreshRow).value == .fetched)
        clock.advance(3600)
        #expect(await rig.service.refresh(.poll).value == .fetched)
        #expect(reads.withLock { $0 } == 3)
    }

    @Test func refusedRereadAfterA401StopsPollReads() async {
        let clock = TestClock(t0)
        let reads = Mutex(0)
        let rig = Rig(usage: [.failure(.unauthorized)], readToken: { () async throws(CredentialError) -> AccessToken in
            if reads.withLock({ $0 += 1; return $0 }) == 1 { return AccessToken("old") }
            throw .refused(exitCode: 51)
        }, clock: clock)
        #expect(await rig.service.refresh(.refreshRow).value == .failed(.keychainDenied))
        clock.advance(3600)
        #expect(await rig.service.refresh(.poll).value == .failed(.keychainDenied))
        #expect(reads.withLock { $0 } == 2)
    }

    @Test(arguments: [CredentialError.notFound, .failed(exitCode: 7), .launchFailed, .malformed])
    func otherReadFailuresLetPollsReadAgain(error: CredentialError) async {
        let clock = TestClock(t0)
        let reads = Mutex(0)
        let rig = Rig(readToken: { () async throws(CredentialError) -> AccessToken in
            if reads.withLock({ $0 += 1; return $0 }) == 1 { throw .refused(exitCode: 51) }
            throw error
        }, clock: clock)
        _ = await rig.service.refresh(.poll).value
        #expect(await rig.service.refresh(.refreshRow).value == .failed(RefreshFailure(error).problem))
        clock.advance(3600)
        _ = await rig.service.refresh(.poll).value
        #expect(reads.withLock { $0 } == 3)
    }

    @Test func menuOpenSoonAfterAPollThatRanNoReadReads() async {
        let clock = TestClock(t0)
        let reads = Mutex(0)
        let rig = Rig(readToken: { () async throws(CredentialError) -> AccessToken in
            reads.withLock { $0 += 1 }
            throw .refused(exitCode: 51)
        }, clock: clock)
        _ = await rig.service.refresh(.poll).value
        clock.advance(3600)
        _ = await rig.service.refresh(.poll).value
        #expect(reads.withLock { $0 } == 1)
        clock.advance(30)
        #expect(await rig.service.refresh(.menuOpen).value == .failed(.keychainDenied))
        #expect(reads.withLock { $0 } == 2)
        clock.advance(30)
        #expect(await rig.service.refresh(.menuOpen).value == .skipped)
        #expect(rig.service.nextPoll == t0.addingTimeInterval(3600 + 30 + 3600))
    }

    @Test func menuOpenSoonAfterAPollThatSentNoRequestSends() async {
        let clock = TestClock(t0)
        let rig = Rig(usage: [.failure(.unauthorized), .failure(.unauthorized)], readToken: reading("dead"), clock: clock)
        _ = await rig.service.refresh(.poll).value
        clock.advance(3600)
        _ = await rig.service.refresh(.poll).value
        #expect(rig.fetcher.usageTokens == ["dead"])
        clock.advance(30)
        #expect(await rig.service.refresh(.menuOpen).value == .failed(.tokenRejected))
        #expect(rig.fetcher.usageTokens == ["dead", "dead"])
    }
}
