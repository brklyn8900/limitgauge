import Foundation
import Synchronization
import Testing
@testable import LimitGaugeCore

private let codexTime = Date(timeIntervalSince1970: 1_800_000_000)

@MainActor
@Suite struct CodexServiceTests {
    private func reading(percent: Int = 20) -> CodexUsageReading {
        CodexUsageReading(snapshot: UsageSnapshot(limits: [
            RateLimit(kind: .other("codex:codex:primary"), percent: percent,
                      resetsAt: codexTime.addingTimeInterval(3600), displayTitle: "Codex · 5 hours")
        ], fetchedAt: codexTime), plan: Plan(rateLimitTier: "pro"))
    }

    @Test func providersPersistIndependentlyAndKeepLegacyClaudeKeys() async {
        let fixture = StoreFixture()
        defer { fixture.clean() }
        let claude = SnapshotStore(defaults: fixture.defaults)
        let codex = SnapshotStore(defaults: fixture.defaults, namespace: "codex")
        let old = UsageSnapshot(limits: [], fetchedAt: codexTime.addingTimeInterval(-60))
        claude.save(snapshot: old)
        let value = reading()
        let service = UsageService(readCodex: { value }, store: codex, delivery: RecordingDelivery(),
                                   thresholds: { .default }, now: { codexTime })
        #expect(service.snapshot == nil)
        #expect(await service.refresh(.launch).value == .fetched)
        #expect(claude.loadSnapshot() == old)
        #expect(codex.loadSnapshot() == value.snapshot)
        #expect(codex.loadPlan()?.plan == value.plan)
        #expect(fixture.defaults.data(forKey: "snapshot") != nil)
        #expect(fixture.defaults.data(forKey: "codex.snapshot") != nil)
    }

    @Test func menuCacheAndConcurrentRequestsUseOneRead() async {
        let fixture = StoreFixture()
        defer { fixture.clean() }
        let calls = Mutex(0)
        let value = reading()
        let service = UsageService(readCodex: {
            calls.withLock { $0 += 1 }
            return value
        }, store: SnapshotStore(defaults: fixture.defaults), delivery: RecordingDelivery(),
           thresholds: { .default }, now: { codexTime })
        let first = service.refresh(.launch)
        let second = service.refresh(.menuOpen)
        #expect(await first.value == .fetched)
        #expect(await second.value == .fetched)
        #expect(await service.refresh(.menuOpen).value == .skipped)
        #expect(calls.withLock { $0 } == 1)
        #expect(service.nextPoll == codexTime.addingTimeInterval(3600))
    }

    @Test func failedReadRetainsSnapshotAndBacksOff() async {
        let fixture = StoreFixture()
        defer { fixture.clean() }
        let store = SnapshotStore(defaults: fixture.defaults, namespace: "codex")
        let old = reading(percent: 75).snapshot
        store.save(snapshot: old)
        let service = UsageService(readCodex: { () async throws(CodexUsageError) -> CodexUsageReading in
            throw .unavailable
        }, store: store, delivery: RecordingDelivery(), thresholds: { .default }, now: { codexTime })
        #expect(await service.refresh(.refreshRow).value == .failed(.codex(.unavailable)))
        #expect(service.snapshot == old)
        #expect(service.nextPoll == codexTime.addingTimeInterval(600))
        _ = await service.refresh(.refreshRow).value
        #expect(service.nextPoll == codexTime.addingTimeInterval(1200))
        #expect(store.loadSnapshot() == old)
    }

    @Test func warningSurvivesRelaunchAndDoesNotTouchClaudeWarnings() async {
        let fixture = StoreFixture()
        defer { fixture.clean() }
        let claude = SnapshotStore(defaults: fixture.defaults)
        let store = SnapshotStore(defaults: fixture.defaults, namespace: "codex")
        let value = reading(percent: 90)
        let delivery = RecordingDelivery()
        let service = UsageService(readCodex: { value }, store: store, delivery: delivery,
                                   thresholds: { .default }, now: { codexTime })
        _ = await service.refresh(.launch).value
        #expect(delivery.offered.count == 1)
        #expect(delivery.identifiers[0].hasPrefix("codex:"))
        #expect(claude.loadFiredWarnings().isEmpty)
        let relaunched = UsageService(readCodex: { value }, store: store, delivery: delivery,
                                      thresholds: { .default }, now: { codexTime })
        _ = await relaunched.refresh(.refreshRow).value
        #expect(delivery.offered.count == 1)
        #expect(relaunched.snapshot?.limits.first?.title == "Codex · 5 hours")
    }

    @Test func missingInstallNeedsUserAndNeverInventsZeroUsage() async {
        let fixture = StoreFixture()
        defer { fixture.clean() }
        let service = UsageService(readCodex: { () async throws(CodexUsageError) -> CodexUsageReading in
            throw .notInstalled
        }, store: SnapshotStore(defaults: fixture.defaults), delivery: RecordingDelivery(),
           thresholds: { .default }, now: { codexTime })
        #expect(await service.refresh(.launch).value == .failed(.codex(.notInstalled)))
        #expect(service.snapshot == nil)
        #expect(service.nextPoll == codexTime.addingTimeInterval(3600))
    }

    @Test func oldSnapshotsStillDecodeWithoutDisplayTitle() throws {
        let value = RateLimit(kind: .session, percent: 15, resetsAt: codexTime)
        let data = try JSONEncoder().encode(value)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["displayTitle"] == nil)
        #expect(try JSONDecoder().decode(RateLimit.self, from: data).title == "Current session")
    }
}

private struct StoreFixture {
    let name: String
    let defaults: UserDefaults
    init() {
        name = FileManager.default.temporaryDirectory.appendingPathComponent("codex-service-tests-\(UUID().uuidString)").path
        defaults = UserDefaults(suiteName: name)!
    }
    func clean() {
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(atPath: name + ".plist")
    }
}
