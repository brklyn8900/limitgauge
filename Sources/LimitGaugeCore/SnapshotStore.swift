import Foundation

struct FetchedPlan: Equatable, Sendable {
    var plan: Plan
    var fetchedAt: Date
}

/// Persists what `UsageService` must remember across launches: the last snapshot, the plan,
/// and the warnings already posted. The app only creates one and hands it over; loading and
/// saving are internal, so only the service reads or writes it.
public struct SnapshotStore {
    private let defaults: UserDefaults
    private let snapshotKey: String
    private let planKey: String
    private let planFetchedAtKey: String
    /// The key `Settings.firedWarnings` used, so posted warnings survive the upgrade.
    private let firedWarningsKey: String

    public init(defaults: UserDefaults = .standard, namespace: String = "") {
        self.defaults = defaults
        let prefix = namespace.isEmpty ? "" : namespace + "."
        snapshotKey = prefix + "snapshot"
        planKey = prefix + "plan"
        planFetchedAtKey = prefix + "planFetchedAt"
        firedWarningsKey = prefix + "firedWarnings"
    }

    func loadSnapshot() -> UsageSnapshot? {
        defaults.data(forKey: snapshotKey).flatMap { try? JSONDecoder().decode(UsageSnapshot.self, from: $0) }
    }

    func loadPlan() -> FetchedPlan? {
        guard let data = defaults.data(forKey: planKey),
              let plan = try? JSONDecoder().decode(Plan.self, from: data),
              let at = defaults.object(forKey: planFetchedAtKey) as? Date
        else { return nil }
        return FetchedPlan(plan: plan, fetchedAt: at)
    }

    func loadFiredWarnings() -> Set<WarningKey> {
        defaults.data(forKey: firedWarningsKey).flatMap { try? JSONDecoder().decode(Set<WarningKey>.self, from: $0) } ?? []
    }

    func save(snapshot: UsageSnapshot) {
        defaults.set(try? JSONEncoder().encode(snapshot), forKey: snapshotKey)
    }

    func save(plan: FetchedPlan) {
        defaults.set(try? JSONEncoder().encode(plan.plan), forKey: planKey)
        defaults.set(plan.fetchedAt, forKey: planFetchedAtKey)
    }

    func save(firedWarnings: Set<WarningKey>) {
        defaults.set(try? JSONEncoder().encode(firedWarnings), forKey: firedWarningsKey)
    }
}
