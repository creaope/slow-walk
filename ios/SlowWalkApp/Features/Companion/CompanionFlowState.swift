import Foundation
import SlowWalkAPIContracts
import SlowWalkClientCore

/// Why a medicine photo could not be read.
///
/// A setback never carries a medicine conclusion. It only describes what
/// happened so the flow can offer a recovery path instead of guessing.
enum MedicineReadSetback: Equatable, Hashable, CaseIterable {
    case textNotLegible
    case noMedicineNameFound
}

/// One medicine-reading attempt inside a single companion session.
struct MedicineReadAttempt: Equatable, Hashable {
    /// `1` for the first attempt, incremented on every retry.
    let attemptNumber: Int
    /// `nil` while the read is still in progress.
    let setback: MedicineReadSetback?

    static let first = MedicineReadAttempt(attemptNumber: 1, setback: nil)

    /// True when the person is being offered a recovery path.
    var isAwaitingRecovery: Bool {
        setback != nil
    }

    func retried() -> MedicineReadAttempt {
        MedicineReadAttempt(attemptNumber: attemptNumber + 1, setback: nil)
    }

    func interrupted(by setback: MedicineReadSetback) -> MedicineReadAttempt {
        MedicineReadAttempt(attemptNumber: attemptNumber, setback: setback)
    }
}

/// How the medicine under review was chosen.
enum MedicineChoiceOrigin: Equatable, Hashable {
    case readFromPhoto
    case chosenFromFrequentList
}

/// A medicine offered for confirmation.
///
/// Demo data only: no dosage, no clinical claim, and no source reference. The
/// real candidate list and its wording come from the server-owned catalog.
struct MedicineCandidate: Equatable, Hashable, Identifiable {
    let id: String
    let displayName: String
    /// A short, non-clinical hint such as packaging appearance.
    let recognitionHint: String
}

struct MedicineConfirmationPrompt: Equatable, Hashable {
    let candidates: [MedicineCandidate]
    let origin: MedicineChoiceOrigin
    /// The read attempt this prompt came from, so taking another photo
    /// continues the attempt count instead of restarting it at 1.
    let attemptNumber: Int
}

struct ConfirmedMedicine: Equatable, Hashable {
    let candidate: MedicineCandidate
    let origin: MedicineChoiceOrigin
}

/// The step between confirming a medicine and being shown anything about it.
///
/// This state is the safety gate. It exists so a confirmed *name* can never be
/// mistaken for an assessed *medicine*: confirmation answers "which box is
/// this", which is not an answer to "is it safe to take". Nothing downstream —
/// no action card, no care-action record, no departure — may happen from here
/// without a real assessment result, and flow continuation additionally
/// requires acknowledgement that the current result was actually displayed.
///
/// The gate stores the latest canonical `MedicineAssessmentStateUpdate` accepted
/// by the reducer. `latestUpdate` is `nil` when no update has been received yet,
/// which is semantically `.idle`.
///
/// `Equatable` only — no `Hashable` usage exists in this build.
struct MedicineAssessmentGate: Equatable {
    let confirmed: ConfirmedMedicine
    /// The prompt the confirmation came from, so a different candidate can be
    /// chosen without re-reading the box.
    let prompt: MedicineConfirmationPrompt
    /// The latest canonical state update accepted. `nil` means no update has
    /// been received — equivalent to `.idle`.
    let latestUpdate: MedicineAssessmentStateUpdate?
    /// The canonical result that the presentation layer most recently reported
    /// as actually displayed. Qualification compares this identity with the
    /// current result so a different result cannot inherit acknowledgement.
    let displayedResultRequestID: UUID?

    init(
        confirmed: ConfirmedMedicine,
        prompt: MedicineConfirmationPrompt,
        latestUpdate: MedicineAssessmentStateUpdate?,
        displayedResultRequestID: UUID? = nil
    ) {
        self.confirmed = confirmed
        self.prompt = prompt
        self.latestUpdate = latestUpdate
        self.displayedResultRequestID = displayedResultRequestID
    }

