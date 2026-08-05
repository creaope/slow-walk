import Foundation
import SlowWalkAPIContracts
import SlowWalkClientCore
import SlowWalkDomain
import SlowWalkMedicinePipeline
import XCTest

final class MedicineAssessmentCoordinatorRoutingTests: XCTestCase {
    func testMatchingRemoteExpectationReachesExistingPresentation()
        async throws
    {
        let requestID = clientTestUUID(131)
        let response = makeMedicineResponse(requestID: requestID)
        let coordinator = makeRoutingCoordinator(
            outcome: remoteOutcome(),
            requester: CapturingMedicineRequester(response: response)
        )

        let state = await runRoutingAssessment(
            coordinator,
            requestID: requestID
        )

        guard case .result(let presentation) = state else {
            return XCTFail("Expected canonical pipeline result.")
        }
        XCTAssertEqual(presentation.response, response)
        XCTAssertEqual(presentation.recognitionContext, .remote)
    }

    func testActualRemoteFirstFallbackContextReachesPresentation()
        async throws
    {
        let requestID = clientTestUUID(142)
        let requester = CapturingMedicineRequester(
            response: makeMedicineResponse(requestID: requestID)
        )
        let coordinator = MedicineAssessmentCoordinator(
            recognitionRouter: RemoteFirstMedicineRecognitionRouter(
                remoteRequester: RecoverableFailureOnlineRequester(
                    failure: .timeout
                ),
                localRecognizer: MockMedicineTextRecognizer(
                    behavior: .observations([makeObservation()])
                ),
                localMapper: try makeRecognitionMapper()
            ),
            requester: requester,
            clock: FixedClientClock(date: clientTestDate),
            apiVersion: SlowWalkAPI.version
        )

        let state = await runRoutingAssessment(
            coordinator,
            requestID: requestID
        )

        guard case .result(let presentation) = state else {
            return XCTFail("Expected local fallback pipeline result.")
        }
        XCTAssertEqual(
            presentation.recognitionContext.source,
            .localFallback
        )
        XCTAssertEqual(
            presentation.recognitionContext.fallbackReason,
            .timeout
        )
        let recordedRequest = await requester.request
        let capturedRequest = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(
            capturedRequest.input.recognizedTexts,
            ["Demo Medicine"]
        )
    }

    func testRemoteExpectedIDConflictDiscardsResponseAndActionCard()
        async throws
    {
        let requestID = clientTestUUID(132)
        let coordinator = makeRoutingCoordinator(
            outcome: remoteOutcome(expectedID: "different-medicine"),
            requester: CapturingMedicineRequester(
                response: makeMedicineResponse(requestID: requestID)
            )
        )

        let state = await runRoutingAssessment(
            coordinator,
            requestID: requestID
        )

        assertDiscardedRemoteResponse(state)
    }

    func testRemoteExpectedIdentityWithMissingSelectionDiscardsResponse()
        async throws
    {
        let requestID = clientTestUUID(133)
        let coordinator = makeRoutingCoordinator(
            outcome: remoteOutcome(),
            requester: CapturingMedicineRequester(
                response: makeMedicineResponse(
                    requestID: requestID,
                    status: .ambiguous,
                    requiresConfirmation: true
                )
            )
        )

        let state = await runRoutingAssessment(
            coordinator,
            requestID: requestID
        )

        assertDiscardedRemoteResponse(state)
    }

    func testRemoteExpectedNameConflictDiscardsResponseAndActionCard()
        async throws
    {
        let requestID = clientTestUUID(134)
        let coordinator = makeRoutingCoordinator(
            outcome: remoteOutcome(expectedName: "Different Name"),
            requester: CapturingMedicineRequester(
                response: makeMedicineResponse(requestID: requestID)
            )
        )

        let state = await runRoutingAssessment(
            coordinator,
            requestID: requestID
        )

        assertDiscardedRemoteResponse(state)
    }

