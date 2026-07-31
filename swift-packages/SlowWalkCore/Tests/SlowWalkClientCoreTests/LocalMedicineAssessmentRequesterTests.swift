import Foundation
import SlowWalkAPIContracts
import SlowWalkDataInterfaces
import SlowWalkDomain
import SlowWalkMedicineKnowledge
import SlowWalkMedicinePipeline
import XCTest

@testable import SlowWalkClientCore

final class LocalMedicineAssessmentRequesterTests: XCTestCase {
    func testNormalAssessmentReturnsGreenWithValidHealthContext()
        async throws
    {
        let requester = LocalMedicineAssessmentRequester.demo(
            clock: FixedClientClock(date: clientTestDate)
        )
        let request = makeRequest(
            texts: ["Acetaminophen"],
            requestID: clientTestUUID(82),
            userProfile: makeCompleteProfile()
        )

        let response = try await requester.assess(request: request)

        XCTAssertEqual(response.assessment?.level, .green)
        XCTAssertEqual(
            response.healthContextValidation?.status,
            HealthContextValidationStatus.valid.rawValue
        )
        XCTAssertEqual(response.healthContextValidation?.warnings, [])
    }

    func testMissingBodyMetricsProducesHealthWarning() async throws {
        let requester = LocalMedicineAssessmentRequester.demo(
            clock: FixedClientClock(date: clientTestDate)
        )
        let request = makeRequest(
            texts: ["Acetaminophen"],
            requestID: clientTestUUID(83)
        )

        let response = try await requester.assess(request: request)

        XCTAssertEqual(response.assessment?.level, .yellow)
        XCTAssertEqual(
            response.healthContextValidation?.status,
            HealthContextValidationStatus.validWithWarnings.rawValue
        )
        XCTAssertFalse(
            response.healthContextValidation?.warnings.isEmpty ?? true
        )
    }

    func testAllergyRiskRemainsRedThroughLocalRequester() async throws {
        let requester = LocalMedicineAssessmentRequester.demo(
            clock: FixedClientClock(date: clientTestDate)
        )
        let request = makeRequest(
            texts: ["Acetaminophen"],
            requestID: clientTestUUID(84),
            userProfile: makeCompleteProfile(
                allergies: ["acetaminophen"]
            )
        )

        let response = try await requester.assess(request: request)

        XCTAssertEqual(response.assessment?.level, .red)
        XCTAssertEqual(response.actionCard.riskLevel, .red)
    }

    func testAssessmentRunsPipelineLocally() async throws {
        let requester = LocalMedicineAssessmentRequester.demo(
            clock: FixedClientClock(date: clientTestDate)
        )
        let request = makeRequest(
            texts: ["Acetaminophen"],
            requestID: clientTestUUID(60)
        )

        let response = try await requester.assess(request: request)

        XCTAssertEqual(response.requestID, request.requestID)
        XCTAssertEqual(response.apiVersion, request.apiVersion)
        XCTAssertEqual(response.resolution.status, .resolved)
        XCTAssertEqual(
            response.resolution.selectedMedicine?.id,
            "demo-acetaminophen"
        )
        XCTAssertFalse(response.sourceDataVersion.isEmpty)
        XCTAssertEqual(response.generatedAt, clientTestDate)
        XCTAssertNoThrow(
            try MedicineAssessmentResponseValidator().validate(
                response,
                for: request
            )
        )
    }

    func testRequesterMatchesDirectPipelineOutputFieldByField()
        async throws
    {
        let request = makeRequest(
            texts: ["Acetaminophen"],
            requestID: clientTestUUID(92),
            userProfile: makeCompleteProfile()
        )
        let clock = FixedClientClock(date: clientTestDate)
        let direct = try await MedicinePipeline(
            dateProvider: clock
        ).assess(
            input: request.input,
            userProfile: request.userProfile.domainModel,
            recentRecords: []
        )
        let requester = LocalMedicineAssessmentRequester(
            pipeline: MedicinePipeline(dateProvider: clock)
        )

        let response = try await requester.assess(request: request)

        XCTAssertEqual(response.requestID, request.requestID)
        XCTAssertEqual(response.resolution, direct.resolution)
        XCTAssertEqual(response.assessment, direct.assessment)
        XCTAssertEqual(response.actionCard, direct.actionCard)
        XCTAssertEqual(response.cacheHit, direct.cacheHit)
        XCTAssertEqual(response.resolutionCacheStatus, direct.cacheStatus)
        XCTAssertEqual(
            response.knowledgeCacheStatus,
            direct.knowledgeResult?.cacheStatus
        )
        XCTAssertEqual(response.sourceDataVersion, direct.sourceDataVersion)
        XCTAssertEqual(response.generatedAt, direct.generatedAt)
        XCTAssertEqual(response.apiVersion, request.apiVersion)
        XCTAssertEqual(
            response.healthContextValidation,
            HealthContextValidationDTO(direct.healthContextValidation)
        )
        XCTAssertEqual(response.medicineKnowledge, direct.knowledgeResult)
    }

