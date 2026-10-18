import Foundation

/// Identifies one warning: a limit within one reset window. A new `resets_at` is a new key,
/// which re-arms the warning (proposal, Warnings).
public struct WarningKey: Hashable, Sendable, Codable {
    public var kind: String
    public var resetsAt: Date

    public init(_ limit: RateLimit) {
        switch limit.kind {
        case .session: kind = "session"
        case .weeklyAll: kind = "weekly_all"
        case .weeklyScoped: kind = "weekly_scoped:\(limit.scopeName ?? "")"
        case .other(let raw): kind = raw
        }
        resetsAt = limit.resetsAt
    }
}

/// Background poll pacing from ADR-0002: the limit with the least headroom to its warning
/// threshold picks the interval. Limits that already fired are excluded.
public enum PollScheduler {
    public static let farInterval: TimeInterval = 60 * 60
    public static let nearInterval: TimeInterval = 30 * 60
    public static let closeInterval: TimeInterval = 10 * 60

    /// Threshold minus percent, in points; negative once past.
    public static func headroom(_ limit: RateLimit, thresholds: WarningThresholds) -> Int {
        thresholds.threshold(for: limit.kind) - limit.percent
    }

    public static func interval(for headroom: Int) -> TimeInterval {
        if headroom > 40 { return farInterval }
        if headroom >= 15 { return nearInterval }
        return closeInterval
    }

    /// Interval until the next background poll, measured from the snapshot's fetch time.
    public static func nextInterval(
        snapshot: UsageSnapshot?,
        thresholds: WarningThresholds,
        fired: Set<WarningKey>
    ) -> TimeInterval {
        guard let snapshot else { return farInterval }
        let pending = snapshot.limits.filter { !fired.contains(WarningKey($0)) }
        guard let least = pending.map({ headroom($0, thresholds: thresholds) }).min() else { return farInterval }
        return interval(for: least)
    }
}

/// Which warnings to post for a snapshot, and the fired set to carry forward.
public enum WarningTracker {
    public struct Outcome: Equatable, Sendable {
        public var toNotify: [RateLimit]
        public var fired: Set<WarningKey>
    }

    public static func evaluate(
        snapshot: UsageSnapshot,
        thresholds: WarningThresholds,
        fired previous: Set<WarningKey>
    ) -> Outcome {
        // Keys whose window has passed drop out, so the next window can fire again.
        let current = Set(snapshot.limits.map { WarningKey($0) })
        var fired = previous.intersection(current)
        var toNotify: [RateLimit] = []
        for limit in snapshot.limits where thresholds.isPast(limit) {
            let key = WarningKey(limit)
            if fired.insert(key).inserted {
                toNotify.append(limit)
            }
        }
        return Outcome(toNotify: toNotify, fired: fired)
    }
}
