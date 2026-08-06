import Foundation
import SlowWalkAPIContracts
import SlowWalkClientCore
import SlowWalkDomain
import SlowWalkMedicineKnowledge

/// Maps the canonical `MedicineAssessmentViewState` to a presentation variant.
///
/// Design rules this type exists to enforce:
///
/// - The input is the canonical Client Core view state. There is no adapter
///   struct with hand-built booleans, so a test cannot construct a state the
///   coordinator could never produce.
/// - Every discriminator is a machine-readable canonical value: a
///   `MedicineAssessmentViewState` case, a `MedicineConfirmationReason`, a
///   `RiskReasonCode`, a `RiskLevel`, a `ClientFailureKind`, or the
///   consolidated knowledge governance verdict. No fixture ID, action-card
///   title, or human warning sentence is ever matched.
/// - The canonical `RiskLevel` is never rewritten. `yellow` and `orange` keep
///   their own level and their own presentation.
/// - `ActionCard.mustConfirmMedicine` never participates in choosing
///   `redRisk`, and `redRisk` never suppresses a confirmation requirement.
public enum MedicineStateMapper {
    /// Rule identifier stamped on health-context warnings that the medicine
    /// pipeline injects on behalf of knowledge-source governance.
    ///
    /// Produced by `MedicinePipeline.addingKnowledgeWarnings`. It is used only
    /// to attribute a warning to the right subsystem, never as the primary
    /// signal: knowledge state is decided by `RiskReasonCode` and the
    /// governance verdict below.
    static let knowledgeSafetyRuleIdentifier =
        "medicine-knowledge-source-safety"

    /// Canonical risk reason codes raised by health-context data-quality
    /// rules. Enumerated explicitly so a new unrelated code cannot silently
    /// start reporting a health warning.
    static let healthContextReasonCodes: Set<RiskReasonCode> = [
        .healthContextWarning,
        .bodyMetricsMissing,
        .bodyMetricsStale,
        .bodyMetricsInvalid,
    ]

    public static func map(
        _ state: MedicineAssessmentViewState,
        demoDisclaimer: String? = nil
    ) -> MedicineDisplayState {
        switch state {
        case .idle:
            return MedicineDisplayState(
                variant: .idle,
                actionCard: nil,
                failure: nil,
                requiresMedicineConfirmation: false,
                demoDisclaimer: demoDisclaimer
            )

        case .recognizing:
            return MedicineDisplayState(
                variant: .recognizing,
                actionCard: nil,
                failure: nil,
                requiresMedicineConfirmation: false,
                demoDisclaimer: demoDisclaimer
            )

        case .assessing:
            return MedicineDisplayState(
                variant: .assessing,
                actionCard: nil,
                failure: nil,
                requiresMedicineConfirmation: false,
                demoDisclaimer: demoDisclaimer
            )

        case .cancelled:
            return MedicineDisplayState(
                variant: .cancelled,
                actionCard: nil,
                failure: nil,
                requiresMedicineConfirmation: false,
                demoDisclaimer: demoDisclaimer
            )

        case let .failed(failure):
            // A timeout is separated from other failures because the canonical
            // fixture documents a distinct retry-capable page. No risk level,
            // instruction, or action card is invented for either case.
            return MedicineDisplayState(
                variant: failure.kind == .timeout
                    ? .timeout
                    : .failed,
                actionCard: nil,
                failure: MedicineFailureDisplay(
                    failure: failure
                ),
                requiresMedicineConfirmation: false,
                demoDisclaimer: demoDisclaimer
            )

        case let .requiresMedicineConfirmation(requirement):
            return mapConfirmation(requirement, demoDisclaimer: demoDisclaimer)

        case let .result(presentation):
            return MedicineDisplayState(
                variant: classifyResponse(
                    presentation.response,
                    fallback: .normal
                ),
                actionCard: presentation.response.actionCard,
                failure: nil,
                recognition: recognitionDisplay(
                    recognizedTexts: presentation.response.resolution
                        .evidence.recognizedTexts,
                    resolvedMedicineName: presentation.response.resolution
                        .selectedMedicine?.canonicalName
                ),
                requiresMedicineConfirmation: false,
                demoDisclaimer: demoDisclaimer
            )
        }
    }

