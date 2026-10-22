import Foundation

/// Identifies one warning: a limit within one reset window. A new `resets_at` is a new key,
/// which re-arms the warning (proposal, Warnings).
///
/// `resetsAt` is rounded to the nearest minute. The endpoint shifts `resets_at` by under a
/// second between fetches in the same window (21:10:00.462, then 21:09:59.776, captured
/// 2026-10-21), so raw values made every fetch a new key and repeated the warning. Truncating
/// would split exactly that pair; windows start on the minute, so rounding cannot merge two.
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
        resetsAt = limit.resetsAt.nearestMinute
    }

    private enum CodingKeys: String, CodingKey {
        case kind, resetsAt
    }

    /// Rounds keys saved before rounding existed, so the upgrade does not repeat a warning
    /// already posted in the current window.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        resetsAt = try container.decode(Date.self, forKey: .resetsAt).nearestMinute
    }

    /// Stable per warning, so delivering the same warning twice replaces the notification
    /// instead of stacking a second one (ADR-0005 point 3).
    public var notificationIdentifier: String {
        "\(kind)@\(Int(resetsAt.timeIntervalSince1970))"
    }
}

extension Date {
    var nearestMinute: Date {
        Date(timeIntervalSince1970: (timeIntervalSince1970 / 60).rounded() * 60)
    }
}

/// Consecutive failed attempts since the last success. Nil on the service while the last
/// attempt succeeded, so "is there a problem" and "are we backing off" cannot disagree.
struct FailureStreak: Equatable, Sendable {
    var problem: UsageProblem
    /// At least 1.
    var count: Int
    var lastAttempt: Date
}

/// Background poll pacing (ADR-0002). A pure function of the snapshot, the failure streak and
/// the thresholds. It never reads the clock, and every due time it returns is at least a
/// minute after the last attempt, so no state can make it poll in a loop. Internal: the app
/// reads `UsageService.nextPoll` and cannot compute a due time of its own.
enum PollScheduler {
    static let farInterval: TimeInterval = 60 * 60
    static let nearInterval: TimeInterval = 30 * 60
    static let closeInterval: TimeInterval = 10 * 60
    static let delayAfterPastLimitReset: TimeInterval = 60

    static func interval(for headroom: Int) -> TimeInterval {
        if headroom > 40 { return farInterval }
        if headroom >= 15 { return nearInterval }
        return closeInterval
    }

    /// The wait after the `count`th consecutive failure (ADR-0002 point 3).
    static func backoff(_ retry: RetryClass, afterFailures count: Int) -> TimeInterval {
        let n = max(count, 1)
        switch retry {
        case .transient: return min(farInterval, closeInterval * Double(1 << min(n - 1, 3)))
        case .rateLimited: return n == 1 ? nearInterval : farInterval
        case .needsUser: return farInterval
        }
    }

    static func paced(_ snapshot: UsageSnapshot, thresholds: WarningThresholds) -> Date {
        let at = snapshot.fetchedAt
        let states = snapshot.limits.map { ($0, thresholds.state(of: $0, at: at)) }
        let least = states.compactMap { state -> Int? in
            if case .below(let headroom) = state.1 { return headroom }
            return nil
        }.min()
        let pace = at.addingTimeInterval(least.map(interval(for:)) ?? farInterval)
        let rearm = states.filter { $0.1 == .past }.map { $0.0.resetsAt.addingTimeInterval(delayAfterPastLimitReset) }.min()
        return min(pace, rearm ?? pace)
    }

    /// When the next background poll is due, or nil before the first attempt on a fresh
    /// install (launch makes one at once).
    ///
    /// After a failure: the backoff from the attempt, but never before the snapshot's own pace,
    /// so a failure cannot poll faster than success would. With no snapshot there is no pace,
    /// and the backoff alone decides. Otherwise: the snapshot's pace.
    static func nextPoll(snapshot: UsageSnapshot?, failures: FailureStreak?, thresholds: WarningThresholds) -> Date? {
        let pace = snapshot.map { paced($0, thresholds: thresholds) }
        guard let failures else { return pace }
        let retry = failures.lastAttempt.addingTimeInterval(backoff(failures.problem.retry, afterFailures: failures.count))
        return max(retry, pace ?? retry)
    }
}

/// Shows a warning to the user. The app's `Notifier` is the only production conformer; it
/// stays in the app because Notification Center needs the app bundle.
@MainActor
public protocol WarningDelivery: AnyObject, Sendable {
    /// True once Notification Center has accepted the request. False when notifications are
    /// off in limitgauge or not allowed by macOS, or the request failed; the warning then
    /// stays due and is offered again (ADR-0005 point 2). `identifier` is the request's
    /// identifier, stable per warning.
    func deliver(_ limit: RateLimit, identifier: String, now: Date) async -> Bool
}

/// Which warnings are due for a snapshot, and the fired set to carry forward. A warning is
/// fired when it is delivered, not when it is due, so marking it is the caller's job.
enum WarningTracker {
    struct Outcome: Equatable, Sendable {
        var due: [RateLimit]
        var firedInCurrentWindows: Set<WarningKey>
    }

    /// A limit whose window has reset since the fetch is unknown and never due (ADR-0005
    /// point 4).
    static func evaluate(
        snapshot: UsageSnapshot,
        thresholds: WarningThresholds,
        fired previous: Set<WarningKey>,
        at now: Date
    ) -> Outcome {
        let fired = previous.intersection(snapshot.limits.map { WarningKey($0) })
        var seen = fired
        let due = snapshot.limits.filter {
            thresholds.state(of: $0, at: now) == .past && seen.insert(WarningKey($0)).inserted
        }
        return Outcome(due: due, firedInCurrentWindows: fired)
    }
}
