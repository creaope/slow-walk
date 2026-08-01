import Testing
import Foundation
import SlowWalkClientCore
import SlowWalkAPIContracts
import SlowWalkDomain
@testable import SlowWalkApp

/// Pure-function tests for `CompanionFlowReducer`.
///
/// These exercise the transition table in isolation: no records, no simulator,
/// no time. A model-level test cannot prove the reducer is correct because the
/// model's side effects can mask a wrong transition, so the reducer is tested
/// directly.
@MainActor
struct CompanionFlowReducerTests {

    // MARK: - Starting a session

    @Test func notStartedCanStart() {
        let next = CompanionFlowReducer.nextState(from: .notStarted, on: .startCompanion)
        #expect(next == .preDepartureCheck)
    }

    @Test func completedCanStartNewRound() {
        let next = CompanionFlowReducer.nextState(
            from: .completed(.arrivedSafely),
            on: .startCompanion
        )
        #expect(next == .preDepartureCheck)
    }

    @Test func activeStateRejectsRepeatedStart() {
        // preDepartureCheck is active; a second startCompanion must be refused.
        let next = CompanionFlowReducer.nextState(
            from: .preDepartureCheck,
            on: .startCompanion
        )
        #expect(next == nil)
    }

    // MARK: - Refused and repeated events

    @Test func illegalEventReturnsNil() {
        // beginMedicineRead is only valid from preDepartureCheck, not notStarted.
        let next = CompanionFlowReducer.nextState(
            from: .notStarted,
            on: .beginMedicineRead
        )
        #expect(next == nil)
    }

    @Test func repeatedFailureHasNoEffect() {
        // First failure interrupts the attempt and offers recovery.
        let interrupted = CompanionFlowReducer.nextState(
            from: .scanningMedicine(.first),
            on: .medicineReadDidNotSucceed(.textNotLegible)
        )
        #expect(interrupted == .scanningMedicine(.first.interrupted(by: .textNotLegible)))

        // Once recovery is offered, a second failure on the same attempt is
        // refused — the person must pick a recovery path instead.
        let second = CompanionFlowReducer.nextState(
            from: .scanningMedicine(.first.interrupted(by: .textNotLegible)),
            on: .medicineReadDidNotSucceed(.textNotLegible)
        )
        #expect(second == nil)
    }

    // MARK: - Ending early

    @Test func endEarlyEntersCompleted() {
        let next = CompanionFlowReducer.nextState(from: .travelling, on: .endEarly)
        #expect(next == .completed(.endedEarly))
    }

    @Test func endEarlyRefusedWhenNotActive() {
        let next = CompanionFlowReducer.nextState(from: .notStarted, on: .endEarly)
        #expect(next == nil)
    }

    // MARK: - isActive coverage

    @Test func isActiveCoversEveryCase() {
        let inactive: [CompanionFlowState] = [
            .notStarted,
            .completed(.arrivedSafely),
            .completed(.endedEarly),
        ]
        for state in inactive {
            #expect(state.isActive == false, "expected inactive: \(state)")
        }

        let active: [CompanionFlowState] = [
            .preDepartureCheck,
            .scanningMedicine(.first),
            .scanningMedicine(.first.interrupted(by: .textNotLegible)),
            .awaitingMedicineConfirmation(
                MedicineConfirmationPrompt(
                    candidates: MedicineCandidate.demoCandidates,
                    origin: .readFromPhoto,
                    attemptNumber: 1
                )
            ),
            .awaitingMedicineAssessment(
                MedicineAssessmentGate(
                    confirmed: ConfirmedMedicine(
                        candidate: MedicineCandidate.demoCandidates[0],
                        origin: .readFromPhoto
                    ),
                    prompt: MedicineConfirmationPrompt(
                        candidates: MedicineCandidate.demoCandidates,
                        origin: .readFromPhoto,
                        attemptNumber: 1
                    ),
                    latestUpdate: nil
                )
            ),
            .travelling,
            .approachingStop,
        ]
        for state in active {
            #expect(state.isActive == true, "expected active: \(state)")
        }
    }