    func testInjectedKnowledgeWarningRemainsConservative() async throws {
        let medicine = try demoMedicines(named: "Acetaminophen")
        let knowledge = makeKnowledgeResult(
            normalizedQuery: "acetaminophen",
            medicines: medicine,
            conservative: true
        )
        let requester = LocalMedicineAssessmentRequester(
            pipeline: MedicinePipeline(
                dateProvider: FixedClientClock(date: clientTestDate),
                knowledgeSearcher: ClientKnowledgeSearcherStub(
                    results: [.success(knowledge)]
                )
            )
        )
        let request = makeRequest(
            texts: ["Acetaminophen"],
            requestID: clientTestUUID(93),
            userProfile: makeCompleteProfile()
        )

        let response = try await requester.assess(request: request)

        XCTAssertEqual(response.resolution.status, .resolved)
        XCTAssertTrue(response.resolution.requiresUserConfirmation)
        XCTAssertTrue(response.actionCard.mustConfirmMedicine)
        XCTAssertEqual(response.assessment?.level, .yellow)
        XCTAssertTrue(
            response.assessment?.reasons.contains {
                $0.code == .knowledgeSourceWarning
            } == true
        )
        XCTAssertNotNil(response.medicineKnowledge)
    }

    func testKnowledgeTimeoutIsRecoverableAndClearsOldConfirmation()
        async throws
    {
        let ambiguousKnowledge = makeKnowledgeResult(
            normalizedQuery: "cold relief",
            medicines: try demoMedicines(alias: "Cold Relief"),
            conservative: false
        )
        let searcher = ClientKnowledgeSearcherStub(
            results: [
                .success(ambiguousKnowledge),
                .failure(
                    .knowledgeSourceTimeout(
                        sourceIdentifier: "injected-test-source"
                    )
                ),
            ]
        )
        let requester = LocalMedicineAssessmentRequester(
            pipeline: MedicinePipeline(
                dateProvider: FixedClientClock(date: clientTestDate),
                knowledgeSearcher: searcher
            )
        )
        let oldRequest = makeRequest(
            texts: ["Cold Relief"],
            requestID: clientTestUUID(94),
            userProfile: makeCompleteProfile()
        )
        let oldResponse = try await requester.assess(request: oldRequest)
        let oldCandidate = try XCTUnwrap(
            oldResponse.resolution.candidates.first
        )
        let currentRequest = makeRequest(
            texts: ["Acetaminophen"],
            requestID: clientTestUUID(95),
            userProfile: makeCompleteProfile()
        )

        do {
            _ = try await requester.assess(request: currentRequest)
            XCTFail("Expected knowledge timeout.")
        } catch let error as ClientAPIError {
            let failure = ClientFailureMapper.map(error)
            XCTAssertEqual(error.error.code, .knowledgeSourceTimeout)
            XCTAssertEqual(error.error.requestID, currentRequest.requestID)
            XCTAssertEqual(failure.kind, .timeout)
            XCTAssertEqual(failure.apiErrorCode, .knowledgeSourceTimeout)
            XCTAssertNil(failure.endpoint)
            XCTAssertTrue(failure.isRecoverable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try await requester.confirmMedicine(
                command: MedicineCandidateConfirmationCommand(
                    originalRequestID: oldRequest.requestID,
                    candidateID: oldCandidate.medicine.id
                )
            )
            XCTFail("Expected old confirmation context to be cleared.")
        } catch let error as LocalMedicineConfirmationError {
            XCTAssertEqual(error, .noPendingAssessment)
        }
    }

    func testKnowledgeCancellationPropagatesFromLocalRequester() async {
        let requester = LocalMedicineAssessmentRequester(
            pipeline: MedicinePipeline(
                dateProvider: FixedClientClock(date: clientTestDate),
                knowledgeSearcher: ClientKnowledgeSearcherStub(
                    results: [.failure(.requestCancelled)]
                )
            )
        )
        let request = makeRequest(
            texts: ["Acetaminophen"],
            requestID: clientTestUUID(96),
            userProfile: makeCompleteProfile()
        )

        do {
            _ = try await requester.assess(request: request)
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected: cancellation must not become an API failure.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testConsecutiveRequestsKeepTheirOwnResults() async throws {
        let requester = LocalMedicineAssessmentRequester.demo(
            clock: FixedClientClock(date: clientTestDate)
        )
        let firstRequest = makeRequest(
            texts: ["Acetaminophen"],
            requestID: clientTestUUID(97),
            userProfile: makeCompleteProfile()
        )
        let secondRequest = makeRequest(
            texts: ["Ibuprofen"],
            requestID: clientTestUUID(98),
            userProfile: makeCompleteProfile()
        )

        let first = try await requester.assess(request: firstRequest)
        let second = try await requester.assess(request: secondRequest)

        XCTAssertEqual(first.requestID, firstRequest.requestID)
        XCTAssertEqual(
            first.resolution.selectedMedicine?.id,
            "demo-acetaminophen"
        )
        XCTAssertEqual(second.requestID, secondRequest.requestID)
        XCTAssertEqual(
            second.resolution.selectedMedicine?.id,
            "demo-ibuprofen"
        )
    }

    func testAmbiguousConfirmationAcceptsOnlyOfferedCandidate()
        async throws
    {
        let requester = LocalMedicineAssessmentRequester.demo()
        let request = makeRequest(
            texts: ["Cold Relief"],
            requestID: clientTestUUID(61)
        )
        let ambiguous = try await requester.assess(request: request)
        XCTAssertEqual(ambiguous.resolution.status, .ambiguous)
        let candidate = try XCTUnwrap(
            ambiguous.resolution.candidates.first
        )

        let confirmed = try await requester.confirmMedicine(
            command: MedicineCandidateConfirmationCommand(
                originalRequestID: request.requestID,
                candidateID: candidate.medicine.id
            )
        )

        XCTAssertEqual(confirmed.resolution.status, .resolved)
        XCTAssertEqual(
            confirmed.resolution.selectedMedicine?.id,
            candidate.medicine.id
        )
        XCTAssertEqual(
            confirmed.resolution.evidence.recognizedTexts,
            ["Cold Relief"]
        )
    }

    func testForgedCandidateIsRejectedWithoutConsumingContext()
        async throws
    {
        let requester = LocalMedicineAssessmentRequester.demo()
        let request = makeRequest(
            texts: ["Cold Relief"],
            requestID: clientTestUUID(62)
        )
        let ambiguous = try await requester.assess(request: request)

        do {
            _ = try await requester.confirmMedicine(
                command: MedicineCandidateConfirmationCommand(
                    originalRequestID: request.requestID,
                    candidateID: "forged-candidate"
                )
            )
            XCTFail("Expected forged candidate rejection.")
        } catch let error as LocalMedicineConfirmationError {
            XCTAssertEqual(error, .candidateNotOffered)
        }

        let offered = try XCTUnwrap(
            ambiguous.resolution.candidates.first
        )
        let confirmed = try await requester.confirmMedicine(
            command: MedicineCandidateConfirmationCommand(
                originalRequestID: request.requestID,
                candidateID: offered.medicine.id
            )
        )
        XCTAssertEqual(confirmed.resolution.status, .resolved)
    }

    func testNewAssessmentInvalidatesOldConfirmationContext()
        async throws
    {
        let requester = LocalMedicineAssessmentRequester.demo()
        let oldRequest = makeRequest(
            texts: ["Cold Relief"],
            requestID: clientTestUUID(63)
        )
        let ambiguous = try await requester.assess(request: oldRequest)
        let candidate = try XCTUnwrap(
            ambiguous.resolution.candidates.first
        )

        _ = try await requester.assess(
            request: makeRequest(
                texts: ["Acetaminophen"],
                requestID: clientTestUUID(64)
            )
        )

        do {
            _ = try await requester.confirmMedicine(
                command: MedicineCandidateConfirmationCommand(
                    originalRequestID: oldRequest.requestID,
                    candidateID: candidate.medicine.id
                )
            )
            XCTFail("Expected stale confirmation rejection.")
        } catch let error as LocalMedicineConfirmationError {
            XCTAssertEqual(error, .noPendingAssessment)
        }
    }

    func testOlderConcurrentAssessmentCannotReplaceNewConfirmationContext()
        async throws
    {
        let cache = OutOfOrderMedicineCache()
        let requester = LocalMedicineAssessmentRequester(
            pipeline: MedicinePipeline(
                cache: cache,
                dateProvider: FixedClientClock(date: clientTestDate)
            )
        )
        let firstRequest = makeRequest(
            texts: ["Cold Relief"],
            requestID: clientTestUUID(74)
        )
        let secondRequest = makeRequest(
            texts: ["Cold Relief"],
            requestID: clientTestUUID(75)
        )

        let firstTask = Task {
            try await requester.assess(request: firstRequest)
        }
        await cache.waitUntilFirstLookupIsSuspended()
        let second = try await requester.assess(request: secondRequest)
        await cache.releaseFirstLookup()
        _ = try await firstTask.value

        let candidate = try XCTUnwrap(second.resolution.candidates.first)
        let confirmed = try await requester.confirmMedicine(
            command: MedicineCandidateConfirmationCommand(
                originalRequestID: secondRequest.requestID,
                candidateID: candidate.medicine.id
            )
        )

        XCTAssertEqual(confirmed.requestID, secondRequest.requestID)
        XCTAssertEqual(confirmed.resolution.status, .resolved)
    }

    func testUnsupportedProfileSchemaUsesCanonicalAPIError() async {
        let requester = LocalMedicineAssessmentRequester.demo(
            clock: FixedClientClock(date: clientTestDate)
        )
        let profile = UserHealthProfileDTO(
            id: clientTestUUID(76),
            age: 70,
            allergies: [],
            diagnosedConditions: [],
            currentMedicineIngredientIDs: [],
            bodyMetrics: nil,
            createdAt: clientTestDate,
            updatedAt: clientTestDate,
            schemaVersion: 999
        )

        do {
            _ = try await requester.assess(
                request: makeRequest(
                    texts: ["Acetaminophen"],
                    requestID: clientTestUUID(77),
                    userProfile: profile
                )
            )
            XCTFail("Expected unsupported profile schema rejection.")
        } catch let error as ClientAPIError {
            XCTAssertEqual(error.error.code, .unsupportedProfileSchema)
            XCTAssertEqual(error.error.requestID, clientTestUUID(77))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInvalidMedicationRecordEnumUsesCanonicalAPIError() async {
        let requester = LocalMedicineAssessmentRequester.demo(
            clock: FixedClientClock(date: clientTestDate)
        )
        let record = MedicationRecordDTO(
            id: clientTestUUID(78),
            medicineID: "demo-acetaminophen",
            activeIngredientIDs: ["acetaminophen"],
            recordedAt: clientTestDate,
            eventType: "unsupported-event",
            source: "manual"
        )

        do {
            _ = try await requester.assess(
                request: makeRequest(
                    texts: ["Acetaminophen"],
                    requestID: clientTestUUID(79),
                    recentRecords: [record]
                )
            )
            XCTFail("Expected invalid medication record rejection.")
        } catch let error as ClientAPIError {
            XCTAssertEqual(error.error.code, .invalidMedicationRecord)
            XCTAssertEqual(error.error.requestID, clientTestUUID(79))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUnsupportedAPIVersionUsesCanonicalAPIError() async {
        let requester = LocalMedicineAssessmentRequester.demo(
            clock: FixedClientClock(date: clientTestDate)
        )
        let request = makeRequest(
            texts: ["Acetaminophen"],
            requestID: clientTestUUID(85),
            apiVersion: "unsupported-version"
        )

        do {
            _ = try await requester.assess(request: request)
            XCTFail("Expected unsupported API version rejection.")
        } catch let error as ClientAPIError {
            XCTAssertEqual(error.error.code, .unsupportedAPIVersion)
            XCTAssertEqual(error.error.requestID, request.requestID)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testResponseValidatorRejectsRequestIDMismatch() {
        let request = makeRequest(
            texts: ["Demo Medicine"],
            requestID: clientTestUUID(65)
        )
        let response = makeMedicineResponse(
            requestID: clientTestUUID(66)
        )

        XCTAssertThrowsError(
            try MedicineAssessmentResponseValidator().validate(
                response,
                for: request
            )
        ) { error in
            XCTAssertEqual(
                error as? MedicineAssessmentResponseValidationError,
                .requestIDMismatch
            )
        }
    }

    func testResponseValidatorRejectsAPIVersionMismatch() {
        let requestID = clientTestUUID(87)
        let request = makeRequest(
            texts: ["Demo Medicine"],
            requestID: requestID
        )
        let response = makeMedicineResponse(
            requestID: requestID,
            apiVersion: "unsupported-version"
        )

        assertValidationError(
            .apiVersionMismatch,
            response: response,
            request: request
        )
    }

    func testResponseValidatorRejectsMissingSourceDataVersion() {
        let requestID = clientTestUUID(88)
        let request = makeRequest(
            texts: ["Demo Medicine"],
            requestID: requestID
        )
        let response = makeMedicineResponse(
            requestID: requestID,
            sourceDataVersion: "  "
        )

        assertValidationError(
            .missingSourceDataVersion,
            response: response,
            request: request
        )
    }

    func testResponseValidatorRejectsGeneratedAtMismatch() {
        let requestID = clientTestUUID(89)
        let request = makeRequest(
            texts: ["Demo Medicine"],
            requestID: requestID
        )
        let response = makeMedicineResponse(
            requestID: requestID,
            cardGeneratedAt: clientTestDate.addingTimeInterval(1)
        )

        assertValidationError(
            .generatedAtMismatch,
            response: response,
            request: request
        )
    }

    func testResponseValidatorRejectsDuplicateCandidateID() {
        let requestID = clientTestUUID(90)
        let request = makeRequest(
            texts: ["Demo Medicine"],
            requestID: requestID
        )
        let response = makeMedicineResponse(
            requestID: requestID,
            duplicateCandidate: true
        )

        assertValidationError(
            .duplicateCandidateID,
            response: response,
            request: request
        )
    }

    func testResponseValidatorRejectsConfirmationMismatch() {
        let requestID = clientTestUUID(67)
        let request = makeRequest(
            texts: ["Demo Medicine"],
            requestID: requestID
        )
        let response = makeMedicineResponse(
            requestID: requestID,
            requiresConfirmation: true,
            cardRequiresConfirmation: false
        )

        XCTAssertThrowsError(
            try MedicineAssessmentResponseValidator().validate(
                response,
                for: request
            )
        ) { error in
            XCTAssertEqual(
                error as? MedicineAssessmentResponseValidationError,
                .confirmationMismatch
            )
        }
    }

    func testResponseValidatorRejectsResolvedResponseWithoutAssessment() {
        let requestID = clientTestUUID(68)
        let request = makeRequest(
            texts: ["Demo Medicine"],
            requestID: requestID
        )
        let response = makeMedicineResponse(
            requestID: requestID,
            includeAssessment: false
        )

        XCTAssertThrowsError(
            try MedicineAssessmentResponseValidator().validate(
                response,
                for: request
            )
        ) { error in
            XCTAssertEqual(
                error as? MedicineAssessmentResponseValidationError,
                .assessmentMismatch
            )
        }
    }

    func testResponseValidatorAcceptsConservativeRiskElevation() {
        let requestID = clientTestUUID(80)
        let request = makeRequest(
            texts: ["Demo Medicine"],
            requestID: requestID
        )
        let response = makeMedicineResponse(
            requestID: requestID,
            riskLevel: .yellow,
            assessmentRiskLevel: .green
        )

        XCTAssertNoThrow(
            try MedicineAssessmentResponseValidator().validate(
                response,
                for: request
            )
        )
    }

    func testResponseValidatorRejectsRiskBelowAssessment() {
        let requestID = clientTestUUID(91)
        let request = makeRequest(
            texts: ["Demo Medicine"],
            requestID: requestID
        )
        let response = makeMedicineResponse(
            requestID: requestID,
            riskLevel: .yellow,
            assessmentRiskLevel: .red
        )

        assertValidationError(
            .assessmentMismatch,
            response: response,
            request: request
        )
    }

    func testResponseValidatorRejectsSelectedMedicinePayloadMismatch() {
        let requestID = clientTestUUID(81)
        let request = makeRequest(
            texts: ["Demo Medicine"],
            requestID: requestID
        )
        let response = makeMedicineResponse(
            requestID: requestID,
            selectedMedicineName: "Altered Medicine"
        )

        XCTAssertThrowsError(
            try MedicineAssessmentResponseValidator().validate(
                response,
                for: request
            )
        ) { error in
            XCTAssertEqual(
                error as? MedicineAssessmentResponseValidationError,
                .invalidResolution
            )
        }
    }

    func testResponseValidatorRejectsRecognizedTextsMismatch() {
        let requestID = clientTestUUID(100)
        let request = makeRequest(
            texts: ["Demo Medicine", "Second Line"],
            requestID: requestID
        )

        // Different text, dropped text, and reordered text must all fail: the
        // comparison is item by item and order sensitive.
        for texts in [
            ["Stale Medicine"],
            [],
            ["Demo Medicine"],
            ["Second Line", "Demo Medicine"],
        ] {
            assertValidationError(
                .recognitionEvidenceMismatch,
                response: makeResponseWithEvidence(
                    requestID: requestID,
                    recognizedTexts: texts
                ),
                request: request
            )
        }
    }

    func testResponseValidatorRejectsLanguageCodeMismatch() {
        let requestID = clientTestUUID(101)
        let request = makeRequest(
            texts: ["Demo Medicine"],
            requestID: requestID
        )

        for languageCode: String? in ["zh", nil] {
            assertValidationError(
                .recognitionEvidenceMismatch,
                response: makeResponseWithEvidence(
                    requestID: requestID,
                    languageCode: languageCode
                ),
                request: request
            )
        }
    }

    func testResponseValidatorRejectsRawConfidenceMismatch() {
        let requestID = clientTestUUID(102)
        let request = makeRequest(
            texts: ["Demo Medicine"],
            requestID: requestID
        )

        for confidence: Double? in [0.5, nil, 0.95 + 1e-6] {
            assertValidationError(
                .recognitionEvidenceMismatch,
                response: makeResponseWithEvidence(
                    requestID: requestID,
                    rawConfidence: confidence
                ),
                request: request
            )
        }
    }

    func testResponseValidatorRejectsNonFiniteRawConfidence() {
        let requestID = clientTestUUID(103)

        // The inner loop also pairs a non-finite value with itself: an
        // infinity that survived a naive equality check would otherwise be
        // read as matching evidence.
        for confidence in [Double.nan, .infinity, -.infinity, .signalingNaN] {
            for requestConfidence: Double? in [0.95, confidence] {
                assertValidationError(
                    .recognitionEvidenceMismatch,
                    response: makeResponseWithEvidence(
                        requestID: requestID,
                        rawConfidence: confidence
                    ),
                    request: makeRequest(
                        texts: ["Demo Medicine"],
                        requestID: requestID,
                        rawConfidence: requestConfidence
                    )
                )
            }
        }
    }

    func testResponseValidatorAcceptsMatchingRecognitionEvidence() {
        let requestID = clientTestUUID(104)
        let validator = MedicineAssessmentResponseValidator()
        // Exact evidence, drift inside the tolerance, and a matching absent
        // confidence must all pass: the guard must not require bitwise
        // identical doubles, and absent evidence is not by itself suspicious.
        let accepted: [(String?, Double?, Double?)] = [
            ("en", 0.95, 0.95),
            ("en", 0.95 + 1e-13, 0.95),
            (nil, nil, nil),
        ]

        for (languageCode, evidenceConfidence, requestConfidence) in accepted {
            XCTAssertNoThrow(
                try validator.validate(
                    makeResponseWithEvidence(
                        requestID: requestID,
                        languageCode: languageCode,
                        rawConfidence: evidenceConfidence
                    ),
                    for: makeRequest(
                        texts: ["Demo Medicine"],
                        requestID: requestID,
                        languageCode: languageCode,
                        rawConfidence: requestConfidence
                    )
                )
            )
        }
    }

    func testInFlightConfirmationIsCancelledWhenNewAssessmentStarts()
        async throws
    {
        let barrier = ConfirmationSuspensionBarrier()
        let requester = LocalMedicineAssessmentRequester(
            pipeline: MedicinePipeline(
                dateProvider: FixedClientClock(date: clientTestDate)
            ),
            confirmationBarrier: barrier
        )
        let oldRequest = makeRequest(
            texts: ["Cold Relief"],
            requestID: clientTestUUID(108)
        )
        let ambiguous = try await requester.assess(request: oldRequest)
        XCTAssertEqual(ambiguous.resolution.status, .ambiguous)
        let oldCandidate = try XCTUnwrap(
            ambiguous.resolution.candidates.first
        )

        let confirmationTask = Task {
            try await requester.confirmMedicine(
                command: MedicineCandidateConfirmationCommand(
                    originalRequestID: oldRequest.requestID,
                    candidateID: oldCandidate.medicine.id
                )
            )
        }
        await barrier.waitUntilConfirmationIsSuspended()

        // The new scan reuses the identifier so that only the generation
        // counter can distinguish it: matching identifiers must not be enough.
        let newRequest = makeRequest(
            texts: ["Cold Relief"],
            requestID: oldRequest.requestID
        )
        let newResponse = try await requester.assess(request: newRequest)
        await barrier.releaseConfirmation()

        do {
            _ = try await confirmationTask.value
            XCTFail("Expected the stale confirmation to be cancelled.")
        } catch is CancellationError {
            // Expected: a superseded confirmation must not return a response.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(newResponse.resolution.status, .ambiguous)
        let newCandidate = try XCTUnwrap(
            newResponse.resolution.candidates.first
        )
        let confirmed = try await requester.confirmMedicine(
            command: MedicineCandidateConfirmationCommand(
                originalRequestID: newRequest.requestID,
                candidateID: newCandidate.medicine.id
            )
        )
        XCTAssertEqual(confirmed.requestID, newRequest.requestID)
        XCTAssertEqual(confirmed.resolution.status, .resolved)
        XCTAssertEqual(
            confirmed.resolution.selectedMedicine?.id,
            newCandidate.medicine.id
        )
    }

    func testSecondConcurrentConfirmationConsumesPendingContextAndCancelsFirst()
        async throws
    {
        let barrier = ConfirmationSuspensionBarrier()
        let requester = LocalMedicineAssessmentRequester(
            pipeline: MedicinePipeline(
                dateProvider: FixedClientClock(date: clientTestDate)
            ),
            confirmationBarrier: barrier
        )
        let request = makeRequest(
            texts: ["Cold Relief"],
            requestID: clientTestUUID(110)
        )
        let ambiguous = try await requester.assess(request: request)
        XCTAssertEqual(ambiguous.resolution.status, .ambiguous)
        let candidate = try XCTUnwrap(ambiguous.resolution.candidates.first)
        let command = MedicineCandidateConfirmationCommand(
            originalRequestID: request.requestID,
            candidateID: candidate.medicine.id
        )

        let firstConfirmation = Task {
            try await requester.confirmMedicine(command: command)
        }
        await barrier.waitUntilConfirmationIsSuspended()

        // No further assessment starts, so the generation counter cannot tell
        // the two confirmations apart and only the consumed pending context
        // can. The barrier holds the first confirmation alone, so the second
        // reaches the pipeline while the first is still in flight.
        let confirmed = try await requester.confirmMedicine(command: command)
        XCTAssertEqual(confirmed.resolution.status, .resolved)
        XCTAssertEqual(
            confirmed.resolution.selectedMedicine?.id,
            candidate.medicine.id
        )

        await barrier.releaseConfirmation()

        do {
            _ = try await firstConfirmation.value
            XCTFail("Expected the superseded confirmation to be cancelled.")
        } catch is CancellationError {
            // Expected: the context was already consumed by the second call.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeRequest(
        texts: [String],
        requestID: UUID,
        userProfile: UserHealthProfileDTO = makeClientProfile(),
        recentRecords: [MedicationRecordDTO] = [],
        apiVersion: String = SlowWalkAPI.version,
        languageCode: String? = "en",
        rawConfidence: Double? = 0.95
    ) -> MedicineAssessmentRequestDTO {
        MedicineAssessmentRequestDTO(
            input: MedicineRecognitionInput(
                recognizedTexts: texts,
                capturedAt: clientTestDate,
                languageCode: languageCode,
                rawConfidence: rawConfidence
            ),
            userProfile: userProfile,
            recentRecords: recentRecords,
            requestID: requestID,
            apiVersion: apiVersion
        )
    }

    /// Rebuilds the canonical fixture with altered recognition evidence.
    ///
    /// Only the evidence changes, so a rejection can only come from the
    /// evidence binding rather than from an unrelated structural check.
    private func makeResponseWithEvidence(
        requestID: UUID,
        recognizedTexts: [String] = ["Demo Medicine"],
        languageCode: String? = "en",
        rawConfidence: Double? = 0.95
    ) -> MedicineAssessmentResponseDTO {
        let base = makeMedicineResponse(requestID: requestID)
        let evidence = base.resolution.evidence
        let resolution = MedicineResolution(
            status: base.resolution.status,
            candidates: base.resolution.candidates,
            selectedMedicine: base.resolution.selectedMedicine,
            evidence: MedicineResolutionEvidence(
                recognizedTexts: recognizedTexts,
                normalizedText: evidence.normalizedText,
                normalizedQuery: evidence.normalizedQuery,
                languageCode: languageCode,
                rawConfidence: rawConfidence,
                dosageForms: evidence.dosageForms,
                removedSpecifications: evidence.removedSpecifications,
                discardedNoise: evidence.discardedNoise,
                matcherVersion: evidence.matcherVersion,
                sourceDataVersions: evidence.sourceDataVersions
            ),
            requiresUserConfirmation:
                base.resolution.requiresUserConfirmation
        )
        return MedicineAssessmentResponseDTO(
            requestID: base.requestID,
            resolution: resolution,
            assessment: base.assessment,
            actionCard: base.actionCard,
            cacheHit: base.cacheHit,
            resolutionCacheStatus: base.resolutionCacheStatus,
            knowledgeCacheStatus: base.knowledgeCacheStatus,
            sourceDataVersion: base.sourceDataVersion,
            generatedAt: base.generatedAt,
            apiVersion: base.apiVersion,
            healthContextValidation: base.healthContextValidation,
            medicineKnowledge: base.medicineKnowledge
        )
    }

    private func makeCompleteProfile(
        allergies: [String] = []
    ) -> UserHealthProfileDTO {
        UserHealthProfileDTO(
            id: clientTestUUID(86),
            age: 70,
            allergies: allergies,
            diagnosedConditions: [],
            currentMedicineIngredientIDs: [],
            bodyMetrics: BodyMetricsDTO(
                systolicBloodPressure: 120,
                diastolicBloodPressure: 75,
                heartRate: 68,
                measuredAt: clientTestDate.addingTimeInterval(-60),
                source: "demo_data",
                deviceIdentifier: nil
            ),
            createdAt: clientTestDate.addingTimeInterval(-60),
            updatedAt: clientTestDate.addingTimeInterval(-60),
            schemaVersion: UserHealthProfile.currentSchemaVersion
        )
    }

    private func demoMedicines(named name: String) throws -> [Medicine] {
        try BundledDemoMedicineCatalogLoader().loadCatalog().medicines.filter {
            $0.canonicalName == name
        }
    }

    private func demoMedicines(alias: String) throws -> [Medicine] {
        try BundledDemoMedicineCatalogLoader().loadCatalog().medicines.filter {
            $0.aliases.contains(alias)
        }
    }

    private func makeKnowledgeResult(
        normalizedQuery: String,
        medicines: [Medicine],
        conservative: Bool
    ) -> MedicineKnowledgeSearchResult {
        let warnings = conservative
            ? [
                MedicineKnowledgeWarning(
                    code: .authoritativeSourceMissing,
                    message: "Injected knowledge requires source review.",
                    sourceIdentifiers: ["injected-test-source"]
                ),
            ]
            : []
        let candidates = medicines.map {
            MedicineKnowledgeCandidate(
                medicine: $0,
                completeness: conservative ? 0.5 : 1,
                validationStatus: conservative ? .warning : .valid,
                sourceIdentifiers: ["injected-test-source"],
                conflicts: [],
                warnings: warnings,
                requiresConfirmation: conservative
            )
        }
        return MedicineKnowledgeSearchResult(
            normalizedQuery: normalizedQuery,
            candidates: candidates,
            sourceStatus: conservative ? .partial : .authoritative,
            cacheStatus: .miss,
            completeness: conservative ? 0.5 : 1,
            sourceReferences: medicines.flatMap(\.sourceReferences),
            warnings: warnings,
            sourceVersions: ["injected-test-source": "demo-v1"],
            generatedAt: clientTestDate,
            isOffline: false
        )
    }

    private func assertValidationError(
        _ expected: MedicineAssessmentResponseValidationError,
        response: MedicineAssessmentResponseDTO,
        request: MedicineAssessmentRequestDTO,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try MedicineAssessmentResponseValidator().validate(
                response,
                for: request
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? MedicineAssessmentResponseValidationError,
                expected,
                file: file,
                line: line
            )
        }
    }
}

actor ClientKnowledgeSearcherStub: MedicineKnowledgeSearching {
    private var results: [
        Result<MedicineKnowledgeSearchResult, MedicineKnowledgeError>
    ]

    init(
        results: [
            Result<MedicineKnowledgeSearchResult, MedicineKnowledgeError>
        ]
    ) {
        self.results = results
    }

    func search(
        query: MedicineKnowledgeQuery
    ) async throws -> MedicineKnowledgeSearchResult {
        guard !results.isEmpty else {
            throw MedicineKnowledgeError.knowledgeSourceUnavailable(
                sourceIdentifier: "injected-test-source"
            )
        }
        return try results.removeFirst().get()
    }
}

/// Holds the first confirmation at a known point until the test releases it.
///
/// This makes the stale-confirmation guard observable without guessing the
/// scheduler: the test only proceeds once the confirmation is truly suspended.
private actor ConfirmationSuspensionBarrier: LocalConfirmationBarrier {
    private var confirmationCount = 0
    private var confirmationContinuation: CheckedContinuation<Void, Never>?
    private var suspensionWaiters = [CheckedContinuation<Void, Never>]()

    func waitBeforeConfirmation() async {
        confirmationCount += 1
        guard confirmationCount == 1 else { return }
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            confirmationContinuation = continuation
        }
    }

    func waitUntilConfirmationIsSuspended() async {
        guard confirmationCount == 0 else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func releaseConfirmation() {
        confirmationContinuation?.resume()
        confirmationContinuation = nil
    }
}

private actor OutOfOrderMedicineCache: MedicineCache {
    private var lookupCount = 0
    private var firstLookupContinuation: CheckedContinuation<Void, Never>?
    private var firstLookupWaiters = [CheckedContinuation<Void, Never>]()

    func cachedMedicine(id: String) async throws -> Medicine? {
        nil
    }

    func store(_ medicine: Medicine) async throws {}

    func removeMedicine(id: String) async throws {}

    func removeAll() async throws {}

    func cachedResolution(
        normalizedQuery: String,
        sourceDataVersion: String,
        now: Date
    ) async throws -> MedicineResolutionCacheLookup {
        lookupCount += 1
        if lookupCount == 1 {
            let waiters = firstLookupWaiters
            firstLookupWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                firstLookupContinuation = continuation
            }
        }
        return MedicineResolutionCacheLookup(status: .miss)
    }

    func storeResolution(
        _ resolution: MedicineResolution,
        normalizedQuery: String,
        sourceDataVersion: String,
        now: Date
    ) async throws {}

    func waitUntilFirstLookupIsSuspended() async {
        guard lookupCount == 0 else { return }
        await withCheckedContinuation { continuation in
            firstLookupWaiters.append(continuation)
        }
    }

    func releaseFirstLookup() {
        firstLookupContinuation?.resume()
        firstLookupContinuation = nil
    }
}
