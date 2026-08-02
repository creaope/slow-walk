import Foundation

/// The wall of waiting between scripted demo legs.
///
/// Isolated behind a protocol so the automatic timeline can be driven
/// deterministically in tests: the production sleeper uses `Task.sleep`,
/// while a test double parks on continuations the test releases at chosen
/// moments. This is the seam that makes the stale-session race observable
/// without a real clock.
protocol DemoOutingSleeping: Sendable {
    /// Waits for one scripted leg to elapse.
    ///
    /// - Throws: `CancellationError` when the owning session is cancelled or
    ///   replaced, so a stale leg never publishes after its session ended.
    func sleep(for duration: Duration) async throws
}

/// Production sleeper backed by `Task.sleep`.
struct TaskDemoOutingSleeper: DemoOutingSleeping {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
