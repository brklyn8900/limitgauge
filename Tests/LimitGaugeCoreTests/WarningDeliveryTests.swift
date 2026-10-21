import Foundation
import Testing
@testable import LimitGaugeCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func snapshot(percent: Int) -> UsageSnapshot {
    UsageSnapshot(limits: [RateLimit(kind: .session, percent: percent, resetsAt: t0.addingTimeInterval(3600))],
                  fetchedAt: t0)
}

/// Holds every delivery until released, to catch a warning offered twice while in flight.
@MainActor
final class GatedDelivery: WarningDelivery {
    private(set) var offered: [RateLimit] = []
    private var waiting: [CheckedContinuation<Bool, Never>] = []

    func deliver(_ limit: RateLimit, identifier: String, now: Date) async -> Bool {
        offered.append(limit)
        return await withCheckedContinuation { waiting.append($0) }
    }

    func release(accepting: Bool) {
        waiting.forEach { $0.resume(returning: accepting) }
        waiting = []
    }
}

@MainActor
@Suite struct WarningDeliveryTests {
    /// Today the warning counts as posted before delivery, so with notifications off the
    /// window's warning is lost.
    @Test func undeliveredWarningStaysPendingUntilAccepted() async {
        let delivery = RecordingDelivery(accepting: false)
        let rig = Rig(usage: [.success(snapshot(percent: 90))], delivery: delivery)
        _ = await rig.service.refresh(.refreshRow).value
        #expect(delivery.offered.map(\.kind) == [.session])
        #expect(rig.store.loadFiredWarnings().isEmpty)

        delivery.accepting = true
        await rig.service.settingsChanged().value
        #expect(delivery.offered.count == 2)
        #expect(rig.store.loadFiredWarnings().count == 1)

        await rig.service.settingsChanged().value
        #expect(delivery.offered.count == 2)
    }

    /// A delivery that never answers must not hold the refresh, or polling stops.
    @Test func hungDeliveryIsAbandonedAtTheDeadline() async throws {
        let delivery = GatedDelivery()
        let rig = Rig(usage: [.success(snapshot(percent: 90))], delivery: delivery)
        _ = rig.service.refresh(.refreshRow)
        try await Task.sleep(for: .milliseconds(500))
        #expect(!rig.service.isRefreshing)
        #expect(rig.store.loadFiredWarnings().isEmpty)
        delivery.release(accepting: true)
    }

    /// Today every fetch made a new key and the Fable warning re-fired (seen 2026-10-21). The
    /// request identifier comes from the key, so a repeat would replace, not stack.
    @Test func jitteredResetDoesNotRefire() async throws {
        let a = try #require(ISO8601.date("2026-10-21T21:10:00.462+00:00"))
        let b = try #require(ISO8601.date("2026-10-21T21:09:59.776+00:00"))
        let at = a.addingTimeInterval(-3 * 3600)
        func fable(_ resetsAt: Date) -> UsageSnapshot {
            UsageSnapshot(limits: [RateLimit(kind: .weeklyScoped, percent: 83, resetsAt: resetsAt, scopeName: "Fable")], fetchedAt: at)
        }
        let delivery = RecordingDelivery()
        let rig = Rig(usage: [.success(fable(a)), .success(fable(b))], delivery: delivery, clock: TestClock(at))
        _ = await rig.service.refresh(.refreshRow).value
        _ = await rig.service.refresh(.refreshRow).value
        #expect(delivery.offered.count == 1)
        #expect(delivery.identifiers == [WarningKey(RateLimit(kind: .weeklyScoped, percent: 83, resetsAt: b, scopeName: "Fable")).notificationIdentifier])
    }

    /// A settings change while the refresh's delivery is pending must not post it again.
    @Test func warningBeingDeliveredIsNotOfferedTwice() async {
        let delivery = GatedDelivery()
        let rig = Rig(usage: [.success(snapshot(percent: 90))], delivery: delivery)
        let refresh = rig.service.refresh(.refreshRow)
        while delivery.offered.isEmpty { await Task.yield() }
        let change = rig.service.settingsChanged()
        delivery.release(accepting: true)
        _ = await refresh.value
        await change.value
        #expect(delivery.offered.count == 1)
    }
}
