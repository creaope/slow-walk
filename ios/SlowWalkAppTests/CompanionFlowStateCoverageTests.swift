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
        case beginMedicineCaptureAssessment
        case beginMedicineRead
        case medicineReadDidNotSucceed
        case retryMedicineRead
        case chooseFromFrequentList
        case medicineCandidatesReady
        case retakeMedicinePhoto
        case confirmMedicine
        case medicineAssessmentStateDidUpdate
        case medicineAssessmentResultDidDisplay
        case continueToOuting
        case completeMedicineCheck
        case reconsiderMedicineChoice
        case approachStop
        case arriveSafely
        case endEarly
    }

    private static func kind(of event: CompanionFlowEvent) -> EventKind {
        switch event {
        case .startCompanion: .startCompanion
        case .beginMedicineCaptureAssessment: .beginMedicineCaptureAssessment
        case .beginMedicineRead: .beginMedicineRead
        case .medicineReadDidNotSucceed: .medicineReadDidNotSucceed
        case .retryMedicineRead: .retryMedicineRead
        case .chooseFromFrequentList: .chooseFromFrequentList
        case .medicineCandidatesReady: .medicineCandidatesReady
        case .retakeMedicinePhoto: .retakeMedicinePhoto
        case .confirmMedicine: .confirmMedicine
        case .medicineAssessmentStateDidUpdate: .medicineAssessmentStateDidUpdate
        case .medicineAssessmentResultDidDisplay: .medicineAssessmentResultDidDisplay
        case .continueToOuting: .continueToOuting
        case .completeMedicineCheck: .completeMedicineCheck
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

    // MARK: - Gate update sweep

    /// Every canonical `MedicineAssessmentViewState` case appears in the gate
    /// update sweep.
    ///
    /// The exhaustive switch here matches the canonical enum's cases. A new
    /// case added to `MedicineAssessmentViewState` breaks this file compiling,
    /// which forces the gate sweep to be extended.
    @Test func everyGateUpdateCoversEveryCanonicalCase() {
        let coveredKinds: Set<String> = Set(
            MedicineAssessmentGateTests.everyGateUpdate.compactMap { update in
                guard let state = update?.state else { return "nil" }
                switch state {
                case .idle: return "idle"
                case .recognizing: return "recognizing"
                case .requiresMedicineConfirmation: return "requiresMedicineConfirmation"
                case .assessing: return "assessing"
                case .result: return "result"
                case .failed: return "failed"
                case .cancelled: return "cancelled"
                }
            }
        )
        #expect(coveredKinds.contains("nil"), "nil (no update) must be in gate sweep")
        #expect(coveredKinds.contains("idle"))
        #expect(coveredKinds.contains("recognizing"))
        #expect(coveredKinds.contains("requiresMedicineConfirmation"))
        #expect(coveredKinds.contains("assessing"))
        #expect(coveredKinds.contains("result"))
        #expect(coveredKinds.contains("failed"))
        #expect(coveredKinds.contains("cancelled"))
        #expect(coveredKinds.count == 8) // 7 canonical + nil
    }

    // MARK: - Care Records boundary

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
