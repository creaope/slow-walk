import Foundation

/// The wall of waiting between starting a read and resolving it.
///
/// Isolated behind a protocol so a read can be driven deterministically in
/// tests: the production double sleeps for the demo duration, while a test
/// double parks on a continuation the test releases at a chosen moment. This
/// is the seam that makes the stale-read race observable without a real clock.
@MainActor
protocol MedicineReadDelaying {
    /// Blocks the caller until the simulated read should resolve.
    func wait() async throws
}

/// Produces the outcome of a simulated medicine scan for a given attempt.
///
/// Isolated behind a protocol so tests can swap in a spy that records calls,
/// instead of the demo double that hands out a fixed script.
@MainActor
protocol MedicineScanSimulating {
    func outcome(forAttemptNumber attemptNumber: Int)
        -> MockMedicineScanSimulator.Outcome?
}

/// Production read delay: sleeps for the simulated read duration.
///
/// A struct is enough — it holds no state — and under the project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` it is main-actor isolated, so
/// it satisfies the `@MainActor` `MedicineReadDelaying` protocol.
struct ContinuousMedicineReadDelay: MedicineReadDelaying {
    func wait() async throws {
        try await Task.sleep(
            for: MockMedicineScanSimulator.simulatedReadDuration
        )
    }
}

/// Drives the demo medicine-reading step without any camera or OCR.
///
/// The real reader will be a `MedicineTextRecognizing` adapter backed by
/// Vision, injected at the composition root. This simulator exists so the
/// companion flow — including one failed read and its recovery — can be walked
/// through and reviewed before any platform capability is wired up.
///
/// DEMO DATA — NOT FOR CLINICAL USE.
struct MockMedicineScanSimulator: MedicineScanSimulating {
    /// What the next simulated read should do.
    enum Outcome: Equatable, Hashable {
        case doesNotSucceed(MedicineReadSetback)
        case findsCandidates([MedicineCandidate])
    }

    /// Outcomes in the order they are handed out, one per attempt.
    ///
    /// The default script shows a first read that does not succeed, so the
    /// recovery path is part of the main walkthrough rather than an edge case.
    let scriptedOutcomes: [Outcome]

    static let demo = MockMedicineScanSimulator(
        scriptedOutcomes: [
            .doesNotSucceed(.textNotLegible),
            .findsCandidates(MedicineCandidate.demoCandidates),
        ]
    )

    /// The outcome for a given attempt. The last entry repeats so a person can
    /// retry as many times as they like without hitting a dead end.
    func outcome(forAttemptNumber attemptNumber: Int) -> Outcome? {
        guard !scriptedOutcomes.isEmpty else { return nil }
        let index = min(max(attemptNumber, 1), scriptedOutcomes.count) - 1
        return scriptedOutcomes[index]
    }

    /// How long the simulated read appears to take.
    static let simulatedReadDuration = Duration.milliseconds(900)
}
