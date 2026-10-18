import Foundation

/// Persists the last snapshot and plan so the menu is populated at launch.
public struct SnapshotStore {
    private let defaults: UserDefaults
    private let snapshotKey = "snapshot"
    private let planKey = "plan"
    private let planFetchedAtKey = "planFetchedAt"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadSnapshot() -> UsageSnapshot? {
        defaults.data(forKey: snapshotKey).flatMap { try? JSONDecoder().decode(UsageSnapshot.self, from: $0) }
    }

    public func loadPlan() -> (Plan, Date)? {
        guard let data = defaults.data(forKey: planKey),
              let plan = try? JSONDecoder().decode(Plan.self, from: data),
              let at = defaults.object(forKey: planFetchedAtKey) as? Date
        else { return nil }
        return (plan, at)
    }

    public func save(snapshot: UsageSnapshot?) {
        defaults.set(snapshot.flatMap { try? JSONEncoder().encode($0) }, forKey: snapshotKey)
    }

    public func save(plan: Plan?, fetchedAt: Date?) {
        defaults.set(plan.flatMap { try? JSONEncoder().encode($0) }, forKey: planKey)
        defaults.set(fetchedAt, forKey: planFetchedAtKey)
    }
}
