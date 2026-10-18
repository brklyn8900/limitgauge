import Foundation
import Testing
@testable import LimitGaugeCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Double = 0) -> Date {
    var c = DateComponents()
    (c.year, c.month, c.day, c.hour, c.minute) = (y, mo, d, h, mi)
    c.second = Int(s)
    c.nanosecond = Int((s - Double(Int(s))) * 1_000_000_000)
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: c)!
}

@Suite struct UsageDecodingTests {
    @Test func fullResponseDecodesEveryRow() throws {
        let now = Date()
        let snap = try UsageDecoding.snapshot(from: fixture("usage"), fetchedAt: now)

        #expect(snap.fetchedAt == now)
        #expect(snap.limits.count == 3)

        let session = try #require(snap.limit(.session))
        #expect(session.percent == 25)
        #expect(abs(session.resetsAt.timeIntervalSince(utc(2030, 1, 7, 5, 0, 0.123))) < 0.001)
        #expect(session.scopeName == nil)
        #expect(session.title == "Current session")

        let week = try #require(snap.limit(.weeklyAll))
        #expect(week.percent == 50)
        #expect(week.title == "This week")

        let scoped = try #require(snap.limit(.weeklyScoped))
        #expect(scoped.percent == 75)
        #expect(scoped.scopeName == "Fable")
        #expect(scoped.title == "Fable this week")

        let cloud = try #require(snap.cloudCredits)
        #expect(cloud.limitDollars == 100)
        #expect(cloud.remainingDollars == 100)
        #expect(cloud.resetsAt == utc(2030, 2, 1, 8, 0))

        let credits = try #require(snap.usageCredits)
        #expect(credits.used == 0)
        #expect(credits.currency == "USD")
        #expect(credits.balance == nil)
        #expect(credits.extraUsageEnabled == false)

        let resets = try #require(snap.limitResets)
        #expect(resets.eligible == false)
        #expect(resets.grants.isEmpty)

        let breakdown = try #require(snap.weeklyBreakdown)
        #expect(breakdown == [
            BreakdownRow(name: "Claude Code", percent: 70),
            BreakdownRow(name: "Chats", percent: 20),
            BreakdownRow(name: "Cowork", percent: 10),
            BreakdownRow(name: "Other", percent: 0),
        ])
    }

    @Test func limitsOnlyResponseLeavesOptionalRowsNil() throws {
        let snap = try UsageDecoding.snapshot(from: fixture("usage-limits-only"))
        #expect(snap.limits.count == 3)
        #expect(snap.cloudCredits == nil)
        #expect(snap.usageCredits == nil)
        #expect(snap.limitResets == nil)
        #expect(snap.weeklyBreakdown == nil)
    }

    @Test func renamedCodenameKeyHidesOnlyItsRow() throws {
        // A codename section with an unexpected shape must not fail the fetch.
        var json = try #require(try JSONSerialization.jsonObject(with: fixture("usage")) as? [String: Any])
        json["iguana_necktie"] = "gone"
        json["seven_day_breakdown"] = ["rows": "not an array"]
        let data = try JSONSerialization.data(withJSONObject: json)

        let snap = try UsageDecoding.snapshot(from: data)
        #expect(snap.limits.count == 3)
        #expect(snap.cloudCredits == nil)
        #expect(snap.weeklyBreakdown == nil)
        #expect(snap.usageCredits != nil)
    }

    @Test func missingLimitsIsAnError() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: fixture("usage")) as? [String: Any])
        json["limits"] = nil
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: UsageDecoding.Error.missingLimits) {
            try UsageDecoding.snapshot(from: data)
        }
    }

    @Test func unknownLimitKindIsKept() throws {
        let data = Data("""
        {"limits": [{"kind": "monthly_thing", "percent": 5, "resets_at": "2026-11-01T00:00:00+00:00"}]}
        """.utf8)
        let snap = try UsageDecoding.snapshot(from: data)
        #expect(snap.limits.first?.kind == .other("monthly_thing"))
        #expect(snap.limits.first?.title == "monthly_thing")
    }

    @Test func moneyUsesExponent() throws {
        let data = Data("""
        {"limits": [{"kind": "session", "percent": 1, "resets_at": "2026-11-01T00:00:00+00:00"}],
         "spend": {"used": {"amount_minor": 1234, "currency": "USD", "exponent": 2},
                   "balance": {"amount_minor": 5000, "currency": "USD", "exponent": 2}},
         "extra_usage": {"is_enabled": true}}
        """.utf8)
        let credits = try #require(try UsageDecoding.snapshot(from: data).usageCredits)
        #expect(credits.used == Decimal(string: "12.34"))
        #expect(credits.balance == 50)
        #expect(credits.extraUsageEnabled)
    }

    @Test func profileDecodesToPlan() throws {
        let plan = try UsageDecoding.plan(from: fixture("profile"))
        #expect(plan.rateLimitTier == "default_claude_max_5x")
        #expect(plan.displayName == "Max 5x")
    }

    @Test func planDisplayNames() {
        #expect(Plan(rateLimitTier: "default_claude_max_20x").displayName == "Max 20x")
        #expect(Plan(rateLimitTier: "default_claude_pro").displayName == "Pro")
        #expect(Plan(rateLimitTier: "something_else").displayName == "Something Else")
    }
}

