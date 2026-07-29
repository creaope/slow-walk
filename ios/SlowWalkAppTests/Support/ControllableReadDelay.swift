import Foundation
@testable import SlowWalkApp

/// A `MedicineReadDelaying` double that parks a read on a continuation the
/// test releases by hand.
///
/// This is the seam that makes the stale-read race deterministic: instead of
/// sleeping for a duration and hoping the test wins the race to abandon the
/// read, the read suspends on a continuation and cannot resume until the test
/// calls `release()`. No real sleep, no `Task.yield()` polling, and no test
/// clock is used.
@MainActor
final class ControllableReadDelay: MedicineReadDelaying {
    /// The continuation the in-flight read is parked on, or `nil` when no read
    /// is currently waiting.
    private var parked: CheckedContinuation<Void, Error>?

    /// Resumed by `wait()` the moment it installs `parked`, so a test can await
    /// "the read has actually started waiting" before it abandons the read.
    private var installWaiter: CheckedContinuation<Void, Never>?

    /// Number of times `wait()` has installed a continuation.
    private(set) var installCount = 0

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            parked = continuation
            installCount += 1
            // If a test is already awaiting installation, unblock it now that
            // the read is genuinely parked.
            if let waiter = installWaiter {
                installWaiter = nil
                waiter.resume()
            }
        }
    }

    /// Suspends until a read has installed its continuation, then returns.
    ///
    /// Call this after `beginMedicineRead()` so the test never races ahead of
    /// the read actually starting. If a read is already parked, returns at
    /// once.
    func waitForInstall() async {
        if parked != nil { return }
        await withCheckedContinuation { continuation in
            installWaiter = continuation
        }
    }

    /// Releases the parked read so its task can run to the generation guard.
    ///
    /// Returns `false` when no continuation is installed — useful for
    /// asserting that a read never even reached the waiting stage. Resuming is
    /// idempotent-safe: `parked` is cleared first, so a double call cannot
    /// resume a continuation twice.
    @discardableResult
    func release() -> Bool {
        guard let continuation = parked else { return false }
        parked = nil
        continuation.resume()
        return true
    }
}
