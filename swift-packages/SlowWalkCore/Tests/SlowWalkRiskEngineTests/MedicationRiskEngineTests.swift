import Foundation
import SlowWalkDomain
import XCTest
@testable import SlowWalkRiskEngine

final class MedicationRiskEngineTests: XCTestCase {
    private static let day: TimeInterval = 24 * 60 * 60

    private let now = Date(timeIntervalSince1970: 1_735_689_600)

    func testCompleteEvidenceWithNoFindingsReturnsGreen() {
        let assessment = MedicationRiskEngine().assess(context: makeContext())

        XCTAssertEqual(assessment.level, .green)
        XCTAssertTrue(assessment.reasons.isEmpty)
        XCTAssertEqual(
            assessment.recommendedActions,
            [.followVerifiedSourceInformation]
        )
        XCTAssertEqual(assessment.evidenceCompleteness, .complete)
        XCTAssertFalse(assessment.requiresProfessionalAdvice)
        XCTAssertFalse(assessment.requiresFamilyAttention)
    }

    func testAllergyMatchReturnsRedWithTraceableReason() {
        let profile = makeProfile(allergies: [" INGREDIENT-A "])
        let assessment = MedicationRiskEngine().assess(
            context: makeContext(profile: profile)
        )

        XCTAssertEqual(assessment.level, .red)
        XCTAssertTrue(assessment.reasons.map(\.code).contains(.allergyMatch))
        XCTAssertTrue(
            assessment.recommendedActions.contains(
                .doNotTakeUntilMedicineConfirmed
            )
        )
        XCTAssertTrue(assessment.requiresProfessionalAdvice)
        XCTAssertTrue(assessment.requiresFamilyAttention)
    }

    func testCanonicalMedicineNameInAllergyProfileReturnsRed() {
        let profile = makeProfile(allergies: [" demo medicine a "])
        let assessment = MedicationRiskEngine().assess(
            context: makeContext(profile: profile)
        )

        XCTAssertEqual(assessment.level, .red)
        XCTAssertTrue(assessment.reasons.map(\.code).contains(.allergyMatch))
    }

    func testSourcedMedicineAliasInAllergyProfileReturnsRed() {
        let profile = makeProfile(allergies: [" MEDICINE A "])
        let assessment = MedicationRiskEngine().assess(
            context: makeContext(profile: profile)
        )

        XCTAssertEqual(assessment.level, .red)
        XCTAssertTrue(assessment.reasons.map(\.code).contains(.allergyMatch))
    }

    func testAllergyIdentityMatchDoesNotUseSubstrings() {
        let profile = makeProfile(allergies: ["medicine"])
        let assessment = MedicationRiskEngine().assess(
            context: makeContext(profile: profile)
        )

        XCTAssertFalse(assessment.reasons.map(\.code).contains(.allergyMatch))
    }

    func testDuplicateActiveIngredientReturnsRed() {
        let profile = makeProfile(
            currentMedicineIngredientIDs: ["ingredient-a"]
        )
        let assessment = MedicationRiskEngine().assess(
            context: makeContext(profile: profile)
        )

        XCTAssertEqual(assessment.level, .red)
        XCTAssertTrue(
            assessment.reasons.map(\.code).contains(
                .duplicateActiveIngredient
            )
        )
    }

    func testFrequentUseAtConfiguredThresholdReturnsOrange() {
        let records = [
            makeRecord(token: 1, at: now.addingTimeInterval(-3 * 60 * 60)),
            makeRecord(token: 2, at: now.addingTimeInterval(-2 * 60 * 60)),
            makeRecord(token: 3, at: now.addingTimeInterval(-1 * 60 * 60)),
        ]

        let finding = FrequentUseRule(configuration: .demo).evaluate(
            context: makeContext(records: records)
        )

        XCTAssertEqual(finding?.level, .orange)
        XCTAssertEqual(finding?.reason.code, .frequentUse)
        XCTAssertTrue(
            finding?.recommendedActions.contains(.reviewMedicationHistory)
                == true
        )
    }

    func testProlongedUseReturnsYellowForDemoSequence() {
        let records = [
            makeRecord(token: 1, at: now.addingTimeInterval(-4 * Self.day)),
            makeRecord(token: 2, at: now.addingTimeInterval(-2 * Self.day)),
            makeRecord(token: 3, at: now),
        ]

        let finding = ProlongedUseRule(configuration: .demo).evaluate(
            context: makeContext(records: records)
        )

        XCTAssertEqual(finding?.level, .yellow)
        XCTAssertEqual(finding?.reason.code, .prolongedUse)
    }

