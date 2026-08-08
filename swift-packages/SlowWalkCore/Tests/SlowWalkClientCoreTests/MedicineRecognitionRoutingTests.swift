import Foundation
import SlowWalkClientCore
import SlowWalkDomain
import XCTest

final class MedicineRecognitionRoutingTests: XCTestCase {
    func testRecoverableRemoteFailuresUseBoundedLocalFallback()
        async throws
    {
        let cases: [(
            OnlineMedicineRecognitionFailure,
            MedicineRecognitionFallbackReason
        )] = [
            (.offline, .offline),
            (.timeout, .timeout),
            (.rateLimited, .rateLimited),
            (.serverUnavailable, .serverUnavailable),
            (.providerUnavailable, .providerUnavailable),
        ]

        for (failure, expectedReason) in cases {
            let remote = RoutingRemoteSpy(behavior: .failure(failure))
            let local = RoutingTextRecognizerSpy(
                observations: [makeObservation(text: "Local Medicine")]
            )
            let router = RemoteFirstMedicineRecognitionRouter(
                remoteRequester: remote,
                localRecognizer: local,
                localMapper: try makeRecognitionMapper()
            )

            let outcome = try await router.recognize(
                imageInput: makeOCRImageInput(),
                requestID: clientTestUUID(121),
                mode: .remotePreferred
            )

            XCTAssertEqual(outcome.source, .localFallback)
            XCTAssertEqual(outcome.fallbackReason, expectedReason)
            XCTAssertEqual(
                outcome.recognitionInput.recognizedTexts,
                ["Local Medicine"]
            )
            XCTAssertNil(outcome.expectedCanonicalMedicineID)
            XCTAssertNil(outcome.expectedCanonicalMedicineName)
            let remoteCallCount = await remote.callCount
            let localCallCount = await local.callCount
            XCTAssertEqual(remoteCallCount, 1)
            XCTAssertEqual(localCallCount, 1)
        }
    }

    func testSemanticAndProtocolFailuresNeverUseLocalFallback()
        async throws
    {
        let failures: [OnlineMedicineRecognitionFailure] = [
            .ambiguous,
            .noCandidate,
            .unreadable,
            .invalidResponse,
            .invalidImage,
            .imageTooLarge,
        ]

        for failure in failures {
            let remote = RoutingRemoteSpy(behavior: .failure(failure))
            let local = RoutingTextRecognizerSpy(
                observations: [makeObservation(text: "Local Guess")]
            )
            let router = RemoteFirstMedicineRecognitionRouter(
                remoteRequester: remote,
                localRecognizer: local,
                localMapper: try makeRecognitionMapper()
            )

            do {
                _ = try await router.recognize(
                    imageInput: makeOCRImageInput(),
                    requestID: clientTestUUID(122),
                    mode: .remotePreferred
                )
                XCTFail("Expected remote failure \(failure).")
            } catch let received as OnlineMedicineRecognitionFailure {
                XCTAssertEqual(received, failure)
            } catch {
                XCTFail("Unexpected error: \(type(of: error)).")
            }

            let remoteCallCount = await remote.callCount
            let localCallCount = await local.callCount
            XCTAssertEqual(remoteCallCount, 1)
            XCTAssertEqual(localCallCount, 0)
        }
    }

    func testOnDeviceOnlyModeNeverCallsRemoteRequester() async throws {
        let remote = RoutingRemoteSpy(
            behavior: .failure(.invalidResponse)
        )
        let local = RoutingTextRecognizerSpy(
            observations: [makeObservation(text: "Private Local Scan")]
        )
        let router = RemoteFirstMedicineRecognitionRouter(
            remoteRequester: remote,
            localRecognizer: local,
            localMapper: try makeRecognitionMapper()
        )

        let outcome = try await router.recognize(
            imageInput: makeOCRImageInput(),
            requestID: clientTestUUID(123),
            mode: .onDeviceOnly
        )

        XCTAssertEqual(outcome.recognitionContext, .onDeviceOnly)
        let remoteCallCount = await remote.callCount
        let localCallCount = await local.callCount
        XCTAssertEqual(remoteCallCount, 0)
        XCTAssertEqual(localCallCount, 1)
    }

