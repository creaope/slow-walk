import Foundation

/// The single place where companion flow transitions are decided.
///
/// `nextState(from:on:)` is a pure function: it reads no clock, writes no
/// records, and starts no work. Side effects belong to
/// `CompanionSessionModel`, which keeps this logic reviewable and testable on
/// its own.
///
/// - Important: `.travelling` is currently unreachable, and that is the point.
///   Departure is only legitimate after a formal medicine assessment has
///   produced a result, and no adapter in this build can produce one. The
///   `.travelling` → `.approachingStop` → `.completed` transitions are kept
///   because they are correct and tested; they simply have no entry until the
///   assessment path exists. Restoring an entry into `.travelling` that does
///   not carry an assessment result would reintroduce the defect
///   `.awaitingMedicineAssessment` was added to close.
///
/// - Note: The project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
///   so this type is main-actor isolated like the rest of the app. It holds no
///   state, so a future test target can exercise it directly from
///   `@MainActor` tests.
enum CompanionFlowReducer {
    /// Returns the next state, or `nil` when the event does not apply.
    ///
    /// Returning `nil` rather than throwing lets callers ignore stale or
    /// repeated input without any side effect.
    static func nextState(
        from state: CompanionFlowState,
        on event: CompanionFlowEvent
    ) -> CompanionFlowState? {
        // Ending early is available from any step that is underway.
        if case .endEarly = event {
            return state.isActive ? .completed(.endedEarly) : nil
        }

        switch (state, event) {
        case (.notStarted, .startCompanion),
             (.completed, .startCompanion):
            // A finished session can be followed by a new one; the previous
            // session stays in the care records.
            return .preDepartureCheck

        case (.preDepartureCheck, .beginMedicineRead):
            return .scanningMedicine(.first)

        case let (.scanningMedicine(attempt), .medicineReadDidNotSucceed(setback)):
            guard !attempt.isAwaitingRecovery else { return nil }
            return .scanningMedicine(attempt.interrupted(by: setback))

        case let (.scanningMedicine(attempt), .retryMedicineRead):
            guard attempt.isAwaitingRecovery else { return nil }
            return .scanningMedicine(attempt.retried())

        case let (.scanningMedicine(attempt), .medicineCandidatesReady(candidates)):
            guard !attempt.isAwaitingRecovery, !candidates.isEmpty else { return nil }
            return .awaitingMedicineConfirmation(
                MedicineConfirmationPrompt(
                    candidates: candidates,
                    origin: .readFromPhoto,
                    attemptNumber: attempt.attemptNumber
                )
            )

        case let (.scanningMedicine(attempt), .chooseFromFrequentList(candidates)):
            guard !candidates.isEmpty else { return nil }
            return .awaitingMedicineConfirmation(
                MedicineConfirmationPrompt(
                    candidates: candidates,
                    origin: .chosenFromFrequentList,
                    attemptNumber: attempt.attemptNumber
                )
            )

        case let (.awaitingMedicineConfirmation(prompt), .retakeMedicinePhoto):
            // None of the offered candidates matched the box in hand. Going
            // back to reading is the recovery path the confirmation step
            // promises, so this step is never a dead end.
            return .scanningMedicine(
                MedicineReadAttempt(
                    attemptNumber: prompt.attemptNumber + 1,
                    setback: nil
                )
            )

        case let (.awaitingMedicineConfirmation(prompt), .confirmMedicine(candidate)):
            guard prompt.candidates.contains(candidate) else { return nil }
            // Confirming answers "which box is this", not "is it safe to
            // take". The session therefore goes to the assessment gate, never
            // straight to anything that shows a care action: a confirmed name
            // is not an assessment result, and treating it as one is how a
            // person ends up leaving the house on the strength of a name.
            return .awaitingMedicineAssessment(
                MedicineAssessmentGate(
                    confirmed: ConfirmedMedicine(
                        candidate: candidate,
                        origin: prompt.origin
                    ),
                    prompt: prompt,
                    progress: .notStarted
                )
            )

        case let (.awaitingMedicineAssessment(gate), .medicineAssessmentDidNotSucceed(setback)):
            // Only the first setback lands, so a repeated failure cannot
            // reopen a step the person has already been offered a way out of.
            guard !gate.isAwaitingRecovery else { return nil }
            return .awaitingMedicineAssessment(
                MedicineAssessmentGate(
                    confirmed: gate.confirmed,
                    prompt: gate.prompt,
                    progress: .couldNotAssess(setback)
                )
            )

        case let (.awaitingMedicineAssessment(gate), .reconsiderMedicineChoice):
            // The gate is never a dead end: the candidate list it came from is
            // still available, so a different medicine can be chosen without
            // re-reading the box.
            return .awaitingMedicineConfirmation(gate.prompt)

        case let (.awaitingMedicineAssessment(gate), .retakeMedicinePhoto):
            // The other way out: read the box again from the start.
            return .scanningMedicine(
                MedicineReadAttempt(
                    attemptNumber: gate.prompt.attemptNumber + 1,
                    setback: nil
                )
            )

        // There is deliberately no transition out of
        // `.awaitingMedicineAssessment` into `.travelling`. Departure requires
        // a real assessment result, and this build cannot produce one, so the
        // only ways on from the gate are to choose again, read again, or end
        // the session. Adding a departure path here without a result is the
        // exact defect this state exists to prevent.

        case (.travelling, .approachStop):
            return .approachingStop

        case (.approachingStop, .arriveSafely):
            return .completed(.arrivedSafely)

        default:
            return nil
        }
    }
}