    func testProlongedUseReturnsOrangeForLongerDemoSequence() {
        let records = [
            makeRecord(token: 1, at: now.addingTimeInterval(-8 * Self.day)),
            makeRecord(token: 2, at: now.addingTimeInterval(-6 * Self.day)),
            makeRecord(token: 3, at: now.addingTimeInterval(-4 * Self.day)),
            makeRecord(token: 4, at: now.addingTimeInterval(-2 * Self.day)),
            makeRecord(token: 5, at: now),
        ]

        let finding = ProlongedUseRule(configuration: .demo).evaluate(
            context: makeContext(records: records)
        )

        XCTAssertEqual(finding?.level, .orange)
    }

    func testMissingSourceNeverReturnsGreenOrDosageAction() {
        let medicine = makeMedicine(sourceReferences: [])
        let assessment = MedicationRiskEngine().assess(
            context: makeContext(medicine: medicine)
        )

        XCTAssertGreaterThanOrEqual(assessment.level, .yellow)
        XCTAssertTrue(
            assessment.reasons.map(\.code).contains(.missingEvidence)
        )
        XCTAssertFalse(
            assessment.recommendedActions.contains(
                .followVerifiedSourceInformation
            )
        )
        XCTAssertTrue(
            assessment.recommendedActions.contains(.reviewMedicineSources)
        )
    }

    func testRecognitionFailureBlocksMedicineSpecificGuidance() {
        let scan = makeScan(
            candidateMedicineID: nil,
            confidence: 0.1,
            status: .failed,
            recognizedText: ""
        )
        let assessment = MedicationRiskEngine().assess(
            context: makeContext(scan: scan)
        )

        XCTAssertGreaterThanOrEqual(assessment.level, .yellow)
        XCTAssertTrue(
            assessment.reasons.map(\.code).contains(.recognitionFailed)
        )
        XCTAssertTrue(
            assessment.recommendedActions.contains(
                .doNotTakeUntilMedicineConfirmed
            )
        )
        XCTAssertTrue(
            assessment.recommendedActions.contains(.retakeMedicinePhoto)
        )
    }

    func testLowRecognitionConfidenceRequestsNewPhoto() {
        let scan = makeScan(confidence: 0.5)
        let assessment = MedicationRiskEngine().assess(
            context: makeContext(scan: scan)
        )

        XCTAssertGreaterThanOrEqual(assessment.level, .yellow)
        XCTAssertTrue(
            assessment.reasons.map(\.code).contains(.missingEvidence)
        )
        XCTAssertTrue(
            assessment.recommendedActions.contains(.retakeMedicinePhoto)
        )
    }

    func testMissingBodyMetricsReturnsYellowDataQualityFinding() {
        let profile = makeProfile(metrics: .missing)
        let assessment = MedicationRiskEngine().assess(
            context: makeContext(profile: profile)
        )

        XCTAssertGreaterThanOrEqual(assessment.level, .yellow)
        XCTAssertTrue(
            assessment.reasons.map(\.code).contains(.bodyMetricsMissing)
        )
        XCTAssertTrue(
            assessment.recommendedActions.contains(.remeasureBodyMetrics)
        )
    }

    func testStaleBodyMetricsReturnsYellowWithoutDiagnosticThresholds() {
        let staleMetrics = BodyMetrics(
            systolicBloodPressure: 120,
            diastolicBloodPressure: 80,
            heartRate: 70,
            measuredAt: now.addingTimeInterval(-31 * Self.day)
        )
        let profile = makeProfile(metrics: .value(staleMetrics))
        let assessment = MedicationRiskEngine().assess(
            context: makeContext(profile: profile)
        )

        XCTAssertEqual(assessment.level, .yellow)
        XCTAssertTrue(
            assessment.reasons.map(\.code).contains(.bodyMetricsStale)
        )
    }

    func testStructurallyInvalidBodyMetricsReturnsYellow() {
        let invalidMetrics = BodyMetrics(
            systolicBloodPressure: -1,
            diastolicBloodPressure: nil,
            heartRate: 70,
            measuredAt: now
        )
        let profile = makeProfile(metrics: .value(invalidMetrics))
        let assessment = MedicationRiskEngine().assess(
            context: makeContext(profile: profile)
        )

        XCTAssertEqual(assessment.level, .yellow)
        XCTAssertTrue(
            assessment.reasons.map(\.code).contains(.bodyMetricsInvalid)
        )
    }