    /// The current canonical assessment state, defaulting to `.idle`.
    var assessmentState: MedicineAssessmentViewState {
        latestUpdate?.state ?? .idle
    }

    /// Whether the canonical result currently held by this gate was displayed.
    var hasDisplayedCurrentResult: Bool {
        guard case let .result(presentation) = assessmentState else {
            return false
        }
        return displayedResultRequestID == presentation.response.requestID
    }

    /// True once the person is being offered a way out rather than a wait.
    var isAwaitingRecovery: Bool {
        switch assessmentState {
        case .failed, .cancelled:
            true
        case .idle, .recognizing, .requiresMedicineConfirmation,
             .assessing, .result:
            false
        }
    }
}

/// How a companion session finished.
///
enum CompanionCompletion: Equatable, Hashable {
    case arrivedSafely
    case completedMedicineCheck
    case endedEarly
}

/// The steps of one continuous companion session.
///
/// This models the *flow of a session*, not the presentation of a medicine
/// assessment. Risk wording, severity and colour belong to
/// `SlowWalkPresentation` and are deliberately absent here.
///
/// There is deliberately no App-owned state that presents a care action. The
/// state that used to do so, `showingRiskAction(ConfirmedMedicine)`, carried
/// only a medicine *name*, which let the flow present a care action and permit
/// departure on the strength of a confirmed name alone. It is replaced by
/// `awaitingMedicineAssessment`. The external result presenter reports actual
/// display back through the request-ID-bound event while the gate stays the
/// single flow authority.
///
/// `Equatable` only — no `Hashable` usage exists in this build.
enum CompanionFlowState: Equatable {
    case notStarted
    case preDepartureCheck
    case scanningMedicine(MedicineReadAttempt)
    case awaitingMedicineConfirmation(MedicineConfirmationPrompt)
    /// A medicine is confirmed and a formal assessment is owed. Nothing is
    /// shown about the medicine and the session cannot move on from here.
    /// The gate carries the latest canonical `MedicineAssessmentStateUpdate`.
    case awaitingMedicineAssessment(MedicineAssessmentGate)
    case travelling
    case approachingStop
    case completed(CompanionCompletion)

    /// True while a session is underway and can still be ended early.
    var isActive: Bool {
        switch self {
        case .notStarted, .completed:
            false
        case .preDepartureCheck,
             .scanningMedicine,
             .awaitingMedicineConfirmation,
             .awaitingMedicineAssessment,
             .travelling,
             .approachingStop:
            true
        }
    }
}

/// Every input that can move a companion session forward.
///
/// `Equatable` only — no `Hashable` usage exists in this build.
enum CompanionFlowEvent: Equatable {
    case startCompanion
    case beginMedicineRead
    case medicineReadDidNotSucceed(MedicineReadSetback)
    case retryMedicineRead
    case chooseFromFrequentList([MedicineCandidate])
    case medicineCandidatesReady([MedicineCandidate])
    /// Raised when none of the offered candidates match the box in hand.
    case retakeMedicinePhoto
    case confirmMedicine(MedicineCandidate)
    /// A canonical state update from the medicine assessment coordinator.
    ///
    /// The update carries a monotonic `sequenceNumber` so the reducer can
    /// reject stale or duplicate deliveries. All seven canonical cases are
    /// accepted and stored. A `.result` remains blocked until its own request
    /// ID is acknowledged by `medicineAssessmentResultDidDisplay`.
    case medicineAssessmentStateDidUpdate(MedicineAssessmentStateUpdate)
    /// Raised only after the current canonical result has actually rendered.
    /// The session derives the request identifier from that result; callers do
    /// not supply one.
    case medicineAssessmentResultDidDisplay(UUID)
    /// Explicitly continues an outing after the current result was displayed.
    case continueToOuting
    /// Explicitly completes a medicine-only session after display.
    case completeMedicineCheck
    /// Goes back to the candidate list to pick a different medicine.
    case reconsiderMedicineChoice
    case approachStop
    case arriveSafely
    case endEarly
}
