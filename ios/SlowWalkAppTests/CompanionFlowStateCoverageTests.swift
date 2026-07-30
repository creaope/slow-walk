import Testing
@testable import SlowWalkApp

/// Proves the exhaustive sweep fixtures really are exhaustive.
///
/// `MedicineAssessmentGateTests` asserts things about *every* state and *every*
/// event — "no transition reaches travelling", "no event departs from the gate".
/// Those guarantees are only as good as the hand-written fixture lists, and
/// `CompanionFlowState` carries payloads so it cannot be `CaseIterable`.
///
/// The tripwire is the exhaustive `switch` in each `kind(of:)` below. Adding a
/// case to `CompanionFlowState` or `CompanionFlowEvent` stops this file
/// compiling; adding the matching `Kind` case then makes the coverage test fail
/// until the fixture list is extended. A new state therefore cannot slip past
/// the safety sweeps unnoticed.
///
/// Only case *names* are enumerated here. No transition, and no production
/// logic, is reproduced.
@MainActor
struct CompanionFlowStateCoverageTests {

    // MARK: - States

    private enum StateKind: String, CaseIterable {
        case notStarted
        case preDepartureCheck
        case scanningMedicine
        case awaitingMedicineConfirmation
        case awaitingMedicineAssessment
        case travelling
        case approachingStop
        case completed
    }

    private static func kind(of state: CompanionFlowState) -> StateKind {
        switch state {
        case .notStarted: .notStarted
        case .preDepartureCheck: .preDepartureCheck
        case .scanningMedicine: .scanningMedicine
        case .awaitingMedicineConfirmation: .awaitingMedicineConfirmation
        case .awaitingMedicineAssessment: .awaitingMedicineAssessment
        case .travelling: .travelling
        case .approachingStop: .approachingStop
        case .completed: .completed
        }
    }