    func testHighestRiskWinsAndAllReasonsAreRetained() {
        let medicine = makeMedicine(contraindicationTags: ["allergy-a"])
        let profile = makeProfile(
            allergies: ["allergy-a"],
            currentMedicineIngredientIDs: ["ingredient-a"]
        )

        let assessment = MedicationRiskEngine().assess(
            context: makeContext(medicine: medicine, profile: profile)
        )

        XCTAssertEqual(assessment.level, .red)
        XCTAssertEqual(
            assessment.reasons.map(\.code),
            [.allergyMatch, .duplicateActiveIngredient]
        )
    }

    func testReasonOrderAndAssessmentAreIndependentOfRecordOrder() {
        let medicine = makeMedicine(contraindicationTags: ["allergy-a"])
        let profile = makeProfile(
            allergies: ["allergy-a"],
            currentMedicineIngredientIDs: ["ingredient-a"]
        )
        let records = [
            makeRecord(token: 1, at: now.addingTimeInterval(-3 * 60 * 60)),
            makeRecord(token: 2, at: now.addingTimeInterval(-2 * 60 * 60)),
            makeRecord(token: 3, at: now.addingTimeInterval(-1 * 60 * 60)),
        ]
        let engine = MedicationRiskEngine()

        let first = engine.assess(
            context: makeContext(
                medicine: medicine,
                profile: profile,
                records: records
            )
        )
        let second = engine.assess(
            context: makeContext(
                medicine: medicine,
                profile: profile,
                records: Array(records.reversed())
            )
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            first.reasons.map(\.code),
            [.allergyMatch, .duplicateActiveIngredient, .frequentUse]
        )
    }

    func testSevenDayWindowIncludesExactBoundary() throws {
        let configuration = try makeConfiguration(frequentUseThreshold: 1)
        let rule = FrequentUseRule(configuration: configuration)
        let boundaryRecord = makeRecord(
            token: 1,
            at: now.addingTimeInterval(-7 * Self.day)
        )

        let finding = rule.evaluate(
            context: makeContext(records: [boundaryRecord])
        )

        XCTAssertEqual(finding?.reason.code, .frequentUse)
    }

    func testSevenDayWindowExcludesOneSecondBeforeBoundary() throws {
        let configuration = try makeConfiguration(frequentUseThreshold: 1)
        let rule = FrequentUseRule(configuration: configuration)
        let outsideRecord = makeRecord(
            token: 1,
            at: now.addingTimeInterval(-(7 * Self.day) - 1)
        )

        let finding = rule.evaluate(
            context: makeContext(records: [outsideRecord])
        )

        XCTAssertNil(finding)
    }

    func testDuplicateRecordIDDoesNotInflateFrequency() throws {
        let configuration = try makeConfiguration(frequentUseThreshold: 2)
        let record = makeRecord(
            token: 1,
            at: now.addingTimeInterval(-Self.day)
        )

        let finding = FrequentUseRule(configuration: configuration).evaluate(
            context: makeContext(records: [record, record])
        )

        XCTAssertNil(finding)
    }

    func testEmptyRecordsDoNotTriggerFrequencyOrDuration() {
        let context = makeContext(records: [])

        XCTAssertNil(
            FrequentUseRule(configuration: .demo).evaluate(context: context)
        )
        XCTAssertNil(
            ProlongedUseRule(configuration: .demo).evaluate(context: context)
        )
    }

    func testFutureRecordIsExcludedFromFrequencyAndDowngradesEvidence() throws {
        let configuration = try makeConfiguration(frequentUseThreshold: 1)
        let futureRecord = makeRecord(
            token: 1,
            at: now.addingTimeInterval(1)
        )
        let context = makeContext(records: [futureRecord])

        let frequencyFinding = FrequentUseRule(
            configuration: configuration
        ).evaluate(context: context)
        let assessment = MedicationRiskEngine(
            configuration: configuration
        ).assess(context: context)

        XCTAssertNil(frequencyFinding)
        XCTAssertEqual(assessment.level, .yellow)
        XCTAssertEqual(assessment.evidenceCompleteness, .partial)
        XCTAssertTrue(
            assessment.reasons.map(\.code).contains(.missingEvidence)
        )
    }

    func testPartialEvidenceCannotBecomeGreenEvenWithCustomNoOpRules() {
        let engine = MedicationRiskEngine(rules: [])
        let assessment = engine.assess(
            context: makeContext(evidenceCompleteness: .partial)
        )

        XCTAssertEqual(assessment.level, .yellow)
        XCTAssertEqual(assessment.reasons.first?.code, .missingEvidence)
    }

