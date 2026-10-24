import Foundation
import Testing
@testable import LimitGaugeCore

@Suite struct ResetTextTests {
    @Test func weeklyPacing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func caption(_ percent: Int, _ hours: Double, _ kind: RateLimit.Kind = .weeklyAll) -> String? {
            ResetText.weeklyPacing(RateLimit(kind: kind, percent: percent, resetsAt: now + hours * 3600), now: now)
        }
        let compact = RateLimit(kind: .weeklyAll, percent: 46, resetsAt: now + 72 * 3600)
        #expect(ResetText.weeklyPacing(compact, now: now, includeReset: false) == "~18%/day")
        #expect(caption(46, 72) == "~18%/day · resets in 3d")
        #expect(caption(73, 36, .weeklyScoped) == "~18%/day · resets in 1d 12h")
        #expect(caption(73, 8, .other("codex:codex:10080")) == "27% left · resets in 8h")
        #expect(caption(73, 24) == "~27%/day · resets in 1d")
        #expect(caption(99, 72) == "<1%/day · resets in 3d")
        #expect(caption(100, 72) == "~0%/day · resets in 3d")
        #expect(caption(0, 168) == "~14%/day · resets in 7d")
        #expect(caption(73, 0) == nil)
        #expect(caption(73, -1) == nil)
        #expect(caption(101, 24) == nil)
        #expect(caption(10, 3, .session) == nil)
        #expect(caption(10, 72, .other("codex:codex:300")) == nil)
        #expect(caption(10, 72, .other("unknown")) == nil)
    }

    @Test func durations() {
        #expect(ResetText.duration(134 * 60) == "2h 14m")
        #expect(ResetText.duration(2 * 3600) == "2h")
        #expect(ResetText.duration(5 * 60) == "5m")
        #expect(ResetText.duration(29 * 3600) == "1d 5h")
        #expect(ResetText.duration(48 * 3600) == "2d")
        #expect(ResetText.duration(90) == "2m")
    }

    @Test func resetsNowWhenPassed() {
        let now = Date()
        #expect(ResetText.resets(at: now.addingTimeInterval(-5), now: now) == "Resets now")
        #expect(ResetText.resets(at: now.addingTimeInterval(10), now: now) == "Resets now")
    }

    // 2026-10-18 10:00 UTC, a Sunday.
    let sunday = Date(timeIntervalSince1970: 1_792_317_600)

    func pinned(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    @Test func sameDayOmitsWeekday() {
        #expect(ResetText.resets(at: sunday + 2 * 3600, now: sunday, calendar: pinned("UTC")) == "Resets in 2h (12:00\u{202F}PM)")
    }

    @Test func otherDayIncludesWeekday() {
        #expect(ResetText.resets(at: sunday + 36 * 3600, now: sunday, calendar: pinned("UTC")) == "Resets in 1d 12h (Mon 10:00\u{202F}PM)")
    }

    /// 22:00 UTC on Monday is 01:00 on Tuesday in Jerusalem (UTC+3 until 2026-10-25).
    @Test func timeZoneMovesTheClockAndTheDay() {
        #expect(ResetText.resets(at: sunday + 36 * 3600, now: sunday, calendar: pinned("Asia/Jerusalem")) == "Resets in 1d 12h (Tue 1:00\u{202F}AM)")
    }

    @Test func expiry() {
        // 2026-11-05 07:59 UTC.
        let date = Date(timeIntervalSince1970: 1_793_865_540)
        #expect(ResetText.expires(at: date, calendar: pinned("UTC")) == "Expires Nov 5 at 7:59\u{202F}AM")
        #expect(ResetText.expires(at: date, calendar: pinned("Asia/Jerusalem")) == "Expires Nov 5 at 9:59\u{202F}AM")
    }

    @Test func ago() {
        let now = Date()
        #expect(ResetText.ago(now.addingTimeInterval(-12), now: now) == "12 s ago")
        #expect(ResetText.ago(now.addingTimeInterval(-200), now: now) == "3 min ago")
        #expect(ResetText.ago(now.addingTimeInterval(-7200), now: now) == "2 h ago")
    }
}

@Suite struct WarningThresholdTests {
    @Test func defaultsAndLookup() {
        let t = WarningThresholds.default
        #expect(t.threshold(for: .session) == 80)
        #expect(t.threshold(for: .weeklyAll) == 85)
        #expect(t.threshold(for: .weeklyScoped) == 80)
        #expect(t.threshold(for: .other("x")) == 85)
    }

    @Test func pastDetection() {
        let t = WarningThresholds.default
        let now = Date()
        let later = now.addingTimeInterval(3600)
        let snap = UsageSnapshot(limits: [
            RateLimit(kind: .session, percent: 79, resetsAt: later),
            RateLimit(kind: .weeklyScoped, percent: 80, resetsAt: later),
        ], fetchedAt: now)
        #expect(t.state(of: snap.limits[0], at: now) == .below(headroom: 1))
        #expect(t.state(of: snap.limits[1], at: now) == .past)
        #expect(t.earliestPastReset(in: snap, at: now) == later)
    }

    @Test func resetLimitIsUnknownAndLeavesTheDot() {
        let t = WarningThresholds.default
        let now = Date()
        let snap = UsageSnapshot(limits: [RateLimit(kind: .session, percent: 95, resetsAt: now.addingTimeInterval(-1))],
                                 fetchedAt: now.addingTimeInterval(-3600))
        #expect(t.state(of: snap.limits[0], at: now) == .reset)
        #expect(t.earliestPastReset(in: snap, at: now) == nil)
    }
}
