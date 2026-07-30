import Foundation

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

/// Why a formal medicine assessment could not be produced.
///
/// Like `MedicineReadSetback`, a setback never carries a medicine conclusion or
/// a risk level. It only says why there is no result, so the flow can offer a
/// way out instead of inventing one.
enum MedicineAssessmentSetback: Equatable, Hashable, CaseIterable {
    /// No assessment path is wired up in this build.
    ///
    /// This is the honest state of Phase 0: `MedicinePipeline` exists in
    /// `SlowWalkCore`, but no adapter in this target reaches it. Removing this
    /// case is part of landing `LocalMedicineAssessmentRequester`, not part of
    /// hiding it.
    case notWiredUpYet
}

/// How far the formal medicine assessment has got.
///
/// The point of this type is that there is no value meaning "assessed" yet.
/// A successful assessment carries a result, and that result is owned by
/// `SlowWalkCore` and presented by `SlowWalkPresentation`; until an adapter
/// produces one, the only truthful values are "not started" and "could not".
enum MedicineAssessmentProgress: Equatable, Hashable {
    /// A formal assessment is owed but has not produced anything yet.
    case notStarted
    /// The assessment could not be carried out. Recovery is offered.
    case couldNotAssess(MedicineAssessmentSetback)

    var setback: MedicineAssessmentSetback? {
        switch self {
        case .notStarted: nil
        case let .couldNotAssess(setback): setback
        }
    }
}

/// The step between confirming a medicine and being shown anything about it.
///
/// This state is the safety gate. It exists so a confirmed *name* can never be
/// mistaken for an assessed *medicine*: confirmation answers "which box is
/// this", which is not an answer to "is it safe to take". Nothing downstream —
/// no action card, no care-action record, no departure — may happen from here
/// without a real assessment result.
struct MedicineAssessmentGate: Equatable, Hashable {
    let confirmed: ConfirmedMedicine
    /// The prompt the confirmation came from, so a different candidate can be
    /// chosen without re-reading the box.
    let prompt: MedicineConfirmationPrompt
    let progress: MedicineAssessmentProgress

    /// True once the person is being offered a way out rather than a wait.
    var isAwaitingRecovery: Bool {
        progress.setback != nil
    }
}

/// How a companion session finished.
enum CompanionCompletion: Equatable, Hashable {
    case arrivedSafely
    case endedEarly
}

/// The steps of one continuous companion session.
///
/// This models the *flow of a session*, not the presentation of a medicine
/// assessment. Risk wording, severity and colour belong to
/// `SlowWalkPresentation` and are deliberately absent here.
///
/// There is deliberately no state that shows a care action. The state that used
/// to do so, `showingRiskAction(ConfirmedMedicine)`, carried only a medicine
/// *name*, which let the flow present a care action and permit departure on the
/// strength of a confirmed name alone. It is replaced by
/// `awaitingMedicineAssessment`. When a real assessment result exists, the
/// showing state returns carrying that result — never just a name.
enum CompanionFlowState: Equatable, Hashable {
    case notStarted
    case preDepartureCheck
    case scanningMedicine(MedicineReadAttempt)
    case awaitingMedicineConfirmation(MedicineConfirmationPrompt)
    /// A medicine is confirmed and a formal assessment is owed. Nothing is
    /// shown about the medicine and the session cannot move on from here.
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
enum CompanionFlowEvent: Equatable, Hashable {
    case startCompanion
    case beginMedicineRead
    case medicineReadDidNotSucceed(MedicineReadSetback)
    case retryMedicineRead
    case chooseFromFrequentList([MedicineCandidate])
    case medicineCandidatesReady([MedicineCandidate])
    /// Raised when none of the offered candidates match the box in hand.
    case retakeMedicinePhoto
    case confirmMedicine(MedicineCandidate)
    /// Raised when a formal assessment could not be produced.
    ///
    /// There is deliberately no `medicineAssessmentSucceeded` counterpart yet.
    /// Adding one means adding the result type it carries, which is the next
    /// stage's work; leaving it out is what keeps this build from claiming an
    /// assessment it never made.
    case medicineAssessmentDidNotSucceed(MedicineAssessmentSetback)
    /// Goes back to the candidate list to pick a different medicine.
    case reconsiderMedicineChoice
    case approachStop
    case arriveSafely
    case endEarly
}