    func testRecognitionContextSurvivesCandidateConfirmation()
        async throws
    {
        let context = MedicineRecognitionContext(
            source: .localFallback,
            fallbackReason: .timeout
        )
        let requester = LocalMedicineAssessmentRequester.demo()
        let coordinator = MedicineAssessmentCoordinator(
            recognitionRouter: FixedMedicineRecognitionRouter(
                behavior: .outcome(
                    MedicineRecognitionRoutingOutcome(
                        recognitionInput: MedicineRecognitionInput(
                            recognizedTexts: ["Cold Relief"],
                            capturedAt: makeOCRImageInput().capturedAt,
                            languageCode: "en",
                            rawConfidence: 0.95
                        ),
                        recognitionContext: context
                    )
                )
            ),
            requester: requester,
            confirmer: requester,
            clock: FixedClientClock(date: clientTestDate),
            apiVersion: SlowWalkAPI.version
        )

        let first = await runRoutingAssessment(
            coordinator,
            requestID: clientTestUUID(135)
        )
        guard case .requiresMedicineConfirmation(let requirement) = first,
              let candidateID = requirement.response?
                .resolution.candidates.first?.medicine.id
        else {
            return XCTFail("Expected an ambiguous local candidate.")
        }
        XCTAssertEqual(requirement.recognitionContext, context)

        let confirmed = await coordinator.confirmMedicine(
            candidateID: candidateID
        )

        guard case .result(let presentation) = confirmed else {
            return XCTFail("Expected confirmed result.")
        }
        XCTAssertEqual(presentation.recognitionContext, context)
    }

    func testConfirmationResponseCannotSelectDifferentCandidate()
        async throws
    {
        let requester = LocalMedicineAssessmentRequester.demo()
        let coordinator = MedicineAssessmentCoordinator(
            recognitionRouter: FixedMedicineRecognitionRouter(
                behavior: .outcome(
                    MedicineRecognitionRoutingOutcome(
                        recognitionInput: MedicineRecognitionInput(
                            recognizedTexts: ["Cold Relief"],
                            capturedAt: makeOCRImageInput().capturedAt,
                            languageCode: "en",
                            rawConfidence: 0.95
                        ),
                        recognitionContext: .onDeviceOnly
                    )
                )
            ),
            requester: requester,
            confirmer: DifferentCandidateMedicineConfirmer(
                requester: requester
            ),
            clock: FixedClientClock(date: clientTestDate),
            apiVersion: SlowWalkAPI.version
        )
        let first = await runRoutingAssessment(
            coordinator,
            requestID: clientTestUUID(141)
        )
        guard case .requiresMedicineConfirmation(let requirement) = first,
              let candidateID = requirement.response?
                .resolution.candidates.first?.medicine.id
        else {
            return XCTFail("Expected offered candidates.")
        }

        let confirmed = await coordinator.confirmMedicine(
            candidateID: candidateID
        )

        guard case .failed(let failure) = confirmed else {
            return XCTFail("Expected mismatched confirmation to fail.")
        }
        XCTAssertEqual(failure.kind, .malformedResponse)
        XCTAssertFalse(failure.isRecoverable)
    }

    func testRemoteSemanticFailuresDoNotEnterAssessmentPipeline()
        async throws
    {
        let cases: [(
            OnlineMedicineRecognitionFailure,
            MedicineConfirmationReason
        )] = [
            (.ambiguous, .ambiguousMedicine),
            (.noCandidate, .unresolvedMedicine),
            (.unreadable, .noRecognizedText),
        ]

        for (failure, expectedReason) in cases {
            let requester = CapturingMedicineRequester(
                response: makeMedicineResponse(requestID: clientTestUUID(136))
            )
            let coordinator = MedicineAssessmentCoordinator(
                recognitionRouter: FixedMedicineRecognitionRouter(
                    behavior: .failure(failure)
                ),
                requester: requester,
                clock: FixedClientClock(date: clientTestDate),
                apiVersion: SlowWalkAPI.version
            )

            let state = await runRoutingAssessment(
                coordinator,
                requestID: clientTestUUID(136)
            )

            guard case .requiresMedicineConfirmation(let requirement) = state
            else {
                XCTFail("Expected semantic confirmation state.")
                continue
            }
            XCTAssertEqual(requirement.reason, expectedReason)
            XCTAssertTrue(requirement.recognitionInput.recognizedTexts.isEmpty)
            XCTAssertNil(requirement.response)
            XCTAssertEqual(requirement.recognitionContext, .remote)
            let capturedRequest = await requester.request
            XCTAssertNil(capturedRequest)
        }
    }

