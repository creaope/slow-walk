import Foundation

/// Why a step in a care record could not be completed.
///
/// Care Records owns this type rather than reusing a Companion flow enum. The
/// timeline is the thing that will outlive the current UI: it is what a
/// versioned persistence schema will be written against, so its vocabulary must
/// not change every time the flow's internal states are reshaped.
///
/// Deliberate boundaries:
/// - This is **not** a medical error type, and must not become one. It says a
///   step did not complete; it never says anything about a medicine, a dosage,
///   or a risk. A second medical error DTO must not appear here — assessment
///   results and their failures are owned by `SlowWalkCore`.
/// - It carries no UI wording. `CareRecordsView` turns a reason into a sentence;
///   this type only names the reason.
/// - It carries no risk enum, and must never be mapped onto one.
///
/// - This file names reasons only. It holds no conversion from a Companion
///   type, and must not gain one: the translation is the calling layer's
///   responsibility, so Care Records depends on nothing inside the flow.
///
/// The Companion layer converts its own setbacks into this vocabulary on its own
/// side of the boundary (`MedicineAssessmentSetback.careRecordReason`, private to
/// `CompanionSessionModel.swift`), so the flow's states and the record's states
/// can evolve independently — and the dependency points one way only.
enum CareRecordIncompleteReason: Equatable, Hashable, CaseIterable {
    /// The capability the step needed is not wired up in this build.
    case capabilityNotAvailableYet
}

/// What happened during a companion session, in the order it happened.
///
/// Records describe the process of accompanying someone. They deliberately
/// carry no risk level and no medicine conclusion.
enum CareRecordEventKind: Equatable, Hashable {
    case dayPlanItemStarted(title: String)
    case medicineReadStarted(attemptNumber: Int)
    case medicineReadDidNotSucceed(MedicineReadSetback)
    /// A read that produced candidates. The count is recorded, never a
    /// conclusion about which medicine it is.
    case medicineReadFoundCandidates(candidateCount: Int)
    case medicineConfirmed(medicineName: String, origin: MedicineChoiceOrigin)
    /// A formal assessment was owed and could not be carried out.
    ///
    /// Recorded so the timeline says plainly that no assessment happened.
    /// Without it, a reader seeing a confirmed medicine and nothing after it
    /// could reasonably assume the medicine was checked.
    ///
    /// Carries the Care Records reason, not the Companion setback: what reaches
    /// the timeline is "this step could not be completed", never a medicine
    /// finding.
    case medicineAssessmentDidNotSucceed(CareRecordIncompleteReason)
    /// A care action was actually shown to the person.
    ///
    /// This may only be written by something that presented a real assessment
    /// result. It must never be written on the strength of a confirmed medicine
    /// name: that put a claim in the timeline that nothing had produced.
    case careActionShown(medicineName: String)
    case companionFinished(CompanionCompletion)
}

/// One recorded event, held in memory for the demo flow only.
///
/// This is not a persistence format. A versioned schema has to exist before
/// this type or `CareRecordEventKind` gains `Codable` or a SwiftData model,
/// and migration, privacy, retention and deletion settled along with it.
struct CareRecordEvent: Identifiable, Equatable, Hashable {
    let id: UUID
    let occurredAt: Date
    let kind: CareRecordEventKind

    init(id: UUID, occurredAt: Date, kind: CareRecordEventKind) {
        self.id = id
        self.occurredAt = occurredAt
        self.kind = kind
    }
}
