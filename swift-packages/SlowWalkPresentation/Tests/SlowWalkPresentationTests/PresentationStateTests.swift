import SlowWalkAPIContracts
import SlowWalkClientCore
import SlowWalkDomain
import SlowWalkMedicineKnowledge
import SlowWalkPresentation
import XCTest

/// Verifies risk-level preservation, state discrimination, and edge cases.
///
/// Every assertion reads canonical values: `RiskLevel`, `RiskReasonCode`,
/// `ClientFailureKind`, `MedicineResolutionStatus`, and the governance
/// verdict. No fixture ID or human-readable string is matched.
final class PresentationStateTests: XCTestCase {

    // MARK: - Test 6: yellow 不归 green

    func test_yellowRiskLevel_isNotCollapsedToGreen() async throws {
        let payload = try PresentationFixtureLoader.load(
            "medicine-health-warning.json"
        )
        let viewState = try await CoordinatorHarness.viewState(
            for: payload
        )
        let display = MedicineStateMapper.map(viewState)

        // The canonical risk level is yellow, not green.
        XCTAssertEqual(
            display.actionCard?.riskLevel,
            .yellow
        )
        // The variant must not be .normal (green).
        XCTAssertNotEqual(display.variant, .normal)
        XCTAssertEqual(
            display.variant,
            .healthWarning
        )
    }

    // MARK: - Test 7: orange 不归 green

    func test_orangeRiskLevel_isNotCollapsedToGreen() async throws {
        let payload = try PresentationFixtureLoader.load(
            "medicine-normal.json"
        )
        let orangeCard = payload.response.actionCard.replacing(
            riskLevel: .orange
        )
        let orangeAssessment = payload.response.assessment?
            .replacing(level: .orange)
        let orangeResponse = payload.response.replacing(
            assessment: orangeAssessment,
            actionCard: orangeCard
        )

        let viewState = try await CoordinatorHarness.viewState(
            response: orangeResponse,
            payload: payload
        )
        let display = MedicineStateMapper.map(viewState)

        // The canonical level is orange.
        XCTAssertEqual(
            display.actionCard?.riskLevel,
            .orange
        )
        // Not mapped to normal or healthWarning or knowledgeWarning.
        XCTAssertEqual(
            display.variant,
            .elevatedRisk
        )
    }

    // MARK: - Test 8: valid health validation 不产生健康警告

    func test_validHealthValidation_doesNotProduceHealthWarning() async throws {
        let payload = try PresentationFixtureLoader.load(
            "medicine-normal.json"
        )
        // Confirm the validation status is "valid" in the fixture.
        XCTAssertEqual(
            payload.response.healthContextValidation?.status,
            "valid"
        )

        let viewState = try await CoordinatorHarness.viewState(
            for: payload
        )
        let display = MedicineStateMapper.map(viewState)

        XCTAssertNotEqual(
            display.variant,
            .healthWarning
        )
    }

    // MARK: - Test 9: disclaimer warning 不产生知识来源警告

    func test_disclaimerWarning_doesNotProduceKnowledgeWarning() async throws {
        let payload = try PresentationFixtureLoader.load(
            "medicine-normal.json"
        )
        // The action card carries a DEMO DATA disclaimer warning.
        XCTAssertTrue(
            payload.response.actionCard.warnings.contains(
                "DEMO DATA — NOT FOR CLINICAL USE"
            )
        )

        let viewState = try await CoordinatorHarness.viewState(
            for: payload
        )
        let display = MedicineStateMapper.map(viewState)

        // Variant must not be knowledgeWarning despite the disclaimer.
        XCTAssertNotEqual(
            display.variant,
            .knowledgeWarning
        )
        XCTAssertEqual(display.variant, .normal)
    }

    // MARK: - Test 10: ambiguous 不被其他状态吞掉

    func test_ambiguous_isNotSwallowedByOtherWarnings() async throws {
        let payload = try PresentationFixtureLoader.load(
            "medicine-ambiguous.json"
        )

        let viewState = try await CoordinatorHarness.viewState(
            for: payload
        )
        let display = MedicineStateMapper.map(viewState)

        // The ambiguous fixture has health-context warnings *and* is
        // ambiguous. Ambiguous must win because the medicine identity
        // itself is unconfirmed.
        XCTAssertEqual(display.variant, .ambiguous)
        XCTAssertTrue(display.requiresMedicineConfirmation)
    }

    // MARK: - Test 11: knowledge confirmation 状态正确

    func test_knowledgeConfirmationStatus_isCorrect() async throws {
        let payload = try PresentationFixtureLoader.load(
            "medicine-source-warning.json"
        )

        // Governance verdict requires confirmation — this is the canonical
        // consolidated safety decision.
        let knowledge = try XCTUnwrap(
            payload.response.medicineKnowledge
        )
        XCTAssertTrue(
            knowledge.governanceVerdict.requiresConfirmation
        )
        XCTAssertTrue(
            knowledge.requiresConservativeAction
        )

        let viewState = try await CoordinatorHarness.viewState(
            for: payload
        )
        let display = MedicineStateMapper.map(viewState)

        XCTAssertEqual(
            display.variant,
            .knowledgeWarning
        )
        XCTAssertTrue(display.requiresMedicineConfirmation)
    }

    // MARK: - Test 12: redRisk 在需要确认时仍保持 red