    func testRemoteProtocolFailureUsesExistingFailedState()
        async throws
    {
        let coordinator = MedicineAssessmentCoordinator(
            recognitionRouter: FixedMedicineRecognitionRouter(
                behavior: .failure(.invalidResponse)
            ),
            requester: CapturingMedicineRequester(
                response: makeMedicineResponse(requestID: clientTestUUID(137))
            ),
            clock: FixedClientClock(date: clientTestDate),
            apiVersion: SlowWalkAPI.version
        )

        let state = await runRoutingAssessment(
            coordinator,
            requestID: clientTestUUID(137)
        )

        guard case .failed(let failure) = state else {
            return XCTFail("Expected failed state.")
        }
        XCTAssertEqual(failure.kind, .malformedResponse)
        XCTAssertEqual(failure.endpoint, .medicineRecognize)
        XCTAssertFalse(failure.isRecoverable)
    }

    func testRecognitionRouterCancellationBecomesCancelledState()
        async throws
    {
        let coordinator = MedicineAssessmentCoordinator(
            recognitionRouter: FixedMedicineRecognitionRouter(
                behavior: .cancellation
            ),
            requester: CapturingMedicineRequester(
                response: makeMedicineResponse(requestID: clientTestUUID(138))
            ),
            clock: FixedClientClock(date: clientTestDate),
            apiVersion: SlowWalkAPI.version
        )

        let state = await runRoutingAssessment(
            coordinator,
            requestID: clientTestUUID(138)
        )

        XCTAssertEqual(state, .cancelled)
    }

    func testLateRecognitionCannotOverwriteReplacementAssessment()
        async throws
    {
        let router = OutOfOrderMedicineRecognitionRouter()
        let requester = RequestBoundMedicineRequester()
        let coordinator = MedicineAssessmentCoordinator(
            recognitionRouter: router,
            requester: requester,
            clock: FixedClientClock(date: clientTestDate),
            apiVersion: SlowWalkAPI.version
        )
        let firstRequestID = clientTestUUID(139)
        let currentRequestID = clientTestUUID(140)
        let firstTask = Task {
            await coordinator.assess(
                imageInput: makeOCRImageInput(),
                userProfile: makeClientProfile(),
                recentRecords: [],
                requestID: firstRequestID,
                mode: .remotePreferred
            )
        }

        await router.waitUntilFirstRequestIsSuspended()
        let current = await runRoutingAssessment(
            coordinator,
            requestID: currentRequestID
        )
        await router.releaseFirstRequest()
        let replaced = await firstTask.value
        let finalState = await coordinator.state

        XCTAssertEqual(replaced, .cancelled)
        guard case .result(let presentation) = current else {
            return XCTFail("Expected replacement result.")
        }
        XCTAssertEqual(presentation.response.requestID, currentRequestID)
        XCTAssertEqual(finalState, current)
    }

    private func makeRoutingCoordinator(
        outcome: MedicineRecognitionRoutingOutcome,
        requester: any MedicineAssessmentRequesting
    ) -> MedicineAssessmentCoordinator {
        MedicineAssessmentCoordinator(
            recognitionRouter: FixedMedicineRecognitionRouter(
                behavior: .outcome(outcome)
            ),
            requester: requester,
            clock: FixedClientClock(date: clientTestDate),
            apiVersion: SlowWalkAPI.version
        )
    }

    private func remoteOutcome(
        expectedID: String = "demo-medicine",
        expectedName: String = "Demo Medicine"
    ) -> MedicineRecognitionRoutingOutcome {
        MedicineRecognitionRoutingOutcome(
            recognitionInput: MedicineRecognitionInput(
                recognizedTexts: ["Demo Medicine"],
                capturedAt: makeOCRImageInput().capturedAt,
                languageCode: "en",
                rawConfidence: 0.95
            ),
            recognitionContext: .remote,
            expectedCanonicalMedicineID: expectedID,
            expectedCanonicalMedicineName: expectedName
        )
    }

