import Foundation
import SlowWalkAPIContracts
import SlowWalkClientCore

/// The single place where companion flow transitions are decided.
///
/// `nextState(from:on:)` is a pure function: it reads no clock, writes no
/// records, and starts no work. Side effects belong to
/// `CompanionSessionModel`, which keeps this logic reviewable and testable on
/// its own.
///
/// - Important: `.travelling` and medicine-only completion are reachable from
///   the assessment gate only after the current canonical result's request ID
///   has been acknowledged as actually displayed.
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

        case (.preDepartureCheck, .beginMedicineCaptureAssessment):
            return .awaitingMedicineAssessment(
                MedicineAssessmentGate(latestUpdate: nil)
            )

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

        case let (.preDepartureCheck, .chooseFromFrequentList(candidates)):
            guard !candidates.isEmpty else { return nil }
            return .awaitingMedicineConfirmation(
                MedicineConfirmationPrompt(
                    candidates: candidates,
                    origin: .chosenFromFrequentList,
                    attemptNumber: 1
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
                    latestUpdate: nil,
                    displayedResultRequestID: nil
                )
            )

        case let (.awaitingMedicineAssessment(gate), .medicineAssessmentStateDidUpdate(update)):
            // Staleness guard based on operation generation, not per-publish:
            // - Lower sequenceNumber: old operation → reject.
            // - Same sequenceNumber, same state: exact duplicate → reject.
            // - Same sequenceNumber, different state: normal progression within
            //   the same operation (e.g. recognizing → assessing → result) → accept.
            // - Higher sequenceNumber: new operation → accept.
            if let current = gate.latestUpdate {
                if update.sequenceNumber < current.sequenceNumber {
                    return nil
                }
                if update.sequenceNumber == current.sequenceNumber,
                   update.state == current.state {
                    return nil
                }
            }
            // Every canonical case is accepted and stored; the gate itself
            // remains the session state regardless of which case it is.
            // A `.result` alone does not earn qualification. Its request ID
            // must also be acknowledged by the display event below.
            switch update.state {
            case .idle, .recognizing, .requiresMedicineConfirmation,
                 .assessing, .result, .failed, .cancelled:
                break
            }
            return .awaitingMedicineAssessment(
                MedicineAssessmentGate(
                    preAssessmentSelection: gate.preAssessmentSelection,
                    latestUpdate: update,
                    displayedResultRequestID: gate.displayedResultRequestID
                )
            )

        case let (
            .awaitingMedicineAssessment(gate),
            .medicineAssessmentResultDidDisplay(requestID)
        ):
            guard case let .result(presentation) = gate.assessmentState,
                  presentation.response.requestID == requestID,
                  gate.displayedResultRequestID != requestID
            else { return nil }
            return .awaitingMedicineAssessment(
                MedicineAssessmentGate(
                    preAssessmentSelection: gate.preAssessmentSelection,
                    latestUpdate: gate.latestUpdate,
                    displayedResultRequestID: requestID
                )
            )

        case let (.awaitingMedicineAssessment(gate), .continueToOuting):
            guard gate.hasDisplayedCurrentResult else { return nil }
            return .travelling

        case let (.awaitingMedicineAssessment(gate), .completeMedicineCheck):
            guard gate.hasDisplayedCurrentResult else { return nil }
            return .completed(.completedMedicineCheck)

        case let (.awaitingMedicineAssessment(gate), .reconsiderMedicineChoice):
            // The gate is never a dead end: the candidate list it came from is
            // still available, so a different medicine can be chosen without
            // re-reading the box.
            guard let prompt = gate.preAssessmentSelection?.prompt else {
                return nil
            }
            return .awaitingMedicineConfirmation(prompt)

        case let (
            .awaitingMedicineAssessment,
            .chooseFromFrequentList(candidates)
        ):
            guard !candidates.isEmpty else { return nil }
            return .awaitingMedicineConfirmation(
                MedicineConfirmationPrompt(
                    candidates: candidates,
                    origin: .chosenFromFrequentList,
                    attemptNumber: 1
                )
            )

        case let (.awaitingMedicineAssessment(gate), .retakeMedicinePhoto):
            // The other way out: read the box again from the start.
            guard let prompt = gate.preAssessmentSelection?.prompt else {
                return nil
            }
            return .scanningMedicine(
                MedicineReadAttempt(
                    attemptNumber: prompt.attemptNumber + 1,
                    setback: nil
                )
            )

        case (.travelling, .approachStop):
            return .approachingStop

        case (.approachingStop, .arriveSafely):
            return .completed(.arrivedSafely)

        default:
            return nil
        }
    }
}
