import Foundation
import Testing
@testable import LimitGaugeCore

/// Scripted fetcher: each call pops the next result for its endpoint.
final class ScriptedFetcher: UsageFetching, @unchecked Sendable {
    var usageResults: [Result<UsageSnapshot, UsageAPI.Error>]
    var planResults: [Result<Plan, UsageAPI.Error>]
    private(set) var usageTokens: [String] = []
    private(set) var planTokens: [String] = []
    private let lock = NSLock()

    init(usage: [Result<UsageSnapshot, UsageAPI.Error>], plan: [Result<Plan, UsageAPI.Error>] = []) {
        usageResults = usage
        planResults = plan
    }

    func fetchUsage(token: String) async throws(UsageAPI.Error) -> UsageSnapshot {
        let result: Result<UsageSnapshot, UsageAPI.Error> = lock.withLock {
            usageTokens.append(token)
            return usageResults.isEmpty ? .failure(.httpStatus(599)) : usageResults.removeFirst()
        }
        return try result.get()
    }

    func fetchPlan(token: String) async throws(UsageAPI.Error) -> Plan {
        let result: Result<Plan, UsageAPI.Error> = lock.withLock {
            planTokens.append(token)
            return planResults.isEmpty ? .failure(.httpStatus(599)) : planResults.removeFirst()
        }
        return try result.get()
    }
}

private func snapshot(at date: Date, percent: Int = 10) -> UsageSnapshot {
    UsageSnapshot(limits: [RateLimit(kind: .session, percent: percent, resetsAt: date.addingTimeInterval(3600))],
                  fetchedAt: date)
}

private func token(_ s: String) -> ClaudeCodeCredentials.Token {
    ClaudeCodeCredentials.Token(accessToken: s, expiresAt: nil)
}