    func testRemoteSuccessCarriesIdentityWitnessWithoutCallingLocal()
        async throws
    {
        let requestID = clientTestUUID(124)
        let recognitionInput = makeRoutingRecognitionInput()
        let remote = RoutingRemoteSpy(
            behavior: .result(
                OnlineMedicineRecognitionResult(
                    requestID: requestID,
                    recognitionInput: recognitionInput,
                    expectedCanonicalMedicineID: "demo-medicine",
                    expectedCanonicalMedicineName: "Demo Medicine"
                )
            )
        )
        let local = RoutingTextRecognizerSpy(observations: [])
        let router = RemoteFirstMedicineRecognitionRouter(
            remoteRequester: remote,
            localRecognizer: local,
            localMapper: try makeRecognitionMapper()
        )

        let outcome = try await router.recognize(
            imageInput: makeOCRImageInput(),
            requestID: requestID,
            mode: .remotePreferred
        )

        XCTAssertEqual(outcome.recognitionInput, recognitionInput)
        XCTAssertEqual(outcome.recognitionContext, .remote)
        XCTAssertEqual(
            outcome.expectedCanonicalMedicineID,
            "demo-medicine"
        )
        XCTAssertEqual(
            outcome.expectedCanonicalMedicineName,
            "Demo Medicine"
        )
        let localCallCount = await local.callCount
        XCTAssertEqual(localCallCount, 0)
    }

    func testMismatchedRemoteRequestIDIsInvalidWithoutFallback()
        async throws
    {
        let expectedRequestID = clientTestUUID(127)
        let remote = RoutingRemoteSpy(
            behavior: .result(
                OnlineMedicineRecognitionResult(
                    requestID: clientTestUUID(128),
                    recognitionInput: makeRoutingRecognitionInput(),
                    expectedCanonicalMedicineID: "demo-medicine",
                    expectedCanonicalMedicineName: "Demo Medicine"
                )
            )
        )
        let local = RoutingTextRecognizerSpy(
            observations: [makeObservation(text: "Local Guess")]
        )
        let router = RemoteFirstMedicineRecognitionRouter(
            remoteRequester: remote,
            localRecognizer: local,
            localMapper: try makeRecognitionMapper()
        )

        do {
            _ = try await router.recognize(
                imageInput: makeOCRImageInput(),
                requestID: expectedRequestID,
                mode: .remotePreferred
            )
            XCTFail("Expected request ID mismatch to fail.")
        } catch let failure as OnlineMedicineRecognitionFailure {
            XCTAssertEqual(failure, .invalidResponse)
        } catch {
            XCTFail("Unexpected error: \(type(of: error)).")
        }
        let localCallCount = await local.callCount
        XCTAssertEqual(localCallCount, 0)
    }

    func testUnknownRemoteErrorIsPropagatedWithoutFallback()
        async throws
    {
        let remote = RoutingRemoteSpy(
            behavior: .unknownFailure(.synthetic)
        )
        let local = RoutingTextRecognizerSpy(
            observations: [makeObservation(text: "Local Guess")]
        )
        let router = RemoteFirstMedicineRecognitionRouter(
            remoteRequester: remote,
            localRecognizer: local,
            localMapper: try makeRecognitionMapper()
        )

        do {
            _ = try await router.recognize(
                imageInput: makeOCRImageInput(),
                requestID: clientTestUUID(129),
                mode: .remotePreferred
            )
            XCTFail("Expected unknown remote error.")
        } catch let error as UnknownRoutingRemoteError {
            XCTAssertEqual(error, .synthetic)
        } catch {
            XCTFail("Unexpected error: \(type(of: error)).")
        }
        let localCallCount = await local.callCount
        XCTAssertEqual(localCallCount, 0)
    }

