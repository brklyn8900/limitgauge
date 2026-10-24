import Foundation

public struct RateLimit: Equatable, Sendable, Codable {
    public enum Kind: Equatable, Sendable, Codable {
        case session
        case weeklyAll
        case weeklyScoped
        case other(String)

        init(rawKind: String) {
            switch rawKind {
            case "session": self = .session
            case "weekly_all": self = .weeklyAll
            case "weekly_scoped": self = .weeklyScoped
            default: self = .other(rawKind)
            }
        }
    }

    public var kind: Kind
    public var percent: Int
    public var resetsAt: Date
    /// Model or surface name for a scoped limit, e.g. "Fable". Nil for the unscoped limits.
    public var scopeName: String?
    /// Provider-supplied row label; identity remains in kind for warning deduplication.
    public var displayTitle: String?

    public init(kind: Kind, percent: Int, resetsAt: Date, scopeName: String? = nil, displayTitle: String? = nil) {
        self.kind = kind
        self.percent = percent
        self.resetsAt = resetsAt
        self.scopeName = scopeName
        self.displayTitle = displayTitle
    }

    /// Row title as shown on the Usage page.
    public var title: String {
        if let displayTitle { return displayTitle }
        switch kind {
        case .session: return Kind.session.title
        case .weeklyAll: return "This week"
        case .weeklyScoped: return scopeName.map { "\($0) this week" } ?? "Scoped this week"
        case .other(let raw): return raw
        }
    }
}

extension RateLimit.Kind {
    /// Title of the unscoped rows, usable without a limit value.
    public var title: String {
        switch self {
        case .session: return "Current session"
        case .weeklyAll: return "This week"
        case .weeklyScoped: return "Scoped this week"
        case .other(let raw): return raw
        }
    }
}

/// A dollar allowance with a reset date (cloud session credits).
public struct DollarAllowance: Equatable, Sendable, Codable {
    public var limitDollars: Decimal
    public var remainingDollars: Decimal
    public var resetsAt: Date?

    public init(limitDollars: Decimal, remainingDollars: Decimal, resetsAt: Date?) {
        self.limitDollars = limitDollars
        self.remainingDollars = remainingDollars
        self.resetsAt = resetsAt
    }
}

/// Usage credits: spend so far and prepaid balance, if any.
public struct UsageCredits: Equatable, Sendable, Codable {
    public var used: Decimal
    public var currency: String
    public var balance: Decimal?
    public var extraUsageEnabled: Bool

    public init(used: Decimal, currency: String, balance: Decimal?, extraUsageEnabled: Bool) {
        self.used = used
        self.currency = currency
        self.balance = balance
        self.extraUsageEnabled = extraUsageEnabled
    }
}

/// The "Limit resets" section. Grants are kept as opaque labels until their shape is known.
public struct LimitResets: Equatable, Sendable, Codable {
    public var eligible: Bool
    public var grants: [String]

    public init(eligible: Bool, grants: [String]) {
        self.eligible = eligible
        self.grants = grants
    }
}

public struct BreakdownRow: Equatable, Sendable, Codable {
    public var name: String
    public var percent: Int

    public init(name: String, percent: Int) {
        self.name = name
        self.percent = percent
    }
}

/// Everything the menu shows from one usage fetch. Rows other than `limits` are optional:
/// the endpoint is undocumented and a renamed key hides a row rather than failing the fetch.
public struct UsageSnapshot: Equatable, Sendable, Codable {
    public var limits: [RateLimit]
    public var cloudCredits: DollarAllowance?
    public var usageCredits: UsageCredits?
    public var limitResets: LimitResets?
    public var weeklyBreakdown: [BreakdownRow]?
    /// The raw kind of each `limits[]` element dropped as unreadable, "" where the kind itself
    /// was unreadable. Nil when none was dropped, and in snapshots saved before this existed.
    public var unreadableLimitKinds: [String]?
    public var fetchedAt: Date

    public init(
        limits: [RateLimit],
        cloudCredits: DollarAllowance? = nil,
        usageCredits: UsageCredits? = nil,
        limitResets: LimitResets? = nil,
        weeklyBreakdown: [BreakdownRow]? = nil,
        unreadableLimitKinds: [String]? = nil,
        fetchedAt: Date
    ) {
        self.limits = limits
        self.cloudCredits = cloudCredits
        self.usageCredits = usageCredits
        self.limitResets = limitResets
        self.weeklyBreakdown = weeklyBreakdown
        self.unreadableLimitKinds = unreadableLimitKinds
        self.fetchedAt = fetchedAt
    }

    public func limit(_ kind: RateLimit.Kind) -> RateLimit? {
        limits.first { $0.kind == kind }
    }

