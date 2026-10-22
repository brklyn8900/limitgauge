import Foundation
import Testing
@testable import LimitGaugeCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func snapshot(at date: Date, percent: Int = 10, resetsAt: Date? = nil) -> UsageSnapshot {
    UsageSnapshot(limits: [RateLimit(kind: .session, percent: percent, resetsAt: resetsAt ?? date.addingTimeInterval(3600))],
                  fetchedAt: date)
}

@MainActor
@Suite struct UsageServiceTests {
    @Test func refreshStoresSnapshotAndPlan() async {
        let rig = Rig(usage: [.success(snapshot(at: t0))], plan: [.success(Plan(rateLimitTier: "default_claude_max_5x"))])
        #expect(await rig.service.refresh(.refreshRow).value == .fetched)
        #expect(rig.service.snapshot?.fetchedAt == t0)
        #expect(rig.service.plan?.displayName == "Max 5x")
        #expect(rig.service.problem == nil)
        #expect(rig.fetcher.usageTokens == ["a"])
        #expect(rig.fetcher.planTokens == ["a"])
    }

    @Test func fetchedSnapshotIsStoredBeforeTheOutcome() async {
        let rig = Rig(usage: [.success(snapshot(at: t0))], plan: [.success(Plan(rateLimitTier: "x"))])
        #expect(await rig.service.refresh(.launch).value == .fetched)
        #expect(rig.store.loadSnapshot() == rig.service.snapshot)
        #expect(rig.store.loadPlan()?.plan == Plan(rateLimitTier: "x"))
    }

    @Test func freshSnapshotIsNotRefetched() async {
        let rig = Rig(usage: [.success(snapshot(at: t0))], seed: snapshot(at: t0.addingTimeInterval(-60)))
        #expect(await rig.service.refresh(.menuOpen).value == .skipped)
        #expect(rig.fetcher.usageTokens.isEmpty)
    }

    @Test func staleSnapshotIsRefetched() async {
        let rig = Rig(usage: [.success(snapshot(at: t0))], seed: snapshot(at: t0.addingTimeInterval(-121)))
        #expect(await rig.service.refresh(.menuOpen).value == .fetched)
        #expect(rig.fetcher.usageTokens == ["a"])
        #expect(rig.service.snapshot?.fetchedAt == t0)
    }

    @Test func skippedLaunchStillNotifies() async {
        let rig = Rig(seed: snapshot(at: t0.addingTimeInterval(-30)))
        var changes = 0
        rig.service.onChange = { changes += 1 }
        #expect(await rig.service.refresh(.launch).value == .skipped)
        #expect(changes == 1)
    }

    @Test func unauthorizedRetriesOnceWithRereadToken() async {
        let tokens = Tokens(["old", "new"])
        let rig = Rig(usage: [.failure(.unauthorized), .success(snapshot(at: t0))], readToken: { tokens.nextOrLast() })
        #expect(await rig.service.refresh(.refreshRow).value == .fetched)
        #expect(rig.fetcher.usageTokens == ["old", "new"])
        #expect(rig.service.problem == nil)
    }

    @Test func planIsFetchedWithTheRereadToken() async {
        let tokens = Tokens(["old", "new"])
        let rig = Rig(usage: [.failure(.unauthorized), .success(snapshot(at: t0))],
                      plan: [.success(Plan(rateLimitTier: "default_claude_max_5x"))], readToken: { tokens.nextOrLast() })
        _ = await rig.service.refresh(.refreshRow).value
        #expect(rig.fetcher.usageTokens == ["old", "new"])
        #expect(rig.fetcher.planTokens == ["new"])
        #expect(rig.service.plan?.displayName == "Max 5x")
    }

    @Test func unauthorizedWithSameTokenIsRejected() async {
        let rig = Rig(usage: [.failure(.unauthorized), .success(snapshot(at: t0))], readToken: reading("same"))
        #expect(await rig.service.refresh(.refreshRow).value == .failed(.tokenRejected))
        #expect(rig.fetcher.usageTokens == ["same"])
        #expect(rig.service.snapshot == nil)
    }

    @Test func unauthorizedTwiceIsRejected() async {
        let tokens = Tokens(["old", "new"])
        let rig = Rig(usage: [.failure(.unauthorized), .failure(.unauthorized)], readToken: { tokens.nextOrLast() })
        #expect(await rig.service.refresh(.refreshRow).value == .failed(.tokenRejected))
        #expect(rig.fetcher.usageTokens == ["old", "new"])
    }

    @Test func keychainErrorsMapToProblems() async {
        let missing = Rig(readToken: failing(.notFound))
        #expect(await missing.service.refresh(.refreshRow).value == .failed(.noCredentials))
        let denied = Rig(readToken: failing(.refused(exitCode: 36)))
        #expect(await denied.service.refresh(.refreshRow).value == .failed(.keychainLocked))
        #expect(denied.fetcher.usageTokens.isEmpty)
    }

    @Test func failedFetchKeepsOldSnapshot() async {
        let old = snapshot(at: t0.addingTimeInterval(-500))
        let rig = Rig(usage: [.failure(.httpStatus(503))], seed: old)
        #expect(await rig.service.refresh(.refreshRow).value == .failed(.server(503)))
        #expect(rig.service.snapshot == old)
        #expect(rig.service.problem == .server(503))
    }

    @Test func planIsNotRefetchedWithinADay() async {
        let rig = Rig(usage: [.success(snapshot(at: t0))], plan: [.success(Plan(rateLimitTier: "x"))],
                      seedPlan: Plan(rateLimitTier: "cached"))
        _ = await rig.service.refresh(.refreshRow).value
        #expect(rig.fetcher.planTokens.isEmpty)
        #expect(rig.service.plan?.rateLimitTier == "cached")
    }

    @Test func concurrentRefreshIsSharedWithOneOutcome() async {
        let rig = Rig(usage: [.success(snapshot(at: t0)), .success(snapshot(at: t0))])
        let a = rig.service.refresh(.menuOpen)
        let b = rig.service.refresh(.poll)
        #expect(await a.value == .fetched)
        #expect(await b.value == .fetched)
        #expect(rig.fetcher.usageTokens.count == 1)
    }

    @Test func aRefreshNotifiesAtStartAndEnd() async {
        let rig = Rig(usage: [.success(snapshot(at: t0))])
        var refreshing: [Bool] = []
        rig.onChange { service in refreshing.append(service.isRefreshing) }
        _ = await rig.service.refresh(.refreshRow).value
        #expect(refreshing == [true, false])
    }

    @Test func warningIsPostedOncePerWindow() async {
        let delivery = RecordingDelivery()
        let rig = Rig(usage: [.success(snapshot(at: t0, percent: 90)), .success(snapshot(at: t0, percent: 95))],
                      delivery: delivery)
        _ = await rig.service.refresh(.refreshRow).value
        _ = await rig.service.refresh(.refreshRow).value
        #expect(delivery.offered.map(\.percent) == [90])
        #expect(rig.store.loadFiredWarnings().count == 1)
    }
}