    private static func mapConfirmation(
        _ requirement: MedicineConfirmationRequirement,
        demoDisclaimer: String?
    ) -> MedicineDisplayState {
        let card = requirement.response?.actionCard
        let recognition = recognitionDisplay(
            recognizedTexts: requirement.recognitionInput.recognizedTexts,
            resolvedMedicineName: requirement.response?.resolution
                .selectedMedicine?.canonicalName
        )

        switch requirement.reason {
        case .noRecognizedText,
             .ambiguousMedicine,
             .unresolvedMedicine:
            // The medicine identity itself is unconfirmed. This is decided by
            // the canonical confirmation reason, so unrelated health-context or
            // knowledge warnings on the same response cannot swallow it.
            return MedicineDisplayState(
                variant: .ambiguous,
                actionCard: card,
                failure: nil,
                recognition: recognition,
                requiresMedicineConfirmation: true,
                demoDisclaimer: demoDisclaimer
            )

        case .serverRequiresConfirmation:
            // The medicine resolved, but knowledge governance demanded user
            // confirmation. The fallback is `knowledgeWarning`, never
            // `normal`: a confirmation-required response must not be presented
            // as an ordinary result even if no individual warning matched.
            guard let response = requirement.response else {
                return MedicineDisplayState(
                    variant: .knowledgeWarning,
                    actionCard: nil,
                    failure: nil,
                    recognition: recognition,
                    requiresMedicineConfirmation: true,
                    demoDisclaimer: demoDisclaimer
                )
            }
            return MedicineDisplayState(
                variant: classifyResponse(
                    response,
                    fallback: .knowledgeWarning
                ),
                actionCard: response.actionCard,
                failure: nil,
                recognition: recognition,
                requiresMedicineConfirmation: true,
                demoDisclaimer: demoDisclaimer
            )
        }
    }

    private static func recognitionDisplay(
        recognizedTexts: [String],
        resolvedMedicineName: String?
    ) -> MedicineRecognitionDisplay? {
        guard !recognizedTexts.isEmpty || resolvedMedicineName != nil else {
            return nil
        }
        return MedicineRecognitionDisplay(
            recognizedTexts: recognizedTexts,
            resolvedMedicineName: resolvedMedicineName
        )
    }

    /// Classifies a response that carries a canonical action card.
    ///
    /// Priority is highest-severity-first so a presentation can never
    /// understate the canonical reminder level.
    private static func classifyResponse(
        _ response: MedicineAssessmentResponseDTO,
        fallback: MedicineDisplayVariant
    ) -> MedicineDisplayVariant {
        if response.actionCard.riskLevel == .red {
            return .redRisk
        }
        if hasKnowledgeSourceWarning(response) {
            return .knowledgeWarning
        }
        if hasHealthContextWarning(response) {
            return .healthWarning
        }
        if fallback == .normal,
           response.actionCard.riskLevel != .green
        {
            // An elevated reminder with no attributable cause must not be
            // presented as `normal`. The canonical level is still carried
            // through unchanged.
            return .elevatedRisk
        }
        return fallback
    }

    /// True when medicine knowledge requires source review.
    ///
    /// Both signals are canonical and machine-readable:
    ///
    /// - `RiskReasonCode.knowledgeSourceWarning`, stamped by
    ///   `MedicinePipeline.applyKnowledgeSafety`.
    /// - `KnowledgeGovernanceVerdict.requiresConservativeAction`, the
    ///   consolidated safety decision that Core documents as the value
    ///   consumers must use instead of re-interpreting freshness, cache,
    ///   completeness, and provenance fields separately.
    static func hasKnowledgeSourceWarning(
        _ response: MedicineAssessmentResponseDTO
    ) -> Bool {
        if let assessment = response.assessment,
           assessment.reasons.contains(where: {
               $0.code == .knowledgeSourceWarning
           })
        {
            return true
        }
        if response.medicineKnowledge?
            .requiresConservativeAction == true
        {
            return true
        }
        // Only reachable when no risk assessment exists, so the reason codes
        // above are unavailable.
        return knowledgeAttributedValidationWarnings(response)
            .isEmpty == false
            && response.assessment == nil
    }

    /// True when health-context data quality requires review.
    ///
    /// A valid validation result never reports a health warning: `status` must
    /// be degraded and at least one warning must be attributable to a
    /// health-context rule rather than to knowledge-source governance.
    static func hasHealthContextWarning(
        _ response: MedicineAssessmentResponseDTO
    ) -> Bool {
        if let assessment = response.assessment,
           assessment.reasons.contains(where: {
               healthContextReasonCodes.contains($0.code)
           })
        {
            return true
        }

        guard let validation = response.healthContextValidation,
              let status = HealthContextValidationStatus(
                  rawValue: validation.status
              ),
              status != .valid
        else {
            return false
        }
        return healthAttributedValidationWarnings(response)
            .isEmpty == false
    }

    /// Validation warnings raised by health-context rules.
    static func healthAttributedValidationWarnings(
        _ response: MedicineAssessmentResponseDTO
    ) -> [HealthContextWarningDTO] {
        (response.healthContextValidation?.warnings ?? [])
            .filter {
                $0.ruleIdentifier
                    != knowledgeSafetyRuleIdentifier
            }
    }

    /// Validation warnings the medicine pipeline injected for knowledge-source
    /// governance rather than for health-context data quality.
    static func knowledgeAttributedValidationWarnings(
        _ response: MedicineAssessmentResponseDTO
    ) -> [HealthContextWarningDTO] {
        (response.healthContextValidation?.warnings ?? [])
            .filter {
                $0.ruleIdentifier
                    == knowledgeSafetyRuleIdentifier
            }
    }
}
