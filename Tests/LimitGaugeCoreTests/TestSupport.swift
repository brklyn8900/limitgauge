import Foundation
import Synchronization
@testable import LimitGaugeCore

final class ScriptedFetcher: UsageFetching, @unchecked Sendable {
    var usageResults: [Result<UsageSnapshot, UsageAPI.Error>]
    var planResults: [Result<Plan, UsageAPI.Error>]
    private(set) var usageTokens: [String] = []
    private(set) var planTokens: [String] = []
    private let lock = NSLock()

    init(usage: [Result<UsageSnapshot, UsageAPI.Error>], plan: [Result<Plan, UsageAPI.Error>] = []) {
        usageResults = usage
        planResults = plan
    }

    func fetchUsage(token: AccessToken) async throws(UsageAPI.Error) -> UsageSnapshot {
        let result: Result<UsageSnapshot, UsageAPI.Error> = lock.withLock {
            usageTokens.append(token.value)
            return usageResults.isEmpty ? .failure(.httpStatus(599)) : usageResults.removeFirst()
        }
        return try result.get()
    }

    func fetchPlan(token: AccessToken) async throws(UsageAPI.Error) -> Plan {
        let result: Result<Plan, UsageAPI.Error> = lock.withLock {
            planTokens.append(token.value)
            return planResults.isEmpty ? .failure(.httpStatus(599)) : planResults.removeFirst()
        }
        return try result.get()
    }
}

@MainActor
final class RecordingDelivery: WarningDelivery {
    var accepting: Bool
    private(set) var offered: [RateLimit] = []
    private(set) var identifiers: [String] = []

    init(accepting: Bool = true) {
        self.accepting = accepting
    }

    func deliver(_ limit: RateLimit, identifier: String, now: Date) async -> Bool {
        offered.append(limit)
        identifiers.append(identifier)
        return accepting
    }
}

final class TestClock: Sendable {
    private let time: Mutex<Date>
    init(_ start: Date) { time = Mutex(start) }
    var now: Date { time.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { time.withLock { $0 += seconds } }
}

/// Hands out tokens in order, then repeats the last one.
final class Tokens: Sendable {
    private let values: Mutex<[String]>
    init(_ values: [String]) { self.values = Mutex(values) }
    func next() -> AccessToken {
        AccessToken(values.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] })
    }
}

func reading(_ value: String) -> TokenReader {
    { AccessToken(value) }
}

func failing(_ error: CredentialError) -> TokenReader {
    { () async throws(CredentialError) -> AccessToken in throw error }
}

@MainActor
final class Rig {
    let store: SnapshotStore
    let fetcher: ScriptedFetcher
    let delivery: any WarningDelivery
    let clock: TestClock
    let service: UsageService
    /// An absolute path makes the domain a plist in the temporary directory, so test runs
    /// never write to ~/Library/Preferences.
    private let suiteName = FileManager.default.temporaryDirectory
        .appendingPathComponent("limitgauge-tests-\(UUID().uuidString)").path

    init(
        usage: [Result<UsageSnapshot, UsageAPI.Error>] = [],
        plan: [Result<Plan, UsageAPI.Error>] = [],
        readToken: @escaping TokenReader = reading("a"),
        seed: UsageSnapshot? = nil,
        seedPlan: Plan? = nil,
        delivery: any WarningDelivery = RecordingDelivery(),
        thresholds: WarningThresholds = .default,
        clock: TestClock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    ) {
        store = SnapshotStore(defaults: UserDefaults(suiteName: suiteName)!)
        if let seed { store.save(snapshot: seed) }
        if let seedPlan { store.save(plan: FetchedPlan(plan: seedPlan, fetchedAt: clock.now.addingTimeInterval(-3600))) }
        fetcher = ScriptedFetcher(usage: usage, plan: plan)
        self.delivery = delivery
        self.clock = clock
        service = UsageService(readToken: readToken, fetcher: fetcher, store: store, delivery: delivery,
                               thresholds: { thresholds }, now: { clock.now })
        service.deliveryTimeout = .milliseconds(200)
    }

    /// Sets the service's `onChange`, handing it the service. A closure that captured the rig
    /// would form a cycle through the service, the rig would never deinit, and its plist would
    /// stay in the temporary directory.
    func onChange(_ body: @escaping @MainActor (UsageService) -> Void) {
        service.onChange = { [unowned service] in body(service) }
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(atPath: suiteName + ".plist")
    }
}
