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

    /// Drives the warning dot. A limit whose window has reset is unknown, not past.
    public func anyPast(in snapshot: UsageSnapshot, at now: Date) -> Bool {
        snapshot.limits.contains { state(of: $0, at: now) == .past }
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

/// Where a limit stands, at a given moment, against its threshold.
public enum LimitState: Equatable, Sendable {
    /// Below its threshold by this many points (more than zero).
    case below(headroom: Int)
    /// At or past its threshold, in a window that has not reset.
    case past
    /// Its window has reset since the snapshot was fetched: the value is unknown until a fetch.
    case reset
}
