import XCTest
@testable import SlowWalkPresentation
import SlowWalkDomain
import SlowWalkAPIContracts

final class StateMappingTests: XCTestCase {

    // MARK: - Loading state

    func testMapLoading() {
        let dto = MedicineAssessDTO.loading()
        XCTAssertEqual(StateMapper.map(dto), .loading)
    }

    // MARK: - Timeout state

    func testMapTimeout() {
        let dto = MedicineAssessDTO.timeout()
        XCTAssertEqual(StateMapper.map(dto), .timeout)
    }

    // MARK: - Red risk state

    func testMapRedRisk() {
        let dto = MedicineAssessDTO(currentRisk: .highRed)
        XCTAssertEqual(StateMapper.map(dto), .redRisk)
    }

    // MARK: - Health warning state

    func testMapHealthWarning() {
        let dto = MedicineAssessDTO(hasHealthAlert: true)
        XCTAssertEqual(StateMapper.map(dto), .healthWarning)
    }

    // MARK: - Knowledge warning state

    func testMapKnowledgeWarning() {
        let dto = MedicineAssessDTO(hasSourceWarning: true)
        XCTAssertEqual(StateMapper.map(dto), .knowledgeWarning)
    }

    // MARK: - Ambiguous state

    func testMapAmbiguous() {
        let dto = MedicineAssessDTO(isAmbiguousResult: true)
        XCTAssertEqual(StateMapper.map(dto), .ambiguous)
    }

    // MARK: - Normal success state

    func testMapNormalSuccess() {
        let dto = MedicineAssessDTO(currentRisk: .lowGreen)
        XCTAssertEqual(StateMapper.map(dto), .normalSuccess)
    }

    // MARK: - Priority ordering

    func testPriorityOrderTimeoutOverridesAll() {
        let dto = MedicineAssessDTO(
            isLoading: true,
            isTimeout: true,
            isCancelled: false,
            hasHealthAlert: true,
            hasSourceWarning: false,
            isAmbiguousResult: true,
            currentRisk: .highRed
        )
        XCTAssertEqual(StateMapper.map(dto), .timeout)
    }

    func testPriorityOrderLoadingOverridesRiskAndWarnings() {
        let dto = MedicineAssessDTO(
            isLoading: true,
            isTimeout: false,
            isCancelled: false,
            hasHealthAlert: true,
            hasSourceWarning: true,
            isAmbiguousResult: false,
            currentRisk: .highRed
        )
        XCTAssertEqual(StateMapper.map(dto), .loading)
    }

    func testPriorityOrderRiskOverridesHealthAndSourceWarnings() {
        let dto = MedicineAssessDTO(
            isLoading: false,
            isTimeout: false,
            isCancelled: false,
            hasHealthAlert: true,
            hasSourceWarning: true,
            isAmbiguousResult: true,
            currentRisk: .highRed
        )
        XCTAssertEqual(StateMapper.map(dto), .redRisk)
    }

    func testPriorityOrderHealthOverridesSourceWarning() {
        let dto = MedicineAssessDTO(
            isLoading: false,
            isTimeout: false,
            isCancelled: false,
            hasHealthAlert: true,
            hasSourceWarning: true,
            isAmbiguousResult: true,
            currentRisk: .lowGreen
        )
        XCTAssertEqual(StateMapper.map(dto), .healthWarning)
    }

    func testPriorityOrderSourceWarningOverridesAmbiguous() {
        let dto = MedicineAssessDTO(
            isLoading: false,
            isTimeout: false,
            isCancelled: false,
            hasHealthAlert: false,
            hasSourceWarning: true,
            isAmbiguousResult: true,
            currentRisk: .lowGreen
        )
        XCTAssertEqual(StateMapper.map(dto), .knowledgeWarning)
    }

    // MARK: - init(response:) from API

    func testInitResponseMapsRedRiskCorrectly() {
        let response = makeResponse(
            riskLevel: .red,
            warnings: ["严重警告"],
            hasHealthValidation: nil,
            resolutionStatus: .resolved
        )
        let dto = MedicineAssessDTO(response: response)
        XCTAssertEqual(dto.currentRisk, .highRed)
        XCTAssertTrue(dto.hasSourceWarning)
        XCTAssertFalse(dto.isAmbiguousResult)
    }