@MainActor
@Suite struct UsageServiceTests {
    @Test func refreshStoresSnapshotAndPlan() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let fetcher = ScriptedFetcher(usage: [.success(snapshot(at: t0))],
                                      plan: [.success(Plan(rateLimitTier: "default_claude_max_5x"))])
        let service = UsageService(fetcher: fetcher, tokenSource: { token("a") }, now: { t0 })
        await service.refresh().value
        #expect(service.snapshot?.fetchedAt == t0)
        #expect(service.plan?.displayName == "Max 5x")
        #expect(service.planFetchedAt == t0)
        #expect(service.problem == nil)
        #expect(fetcher.usageTokens == ["a"])
        #expect(fetcher.planTokens == ["a"])
    }

    @Test func freshSnapshotIsNotRefetched() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let fetcher = ScriptedFetcher(usage: [.success(snapshot(at: t0))])
        let service = UsageService(fetcher: fetcher, tokenSource: { token("a") },
                                   snapshot: snapshot(at: t0.addingTimeInterval(-60)), now: { t0 })
        #expect(service.refreshIfStale() == nil)
        #expect(fetcher.usageTokens.isEmpty)
    }

    @Test func staleSnapshotIsRefetched() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let fetcher = ScriptedFetcher(usage: [.success(snapshot(at: t0))])
        let service = UsageService(fetcher: fetcher, tokenSource: { token("a") },
                                   snapshot: snapshot(at: t0.addingTimeInterval(-121)), now: { t0 })
        await service.refreshIfStale()?.value
        #expect(fetcher.usageTokens == ["a"])
        #expect(service.snapshot?.fetchedAt == t0)
    }

    @Test func unauthorizedRetriesOnceWithRereadToken() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let fetcher = ScriptedFetcher(usage: [.failure(.unauthorized), .success(snapshot(at: t0))])
        let tokens = Tokens(["old", "new"])
        let service = UsageService(fetcher: fetcher, tokenSource: { tokens.next() }, now: { t0 })
        await service.refresh().value
        #expect(fetcher.usageTokens == ["old", "new"])
        #expect(service.problem == nil)
        #expect(service.snapshot != nil)
    }

    /// The plan must go out with the token that worked, not the one the endpoint rejected.
    @Test func planIsFetchedWithTheRereadToken() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let fetcher = ScriptedFetcher(usage: [.failure(.unauthorized), .success(snapshot(at: t0))],
                                      plan: [.success(Plan(rateLimitTier: "default_claude_max_5x"))])
        let tokens = Tokens(["old", "new"])
        let service = UsageService(fetcher: fetcher, tokenSource: { tokens.next() }, now: { t0 })
        await service.refresh().value
        #expect(fetcher.usageTokens == ["old", "new"])
        #expect(fetcher.planTokens == ["new"])
        #expect(service.plan?.displayName == "Max 5x")
    }

    @Test func unauthorizedWithSameTokenIsRejected() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let fetcher = ScriptedFetcher(usage: [.failure(.unauthorized), .success(snapshot(at: t0))])
        let service = UsageService(fetcher: fetcher, tokenSource: { token("same") }, now: { t0 })
        await service.refresh().value
        #expect(fetcher.usageTokens == ["same"])
        #expect(service.problem == .tokenRejected)
        #expect(service.snapshot == nil)
    }

    @Test func unauthorizedTwiceIsRejected() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let fetcher = ScriptedFetcher(usage: [.failure(.unauthorized), .failure(.unauthorized)])
        let tokens = Tokens(["old", "new"])
        let service = UsageService(fetcher: fetcher, tokenSource: { tokens.next() }, now: { t0 })
        await service.refresh().value
        #expect(fetcher.usageTokens == ["old", "new"])
        #expect(service.problem == .tokenRejected)
    }

    @Test func keychainErrorsMapToProblems() async {
        let fetcher = ScriptedFetcher(usage: [])
        let missing = UsageService(fetcher: fetcher, tokenSource: { throw ClaudeCodeCredentials.Error.notFound })
        await missing.refresh().value
        #expect(missing.problem == .noCredentials)

        let denied = UsageService(fetcher: fetcher, tokenSource: { throw ClaudeCodeCredentials.Error.accessDenied })
        await denied.refresh().value
        #expect(denied.problem == .keychainDenied)
        #expect(fetcher.usageTokens.isEmpty)
    }

    @Test func failedFetchKeepsOldSnapshot() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let old = snapshot(at: t0.addingTimeInterval(-500))
        let fetcher = ScriptedFetcher(usage: [.failure(.httpStatus(503))])
        let service = UsageService(fetcher: fetcher, tokenSource: { token("a") }, snapshot: old, now: { t0 })
        await service.refresh().value
        #expect(service.snapshot == old)
        #expect(service.problem == .server(503))
    }

    @Test func planIsNotRefetchedWithinADay() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let fetcher = ScriptedFetcher(usage: [.success(snapshot(at: t0)), .success(snapshot(at: t0))],
                                      plan: [.success(Plan(rateLimitTier: "x"))])
        let service = UsageService(fetcher: fetcher, tokenSource: { token("a") },
                                   plan: Plan(rateLimitTier: "cached"), planFetchedAt: t0.addingTimeInterval(-3600),
                                   now: { t0 })
        await service.refresh().value
        #expect(fetcher.planTokens.isEmpty)
        #expect(service.plan?.rateLimitTier == "cached")
    }

    @Test func concurrentRefreshIsShared() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let fetcher = ScriptedFetcher(usage: [.success(snapshot(at: t0)), .success(snapshot(at: t0))])
        let service = UsageService(fetcher: fetcher, tokenSource: { token("a") }, now: { t0 })
        let a = service.refresh()
        let b = service.refresh()
        await a.value
        await b.value
        #expect(fetcher.usageTokens.count == 1)
    }
}

/// Hands out tokens in order, then repeats the last one.
private final class Tokens: @unchecked Sendable {
    private var values: [String]
    private let lock = NSLock()
    init(_ values: [String]) { self.values = values }
    func next() -> ClaudeCodeCredentials.Token {
        lock.lock(); defer { lock.unlock() }
        let v = values.count > 1 ? values.removeFirst() : values[0]
        return token(v)
    }
}
