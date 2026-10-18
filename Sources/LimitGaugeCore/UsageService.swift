import Foundation

/// What the menu shows instead of numbers when a fetch cannot produce them.
public enum UsageProblem: Equatable, Sendable {
    /// No Keychain item: Claude Code has never signed in on this machine.
    case noCredentials
    /// The Keychain prompt was denied.
    case keychainDenied
    /// The token is expired or was rejected twice.
    case tokenRejected
    case offline
    case server(Int)
    case decoding

    public var message: String {
        switch self {
        case .noCredentials: return "Sign in with Claude Code to see usage."
        case .keychainDenied: return "Keychain access was denied. Choose Always Allow when asked."
        case .tokenRejected: return "Token expired. Run claude in a terminal to sign in again."
        case .offline: return "Could not reach the usage endpoint."
        case .server(let status): return "Usage endpoint returned \(status)."
        case .decoding: return "Usage response could not be read."
        }
    }
}

public protocol UsageFetching: Sendable {
    func fetchUsage(token: String) async throws(UsageAPI.Error) -> UsageSnapshot
    func fetchPlan(token: String) async throws(UsageAPI.Error) -> Plan
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
    private let tokenSource: @Sendable () throws -> ClaudeCodeCredentials.Token
    private let now: @Sendable () -> Date
    private var inFlight: Task<Void, Never>?

    public init(
        fetcher: any UsageFetching,
        tokenSource: @escaping @Sendable () throws -> ClaudeCodeCredentials.Token = { try ClaudeCodeCredentials.read() },
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

        let token: ClaudeCodeCredentials.Token
        do {
            token = try tokenSource()
        } catch {
            problem = Self.problem(for: error)
            return
        }

        do {
            snapshot = try await fetcher.fetchUsage(token: token.accessToken)
            problem = nil
        } catch .unauthorized {
            // Claude Code may have rotated the token since the read. One re-read, one retry.
            guard let fresh = try? tokenSource(), fresh.accessToken != token.accessToken else {
                problem = .tokenRejected
                return
            }
            do {
                snapshot = try await fetcher.fetchUsage(token: fresh.accessToken)
                problem = nil
            } catch {
                if case .unauthorized = error {
                    problem = .tokenRejected
                } else {
                    problem = Self.problem(for: error)
                }
                return
            }
        } catch {
            problem = Self.problem(for: error)
            return
        }

        await refreshPlanIfStale(token: token.accessToken)
    }

    private func refreshPlanIfStale(token: String) async {
        if let planFetchedAt, plan != nil, now().timeIntervalSince(planFetchedAt) < Self.planMaxAge { return }
        // The plan row is secondary; a failure here leaves the old value and no problem.
        if let fetched = try? await fetcher.fetchPlan(token: token) {
            plan = fetched
            planFetchedAt = now()
        }
    }

    private static func problem(for error: any Error) -> UsageProblem {
        switch error {
        case ClaudeCodeCredentials.Error.notFound: return .noCredentials
        case ClaudeCodeCredentials.Error.accessDenied: return .keychainDenied
        case is ClaudeCodeCredentials.Error: return .noCredentials
        case UsageAPI.Error.unauthorized: return .tokenRejected
        case UsageAPI.Error.httpStatus(let status): return .server(status)
        case UsageAPI.Error.decoding: return .decoding
        case UsageAPI.Error.transport: return .offline
        default: return .offline
        }
    }
}
