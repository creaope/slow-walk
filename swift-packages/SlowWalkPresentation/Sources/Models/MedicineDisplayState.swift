import Foundation
import SlowWalkAPIContracts
import SlowWalkClientCore
import SlowWalkDomain

/// The presentation variant of one medicine assessment.
///
/// Raw values are the frozen `expectedPresentationVariant` strings recorded in
/// `demo-fixtures/README.md`. Tests decode the fixture string directly into
/// this type, so a renamed variant fails a test instead of drifting silently.
public enum MedicineDisplayVariant:
    String,
    Sendable,
    Equatable,
    Hashable,
    CaseIterable
{
    /// No assessment has been started.
    case idle
    /// Platform OCR is running.
    case recognizing
    /// The canonical assessment request is in flight.
    case assessing
    /// A resolved medicine with no health-context or knowledge-source warning.
    case normal
    /// The medicine identity itself is not confirmed.
    case ambiguous
    /// Health-context data-quality warnings require review.
    case healthWarning
    /// Medicine knowledge requires source review.
    case knowledgeWarning
    /// The canonical action card carries the highest reminder level.
    case redRisk
    /// The reminder level is above `green` but no canonical warning explains
    /// why.
    ///
    /// No canonical fixture maps here. It exists so an elevated `yellow` or
    /// `orange` level can never be presented as `normal`, and it is not a
    /// second risk scale — `MedicineDisplayState.riskLevel` still reports the
    /// canonical level unchanged.
    case elevatedRisk
    /// The request timed out before any response existed.
    case timeout
    /// Any other client failure.
    case failed
    /// The user or the caller cancelled the assessment.
    case cancelled
}

/// Presentation-safe failure detail.
///
/// Only the canonical `ClientFailure` is retained. `ClientFailure` already
/// excludes server messages and field details because they may contain OCR,
/// health-profile, or location values.
public struct MedicineFailureDisplay:
    Sendable,
    Equatable,
    Hashable
{
    public let failure: ClientFailure

    public init(failure: ClientFailure) {
        self.failure = failure
    }

    /// A retry is offered only when the canonical failure says so, and only
    /// after an explicit user action.
    public var allowsRetry: Bool {
        failure.isRecoverable
    }
}

/// The complete input a medicine view needs.
///
/// There is no second medical rule set, risk scale, or API DTO here. The
/// canonical `ActionCard` is carried verbatim and every rendered medical
/// sentence comes out of it.
public struct MedicineDisplayState:
    Sendable,
    Equatable
{
    public let variant: MedicineDisplayVariant

    /// The canonical action card, when the pipeline produced one. `nil` for
    /// idle, in-progress, cancelled, and failure states — a client must not
    /// invent a card it never received.
    public let actionCard: ActionCard?

    /// Present only for `timeout` and `failed`.
    public let failure: MedicineFailureDisplay?

    /// True when the canonical coordinator state is
    /// `requiresMedicineConfirmation`.
    ///
    /// This is deliberately separate from `ActionCard.mustConfirmMedicine`:
    /// a confirmation can be required with no response at all (no recognized
    /// text), and a card can require confirmation at any reminder level.
    public let requiresMedicineConfirmation: Bool

    /// The canonical demo disclaimer, when the caller is a demo or preview.
    ///
    /// Production callers pass `nil`; the disclaimer banner is never shown
    /// for real assessments.  When non-nil the value is always the canonical
    /// `"DEMO DATA — NOT FOR CLINICAL USE"` string and the view renders it
    /// as a dedicated accessibility element, never hidden inside warnings.
    public let demoDisclaimer: String?

    public init(
        variant: MedicineDisplayVariant,
        actionCard: ActionCard?,
        failure: MedicineFailureDisplay?,
        requiresMedicineConfirmation: Bool,
        demoDisclaimer: String? = nil
    ) {
        self.variant = variant
        self.actionCard = actionCard
        self.failure = failure
        self.requiresMedicineConfirmation =
            requiresMedicineConfirmation
        self.demoDisclaimer = demoDisclaimer
    }

    /// The canonical reminder level, never re-derived from `variant`.
    ///
    /// `yellow` and `orange` therefore keep their own level instead of
    /// collapsing into `green`.
    public var riskLevel: RiskLevel? {
        actionCard?.riskLevel
    }

    /// The canonical non-color-only attention semantics already defined by
    /// Client Core, reused instead of a second severity scale.
    public var riskPresentation: RiskPresentation? {
        actionCard.map {
            RiskPresentation(level: $0.riskLevel)
        }
    }
}
