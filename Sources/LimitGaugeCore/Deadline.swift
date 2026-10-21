import Foundation

/// Races work against a timer and returns whichever finishes first. The losing work is
/// abandoned, not awaited: a task group would wait for a child stuck in a call that never
/// returns, which is the hang this exists to prevent.
enum Deadline {
    /// `work`'s value, or nil if `timeout` passed first.
    static func race<T: Sendable>(_ timeout: Duration, _ work: @escaping @Sendable () async -> T) async -> T? {
        let once = ResumeOnce<T?>()
        return await withCheckedContinuation { continuation in
            once.install(continuation)
            let sleeper = Task {
                try? await Task.sleep(for: timeout)
                once.resume(nil)
            }
            Task {
                once.resume(await work())
                sleeper.cancel()
            }
        }
    }
}