    func testInitResponseMapsHealthAlertCorrectly() {
        let response = makeResponse(
            riskLevel: .green,
            warnings: [],
            hasHealthValidation: HealthContextValidationDTO(
                status: "warning",
                warnings: [],
                configurationNotices: []
            ),
            resolutionStatus: .resolved
        )
        let dto = MedicineAssessDTO(response: response)
        XCTAssertTrue(dto.hasHealthAlert)
        XCTAssertFalse(dto.hasSourceWarning)
        XCTAssertEqual(dto.currentRisk, .lowGreen)
    }

    func testInitResponseMapsAmbiguousStatus() {
        let response = makeResponse(
            riskLevel: .yellow,
            warnings: [],
            hasHealthValidation: nil,
            resolutionStatus: .ambiguous
        )
        let dto = MedicineAssessDTO(response: response)
        XCTAssertTrue(dto.isAmbiguousResult)
        XCTAssertEqual(dto.currentRisk, .yellow)
    }

    func testInitResponseMapsInsufficientEvidenceAsAmbiguous() {
        let response = makeResponse(
            riskLevel: .green,
            warnings: [],
            hasHealthValidation: nil,
            resolutionStatus: .insufficientEvidence
        )
        let dto = MedicineAssessDTO(response: response)
        XCTAssertTrue(dto.isAmbiguousResult)
    }

    func testInitResponseMapsNormalSuccess() {
        let response = makeResponse(
            riskLevel: .green,
            warnings: [],
            hasHealthValidation: nil,
            resolutionStatus: .resolved
        )
        let dto = MedicineAssessDTO(response: response)
        XCTAssertFalse(dto.hasHealthAlert)
        XCTAssertFalse(dto.hasSourceWarning)
        XCTAssertFalse(dto.isAmbiguousResult)
        XCTAssertEqual(dto.currentRisk, .lowGreen)
    }

    // MARK: - DisplayRiskLevel mapping

    func testDisplayRiskLevelInitFromDomainRisk() {
        XCTAssertEqual(DisplayRiskLevel(domainRisk: .green), .lowGreen)
        XCTAssertEqual(DisplayRiskLevel(domainRisk: .yellow), .yellow)
        XCTAssertEqual(DisplayRiskLevel(domainRisk: .orange), .orange)
        XCTAssertEqual(DisplayRiskLevel(domainRisk: .red), .highRed)
    }

    // MARK: - StateMapper convenience

    func testStateMapperMapResponse() {
        let response = makeResponse(
            riskLevel: .red,
            warnings: ["警告"],
            hasHealthValidation: nil,
            resolutionStatus: .resolved
        )
        XCTAssertEqual(StateMapper.map(response: response), .redRisk)
    }

    // MARK: - Helper

    private func makeResponse(
        riskLevel: RiskLevel,
        warnings: [String],
        hasHealthValidation: HealthContextValidationDTO?,
        resolutionStatus: MedicineResolutionStatus
    ) -> MedicineAssessmentResponseDTO {
        let evidence = MedicineResolutionEvidence(
            recognizedTexts: ["text"],
            normalizedText: "test",
            normalizedQuery: "test",
            languageCode: nil,
            rawConfidence: 0.9,
            dosageForms: [],
            removedSpecifications: [],
            discardedNoise: [],
            matcherVersion: "v1",
            sourceDataVersions: []
        )
        let resolution = MedicineResolution(
            status: resolutionStatus,
            candidates: [],
            selectedMedicine: nil,
            evidence: evidence,
            requiresUserConfirmation: false
        )
        let actionCard = ActionCard(
            title: "Test",
            primaryInstruction: "Test instruction",
            warnings: warnings,
            recommendedActions: [],
            riskLevel: riskLevel,
            sourceReferences: [],
            mustConfirmMedicine: false,
            generatedAt: Date()
        )
        return MedicineAssessmentResponseDTO(
            requestID: UUID(),
            resolution: resolution,
            assessment: nil,
            actionCard: actionCard,
            cacheHit: false,
            resolutionCacheStatus: .miss,
            knowledgeCacheStatus: nil,
            sourceDataVersion: "v1",
            generatedAt: Date(),
            apiVersion: "v1",
            healthContextValidation: hasHealthValidation,
            medicineKnowledge: nil
        )
    }
}
