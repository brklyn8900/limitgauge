import Foundation

/// How the service gets a token. Production reads the Keychain; tests return or throw.
public typealias TokenReader = @Sendable () async throws(CredentialError) -> AccessToken

public protocol UsageFetching: Sendable {
    func fetchUsage(token: AccessToken) async throws(UsageAPI.Error) -> UsageSnapshot
    func fetchPlan(token: AccessToken) async throws(UsageAPI.Error) -> Plan
}

extension UsageAPI: UsageFetching {}

/// Holds the current snapshot and plan, refreshes them, and applies the credential rules
/// from ADR-0001: read the token, retry once with a re-read token on 401, never refresh it.
@MainActor
public final class UsageService {
    public static let staleAfter: TimeInterval = 120
    public static let planMaxAge: TimeInterval = 24 * 60 * 60

    public private(set) var snapshot: UsageSnapshot?
    public private(set) var plan: Plan?
    public private(set) var planFetchedAt: Date?
    public private(set) var problem: UsageProblem?
    public private(set) var isRefreshing = false

    /// Called on the main actor after every state change.
    public var onChange: (() -> Void)?

    private let fetcher: any UsageFetching
    private let tokenSource: TokenReader
    private let now: @Sendable () -> Date
    private var inFlight: Task<Void, Never>?

    public init(
        fetcher: any UsageFetching,
        tokenSource: @escaping TokenReader = { () async throws(CredentialError) -> AccessToken in
            try await ClaudeCodeCredentials().read()
        },
        snapshot: UsageSnapshot? = nil,
        plan: Plan? = nil,
        planFetchedAt: Date? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetcher = fetcher
        self.tokenSource = tokenSource
        self.snapshot = snapshot
        self.plan = plan
        self.planFetchedAt = planFetchedAt
        self.now = now
    }

    public var snapshotAge: TimeInterval? {
        snapshot.map { now().timeIntervalSince($0.fetchedAt) }
    }

    /// Fetches only when there is no snapshot or it is older than `staleAfter`.
    @discardableResult
    public func refreshIfStale() -> Task<Void, Never>? {
        if let age = snapshotAge, age < Self.staleAfter { return nil }
        return refresh()
    }

    /// Fetches now. A refresh already in flight is shared, not duplicated.
    @discardableResult
    public func refresh() -> Task<Void, Never> {
        if let inFlight { return inFlight }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh()
        }
        inFlight = task
        return task
    }

    private func performRefresh() async {
        isRefreshing = true
        onChange?()
        defer {
            isRefreshing = false
            inFlight = nil
            onChange?()
        }

        let working: AccessToken
        do {
            working = try await fetchUsage()
            problem = nil
        } catch {
            problem = error.problem
            Log.fetch.error("usage fetch failed: \(error.logDescription, privacy: .public)")
            return
        }

        await refreshPlanIfStale(token: working)
    }

    private func refreshPlanIfStale(token: AccessToken) async {
        if let planFetchedAt, plan != nil, now().timeIntervalSince(planFetchedAt) < Self.planMaxAge { return }
        // The plan row is secondary; a failure here leaves the old value and no problem.
        if let fetched = try? await fetcher.fetchPlan(token: token) {
            plan = fetched
            planFetchedAt = now()
        }
    }

    /// ADR-0001: read the token; on 401 re-read once and retry once if it changed. Stores the
    /// snapshot and returns the token that succeeded, so the plan never goes out with a
    /// rejected one.
    private func fetchUsage() async throws(RefreshFailure) -> AccessToken {
        let token: AccessToken
        do {
            token = try await tokenSource()
        } catch {
            throw RefreshFailure(error)
        }
        do {
            snapshot = try await fetcher.fetchUsage(token: token)
            return token
        } catch .unauthorized {
            // Claude Code may have rotated the token since the read. One re-read, one retry.
            let fresh: AccessToken
            do {
                fresh = try await tokenSource()
            } catch {
                throw RefreshFailure(error)
            }
            guard fresh != token else { throw .tokenUnchanged }
            do {
                snapshot = try await fetcher.fetchUsage(token: fresh)
                return fresh
            } catch {
                throw RefreshFailure(error)
            }
        } catch {
            throw RefreshFailure(error)
        }
    }
}
