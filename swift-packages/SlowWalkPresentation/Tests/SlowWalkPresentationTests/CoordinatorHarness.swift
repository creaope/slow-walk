import Foundation
import SlowWalkAPIContracts
import SlowWalkClientCore
import SlowWalkDomain
import SlowWalkMedicineKnowledge

/// Drives the real `MedicineAssessmentCoordinator` so the view state under
/// test is produced by production code.
///
/// The only substitutions are the two documented boundaries the coordinator
/// already injects: a platform OCR recognizer and the network requester. The
/// requester replays a fixture's stored canonical response — the same response
/// the server golden tests prove equals live pipeline output. No pipeline,
/// resolver, risk rule, or action-card logic is reimplemented here.
enum CoordinatorHarness {
    static let apiVersion = "v1"

    struct FixedClock: SlowWalkDomain.Clock {
        let date: Date
        func now() -> Date { date }
    }

    /// Runs the canonical coordinator and returns the resulting view state.
    static func viewState(
        behavior: MockMedicineAssessmentBehavior,
        payload: PresentationFixturePayload
    ) async throws -> MedicineAssessmentViewState {
        let coordinator = try makeCoordinator(
            behavior: behavior,
            payload: payload
        )
        return await coordinator.assess(
            imageInput: imageInput(for: payload),
            userProfile: payload.request.userProfile,
            recentRecords: payload.request.recentRecords,
            requestID: payload.request.requestID
        )
    }

    /// Replays a fixture through the coordinator using the behavior that
    /// matches its frozen scenario.
    static func viewState(
        for payload: PresentationFixturePayload
    ) async throws -> MedicineAssessmentViewState {
        try await viewState(
            behavior: behavior(for: payload),
            payload: payload
        )
    }

    /// Replays a response the test derived from a fixture, keeping the rest of
    /// the canonical path intact.
    static func viewState(
        response: MedicineAssessmentResponseDTO,
        payload: PresentationFixturePayload
    ) async throws -> MedicineAssessmentViewState {
        try await viewState(
            behavior: .success(response),
            payload: payload
        )
    }

    static func makeCoordinator(
        behavior: MockMedicineAssessmentBehavior,
        payload: PresentationFixturePayload
    ) throws -> MedicineAssessmentCoordinator {
        MedicineAssessmentCoordinator(
            recognizer: MockMedicineTextRecognizer(
                behavior: .observations(
                    observations(for: payload)
                )
            ),
            mapper: try MedicineRecognitionInputMapper(
                configuration:
                    MedicineRecognitionMappingConfiguration(
                        minimumConfidence: 0.5,
                        lowConfidenceHandling: .discard
                    )
            ),
            requester: MockMedicineAssessmentRequester(
                behavior: behavior
            ),
            clock: FixedClock(
                date: payload.request.input.capturedAt
            ),
            apiVersion: apiVersion
        )
    }

    /// The mock behavior matching each frozen fixture scenario. Behaviors that
    /// return a response all return the stored canonical response, so the
    /// choice cannot change what the coordinator sees.
    static func behavior(
        for payload: PresentationFixturePayload
    ) -> MockMedicineAssessmentBehavior {
        switch payload.fixtureID {
        case "ambiguous":
            return .ambiguousMedicine(payload.response)
        case "knowledgeWarning":
            return .knowledgeSourceWarning(payload.response)
        case "redRisk":
            return .redRisk(payload.response)
        default:
            return .success(payload.response)
        }
    }

    /// Rebuilds OCR observations from the fixture's canonical recognized text
    /// so the recognized input the coordinator maps matches the fixture.
    static func observations(
        for payload: PresentationFixturePayload
    ) -> [RecognizedTextObservation] {
        let input = payload.request.input
        return input.recognizedTexts.enumerated().map {
            index, text in
            RecognizedTextObservation(
                text: text,
                confidence: input.rawConfidence ?? 1.0,
                boundingRegion: OCRBoundingRegion(
                    x: 0,
                    y: Double(index),
                    width: 1,
                    height: 1
                ),
                languageCode: input.languageCode,
                observedAt: input.capturedAt
            )
        }
    }