    // MARK: - Canonical state update — staleness

    @Test func lowerSequenceNumberRejected() {
        let gate = makeGate(
            latestUpdate: MedicineAssessmentStateUpdate(
                sequenceNumber: 5,
                state: .idle
            )
        )
        let stale = MedicineAssessmentStateUpdate(
            sequenceNumber: 3,
            state: .assessing(startedAt: Date(timeIntervalSince1970: 0))
        )
        let next = CompanionFlowReducer.nextState(
            from: .awaitingMedicineAssessment(gate),
            on: .medicineAssessmentStateDidUpdate(stale)
        )
        #expect(next == nil, "lower generation must be rejected")
    }

    @Test func sameSequenceDifferentStateProgressionIsAccepted() {
        let date = Date(timeIntervalSince1970: 0)
        let gate = makeGate(latestUpdate: nil)

        // recognizing(7)
        let recognizing = MedicineAssessmentStateUpdate(
            sequenceNumber: 7,
            state: .recognizing(startedAt: date)
        )
        let r1 = CompanionFlowReducer.nextState(
            from: .awaitingMedicineAssessment(gate),
            on: .medicineAssessmentStateDidUpdate(recognizing)
        )
        #expect(r1 != nil, "recognizing(7) should be accepted")
        guard case let .awaitingMedicineAssessment(g1)? = r1 else {
            Issue.record("expected gate after recognizing")
            return
        }

        // assessing(7) — same operation, different state
        let assessing = MedicineAssessmentStateUpdate(
            sequenceNumber: 7,
            state: .assessing(startedAt: date)
        )
        let r2 = CompanionFlowReducer.nextState(
            from: .awaitingMedicineAssessment(g1),
            on: .medicineAssessmentStateDidUpdate(assessing)
        )
        #expect(r2 != nil, "assessing(7) should be accepted within same operation")
        guard case let .awaitingMedicineAssessment(g2)? = r2 else {
            Issue.record("expected gate after assessing")
            return
        }

        // result(7) — same operation, different state
        let result = MedicineAssessmentStateUpdate(
            sequenceNumber: 7,
            state: .result(MedicineAssessmentGateTests.presentation)
        )
        let r3 = CompanionFlowReducer.nextState(
            from: .awaitingMedicineAssessment(g2),
            on: .medicineAssessmentStateDidUpdate(result)
        )
        #expect(r3 != nil, "result(7) should be accepted within same operation")
        guard case let .awaitingMedicineAssessment(g3)? = r3 else {
            Issue.record("expected gate after result")
            return
        }
        #expect(g3.assessmentState == .result(MedicineAssessmentGateTests.presentation))
    }

    @Test func exactDuplicateUpdateIsRejected() {
        let date = Date(timeIntervalSince1970: 0)
        let assessing1 = MedicineAssessmentStateUpdate(
            sequenceNumber: 7,
            state: .assessing(startedAt: date)
        )
        let gate = makeGate(latestUpdate: assessing1)

        // Same sequenceNumber + same state → exact duplicate, reject
        let assessing2 = MedicineAssessmentStateUpdate(
            sequenceNumber: 7,
            state: .assessing(startedAt: date)
        )
        let next = CompanionFlowReducer.nextState(
            from: .awaitingMedicineAssessment(gate),
            on: .medicineAssessmentStateDidUpdate(assessing2)
        )
        #expect(next == nil, "exact duplicate must be rejected")
    }

    @Test func higherGenerationStartsNewOperation() {
        let result = MedicineAssessmentStateUpdate(
            sequenceNumber: 8,
            state: .result(MedicineAssessmentGateTests.presentation)
        )
        let gate = makeGate(latestUpdate: result)

        // recognizing(9) — new operation, must be accepted
        let recognizing = MedicineAssessmentStateUpdate(
            sequenceNumber: 9,
            state: .recognizing(startedAt: Date(timeIntervalSince1970: 0))
        )
        let next = CompanionFlowReducer.nextState(
            from: .awaitingMedicineAssessment(gate),
            on: .medicineAssessmentStateDidUpdate(recognizing)
        )
        #expect(next != nil, "higher generation must be accepted")
    }