    /// The main Codex weekly window. Its stable identity is produced by CodexUsageReader
    /// from bucket ID and duration, independent of primary/secondary slot or display label.
    /// Never substitute another bucket or a shorter window in a weekly compact view.
    public var codexWeeklyLimit: RateLimit? {
        limits.first { $0.kind == .other("codex:codex:10080") }
    }

    /// The endpoint drops the session limit while no five-hour window is open, so the menu
    /// shows the session at 0%. Not when a session element was there but unreadable: that
    /// would be a confident 0% that never warns.
    public var sessionIsIdle: Bool {
        limit(.session) == nil && !sessionIsUnreadable
    }

    /// A session element was there but unreadable, and none was read: the menu shows the
    /// session as unknown rather than hiding it.
    public var sessionIsUnreadable: Bool {
        limit(.session) == nil && (unreadableLimitKinds ?? []).contains("session")
    }
}

public struct Plan: Equatable, Sendable, Codable {
    public var rateLimitTier: String

    public init(rateLimitTier: String) {
        self.rateLimitTier = rateLimitTier
    }

    /// "default_claude_max_5x" -> "Max 5x". A tier with no words falls back to the raw value.
    public var displayName: String {
        var tier = rateLimitTier
        for prefix in ["default_claude_", "claude_"] where tier.hasPrefix(prefix) {
            tier.removeFirst(prefix.count)
            break
        }
        let words = tier.split(separator: "_").map { word -> String in
            if word.last == "x", word.dropLast().allSatisfy(\.isNumber) { return String(word) }
            return word.prefix(1).uppercased() + word.dropFirst()
        }
        return words.isEmpty ? rateLimitTier : words.joined(separator: " ")
    }
}

public enum UsageDecoding {
    public enum Error: Swift.Error, Equatable {
        case missingLimits
        case malformedJSON
    }

    /// Decodes a usage response. Throws only when `limits[]` is missing or unreadable.
    public static func snapshot(from data: Data, fetchedAt: Date = Date()) throws -> UsageSnapshot {
        let raw: UsageResponse
        do {
            raw = try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw Error.malformedJSON
        }
        guard let elements = raw.limits?.value, !elements.isEmpty else { throw Error.missingLimits }

        var limits: [RateLimit] = []
        var unreadable: [String] = []
        var unreadableDetail: [String] = []
        for element in elements {
            guard let l = element.limit, let kind = l.kind, let percent = l.percent,
                  let resetsAt = l.resets_at.flatMap(ISO8601.date) else {
                unreadable.append(element.kind ?? "")
                unreadableDetail.append(element.logDescription)
                continue
            }
            let scopeName = l.scope?.model?.display_name ?? l.scope?.surface?.display_name
            limits.append(RateLimit(kind: .init(rawKind: kind), percent: percent, resetsAt: resetsAt, scopeName: scopeName))
        }
        guard !limits.isEmpty else { throw Error.missingLimits }
        if !unreadable.isEmpty {
            // Kinds are the endpoint's own enum strings, and problems name fields, never values:
            // no account data, so they are public.
            let detail = unreadableDetail.joined(separator: "; ")
            Log.fetch.error("usage: dropped \(unreadable.count) of \(elements.count) limits[] elements as unreadable: \(detail, privacy: .public)")
        }

        let cloud = raw.iguana_necktie?.value.flatMap { c -> DollarAllowance? in
            guard let limit = c.limit_dollars, let remaining = c.remaining_dollars else { return nil }
            return DollarAllowance(limitDollars: Decimal(limit), remainingDollars: Decimal(remaining),
                                   resetsAt: c.resets_at.flatMap(ISO8601.date))
        }

        let credits = raw.spend?.value.flatMap { s -> UsageCredits? in
            guard let used = s.used else { return nil }
            return UsageCredits(
                used: used.decimal,
                currency: used.currency ?? "USD",
                balance: s.balance?.decimal,
                extraUsageEnabled: raw.extra_usage?.value?.is_enabled ?? false
            )
        }

        let resets = raw.cedar_ember?.value.map { c in
            LimitResets(eligible: c.eligible ?? false, grants: (c.grants ?? []).map(\.label))
        }

        let breakdown = raw.seven_day_breakdown?.value?.rows.map { rows in
            rows.compactMap { r -> BreakdownRow? in
                guard let name = r.display_name ?? r.key, let percent = r.percent else { return nil }
                return BreakdownRow(name: name, percent: percent)
            }
        }

        return UsageSnapshot(limits: limits, cloudCredits: cloud, usageCredits: credits,
                             limitResets: resets, weeklyBreakdown: breakdown,
                             unreadableLimitKinds: unreadable.isEmpty ? nil : unreadable, fetchedAt: fetchedAt)
    }

