import Foundation
@testable import SlowWalkApp

/// A `MedicineScanSimulating` double that records every call and returns a
/// scripted outcome.
///
/// It holds no risk state and no recovery logic — it only observes whether the
/// session asked for an outcome, which is exactly what the stale-read tests
/// need to assert (a stale read must never reach `outcome(...)`).
@MainActor
final class SpyScanSimulator: MedicineScanSimulating {
    /// The attempt numbers `outcome(forAttemptNumber:)` was called with, in
    /// order. Empty means no read resolved far enough to consult the
    /// simulator.
    private(set) var outcomeCalls: [Int] = []

    /// The outcome handed back on the next call, or `nil` to model a read that
    /// produces nothing.
    let scriptedOutcome: MockMedicineScanSimulator.Outcome?

    init(scriptedOutcome: MockMedicineScanSimulator.Outcome? = nil) {
        self.scriptedOutcome = scriptedOutcome
    }

    func outcome(forAttemptNumber attemptNumber: Int)
        -> MockMedicineScanSimulator.Outcome?
    {
        outcomeCalls.append(attemptNumber)
        return scriptedOutcome
    }
}