    private func runRoutingAssessment(
        _ coordinator: MedicineAssessmentCoordinator,
        requestID: UUID
    ) async -> MedicineAssessmentViewState {
        await coordinator.assess(
            imageInput: makeOCRImageInput(),
            userProfile: makeClientProfile(),
            recentRecords: [],
            requestID: requestID,
            mode: .remotePreferred
        )
    }

    private func assertDiscardedRemoteResponse(
        _ state: MedicineAssessmentViewState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .requiresMedicineConfirmation(let requirement) = state else {
            return XCTFail(
                "Expected unresolved confirmation state.",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(
            requirement.reason,
            .unresolvedMedicine,
            file: file,
            line: line
        )
        XCTAssertNil(requirement.response, file: file, line: line)
        XCTAssertEqual(
            requirement.recognitionContext,
            .remote,
            file: file,
            line: line
        )
    }
}

private enum FixedMedicineRecognitionBehavior: Sendable {
    case outcome(MedicineRecognitionRoutingOutcome)
    case failure(OnlineMedicineRecognitionFailure)
    case cancellation
}

private struct FixedMedicineRecognitionRouter: MedicineRecognitionRouting {
    let behavior: FixedMedicineRecognitionBehavior

    func recognize(
        imageInput: OCRImageInput,
        requestID: UUID,
        mode: MedicineRecognitionMode
    ) async throws -> MedicineRecognitionRoutingOutcome {
        switch behavior {
        case .outcome(let outcome):
            return outcome
        case .failure(let failure):
            throw failure
        case .cancellation:
            throw CancellationError()
        }
    }
}

private actor OutOfOrderMedicineRecognitionRouter:
    MedicineRecognitionRouting
{
    private var requestCount = 0
    private var firstRequestContinuation:
        CheckedContinuation<Void, Never>?
    private var suspensionWaiters:
        [CheckedContinuation<Void, Never>] = []

    func recognize(
        imageInput: OCRImageInput,
        requestID: UUID,
        mode: MedicineRecognitionMode
    ) async throws -> MedicineRecognitionRoutingOutcome {
        requestCount += 1
        if requestCount == 1 {
            let waiters = suspensionWaiters
            suspensionWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                firstRequestContinuation = continuation
            }
        }
        return MedicineRecognitionRoutingOutcome(
            recognitionInput: MedicineRecognitionInput(
                recognizedTexts: ["Demo Medicine"],
                capturedAt: imageInput.capturedAt,
                languageCode: "en",
                rawConfidence: 0.95
            ),
            recognitionContext: .remote
        )
    }

    func waitUntilFirstRequestIsSuspended() async {
        guard requestCount == 0 else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func releaseFirstRequest() {
        firstRequestContinuation?.resume()
        firstRequestContinuation = nil
    }
}

private struct RequestBoundMedicineRequester:
    MedicineAssessmentRequesting
{
    func assess(
        request: MedicineAssessmentRequestDTO
    ) async throws -> MedicineAssessmentResponseDTO {
        makeMedicineResponse(requestID: request.requestID)
    }
}

private struct DifferentCandidateMedicineConfirmer:
    MedicineCandidateConfirming
{
    let requester: LocalMedicineAssessmentRequester

    func confirmMedicine(
        command: MedicineCandidateConfirmationCommand
    ) async throws -> MedicineAssessmentResponseDTO {
        let differentCandidateID =
            command.candidateID == "demo-dextromethorphan"
            ? "demo-chlorpheniramine"
            : "demo-dextromethorphan"
        return try await requester.confirmMedicine(
            command: MedicineCandidateConfirmationCommand(
                originalRequestID: command.originalRequestID,
                candidateID: differentCandidateID
            )
        )
    }
}

private struct RecoverableFailureOnlineRequester:
    OnlineMedicineRecognitionRequesting
{
    let failure: OnlineMedicineRecognitionFailure

    func recognize(
        request: OnlineMedicineRecognitionRequest
    ) async throws -> OnlineMedicineRecognitionResult {
        throw failure
    }
}