    func testInvalidConfigurationIsRejected() {
        XCTAssertThrowsError(
            try MedicationRiskConfiguration(
                recentUseWindow: 0,
                frequentUseThreshold: 3,
                prolongedUseYellowThreshold: Self.day,
                prolongedUseOrangeThreshold: 2 * Self.day,
                prolongedUseMaximumGap: Self.day,
                minimumRecognitionConfidence: 0.75,
                bodyMetricsMaximumAge: 30 * Self.day,
                futureTimestampTolerance: 0
            )
        ) { error in
            XCTAssertEqual(
                error as? MedicationRiskConfigurationError,
                .nonPositiveDuration(field: "recentUseWindow")
            )
        }
    }

    private func makeContext(
        medicine: Medicine? = nil,
        profile: UserHealthProfile? = nil,
        records: [MedicationRecord] = [],
        scan: MedicineScanEvent? = nil,
        evidenceCompleteness: EvidenceCompleteness = .complete
    ) -> MedicationRiskContext {
        MedicationRiskContext(
            medicine: medicine ?? makeMedicine(),
            userProfile: profile ?? makeProfile(),
            recentRecords: records,
            scanEvent: scan ?? makeScan(),
            assessedAt: now,
            evidenceCompleteness: evidenceCompleteness
        )
    }

    private func makeMedicine(
        sourceReferences: [SourceReference]? = nil,
        activeIngredientIDs: [String] = ["ingredient-a"],
        contraindicationTags: [String] = []
    ) -> Medicine {
        Medicine(
            id: "medicine-a",
            canonicalName: "Demo Medicine A",
            aliases: ["Medicine A"],
            activeIngredientIDs: activeIngredientIDs,
            medicineCategory: .other,
            sourceReferences: sourceReferences ?? [makeSourceReference()],
            dosageTextFromSource: "Use only according to the verified source.",
            contraindicationTags: contraindicationTags
        )
    }

    private func makeSourceReference() -> SourceReference {
        SourceReference(
            sourceName: "Demo Source",
            documentTitle: "DEMO DATA - NOT FOR CLINICAL USE",
            optionalURL: nil,
            retrievedAt: now.addingTimeInterval(-Self.day),
            versionOrDate: "demo-v1"
        )
    }

    private enum MetricsInput {
        case valid
        case missing
        case value(BodyMetrics)
    }

    private func makeProfile(
        allergies: [String] = [],
        currentMedicineIngredientIDs: [String] = [],
        metrics: MetricsInput = .valid
    ) -> UserHealthProfile {
        let bodyMetrics: BodyMetrics?
        switch metrics {
        case .valid:
            bodyMetrics = BodyMetrics(
                systolicBloodPressure: 120,
                diastolicBloodPressure: 80,
                heartRate: 70,
                measuredAt: now.addingTimeInterval(-Self.day)
            )
        case .missing:
            bodyMetrics = nil
        case let .value(value):
            bodyMetrics = value
        }

        return UserHealthProfile(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
            age: 70,
            allergies: allergies,
            diagnosedConditions: [],
            currentMedicineIngredientIDs: currentMedicineIngredientIDs,
            bodyMetrics: bodyMetrics,
            updatedAt: now.addingTimeInterval(-Self.day)
        )
    }

    private func makeScan(
        candidateMedicineID: String? = "medicine-a",
        confidence: Double = 0.99,
        status: RecognitionStatus = .recognized,
        recognizedText: String = "Demo Medicine A"
    ) -> MedicineScanEvent {
        MedicineScanEvent(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2)),
            recognizedText: recognizedText,
            candidateMedicineID: candidateMedicineID,
            confidence: confidence,
            scannedAt: now,
            recognitionStatus: status
        )
    }

    private func makeRecord(
        token: UInt8,
        at recordedAt: Date
    ) -> MedicationRecord {
        MedicationRecord(
            id: UUID(
                uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, token)
            ),
            medicineID: "medicine-a",
            activeIngredientIDs: ["ingredient-a"],
            recordedAt: recordedAt,
            eventType: .taken,
            source: .manualEntry
        )
    }

    private func makeConfiguration(
        frequentUseThreshold: Int
    ) throws -> MedicationRiskConfiguration {
        try MedicationRiskConfiguration(
            recentUseWindow: 7 * Self.day,
            frequentUseThreshold: frequentUseThreshold,
            prolongedUseYellowThreshold: 3 * Self.day,
            prolongedUseOrangeThreshold: 7 * Self.day,
            prolongedUseMaximumGap: 2 * Self.day,
            minimumRecognitionConfidence: 0.75,
            bodyMetricsMaximumAge: 30 * Self.day,
            futureTimestampTolerance: 0
        )
    }
}