    /// Image bytes are never retained in a view state or request, so a stable
    /// non-empty placeholder is sufficient.
    static func imageInput(
        for payload: PresentationFixturePayload
    ) -> OCRImageInput {
        OCRImageInput(
            data: Data([0x01]),
            orientation: .up,
            capturedAt: payload.request.input.capturedAt
        )
    }
}

extension MedicineAssessmentResponseDTO {
    /// Returns a copy with selected canonical fields replaced.
    ///
    /// Used only to build the negative controls the guardrails require — a
    /// `valid` health validation, an isolated disclaimer warning, an
    /// `orange` level, `mustConfirmMedicine` toggled independently of the
    /// level. Every value written is a canonical Core type; no medical rule is
    /// re-derived.
    func replacing(
        assessment newAssessment: RiskAssessment?? = nil,
        actionCard newActionCard: ActionCard? = nil,
        healthContextValidation newValidation:
            HealthContextValidationDTO?? = nil,
        medicineKnowledge newKnowledge:
            MedicineKnowledgeSearchResult?? = nil,
        resolution newResolution: MedicineResolution? = nil,
        knowledgeCacheStatus newKnowledgeCacheStatus:
            MedicineKnowledgeCacheStatus?? = nil,
        resolutionCacheStatus newResolutionCacheStatus:
            MedicineResolutionCacheStatus? = nil
    ) -> MedicineAssessmentResponseDTO {
        MedicineAssessmentResponseDTO(
            requestID: requestID,
            resolution: newResolution ?? resolution,
            assessment: newAssessment ?? assessment,
            actionCard: newActionCard ?? actionCard,
            cacheHit: cacheHit,
            resolutionCacheStatus:
                newResolutionCacheStatus
                    ?? resolutionCacheStatus,
            knowledgeCacheStatus:
                newKnowledgeCacheStatus
                    ?? knowledgeCacheStatus,
            sourceDataVersion: sourceDataVersion,
            generatedAt: generatedAt,
            apiVersion: apiVersion,
            healthContextValidation:
                newValidation ?? healthContextValidation,
            medicineKnowledge:
                newKnowledge ?? medicineKnowledge
        )
    }
}

extension ActionCard {
    /// Returns a copy with selected canonical fields replaced.
    func replacing(
        warnings newWarnings: [String]? = nil,
        riskLevel newRiskLevel: RiskLevel? = nil,
        mustConfirmMedicine newMustConfirm: Bool? = nil,
        recommendedActions newActions:
            [RecommendedAction]? = nil,
        sourceReferences newSources:
            [SourceReference]? = nil
    ) -> ActionCard {
        ActionCard(
            title: title,
            primaryInstruction: primaryInstruction,
            warnings: newWarnings ?? warnings,
            recommendedActions: newActions
                ?? recommendedActions,
            riskLevel: newRiskLevel ?? riskLevel,
            sourceReferences: newSources
                ?? sourceReferences,
            mustConfirmMedicine: newMustConfirm
                ?? mustConfirmMedicine,
            generatedAt: generatedAt
        )
    }
}

extension RiskAssessment {
    /// Returns a copy with selected canonical fields replaced.
    func replacing(
        level newLevel: RiskLevel? = nil,
        reasons newReasons: [RiskReason]? = nil
    ) -> RiskAssessment {
        RiskAssessment(
            level: newLevel ?? level,
            reasons: newReasons ?? reasons,
            recommendedActions: recommendedActions,
            assessedAt: assessedAt,
            requiresProfessionalAdvice:
                requiresProfessionalAdvice,
            requiresFamilyAttention:
                requiresFamilyAttention,
            evidenceCompleteness: evidenceCompleteness
        )
    }
}

extension MedicineResolution {
    /// Returns a copy with `requiresUserConfirmation` replaced.
    func replacing(
        requiresUserConfirmation newValue: Bool
    ) -> MedicineResolution {
        MedicineResolution(
            status: status,
            candidates: candidates,
            selectedMedicine: selectedMedicine,
            evidence: evidence,
            requiresUserConfirmation: newValue
        )
    }
}
