import Foundation

/// Per-limit warning thresholds in percent. Defaults from the proposal.
public struct WarningThresholds: Equatable, Sendable, Codable {
    public var session: Int
    public var weeklyAll: Int
    public var weeklyScoped: Int

    public static let `default` = WarningThresholds(session: 80, weeklyAll: 85, weeklyScoped: 80)

    public init(session: Int, weeklyAll: Int, weeklyScoped: Int) {
        self.session = session
        self.weeklyAll = weeklyAll
        self.weeklyScoped = weeklyScoped
    }

    public func threshold(for kind: RateLimit.Kind) -> Int {
        switch kind {
        case .session: return session
        case .weeklyAll: return weeklyAll
        case .weeklyScoped: return weeklyScoped
        case .other: return weeklyAll
        }
    }

    /// Drives the warning dot: nil when no limit is past its threshold at `now`, so the dot is
    /// off; otherwise the earliest reset among those limits, when the dot can change without a
    /// fetch, since after it that limit is unknown, not past (ADR-0005 point 4).
    public func earliestPastReset(in snapshot: UsageSnapshot, at now: Date) -> Date? {
        snapshot.limits.filter { state(of: $0, at: now) == .past }.map(\.resetsAt).min()
    }

    /// Where a limit stands against its threshold at `now`. The menu row, the warning dot,
    /// the warnings and the scheduler all read this one function, so "past" and "reset" mean
    /// the same thing everywhere.
    public func state(of limit: RateLimit, at now: Date) -> LimitState {
        if limit.resetsAt <= now { return .reset }
        let headroom = threshold(for: limit.kind) - limit.percent
        return headroom > 0 ? .below(headroom: headroom) : .past
    }
}

public enum LimitState: Equatable, Sendable {
    /// Below its threshold by this many points (more than zero).
    case below(headroom: Int)
    /// At or past its threshold, in a window that has not reset.
    case past
    /// Its window has reset since the snapshot was fetched: the value is unknown until a fetch.
    case reset
}