    func test_redRisk_isPreservedWhenMedicineConfirmationIsRequired() async throws {
        let payload = try PresentationFixtureLoader.load(
            "medicine-red-risk.json"
        )

        // The red-risk fixture has mustConfirmMedicine == false.
        XCTAssertFalse(
            payload.response.actionCard.mustConfirmMedicine
        )

        // Confirmation is a separate presentation dimension, but the canonical
        // response requires both confirmation flags to agree.
        let cardWithConfirm = payload.response.actionCard.replacing(
            mustConfirmMedicine: true
        )
        let resolutionWithConfirm = payload.response.resolution.replacing(
            requiresUserConfirmation: true
        )
        let responseWithConfirm = payload.response.replacing(
            actionCard: cardWithConfirm,
            resolution: resolutionWithConfirm
        )

        let viewState = try await CoordinatorHarness.viewState(
            response: responseWithConfirm,
            payload: payload
        )
        let display = MedicineStateMapper.map(viewState)

        XCTAssertEqual(display.variant, .redRisk)
        // mustConfirmMedicine on the card is independent of the variant.
        XCTAssertTrue(
            display.actionCard?.mustConfirmMedicine == true
        )
    }

    // MARK: - Test 13: unresolved 状态不误映射 normal

    func test_unresolvedStatus_isNotMappedToNormal() async throws {
        let payload = try PresentationFixtureLoader.load(
            "medicine-normal.json"
        )
        let notFoundResolution = MedicineResolution(
            status: .notFound,
            candidates: payload.response.resolution.candidates,
            selectedMedicine: nil,
            evidence: payload.response.resolution.evidence,
            requiresUserConfirmation: true
        )
        let notFoundResponse = payload.response.replacing(
            assessment: .some(nil),
            actionCard: payload.response.actionCard.replacing(
                mustConfirmMedicine: true
            ),
            resolution: notFoundResolution
        )

        let viewState = try await CoordinatorHarness.viewState(
            response: notFoundResponse,
            payload: payload
        )
        let display = MedicineStateMapper.map(viewState)

        // Any non-resolved, non-ambiguous status must not be presented
        // as a normal result.
        XCTAssertNotEqual(display.variant, .normal)
        XCTAssertTrue(display.requiresMedicineConfirmation)
    }

    // MARK: - Test 14: timeout

    func test_timeout_producesTimeoutVariant() async throws {
        let payload = try PresentationFixtureLoader.load(
            "medicine-normal.json"
        )
        let viewState = try await CoordinatorHarness.viewState(
            behavior: .timeout,
            payload: payload
        )
        let display = MedicineStateMapper.map(viewState)

        XCTAssertEqual(display.variant, .timeout)
        XCTAssertEqual(
            display.failure?.failure.kind,
            .timeout
        )
        XCTAssertNil(display.actionCard)
        // Timeout is recoverable.
        XCTAssertTrue(
            display.failure?.allowsRetry == true
        )
    }

    // MARK: - Test 15: cancellation

    func test_cancellation_producesCancelledVariant() {
        let viewState = MedicineAssessmentViewState.cancelled
        let display = MedicineStateMapper.map(viewState)

        XCTAssertEqual(display.variant, .cancelled)
        XCTAssertNil(display.actionCard)
        XCTAssertNil(display.failure)
        XCTAssertFalse(display.requiresMedicineConfirmation)
    }

    // MARK: - Test 16: generic failure

    func test_genericFailure_producesFailedVariant() async throws {
        let payload = try PresentationFixtureLoader.load(
            "medicine-normal.json"
        )
        let viewState = try await CoordinatorHarness.viewState(
            behavior: .malformedResponse,
            payload: payload
        )
        let display = MedicineStateMapper.map(viewState)

        XCTAssertEqual(display.variant, .failed)
        XCTAssertEqual(
            display.failure?.failure.kind,
            .malformedResponse
        )
        XCTAssertNil(display.actionCard)
    }

    // MARK: - Additional guard: insufficientEvidence, recognitionFailed

    func test_insufficientEvidence_isNotMappedToNormal() async throws {
        let payload = try PresentationFixtureLoader.load(
            "medicine-normal.json"
        )
        let insufficientResolution = MedicineResolution(
            status: .insufficientEvidence,
            candidates: [],
            selectedMedicine: nil,
            evidence: payload.response.resolution.evidence,
            requiresUserConfirmation: true
        )
        let response = payload.response.replacing(
            assessment: .some(nil),
            actionCard: payload.response.actionCard.replacing(
                mustConfirmMedicine: true
            ),
            resolution: insufficientResolution
        )

        let viewState = try await CoordinatorHarness.viewState(
            response: response,
            payload: payload
        )
        let display = MedicineStateMapper.map(viewState)

        XCTAssertNotEqual(display.variant, .normal)
        XCTAssertTrue(display.requiresMedicineConfirmation)
    }

    func test_recognitionFailed_isNotMappedToNormal() async throws {
        let payload = try PresentationFixtureLoader.load(
            "medicine-normal.json"
        )
        let failedResolution = MedicineResolution(
            status: .recognitionFailed,
            candidates: [],
            selectedMedicine: nil,
            evidence: payload.response.resolution.evidence,
            requiresUserConfirmation: true
        )
        let response = payload.response.replacing(
            assessment: .some(nil),
            actionCard: payload.response.actionCard.replacing(
                mustConfirmMedicine: true
            ),
            resolution: failedResolution
        )

        let viewState = try await CoordinatorHarness.viewState(
            response: response,
            payload: payload
        )
        let display = MedicineStateMapper.map(viewState)

        XCTAssertNotEqual(display.variant, .normal)
        XCTAssertTrue(display.requiresMedicineConfirmation)
    }
}