@Suite struct DateParsingTests {
    @Test func sixFractionalDigits() {
        let d = ISO8601.date("2026-10-18T07:10:00.471323+00:00")
        #expect(d != nil)
        #expect(abs(d!.timeIntervalSince(utc(2026, 10, 18, 7, 10, 0.471))) < 0.001)
    }

    @Test func noFraction() {
        #expect(ISO8601.date("2026-11-05T07:59:00+00:00") == utc(2026, 11, 5, 7, 59))
    }

    @Test func zuluAndOneDigit() {
        #expect(ISO8601.date("2026-11-05T07:59:00Z") == utc(2026, 11, 5, 7, 59))
        #expect(abs(ISO8601.date("2026-11-05T07:59:00.5Z")!.timeIntervalSince(utc(2026, 11, 5, 7, 59, 0.5))) < 0.001)
    }

    @Test func garbageIsNil() {
        #expect(ISO8601.date("yesterday") == nil)
    }
}

@Suite struct CredentialParsingTests {
    @Test func parsesClaudeCodeItem() throws {
        let data = Data("""
        {"claudeAiOauth": {"accessToken": "sk-ant-oat01-test", "refreshToken": "r", "expiresAt": 4102444800241,
                           "scopes": ["user:inference"], "subscriptionType": "max"}}
        """.utf8)
        let token = try ClaudeCodeCredentials.parse(data)
        #expect(token.accessToken == "sk-ant-oat01-test")
        #expect(token.expiresAt == Date(timeIntervalSince1970: 4102444800.241))
        #expect(token.isExpired == false)
    }

    @Test func securityExitCodesMapToErrors() {
        #expect(ClaudeCodeCredentials.error(forExitCode: 0) == nil)
        #expect(ClaudeCodeCredentials.error(forExitCode: 44) == .notFound)
        #expect(ClaudeCodeCredentials.error(forExitCode: 36) == .accessDenied)
        #expect(ClaudeCodeCredentials.error(forExitCode: 128) == .accessDenied)
        #expect(ClaudeCodeCredentials.error(forExitCode: 1) == .security(exitCode: 1))
    }

    @Test func missingTokenIsMalformed() {
        let data = Data(#"{"claudeAiOauth": {"refreshToken": "r"}}"#.utf8)
        #expect(throws: ClaudeCodeCredentials.Error.malformed) {
            try ClaudeCodeCredentials.parse(data)
        }
    }

    @Test func expiredToken() throws {
        let data = Data(#"{"claudeAiOauth": {"accessToken": "t", "expiresAt": 1000}}"#.utf8)
        #expect(try ClaudeCodeCredentials.parse(data).isExpired)
    }
}
