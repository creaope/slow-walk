import Foundation
import SlowWalkClientCore
import SlowWalkDomain

/// Interface labels and faithful renderings of canonical enumerations.
///
/// Strict boundary: nothing here invents medical content. Every medical
/// sentence a view shows comes from `ActionCard.title`,
/// `primaryInstruction`, `warnings`, or `sourceReferences`. This type only
/// supplies:
///
/// - section headings ("Risk level", "Recommended actions", "Information
///   sources") that organize canonical content without changing it;
/// - literal readings of canonical enum cases (`RecommendedAction`,
///   `RiskLevel`, `RiskAttentionSemantics`, `ClientFailureKind`);
/// - non-color-only shape and symbol tokens for each reminder level.
///
/// It deliberately contains no reassurance ("no risk", "safe to use"),
/// no prohibition ("do not take", "not recommended") that the canonical card
/// did not state, and no diagnosis, prescription, discontinuation, or
/// permission wording.
public enum MedicinePresentationCopy {
    // MARK: - Demo disclaimer

    /// The canonical demo disclaimer shown by preview and demo callers.
    /// Production assessments never use this value.
    public static let demoDisclaimer =
        "DEMO DATA — NOT FOR CLINICAL USE"

    // MARK: - Section headings

    public static let riskLevelHeading = "Risk level"
    public static let primaryInstructionHeading =
        "What to do next"
    public static let warningsHeading = "Warnings"
    public static let recommendedActionsHeading =
        "Recommended actions"
    public static let sourceReferencesHeading =
        "Information sources"
    public static let confirmationRequiredHeading =
        "Medicine identity not confirmed"

    /// Shown independently of the confirmation-requirement indicator when
    /// the canonical card's `mustConfirmMedicine` is `true`.
    public static let mustConfirmLabel =
        "Please confirm the medicine information"

    /// Shown when the canonical card has no source references at all, so the
    /// absence is visible instead of silently rendering an empty section.
    public static let noSourceReferencesText =
        "No information source was recorded for this result."

    // MARK: - Progress and lifecycle

    public static let idleText =
        "尚未开始药品评估。"
    public static let recognizingText =
        "Reading the medicine label."
    public static let assessingText =
        "Checking the medicine information."
    public static let cancelledText =
        "The medicine assessment was cancelled."

    // MARK: - Risk level

    /// The canonical level name. No severity word is added, because the
    /// canonical attention semantics below already carry that meaning.
    public static func levelName(
        _ level: RiskLevel
    ) -> String {
        switch level {
        case .green:
            return "Green"
        case .yellow:
            return "Yellow"
        case .orange:
            return "Orange"
        case .red:
            return "Red"
        }
    }

    /// A literal reading of `RiskAttentionSemantics`, the non-color-only
    /// severity vocabulary Client Core already defines.
    public static func attentionName(
        _ attention: RiskAttentionSemantics
    ) -> String {
        switch attention {
        case .routine:
            return "Routine attention"
        case .reviewRequired:
            return "Review required"
        case .urgentAttention:
            return "Urgent attention"
        case .immediateAttention:
            return "Immediate attention"
        }
    }

    /// SF Symbol per level. Each level gets a distinct silhouette so the four
    /// levels stay distinguishable without color — in particular `yellow`
    /// (triangle) and `orange` (octagon) never share a shape.
    ///
    /// All names verified present in the system symbol library.
    public static func symbolName(
        _ level: RiskLevel
    ) -> String {
        switch level {
        case .green:
            return "checkmark.circle.fill"
        case .yellow:
            return "exclamationmark.triangle.fill"
        case .orange:
            return "exclamationmark.octagon.fill"
        case .red:
            return "hand.raised.fill"
        }
    }

    /// A text shape token rendered next to the badge. It repeats the level
    /// distinction in a third channel, so the level survives color blindness,
    /// a monochrome display, and a symbol that fails to load.
    public static func shapeToken(
        _ level: RiskLevel
    ) -> String {
        switch level {
        case .green:
            return "●"
        case .yellow:
            return "▲"
        case .orange:
            return "◆"
        case .red:
            return "■"
        }
    }

    /// Full VoiceOver reading for a reminder level: heading, canonical level
    /// name, and canonical attention semantics. Color is never the only cue.
    public static func riskAccessibilityLabel(
        _ presentation: RiskPresentation
    ) -> String {
        """
        \(riskLevelHeading): \
        \(levelName(presentation.level)), \
        \(attentionName(presentation.attention))
        """
    }

    // MARK: - Recommended actions

    /// A literal reading of one canonical `RecommendedAction`.
    ///
    /// Each string restates its enum case and nothing more. No action gains
    /// urgency, loses a restriction, or acquires clinical detail in
    /// translation.
    public static func actionName(
        _ action: RecommendedAction
    ) -> String {
        switch action {
        case .followVerifiedSourceInformation:
            return "Follow the verified source information"
        case .consultHealthcareProfessional:
            return "Consult a healthcare professional"
        case .notifyFamilyMember:
            return "Notify a family member"
        case .reviewMedicineSources:
            return "Review the medicine sources"
        case .updateHealthProfile:
            return "Update the health profile"
        case .retakeMedicinePhoto:
            return "Retake the medicine photo"
        case .doNotTakeUntilMedicineConfirmed:
            return "Do not take until the medicine is confirmed"
        case .reviewMedicationHistory:
            return "Review the medication history"
        case .remeasureBodyMetrics:
            return "Measure body metrics again"
        }
    }

    // MARK: - Failure

    /// A literal reading of one canonical `ClientFailureKind`. No failure is
    /// described as a medical outcome.
    public static func failureName(
        _ kind: ClientFailureKind
    ) -> String {
        switch kind {
        case .api:
            return "The service could not complete the request."
        case .timeout:
            return "The request timed out before a result arrived."
        case .malformedResponse:
            return "The response could not be read."
        case .transportUnavailable:
            return "The service could not be reached."
        case .recognition:
            return "The medicine label could not be read."
        case .unknown:
            return "The request did not complete."
        }
    }

    /// No risk level, instruction, or action card is implied for a failure.
    public static let noResultAvailableText =
        "No medicine result was received."

    public static let retryButtonTitle = "Try again"
    public static let retryAccessibilityHint =
        "Requests the medicine assessment again."
    public static let confirmMedicineButtonTitle =
        "Confirm the medicine"
    public static let confirmMedicineAccessibilityHint =
        "Opens medicine confirmation."

    // MARK: - Source references

    /// Renders one canonical `SourceReference` from its own recorded fields
    /// only. No authority, endorsement, or currency is asserted beyond them.
    public static func sourceSummary(
        _ reference: SourceReference
    ) -> String {
        "\(reference.sourceName) — \(reference.documentTitle)"
    }

    public static func sourceVersionSummary(
        _ reference: SourceReference
    ) -> String {
        "Version \(reference.versionOrDate)"
    }
}