    public static func plan(from data: Data) throws -> Plan {
        let raw: ProfileResponse
        do {
            raw = try JSONDecoder().decode(ProfileResponse.self, from: data)
        } catch {
            throw Error.malformedJSON
        }
        guard let tier = raw.organization?.rate_limit_tier else { throw Error.malformedJSON }
        return Plan(rateLimitTier: tier)
    }
}

struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) {
        value = try? T(from: decoder)
    }
}

struct UsageResponse: Decodable {
    var limits: Lenient<[LenientRawLimit]>?
    var iguana_necktie: Lenient<RawDollarWindow>?
    var spend: Lenient<RawSpend>?
    var extra_usage: Lenient<RawExtraUsage>?
    var cedar_ember: Lenient<RawResets>?
    var seven_day_breakdown: Lenient<RawBreakdown>?
}

struct RawLimit: Decodable {
    var kind: String?
    var percent: Int?
    var resets_at: String?
    var scope: RawScope?
}

/// One `limits[]` element, read leniently. Its kind is read on its own, so an element that
/// fails to decode still says which limit it was.
struct LenientRawLimit: Decodable {
    private enum Keys: String, CodingKey { case kind, percent, resets_at, scope }
    let limit: RawLimit?
    let kind: String?
    /// Each field that keeps the element from reading, and how: "resets_at: null". Field
    /// names and states only, never values, so it can be logged in public.
    let problems: [String]

    init(from decoder: Decoder) {
        limit = try? RawLimit(from: decoder)
        guard let c = try? decoder.container(keyedBy: Keys.self) else {
            kind = nil
            problems = ["not an object"]
            return
        }
        var problems: [String] = []
        func read<T: Decodable>(_ key: Keys, _ type: T.Type, _ typeName: String, required: Bool = true) -> T? {
            if !c.contains(key) {
                if required { problems.append("\(key.stringValue): missing") }
            } else if (try? c.decodeNil(forKey: key)) == true {
                if required { problems.append("\(key.stringValue): null") }
            } else if let value = try? c.decode(T.self, forKey: key) {
                return value
            } else {
                problems.append("\(key.stringValue): not \(typeName)")
            }
            return nil
        }
        kind = read(.kind, String.self, "a string")
        _ = read(.percent, Int.self, "an integer")
        if let resetsAt = read(.resets_at, String.self, "a string"), ISO8601.date(resetsAt) == nil {
            problems.append("resets_at: not a date")
        }
        _ = read(.scope, RawScope.self, "the known shape", required: false)
        self.problems = problems
    }
}

extension LenientRawLimit {
    /// "session (resets_at: null)", as the unreadable-element log line shows it.
    var logDescription: String {
        let name = kind ?? "(no kind)"
        return problems.isEmpty ? name : "\(name) (\(problems.joined(separator: ", ")))"
    }
}

struct RawScope: Decodable {
    struct Named: Decodable { var display_name: String? }
    var model: Named?
    var surface: Named?
}

struct RawDollarWindow: Decodable {
    var resets_at: String?
    var limit_dollars: Double?
    var remaining_dollars: Double?
}

struct RawMoney: Decodable {
    var amount_minor: Int?
    var currency: String?
    var exponent: Int?

    var decimal: Decimal {
        Decimal(amount_minor ?? 0) / pow(10, exponent ?? 2)
    }
}

struct RawSpend: Decodable {
    var used: RawMoney?
    var balance: RawMoney?
}

struct RawExtraUsage: Decodable {
    var is_enabled: Bool?
}

struct RawResets: Decodable {
    struct Grant: Decodable {
        var id: String?
        var label: String {
            id ?? "grant"
        }
    }
    var eligible: Bool?
    var grants: [Grant]?
}

struct RawBreakdown: Decodable {
    struct Row: Decodable {
        var key: String?
        var display_name: String?
        var percent: Int?
    }
    var rows: [Row]?
}

struct ProfileResponse: Decodable {
    struct Organization: Decodable { var rate_limit_tier: String? }
    var organization: Organization?
}

/// The endpoint emits "2026-10-18T07:10:00.471323+00:00" and "2026-11-05T07:59:00+00:00":
/// six fractional digits or none. Foundation's parser wants exactly three or none.
enum ISO8601 {
    static func date(_ s: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: s) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let dot = s.firstIndex(of: ".") else { return nil }
        let tail = s[dot...].dropFirst()
        let digitsEnd = tail.firstIndex { !$0.isNumber } ?? tail.endIndex
        let digits = tail[..<digitsEnd]
        let rest = tail[digitsEnd...]
        let threeDigits = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
        return fractional.date(from: s[..<dot] + "." + threeDigits + rest)
    }
}
