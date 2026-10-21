import Foundation

/// How the service gets a token. Production reads the Keychain; tests return or throw.
public typealias TokenReader = @Sendable () async throws(CredentialError) -> AccessToken

public protocol UsageFetching: Sendable {
    func fetchUsage(token: AccessToken) async throws(UsageAPI.Error) -> UsageSnapshot
    func fetchPlan(token: AccessToken) async throws(UsageAPI.Error) -> Plan
}

extension UsageAPI: UsageFetching {}

/// Why a refresh was asked for. The service, not the caller, decides what each reason means,
/// so the two-minute cache lives in one tested place.
public enum RefreshReason: String, Sendable {
    /// App launch and menu open: fetch only if the snapshot is over two minutes old
    /// (ADR-0002 point 1).
    case launch, menuOpen
    /// The Refresh row: always fetch.
    case refreshRow
    /// The poll timer firing at `nextPoll`: always fetch.
    case poll
}

/// What one refresh did. Every caller of a shared in-flight refresh gets the same value.
public enum RefreshOutcome: Equatable, Sendable {
    /// A new snapshot is stored.
    case fetched
    /// Nothing new; the previous snapshot, if any, stays.
    case failed(UsageProblem)
    /// The reason did not call for a fetch (the two-minute cache).
    case skipped
}

/// Keeps the usage numbers current and warns about them. One refresh, from any trigger, runs
/// the whole sequence: read the token off the main actor, fetch with ADR-0001's one re-read on
/// 401, fetch the plan with the token that worked, store the result, log a failure once,
/// deliver due warnings, then tell the app. Callers say why they want a refresh and read the
/// state; they never sequence any of that themselves.
@MainActor
public final class UsageService {
    public static let staleAfter: TimeInterval = 120
    public static let planMaxAge: TimeInterval = 24 * 60 * 60

    /// The last good snapshot. Survives failures and relaunches.
    public private(set) var snapshot: UsageSnapshot?
    /// Set while the last refresh failed; cleared by a success.
    public private(set) var problem: UsageProblem?

    public var plan: Plan? { fetchedPlan?.plan }
    public var isRefreshing: Bool { inFlight != nil }

    /// When the next background poll is due: the snapshot's fetch time plus the headroom
    /// interval (ADR-0002). Nil without a snapshot.
    public var nextPoll: Date? {
        snapshot.map { $0.fetchedAt.addingTimeInterval(PollScheduler.nextInterval(snapshot: $0, thresholds: thresholds(), fired: fired)) }
    }

    /// Called on the main actor when a refresh starts, when it ends or is skipped, and after a
    /// settings change. The app redraws and re-arms its timer from `nextPoll`; nothing more.
    public var onChange: (@MainActor () -> Void)?

    private var fetchedPlan: FetchedPlan?
    /// Warnings already posted, per window (mirrors the store).
    private var fired: Set<WarningKey>
    private var inFlight: Task<RefreshOutcome, Never>?

    private let readToken: TokenReader
    private let fetcher: any UsageFetching
    private let store: SnapshotStore
    private let delivery: any WarningDelivery
    private let thresholds: @MainActor () -> WarningThresholds
    private let now: @Sendable () -> Date

    /// Snapshot, plan and posted warnings load from `store`, the one place they persist.
    public init(
        readToken: @escaping TokenReader,
        fetcher: any UsageFetching,
        store: SnapshotStore,
        delivery: any WarningDelivery,
        thresholds: @escaping @MainActor () -> WarningThresholds,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.readToken = readToken
        self.fetcher = fetcher
        self.store = store
        self.delivery = delivery
        self.thresholds = thresholds
        self.now = now
        snapshot = store.loadSnapshot()
        fetchedPlan = store.loadPlan()
        fired = store.loadFiredWarnings()
    }

    /// Starts a refresh if `reason` calls for one, or joins the one in flight. Fire and forget
    /// from the app; tests await `.value`.
    @discardableResult
    public func refresh(_ reason: RefreshReason) -> Task<RefreshOutcome, Never> {
        if let inFlight { return inFlight }
        guard shouldFetch(for: reason) else {
            // A skipped launch still arms the app's timer; a redraw on menu open is harmless.
            onChange?()
            return Task { .skipped }
        }
        let task = Task { await self.perform() }
        inFlight = task
        onChange?()
        return task
    }

    /// Thresholds changed. A raised threshold re-arms its warning, a lowered one may make a
    /// warning due, and the pace follows. Tests await `.value`.
    @discardableResult
    public func settingsChanged() -> Task<Void, Never> {
        if let snapshot {
            let past = snapshot.limits.filter { thresholds().isPast($0) }.map { WarningKey($0) }
            setFired(fired.intersection(past))
        }
        onChange?()
        return Task {
            await self.deliverDueWarnings()
            self.onChange?()
        }
    }

    // MARK: Private

    private func shouldFetch(for reason: RefreshReason) -> Bool {
        switch reason {
        case .refreshRow, .poll:
            return true
        case .launch, .menuOpen:
            guard let snapshot else { return true }
            return now().timeIntervalSince(snapshot.fetchedAt) >= Self.staleAfter
        }
    }

    /// The whole refresh. Applies every effect once, before the task completes, so a caller
    /// that awaits the outcome sees a finished state.
    private func perform() async -> RefreshOutcome {
        let outcome: RefreshOutcome
        do {
            let working = try await fetchUsage()
            problem = nil
            if let snapshot { store.save(snapshot: snapshot) }
            if let plan = await planIfStale(token: working) {
                fetchedPlan = plan
                store.save(plan: plan)
            }
            outcome = .fetched
        } catch {
            problem = error.problem
            Log.fetch.error("usage fetch failed: \(error.logDescription, privacy: .public)")
            outcome = .failed(error.problem)
        }
        await deliverDueWarnings()
        inFlight = nil
        onChange?()
        return outcome
    }

    /// ADR-0001: read the token; on 401 re-read once and retry once if it changed. Stores the
    /// snapshot and returns the token that succeeded, so the plan never goes out with a
    /// rejected one.
    private func fetchUsage() async throws(RefreshFailure) -> AccessToken {
        let token: AccessToken
        do {
            token = try await readToken()
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
                fresh = try await readToken()
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

    /// The plan row is secondary: a failure keeps the old value, sets no problem, and logs at
    /// debug level only.
    private func planIfStale(token: AccessToken) async -> FetchedPlan? {
        if let fetchedPlan, now().timeIntervalSince(fetchedPlan.fetchedAt) < Self.planMaxAge { return nil }
        do {
            return FetchedPlan(plan: try await fetcher.fetchPlan(token: token), fetchedAt: now())
        } catch {
            Log.fetch.debug("plan fetch failed: \(RefreshFailure(error).logDescription, privacy: .public)")
            return nil
        }
    }

    /// Posts warnings for limits newly past their threshold in this window.
    private func deliverDueWarnings() async {
        guard let snapshot else { return }
        let outcome = WarningTracker.evaluate(snapshot: snapshot, thresholds: thresholds(), fired: fired)
        setFired(outcome.fired)
        for limit in outcome.toNotify {
            _ = await delivery.deliver(limit, now: now())
        }
    }

    private func setFired(_ new: Set<WarningKey>) {
        guard new != fired else { return }
        fired = new
        store.save(firedWarnings: new)
    }
}
