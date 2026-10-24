import Foundation

public typealias TokenReader = @Sendable () async throws(CredentialError) -> AccessToken

public protocol UsageFetching: Sendable {
    func fetchUsage(token: AccessToken) async throws(UsageAPI.Error) -> UsageSnapshot
    func fetchPlan(token: AccessToken) async throws(UsageAPI.Error) -> Plan
}

extension UsageAPI: UsageFetching {}

/// Why a refresh was asked for. The service, not the caller, decides what each reason means,
/// so the two-minute cache lives in one tested place.
public enum RefreshReason: String, Sendable {
    /// App launch and menu open: fetch only if the last attempt is over two minutes old, or
    /// was a poll that sent nothing (ADR-0002 point 1).
    case launch, menuOpen
    /// The Refresh row: always fetch.
    case refreshRow
    /// The poll timer firing at `nextPoll`: always an attempt, but it sends nothing after a
    /// refused or timed-out read, or with a rejected token (ADR-0002 point 3).
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

/// Keeps one provider's usage current and warns about it. Both sources share caching,
/// persistence, headroom pacing, failure backoff and delivery tracking. Claude retains its
/// read-only token/retry sequence; Codex delegates account access to its local app server.
/// Callers say why they want a refresh and read the state; they never sequence the work.
@MainActor
public final class UsageService {
    public static let staleAfter: TimeInterval = 120
    public static let planMaxAge: TimeInterval = 24 * 60 * 60

    /// The last good snapshot. Survives failures and relaunches.
    public private(set) var snapshot: UsageSnapshot?
    private(set) var failures: FailureStreak?

    public var plan: Plan? { fetchedPlan?.plan }
    /// There is a problem exactly when the last attempt failed.
    public var problem: UsageProblem? { failures?.problem }
    public var isRefreshing: Bool { inFlight != nil }

    /// When the next background poll is due, from the pure scheduler (ADR-0002). Derived on
    /// every read, so a refresh or a threshold change shows without anyone recomputing it.
    /// Nil before the first attempt on a fresh install, and while a refresh runs: the due time
    /// is stale until it ends, and its end re-arms the timer.
    public var nextPoll: Date? {
        guard inFlight == nil else { return nil }
        return PollScheduler.nextPoll(snapshot: snapshot, failures: failures, thresholds: thresholds())
    }

    /// Called on the main actor when a refresh starts, when it ends or is skipped, and after a
    /// settings change. The app redraws and re-arms its timer from `nextPoll`; nothing more.
    public var onChange: (@MainActor () -> Void)?

    private var fetchedPlan: FetchedPlan?
    private var fired: Set<WarningKey>
    private var delivering: Set<WarningKey> = []
    private var inFlight: Task<RefreshOutcome, Never>?
    /// ADR-0002 point 3.
    private var rejectedToken: AccessToken?
    /// The problem of the last Keychain read, if it was refused or timed out. A poll then runs
    /// no read, so a Keychain dialog cannot come back on every poll; launch, menu open and
    /// Refresh still read. Cleared by any read that ends otherwise.
    private var refusedRead: UsageProblem?

    private enum Source {
        case claude(TokenReader, any UsageFetching)
        case codex(@Sendable () async throws(CodexUsageError) -> CodexUsageReading)
    }
    private let source: Source
    private let store: SnapshotStore
    private let delivery: any WarningDelivery
    private let thresholds: @MainActor () -> WarningThresholds
    private let now: @Sendable () -> Date
    var deliveryTimeout: Duration = .seconds(10)

    /// Snapshot, plan and posted warnings load from `store`, the one place they persist.
    public convenience init(
        readToken: @escaping TokenReader,
        fetcher: any UsageFetching,
        store: SnapshotStore,
        delivery: any WarningDelivery,
        thresholds: @escaping @MainActor () -> WarningThresholds,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(source: .claude(readToken, fetcher), store: store, delivery: delivery,
                  thresholds: thresholds, now: now)
    }

    public convenience init(
        readCodex: @escaping @Sendable () async throws(CodexUsageError) -> CodexUsageReading,
        store: SnapshotStore,
        delivery: any WarningDelivery,
        thresholds: @escaping @MainActor () -> WarningThresholds,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(source: .codex(readCodex), store: store, delivery: delivery,
                  thresholds: thresholds, now: now)
    }

    private init(source: Source, store: SnapshotStore, delivery: any WarningDelivery,
                 thresholds: @escaping @MainActor () -> WarningThresholds,
                 now: @escaping @Sendable () -> Date) {
        self.source = source
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
            onChange?()
            return Task { .skipped }
        }
        let task = Task { await self.perform(reason) }
        inFlight = task
        onChange?()
        return task
    }

    /// Thresholds or notification permission changed. A raised threshold re-arms its warning,
    /// a lowered one may make a warning due, and the pace follows. Tests await `.value`.
    @discardableResult
    public func reevaluateWarnings() -> Task<Void, Never> {
        if let snapshot {
            let past = snapshot.limits.filter { thresholds().state(of: $0, at: now()) == .past }.map { WarningKey($0) }
            setFired(fired.intersection(past))
        }
        onChange?()
        return Task {
            await self.deliverDueWarnings()
            self.onChange?()
        }
    }

