import Testing
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
        let inactive: [CompanionFlowState] = [.notStarted, .completed(.arrivedSafely), .completed(.endedEarly)]
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
            .showingRiskAction(
                ConfirmedMedicine(candidate: MedicineCandidate.demoCandidates[0], origin: .readFromPhoto)
            ),
            .travelling,
            .approachingStop,
        ]
        for state in active {
            #expect(state.isActive == true, "expected active: \(state)")
        }
    }
}