    func testCancellationDuringRemoteIsPropagatedWithoutFallback()
        async throws
    {
        let remote = BlockingRoutingRemoteRequester()
        let local = RoutingTextRecognizerSpy(
            observations: [makeObservation(text: "Local Guess")]
        )
        let router = RemoteFirstMedicineRecognitionRouter(
            remoteRequester: remote,
            localRecognizer: local,
            localMapper: try makeRecognitionMapper()
        )
        let task = Task {
            try await router.recognize(
                imageInput: makeOCRImageInput(),
                requestID: clientTestUUID(125),
                mode: .remotePreferred
            )
        }

        await remote.waitUntilStarted()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(type(of: error)).")
        }
        let localCallCount = await local.callCount
        XCTAssertEqual(localCallCount, 0)
    }

    func testCancellationDuringLocalFallbackIsPropagated()
        async throws
    {
        let remote = RoutingRemoteSpy(behavior: .failure(.offline))
        let local = BlockingRoutingTextRecognizer()
        let router = RemoteFirstMedicineRecognitionRouter(
            remoteRequester: remote,
            localRecognizer: local,
            localMapper: try makeRecognitionMapper()
        )
        let task = Task {
            try await router.recognize(
                imageInput: makeOCRImageInput(),
                requestID: clientTestUUID(126),
                mode: .remotePreferred
            )
        }

        await local.waitUntilStarted()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(type(of: error)).")
        }
    }
}

private enum RoutingRemoteBehavior: Sendable {
    case result(OnlineMedicineRecognitionResult)
    case failure(OnlineMedicineRecognitionFailure)
    case unknownFailure(UnknownRoutingRemoteError)
}

private enum UnknownRoutingRemoteError: Error, Sendable, Equatable {
    case synthetic
}

private actor RoutingRemoteSpy: OnlineMedicineRecognitionRequesting {
    private let behavior: RoutingRemoteBehavior
    private(set) var callCount = 0

    init(behavior: RoutingRemoteBehavior) {
        self.behavior = behavior
    }

    func recognize(
        request: OnlineMedicineRecognitionRequest
    ) async throws -> OnlineMedicineRecognitionResult {
        callCount += 1
        switch behavior {
        case .result(let result):
            return result
        case .failure(let failure):
            throw failure
        case .unknownFailure(let error):
            throw error
        }
    }
}

private actor RoutingTextRecognizerSpy: MedicineTextRecognizing {
    private let observations: [RecognizedTextObservation]
    private(set) var callCount = 0

    init(observations: [RecognizedTextObservation]) {
        self.observations = observations
    }

    func recognizeText(
        in input: OCRImageInput
    ) async throws -> [RecognizedTextObservation] {
        callCount += 1
        return observations
    }
}

private actor BlockingRoutingRemoteRequester:
    OnlineMedicineRecognitionRequesting
{
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func recognize(
        request: OnlineMedicineRecognitionRequest
    ) async throws -> OnlineMedicineRecognitionResult {
        started = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
        try await Task<Never, Never>.sleep(
            nanoseconds: 60_000_000_000
        )
        throw OnlineMedicineRecognitionFailure.serverUnavailable
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor BlockingRoutingTextRecognizer: MedicineTextRecognizing {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func recognizeText(
        in input: OCRImageInput
    ) async throws -> [RecognizedTextObservation] {
        started = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
        try await Task<Never, Never>.sleep(
            nanoseconds: 60_000_000_000
        )
        return []
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private func makeRoutingRecognitionInput() -> MedicineRecognitionInput {
    MedicineRecognitionInput(
        recognizedTexts: ["Demo Medicine"],
        capturedAt: makeOCRImageInput().capturedAt,
        languageCode: "en",
        rawConfidence: 0.95
    )
}