    @Test func firstUpdateAlwaysAccepted() {
        let gate = makeGate(latestUpdate: nil)
        let update = MedicineAssessmentStateUpdate(
            sequenceNumber: 0,
            state: .idle
        )
        let next = CompanionFlowReducer.nextState(
            from: .awaitingMedicineAssessment(gate),
            on: .medicineAssessmentStateDidUpdate(update)
        )
        #expect(next != nil)
    }

    // MARK: - Canonical state update — exhaustive case handling

    @Test func allSevenCanonicalCasesAccepted() {
        let gate = makeGate(latestUpdate: nil)
        let cases: [MedicineAssessmentViewState] = [
            .idle,
            .recognizing(startedAt: Date(timeIntervalSince1970: 0)),
            .requiresMedicineConfirmation(
                MedicineConfirmationRequirement(
                    reason: .noRecognizedText,
                    recognitionInput: MedicineRecognitionInput(
                        recognizedTexts: [],
                        capturedAt: Date(timeIntervalSince1970: 0),
                        languageCode: nil,
                        rawConfidence: nil
                    ),
                    response: nil
                )
            ),
            .assessing(startedAt: Date(timeIntervalSince1970: 0)),
            .result(MedicineAssessmentGateTests.presentation),
            .failed(MedicineAssessmentGateTests.clientFailure),
            .cancelled,
        ]

        for (index, state) in cases.enumerated() {
            let update = MedicineAssessmentStateUpdate(
                sequenceNumber: UInt64(index + 1),
                state: state
            )
            let next = CompanionFlowReducer.nextState(
                from: .awaitingMedicineAssessment(gate),
                on: .medicineAssessmentStateDidUpdate(update)
            )
            #expect(next != nil, "case \(state) was rejected")
        }
    }

    // MARK: - No departure from gate

    /// No event transitions from the gate to travelling, regardless of the
    /// canonical state stored.
    @Test func noEventTransitionsFromGateToTravelling() {
        let updates: [MedicineAssessmentStateUpdate?] = [
            nil,
            MedicineAssessmentStateUpdate(sequenceNumber: 1, state: .idle),
            MedicineAssessmentStateUpdate(
                sequenceNumber: 1,
                state: .result(MedicineAssessmentGateTests.presentation)
            ),
        ]
        let events: [CompanionFlowEvent] = [
            .startCompanion,
            .beginMedicineRead,
            .medicineReadDidNotSucceed(.textNotLegible),
            .retryMedicineRead,
            .chooseFromFrequentList(MedicineCandidate.demoFrequentlyUsed),
            .medicineCandidatesReady(MedicineCandidate.demoCandidates),
            .retakeMedicinePhoto,
            .confirmMedicine(MedicineCandidate.demoCandidates[0]),
            .medicineAssessmentStateDidUpdate(
                MedicineAssessmentStateUpdate(sequenceNumber: 99, state: .idle)
            ),
            .reconsiderMedicineChoice,
            .approachStop,
            .arriveSafely,
            .endEarly,
        ]

        for update in updates {
            let gate = makeGate(latestUpdate: update)
            for event in events {
                let next = CompanionFlowReducer.nextState(
                    from: .awaitingMedicineAssessment(gate),
                    on: event
                )
                #expect(next != .travelling,
                        "gate + \(event) reached travelling")
                #expect(next != .approachingStop,
                        "gate + \(event) reached approachingStop")
            }
        }
    }

    // MARK: - Helpers

    private func makeGate(
        latestUpdate: MedicineAssessmentStateUpdate?
    ) -> MedicineAssessmentGate {
        MedicineAssessmentGate(
            confirmed: ConfirmedMedicine(
                candidate: MedicineCandidate.demoCandidates[0],
                origin: .readFromPhoto
            ),
            prompt: MedicineConfirmationPrompt(
                candidates: MedicineCandidate.demoCandidates,
                origin: .readFromPhoto,
                attemptNumber: 1
            ),
            latestUpdate: latestUpdate
        )
    }
}