    /// ADR-0002 points 1 and 4.
    private var lastAttempt: Date? {
        failures?.lastAttempt ?? snapshot?.fetchedAt
    }

    private func shouldFetch(for reason: RefreshReason) -> Bool {
        switch reason {
        case .refreshRow, .poll:
            return true
        case .launch, .menuOpen:
            guard let lastAttempt, failures?.pollSentNothing != true else { return true }
            return now().timeIntervalSince(lastAttempt) >= Self.staleAfter
        }
    }

    private func perform(_ reason: RefreshReason) async -> RefreshOutcome {
        let started = now()
        let outcome: RefreshOutcome
        do throws(RefreshFailure) {
            switch source {
            case .claude(let readToken, let fetcher):
                let working = try await fetchUsage(reason, readToken: readToken, fetcher: fetcher)
                if let snapshot { store.save(snapshot: snapshot) }
                if let plan = await planIfStale(token: working, fetcher: fetcher) {
                    fetchedPlan = plan
                    store.save(plan: plan)
                }
            case .codex(let read):
                do throws(CodexUsageError) {
                    let reading = try await read()
                    snapshot = reading.snapshot
                    store.save(snapshot: reading.snapshot)
                    if let plan = reading.plan {
                        let fetched = FetchedPlan(plan: plan, fetchedAt: reading.snapshot.fetchedAt)
                        fetchedPlan = fetched
                        store.save(plan: fetched)
                    }
                } catch {
                    throw RefreshFailure(problem: .codex(error), logDescription: "Codex: \(error)")
                }
            }
            failures = nil
            rejectedToken = nil
            outcome = .fetched
        } catch {
            let streak = failures?.next(error.problem, at: started, pollSentNothing: error.pollSentNothing)
                ?? .first(error.problem, at: started, pollSentNothing: error.pollSentNothing)
            failures = streak
            Log.fetch.error("usage fetch failed (\(streak.count) in a row): \(error.logDescription, privacy: .public)")
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
    private func fetchUsage(_ reason: RefreshReason, readToken: TokenReader, fetcher: any UsageFetching) async throws(RefreshFailure) -> AccessToken {
        if reason == .poll, let refusedRead {
            throw .readStillRefused(refusedRead)
        }
        let token = try await read(readToken)
        // A poll exists only for warnings, and a rejected token cannot produce any.
        if reason == .poll, token == rejectedToken {
            throw .tokenStillRejected
        }
        do {
            snapshot = try await fetcher.fetchUsage(token: token)
            return token
        } catch .unauthorized {
            // Claude Code may have rotated the token since the read. One re-read, one retry.
            let fresh = try await read(readToken)
            guard fresh != token else {
                rejectedToken = token
                throw .tokenUnchanged
            }
            do {
                snapshot = try await fetcher.fetchUsage(token: fresh)
                return fresh
            } catch .unauthorized {
                rejectedToken = fresh
                throw RefreshFailure(.unauthorized)
            } catch {
                throw RefreshFailure(error)
            }
        } catch {
            throw RefreshFailure(error)
        }
    }

    /// Reads the token, and remembers a refused or timed-out read for the next poll.
    private func read(_ readToken: TokenReader) async throws(RefreshFailure) -> AccessToken {
        do {
            let token = try await readToken()
            refusedRead = nil
            return token
        } catch {
            let failure = RefreshFailure(error)
            switch error {
            case .refused, .timedOut: refusedRead = failure.problem
            case .notFound, .failed, .launchFailed, .malformed: refusedRead = nil
            }
            throw failure
        }
    }

    /// The plan row is secondary: a failure keeps the old value, sets no problem, and logs at
    /// debug level only.
    private func planIfStale(token: AccessToken, fetcher: any UsageFetching) async -> FetchedPlan? {
        if let fetchedPlan, now().timeIntervalSince(fetchedPlan.fetchedAt) < Self.planMaxAge { return nil }
        do {
            return FetchedPlan(plan: try await fetcher.fetchPlan(token: token), fetchedAt: now())
        } catch {
            Log.fetch.debug("plan fetch failed: \(RefreshFailure(error).logDescription, privacy: .public)")
            return nil
        }
    }

    /// Offers every due warning and records the ones Notification Center accepted
    /// (ADR-0005 point 2). Each delivery is bounded by `deliveryTimeout`, so a hung one cannot
    /// hold the refresh and stop polling.
    private func deliverDueWarnings() async {
        guard let snapshot else { return }
        let outcome = WarningTracker.evaluate(snapshot: snapshot, thresholds: thresholds(), fired: fired, at: now())
        setFired(outcome.firedInCurrentWindows)
        let due = outcome.due.filter { !delivering.contains(WarningKey($0)) }
        let keys = Set(due.map { WarningKey($0) })
        delivering.formUnion(keys)
        defer { delivering.subtract(keys) }
        for limit in due {
            let key = WarningKey(limit)
            let accepted = await Deadline.race(deliveryTimeout) { [delivery, now] in
                await delivery.deliver(limit, identifier: key.notificationIdentifier, now: now())
            } ?? false
            if accepted { setFired(fired.union([key])) }
        }
    }

    private func setFired(_ new: Set<WarningKey>) {
        guard new != fired else { return }
        fired = new
        store.save(firedWarnings: new)
    }
}