    @Test func everyStateFixtureCoversEveryState() {
        let covered = Set(MedicineAssessmentGateTests.everyState.map(Self.kind(of:)))
        let missing = Set(StateKind.allCases)
            .subtracting(covered)
            .map(\.rawValue)
            .sorted()
            .joined(separator: ", ")
        #expect(
            missing.isEmpty,
            "MedicineAssessmentGateTests.everyState is missing: \(missing)"
        )
    }

    // MARK: - Events

    private enum EventKind: String, CaseIterable {
        case startCompanion
        case beginMedicineRead
        case medicineReadDidNotSucceed
        case retryMedicineRead
        case chooseFromFrequentList
        case medicineCandidatesReady
        case retakeMedicinePhoto
        case confirmMedicine
        case medicineAssessmentDidNotSucceed
        case reconsiderMedicineChoice
        case approachStop
        case arriveSafely
        case endEarly
    }

    private static func kind(of event: CompanionFlowEvent) -> EventKind {
        switch event {
        case .startCompanion: .startCompanion
        case .beginMedicineRead: .beginMedicineRead
        case .medicineReadDidNotSucceed: .medicineReadDidNotSucceed
        case .retryMedicineRead: .retryMedicineRead
        case .chooseFromFrequentList: .chooseFromFrequentList
        case .medicineCandidatesReady: .medicineCandidatesReady
        case .retakeMedicinePhoto: .retakeMedicinePhoto
        case .confirmMedicine: .confirmMedicine
        case .medicineAssessmentDidNotSucceed: .medicineAssessmentDidNotSucceed
        case .reconsiderMedicineChoice: .reconsiderMedicineChoice
        case .approachStop: .approachStop
        case .arriveSafely: .arriveSafely
        case .endEarly: .endEarly
        }
    }

    @Test func everyEventFixtureCoversEveryEvent() {
        let covered = Set(MedicineAssessmentGateTests.everyEvent.map(Self.kind(of:)))
        let missing = Set(EventKind.allCases)
            .subtracting(covered)
            .map(\.rawValue)
            .sorted()
            .joined(separator: ", ")
        #expect(
            missing.isEmpty,
            "MedicineAssessmentGateTests.everyEvent is missing: \(missing)"
        )
    }

    // MARK: - Assessment progress

    /// Every progress value is swept, including each setback.
    ///
    /// `MedicineAssessmentSetback` is `CaseIterable`, so this one can be checked
    /// against the real case list rather than a mirror of it.
    @Test func everyProgressFixtureCoversEverySetback() {
        let coveredSetbacks = Set(
            MedicineAssessmentGateTests.everyProgress.compactMap(\.setback)
        )
        #expect(coveredSetbacks == Set(MedicineAssessmentSetback.allCases))

        // And the waiting value itself, which carries no setback.
        #expect(MedicineAssessmentGateTests.everyProgress.contains(.notStarted))
    }

    /// No progress value means "assessed".
    ///
    /// This is the structural guarantee the whole gate rests on: nothing in this
    /// build can produce an assessment result, so no code path can present one.
    /// A success case added to `MedicineAssessmentProgress` must break this
    /// test, forcing the departure and card rules to be revisited deliberately.
    @Test func noProgressValueCarriesAnAssessmentResult() {
        for progress in MedicineAssessmentGateTests.everyProgress {
            switch progress {
            case .notStarted, .couldNotAssess:
                // Neither carries a result. Adding a case that does makes this
                // switch non-exhaustive.
                break
            }
        }
    }

    // MARK: - Care Records boundary

    /// The timeline reason a real assessment failure produces.
    ///
    /// The conversion itself lives on the Companion side of the boundary and is
    /// `private` to `CompanionSessionModel.swift`, so Care Records depends on
    /// nothing inside the flow. That means it cannot be called directly from
    /// here — which is the point. It is checked the way it actually matters
    /// instead: by driving the real session to the gate and reading what landed
    /// in the timeline. A conversion that leaked a flow enum into the record, or
    /// mapped onto the wrong reason, fails here.
    @Test func realAssessmentFailureRecordsACareRecordReason() async {
        let (_, store) = await MedicineAssessmentGateTests.sessionAndStoreAtGate()

        let reasons: [CareRecordIncompleteReason] = store.kinds.compactMap { kind in
            if case let .medicineAssessmentDidNotSucceed(reason) = kind {
                return reason
            }
            return nil
        }
        #expect(reasons == [.capabilityNotAvailableYet])
    }

    /// Every Companion setback has a deliberate Care Records meaning.
    ///
    /// Totality is enforced at compile time, not here: the conversion is an
    /// exhaustive `switch` over `MedicineAssessmentSetback`, so adding a setback
    /// stops `CompanionSessionModel.swift` compiling until the new case has been
    /// given a deliberate record meaning. Mapping a new setback onto an existing
    /// reason is a decision, not a default.
    ///
    /// What this test adds is the coverage claim the check above rests on: there
    /// is exactly one setback today, so the single production path exercised
    /// above covers the whole setback set. A second setback makes that untrue
    /// and fails here, forcing its record meaning to be exercised too.
    @Test func oneSetbackExistsSoTheRealPathCoversThemAll() {
        #expect(MedicineAssessmentSetback.allCases == [.notWiredUpYet])
    }

    /// The record vocabulary carries no medical meaning.
    ///
    /// An exhaustive switch, so a case added to `CareRecordIncompleteReason`
    /// breaks the build here. That is the tripwire against the timeline quietly
    /// growing a second medical error vocabulary — assessment results and their
    /// failures belong to `SlowWalkCore`, not to Care Records.
    @Test func recordReasonsCarryNoMedicalMeaning() {
        for reason in CareRecordIncompleteReason.allCases {
            switch reason {
            case .capabilityNotAvailableYet:
                // Says a step could not run. Says nothing about a medicine.
                break
            }
        }
        #expect(CareRecordIncompleteReason.allCases.count == 1)
    }
}
