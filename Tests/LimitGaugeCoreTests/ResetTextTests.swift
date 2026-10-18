import Foundation
import Testing
@testable import LimitGaugeCore

@Suite struct ResetTextTests {
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

    @Test func sameDayOmitsWeekday() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 10))!
        let later = now.addingTimeInterval(2 * 3600)
        let text = ResetText.resets(at: later, now: now, calendar: cal)
        #expect(text.hasPrefix("Resets in 2h ("))
        #expect(!text.contains("Sun"))
    }

    @Test func otherDayIncludesWeekday() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 10))!
        let text = ResetText.clock(now.addingTimeInterval(36 * 3600), now: now, calendar: cal)
        #expect(text.count > 5)
        #expect(text.first?.isLetter == true)
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
        let snap = UsageSnapshot(limits: [
            RateLimit(kind: .session, percent: 79, resetsAt: now),
            RateLimit(kind: .weeklyScoped, percent: 80, resetsAt: now),
        ], fetchedAt: now)
        #expect(!t.isPast(snap.limits[0]))
        #expect(t.isPast(snap.limits[1]))
        #expect(t.anyPast(in: snap))
    }
}
