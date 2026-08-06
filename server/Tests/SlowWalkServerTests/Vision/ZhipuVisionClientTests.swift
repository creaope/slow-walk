import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import SlowWalkServer
import XCTest

final class ZhipuVisionClientTests: XCTestCase, @unchecked Sendable {
    private let secret = "zhipu-client-KEY-LEAK-CANARY"
    private let imageData = Data("image-BASE64-LEAK-CANARY".utf8)

    func testHTTP200ParsesStrictVisibleTextResultAndUsesExistingRequest() async throws {
        let execution = try await run([
            .response(completion(content: modelContent(
                visibleTexts: ["LOT 42", "2028-01"]
            ))),
        ])

        XCTAssertEqual(execution.result, .success(.fixture))
        XCTAssertEqual(execution.callCount, 1)
        let capturedRequest = await execution.transport.firstRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(
            request.url.absoluteString,
            "https://vision.example.com/v4/chat/completions"
        )
        XCTAssertEqual(
            request.headers[VisionTransportRequest.authorizationHeaderName],
            "Bearer \(secret)"
        )
        let requestBody = String(decoding: request.body, as: UTF8.self)
        XCTAssertTrue(requestBody.contains(imageData.base64EncodedString()))
    }

    func testClientUsesPrimaryModelWithoutExecutingFallback() async throws {
        let execution = try await run(
            [.response(completion(content: modelContent(
                visibleTexts: ["LOT 42", "2028-01"]
            )))],
            primaryModel: "primary-vision-model",
            fallbackModel: "fallback-must-not-be-sent"
        )

        XCTAssertEqual(execution.result, .success(.fixture))
        let capturedRequest = await execution.transport.firstRequest()
        let request = try XCTUnwrap(capturedRequest)
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: request.body)
                as? [String: Any]
        )
        XCTAssertEqual(body["model"] as? String, "primary-vision-model")
        XCTAssertFalse(
            String(decoding: request.body, as: UTF8.self)
                .contains("fallback-must-not-be-sent")
        )
    }

    func testMissingOrEmptyChoicesAndContentAreMalformedProviderResponses() async throws {
        let bodies: [Data] = [
            Data("{}".utf8),
            Data(#"{"choices":[]}"#.utf8),
            completion(content: "").body,
            Data(#"{"choices":[{"message":{}}]}"#.utf8),
        ]
        for body in bodies {
            let execution = try await run([.response(.init(
                statusCode: 200,
                headers: [:],
                body: body
            ))])
            XCTAssertEqual(
                execution.result,
                .failure(.malformedProviderResponse(
                    providerIdentifier: "zhipu"
                ))
            )
        }
    }

    func testNonJSONContentIsInvalidModelPayload() async throws {
        let execution = try await run([
            .response(completion(content: "not JSON")),
        ])
        XCTAssertEqual(
            execution.result,
            .failure(.invalidModelPayload(providerIdentifier: "zhipu"))
        )
    }

    func testMissingRequiredModelFieldIsRejected() async throws {
        let execution = try await run([.response(completion(
            content: #"{"visibleTexts":[],"imageReadable":true}"#
        ))])
        XCTAssertEqual(
            execution.result,
            .failure(.invalidModelPayload(providerIdentifier: "zhipu"))
        )
    }

    func testUnknownMedicalOrActionFieldsAreRejected() async throws {
        for field in ["medicineIdentity", "dose", "riskLevel",
                      "diagnosis", "medicalAdvice", "safeToTake",
                      "actionCard"] {
            let content = #"{"visibleTexts":[],"imageReadable":true,"uncertainRegionsPresent":false,"\#(field)":true}"#
            let execution = try await run([
                .response(completion(content: content)),
            ])
            XCTAssertEqual(
                execution.result,
                .failure(.invalidModelPayload(providerIdentifier: "zhipu")),
                field
            )
        }
    }

    func testWrongFieldTypesAndVisibleTextLimitsAreRejected() async throws {
        let tooMany = Array(
            repeating: "x",
            count: VisionVisibleTextResult.maximumVisibleTextCount + 1
        )
        let tooLong = String(
            repeating: "x",
            count: VisionVisibleTextResult.maximumVisibleTextLength + 1
        )
        let totalTooLong = Array(
            repeating: String(
                repeating: "x",
                count: VisionVisibleTextResult.maximumVisibleTextLength
            ),
            count: 9
        )
        let contents = [
            #"{"visibleTexts":[],"imageReadable":"true","uncertainRegionsPresent":false}"#,
            modelContent(visibleTexts: tooMany),
            modelContent(visibleTexts: [tooLong]),
            modelContent(visibleTexts: totalTooLong),
            modelContent(visibleTexts: ["  \n "]),
        ]
        for content in contents {
            let execution = try await run([
                .response(completion(content: content)),
            ])
            XCTAssertEqual(
                execution.result,
                .failure(.invalidModelPayload(providerIdentifier: "zhipu"))
            )
        }
    }

    func testHTTPStatusErrorsAreMapped() async throws {
        let cases: [(Int, ZhipuVisionClientError)] = [
            (400, .invalidRequest(
                providerIdentifier: "zhipu", statusCode: 400
            )),
            (401, .unauthorized(
                providerIdentifier: "zhipu", statusCode: 401
            )),
            (403, .unauthorized(
                providerIdentifier: "zhipu", statusCode: 403
            )),
            (429, .rateLimited(
                providerIdentifier: "zhipu", statusCode: 429
            )),
            (500, .serverFailure(
                providerIdentifier: "zhipu", statusCode: 500
            )),
        ]
        for (statusCode, expected) in cases {
            let execution = try await run(
                [.response(status(statusCode))],
                maxAttempts: 1
            )
            XCTAssertEqual(execution.result, .failure(expected))
            XCTAssertEqual(execution.callCount, 1)
        }
    }

    func testTimeoutAndOtherTransportFailuresAreDistinct() async throws {
        let timeout = try await run(
            [.urlError(.timedOut)],
            maxAttempts: 1
        )
        XCTAssertEqual(
            timeout.result,
            .failure(.timeout(providerIdentifier: "zhipu"))
        )

        let failure = try await run([.failure], maxAttempts: 3)
        XCTAssertEqual(
            failure.result,
            .failure(.transportFailure(providerIdentifier: "zhipu"))
        )
        XCTAssertEqual(failure.callCount, 1)
    }

    func testDuplicateEntryWaiterIsRejectedWithoutReplacingOriginal() async {
        let gate = TwoPhaseCancellationGate()
        let registered = expectation(description: "entry waiter registered")
        let original = Task {
            try await gate.waitUntilEntered(
                onWaiterRegistered: {
                    registered.fulfill()
                }
            )
        }
        await fulfillment(of: [registered], timeout: 1)
        let originalCounts = await gate.entryRegistrationCounts()
        XCTAssertEqual(originalCounts.waiterInstallations, 1)
        XCTAssertEqual(originalCounts.timeoutTaskInstallations, 1)

        let duplicateResult = await Task { try await gate.waitUntilEntered() }.result
        let countsAfterDuplicate = await gate.entryRegistrationCounts()

        XCTAssertEqual(countsAfterDuplicate.waiterInstallations, 1)
        XCTAssertEqual(countsAfterDuplicate.timeoutTaskInstallations, 1)
        XCTAssertEqual(countsAfterDuplicate, originalCounts)
        guard duplicateResult.failure as? TwoPhaseCancellationGate.GateError
                == .duplicateWaiter else {
            XCTFail("A duplicate entry waiter must fail with duplicateWaiter.")
            await gate.release()
            return
        }

        let arrival = Task { try await gate.arriveAndWaitForRelease() }
        let originalResult = await original.result
        await gate.release()
        let arrivalResult = await arrival.result
        XCTAssertNoThrow(try originalResult.get())
        XCTAssertNoThrow(try arrivalResult.get())
    }

    func testDuplicateReleaseWaiterIsRejectedWithoutReplacingOriginal() async {
        let gate = TwoPhaseCancellationGate()
        let registered = expectation(description: "release waiter registered")
        let original = Task {
            try await gate.arriveAndWaitForRelease(
                onWaiterRegistered: {
                    registered.fulfill()
                }
            )
        }
        await fulfillment(of: [registered], timeout: 1)
        let originalCounts = await gate.releaseRegistrationCounts()
        XCTAssertEqual(originalCounts.waiterInstallations, 1)
        XCTAssertEqual(originalCounts.timeoutTaskInstallations, 1)

        let duplicateResult = await Task {
            try await gate.arriveAndWaitForRelease()
        }.result
        let countsAfterDuplicate = await gate.releaseRegistrationCounts()

        XCTAssertEqual(countsAfterDuplicate.waiterInstallations, 1)
        XCTAssertEqual(countsAfterDuplicate.timeoutTaskInstallations, 1)
        XCTAssertEqual(countsAfterDuplicate, originalCounts)
        guard duplicateResult.failure as? TwoPhaseCancellationGate.GateError
                == .duplicateWaiter else {
            XCTFail("A duplicate release waiter must fail with duplicateWaiter.")
            await gate.release()
            return
        }

        await gate.release()
        let originalResult = await original.result
        XCTAssertNoThrow(try originalResult.get())
    }

    func testDefaultRetryDelayPropagatesCancellation() async throws {
        let gate = TwoPhaseCancellationGate()
        let task = Task {
            try await gate.arriveAndWaitForRelease()
            try await ZhipuVisionClient.defaultRetryDelay(1)
        }
        try await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do {
            try await task.value
            XCTFail("A cancelled retry delay must throw CancellationError.")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
    }

    func testAlreadyCancelledTaskDoesNotStartTransportAttempt() async throws {
        let gate = TwoPhaseCancellationGate()
        let transport = StubVisionTransport(steps: [
            .response(completion(content: modelContent(
                visibleTexts: ["must not be requested"]
            ))),
        ])
        let client = try makeClient(transport: transport, maxAttempts: 3)
        let task = Task {
            try await gate.arriveAndWaitForRelease()
            return try await client.extractVisibleTexts(from: VisionImagePayload(
                data: imageData,
                mimeType: "image/png"
            ))
        }
        try await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("A cancelled task must not start a transport attempt.")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        let callCount = await transport.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testCancellationDuringRetryDelayStopsBeforeNextTransportAttempt() async throws {
        let gate = TwoPhaseCancellationGate()
        let transport = StubVisionTransport(steps: [
            .urlError(.networkConnectionLost),
            .response(completion(content: modelContent(
                visibleTexts: ["must not be requested"]
            ))),
        ])
        let client = try makeClient(
            transport: transport,
            maxAttempts: 3,
            retryDelay: { _ in try await gate.arriveAndWaitForRelease() }
        )
        let task = Task {
            try await client.extractVisibleTexts(from: VisionImagePayload(
                data: imageData,
                mimeType: "image/png"
            ))
        }
        try await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("Cancellation must stop the retry loop.")
        } catch is CancellationError {
            // Expected.
        } catch let error as ZhipuVisionClientError {
            XCTFail("Cancellation was mapped to client error: \(error)")
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        let callCount = await transport.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testTransportCancellationErrorIsPropagatedWithoutRetry() async throws {
        let transport = StubVisionTransport(steps: [
            .cancellation,
            .response(status(200)),
        ])
        let client = try makeClient(transport: transport, maxAttempts: 3)

        do {
            _ = try await client.extractVisibleTexts(from: VisionImagePayload(
                data: imageData,
                mimeType: "image/png"
            ))
            XCTFail("Transport cancellation must be propagated.")
        } catch is CancellationError {
            // Expected.
        } catch let error as ZhipuVisionClientError {
            XCTFail("Cancellation was mapped to client error: \(error)")
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        let callCount = await transport.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testCancelledURLErrorIsCancellationWithoutRetry() async throws {
        let transport = StubVisionTransport(steps: [
            .urlError(.cancelled),
            .response(status(200)),
        ])
        let client = try makeClient(transport: transport, maxAttempts: 3)

        do {
            _ = try await client.extractVisibleTexts(from: VisionImagePayload(
                data: imageData,
                mimeType: "image/png"
            ))
            XCTFail("URLError.cancelled must stop the retry loop.")
        } catch is CancellationError {
            // Expected.
        } catch let error as ZhipuVisionClientError {
            XCTFail("Cancellation was mapped to client error: \(error)")
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        let callCount = await transport.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testNonRetryableHTTP4xxErrorsCallTransportOnce() async throws {
        let cases: [(Int, ZhipuVisionClientError)] = [
            (400, .invalidRequest(
                providerIdentifier: "zhipu", statusCode: 400
            )),
            (401, .unauthorized(
                providerIdentifier: "zhipu", statusCode: 401
            )),
            (403, .unauthorized(
                providerIdentifier: "zhipu", statusCode: 403
            )),
            (404, .invalidRequest(
                providerIdentifier: "zhipu", statusCode: 404
            )),
        ]
        for (statusCode, expectedError) in cases {
            let execution = try await run(
                [.response(status(statusCode)), .response(status(200))],
                maxAttempts: 3
            )
            XCTAssertEqual(execution.result, .failure(expectedError))
            XCTAssertEqual(execution.callCount, 1, "HTTP \(statusCode)")
        }
    }

    func test429ReturnsRateLimitedWithoutRetry() async throws {
        let execution = try await run([
            .response(status(429)),
            .response(completion(content: modelContent(
                visibleTexts: ["must not be requested"]
            ))),
        ], maxAttempts: 3)

        XCTAssertEqual(
            execution.result,
            .failure(.rateLimited(
                providerIdentifier: "zhipu", statusCode: 429
            ))
        )
        XCTAssertEqual(execution.callCount, 1)
        XCTAssertFalse(
            execution.result.failure?.description.contains(
                "provider error body must not escape"
            ) ?? true
        )
    }

    func testAllowed5xxStatusesRetry() async throws {
        for retryableStatus in [500, 502, 503, 504] {
            let execution = try await run([
                .response(status(retryableStatus)),
                .response(completion(content: modelContent(
                    visibleTexts: ["LOT 42", "2028-01"]
                ))),
            ], maxAttempts: 3)
            XCTAssertEqual(execution.result, .success(.fixture))
            XCTAssertEqual(execution.callCount, 2)
        }
    }

    func testTemporaryNetworkFailureRetries() async throws {
        let execution = try await run([
            .urlError(.networkConnectionLost),
            .response(completion(content: modelContent(
                visibleTexts: ["LOT 42", "2028-01"]
            ))),
        ], maxAttempts: 2)
        XCTAssertEqual(execution.result, .success(.fixture))
        XCTAssertEqual(execution.callCount, 2)
    }

    func testTimeoutRetriesUnderExistingPolicy() async throws {
        let execution = try await run([
            .urlError(.timedOut),
            .response(completion(content: modelContent(
                visibleTexts: ["LOT 42", "2028-01"]
            ))),
        ], maxAttempts: 2)
        XCTAssertEqual(execution.result, .success(.fixture))
        XCTAssertEqual(execution.callCount, 2)
    }

    func testRetriesStopAtConfiguredMaximumAttempts() async throws {
        let execution = try await run([
            .response(status(500)),
            .response(status(502)),
            .response(status(504)),
            .response(status(200)),
        ], maxAttempts: 3)
        XCTAssertEqual(
            execution.result,
            .failure(.serverFailure(
                providerIdentifier: "zhipu", statusCode: 504
            ))
        )
        XCTAssertEqual(execution.callCount, 3)
    }

    func testInvalidImageFailsBeforeTransport() async throws {
        let execution = try await run(
            [],
            image: VisionImagePayload(data: Data(), mimeType: "image/png"),
            maxAttempts: 3
        )
        XCTAssertEqual(
            execution.result,
            .failure(.invalidRequest(
                providerIdentifier: "zhipu", statusCode: nil
            ))
        )
        XCTAssertEqual(execution.callCount, 0)
    }

    func testEnvironmentInitializerMapsMissingCredentialWithoutNetwork() async {
        let transport = StubVisionTransport(steps: [])
        XCTAssertThrowsError(try ZhipuVisionClient(
            environment: [
                ZhipuVisionRuntimeConfiguration.apiKeyEnvironmentKey: "  ",
            ],
            transport: transport
        )) { error in
            XCTAssertEqual(error as? ZhipuVisionClientError, .missingCredential)
        }
        let callCount = await transport.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testDescriptionsDebugAndMirrorsDoNotLeakSecretsOrBodies() async throws {
        let responseCanary = "provider-response-BODY-LEAK-CANARY"
        let execution = try await run([
            .response(completion(content: responseCanary)),
        ])
        let error = try XCTUnwrap(execution.result.failure)
        var clientDump = String()
        var errorDump = String()
        dump(execution.client, to: &clientDump)
        dump(error, to: &errorDump)
        let renderings = [
            execution.client.description,
            execution.client.debugDescription,
            String(reflecting: execution.client),
            clientDump,
            error.description,
            error.debugDescription,
            String(reflecting: error),
            (error as NSError).localizedDescription,
            errorDump,
        ]
        for rendering in renderings {
            XCTAssertFalse(rendering.contains(secret), rendering)
            XCTAssertFalse(rendering.lowercased().contains("bearer"), rendering)
            XCTAssertFalse(
                rendering.contains(imageData.base64EncodedString()),
                rendering
            )
            XCTAssertFalse(rendering.contains(responseCanary), rendering)
        }
    }

    func testRedirectDelegateRejectsSameOriginRedirect() {
        assertRedirectRejected(
            targetURL: URL(string: "https://vision.example.com/v4/redirected")!
        )
    }

    func testRedirectDelegateRejectsCrossOriginRedirect() {
        assertRedirectRejected(
            targetURL: URL(string: "https://redirect.example.net/collect")!
        )
    }

    func testRedirectPolicyRenderingDoesNotLeakHeadersOrBody() {
        let headerCanary = "redirect-AUTHORIZATION-LEAK-CANARY"
        let bodyCanary = "redirect-IMAGE-BODY-LEAK-CANARY"
        var proposedRequest = URLRequest(
            url: URL(string: "https://redirect.example.net/collect")!
        )
        proposedRequest.setValue(
            "Bearer \(headerCanary)",
            forHTTPHeaderField: "Authorization"
        )
        proposedRequest.httpBody = Data(bodyCanary.utf8)
        let delegate = VisionHTTPRedirectDelegate()

        XCTAssertNil(delegate.redirectRequest(for: proposedRequest))
        var dumped = String()
        dump(delegate, to: &dumped)
        for rendering in [
            delegate.description,
            delegate.debugDescription,
            String(reflecting: delegate),
            dumped,
            String(describing: VisionHTTPTransportError.nonHTTPResponse),
        ] {
            XCTAssertFalse(rendering.contains(headerCanary), rendering)
            XCTAssertFalse(rendering.contains(bodyCanary), rendering)
            XCTAssertFalse(rendering.lowercased().contains("bearer"), rendering)
        }
    }

    private func run(
        _ steps: [StubVisionTransport.Step],
        image: VisionImagePayload? = nil,
        maxAttempts: Int = 1,
        primaryModel: String = "vision-model",
        fallbackModel: String = "vision-model"
    ) async throws -> Execution {
        let transport = StubVisionTransport(steps: steps)
        let client = try makeClient(
            transport: transport,
            maxAttempts: maxAttempts,
            primaryModel: primaryModel,
            fallbackModel: fallbackModel
        )
        let result: Result<VisionVisibleTextResult, ZhipuVisionClientError>
        do {
            result = .success(try await client.extractVisibleTexts(
                from: image ?? VisionImagePayload(
                    data: imageData,
                    mimeType: "image/png"
                )
            ))
        } catch let error as ZhipuVisionClientError {
            result = .failure(error)
        }
        return Execution(
            result: result,
            callCount: await transport.callCount(),
            client: client,
            transport: transport
        )
    }

    private func makeClient(
        transport: any VisionHTTPTransport,
        maxAttempts: Int,
        primaryModel: String = "vision-model",
        fallbackModel: String = "vision-model",
        retryDelay: @escaping ZhipuVisionClient.RetryDelay = { _ in }
    ) throws -> ZhipuVisionClient {
        let primary = try VisionProviderConfiguration(
            providerIdentifier: "zhipu",
            baseURL: URL(string: "https://vision.example.com/v4")!,
            model: primaryModel,
            requestTimeout: 1,
            maxImageBytes: 4_096,
            maxAttempts: maxAttempts
        )
        let fallback = try VisionProviderConfiguration(
            providerIdentifier: "zhipu",
            baseURL: URL(string: "https://vision.example.com/v4")!,
            model: fallbackModel,
            requestTimeout: 1,
            maxImageBytes: 4_096,
            maxAttempts: maxAttempts
        )
        let runtime = ZhipuVisionRuntimeConfiguration(
            primary: primary,
            fallback: fallback,
            credential: VisionCredential(apiKey: secret)
        )
        return ZhipuVisionClient(
            runtimeConfiguration: runtime,
            transport: transport,
            retryDelay: retryDelay
        )
    }

    private func assertRedirectRejected(targetURL: URL) {
        let originalURL = URL(string: "https://vision.example.com/v4/original")!
        var proposedRequest = URLRequest(url: targetURL)
        proposedRequest.setValue(
            "Bearer redirect-secret",
            forHTTPHeaderField: "Authorization"
        )
        proposedRequest.httpBody = imageData

        let delegate = VisionHTTPRedirectDelegate()
        let completion = RedirectCompletionBox()
        let response = HTTPURLResponse(
            url: originalURL,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": targetURL.absoluteString]
        )!
        let task = URLSession.shared.dataTask(with: originalURL)
        delegate.urlSession(
            .shared,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: proposedRequest
        ) { redirectedRequest in
            completion.store(redirectedRequest)
        }

        switch completion.result() {
        case .notCalled:
            XCTFail("Redirect completion was not called.")
        case .called(let redirectedRequest):
            XCTAssertNil(redirectedRequest, targetURL.absoluteString)
        }
        XCTAssertNil(
            delegate.redirectRequest(for: proposedRequest),
            "Redirect policy must reject the proposed request."
        )
    }

    private func completion(content: String) -> VisionHTTPResponse {
        let object: [String: Any] = [
            "choices": [["message": ["content": content]]],
        ]
        return VisionHTTPResponse(
            statusCode: 200,
            headers: ["x-request-id": "safe-test-request-id"],
            body: try! JSONSerialization.data(withJSONObject: object)
        )
    }

    private func status(_ statusCode: Int) -> VisionHTTPResponse {
        VisionHTTPResponse(
            statusCode: statusCode,
            headers: [:],
            body: Data("provider error body must not escape".utf8)
        )
    }

    private func modelContent(visibleTexts: [String]) -> String {
        let object: [String: Any] = [
            "visibleTexts": visibleTexts,
            "imageReadable": true,
            "uncertainRegionsPresent": false,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}

private struct Execution {
    let result: Result<VisionVisibleTextResult, ZhipuVisionClientError>
    let callCount: Int
    let client: ZhipuVisionClient
    let transport: StubVisionTransport
}

private extension VisionVisibleTextResult {
    static let fixture = VisionVisibleTextResult.fixtureValue

    private static var fixtureValue: VisionVisibleTextResult {
        try! JSONDecoder().decode(
            VisionVisibleTextResult.self,
            from: Data(
                #"{"visibleTexts":["LOT 42","2028-01"],"imageReadable":true,"uncertainRegionsPresent":false}"#.utf8
            )
        )
    }
}

private extension Result {
    var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}

private actor StubVisionTransport: VisionHTTPTransport {
    enum Step: Sendable {
        case response(VisionHTTPResponse)
        case urlError(URLError.Code)
        case cancellation
        case failure
    }

    enum StubError: Error { case unexpectedCall, transportFailure }

    private var steps: [Step]
    private var requests: [VisionTransportRequest] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    func send(_ request: VisionTransportRequest) async throws -> VisionHTTPResponse {
        requests.append(request)
        guard !steps.isEmpty else { throw StubError.unexpectedCall }
        switch steps.removeFirst() {
        case .response(let response): return response
        case .urlError(let code): throw URLError(code)
        case .cancellation: throw CancellationError()
        case .failure: throw StubError.transportFailure
        }
    }

    func callCount() -> Int { requests.count }
    func firstRequest() -> VisionTransportRequest? { requests.first }
}

private actor TwoPhaseCancellationGate {
    enum GateError: Error, Equatable { case duplicateWaiter, entryTimedOut, releaseTimedOut }

    struct RegistrationCounts: Equatable {
        let waiterInstallations: Int
        let timeoutTaskInstallations: Int
    }

    private enum Phase: Hashable {
        case entry, release

        var timeoutError: GateError {
            self == .entry ? .entryTimedOut : .releaseTimedOut
        }
    }

    private let timeout: Duration
    private var entered = false
    private var released = false
    private var waiters: [Phase: CheckedContinuation<Void, Error>] = [:]
    private var timeoutTasks: [Phase: Task<Void, Never>] = [:]
    private var waiterInstallations: [Phase: Int] = [:]
    private var timeoutTaskInstallations: [Phase: Int] = [:]

    init(timeout: Duration = .seconds(2)) {
        self.timeout = timeout
    }

    func arriveAndWaitForRelease(onWaiterRegistered: (@Sendable () -> Void)? = nil) async throws {
        entered = true
        resume(.entry)
        guard !released else { return }
        try await wait(for: .release, onWaiterRegistered: onWaiterRegistered)
    }

    func waitUntilEntered(onWaiterRegistered: (@Sendable () -> Void)? = nil) async throws {
        guard !entered else { return }
        try await withTaskCancellationHandler {
            try await wait(for: .entry, onWaiterRegistered: onWaiterRegistered)
        } onCancel: {
            Task { await self.resume(.entry, throwing: CancellationError()) }
        }
    }

    func release() {
        released = true
        resume(.release)
    }

    func entryRegistrationCounts() -> RegistrationCounts {
        registrationCounts(for: .entry)
    }

    func releaseRegistrationCounts() -> RegistrationCounts {
        registrationCounts(for: .release)
    }

    private func wait(
        for phase: Phase,
        onWaiterRegistered: (@Sendable () -> Void)?
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            if Task.isCancelled && phase == .entry {
                continuation.resume(throwing: CancellationError())
                return
            }
            guard waiters[phase] == nil, timeoutTasks[phase] == nil else {
                continuation.resume(throwing: GateError.duplicateWaiter)
                return
            }
            waiterInstallations[phase, default: 0] += 1
            waiters[phase] = continuation
            timeoutTaskInstallations[phase, default: 0] += 1
            timeoutTasks[phase] = Task { [weak self, timeout] in
                do { try await Task.sleep(for: timeout) } catch { return }
                await self?.resume(phase, throwing: phase.timeoutError)
            }
            onWaiterRegistered?()
        }
    }

    private func registrationCounts(for phase: Phase) -> RegistrationCounts {
        RegistrationCounts(
            waiterInstallations: waiterInstallations[phase, default: 0],
            timeoutTaskInstallations: timeoutTaskInstallations[phase, default: 0]
        )
    }

    private func resume(_ phase: Phase, throwing error: (any Error)? = nil) {
        timeoutTasks.removeValue(forKey: phase)?.cancel()
        guard let continuation = waiters.removeValue(forKey: phase) else {
            return
        }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

private final class RedirectCompletionBox: @unchecked Sendable {
    enum Result {
        case notCalled
        case called(URLRequest?)
    }

    private let lock = NSLock()
    private var storedResult = Result.notCalled

    func store(_ request: URLRequest?) {
        lock.lock()
        storedResult = .called(request)
        lock.unlock()
    }

    func result() -> Result {
        lock.lock()
        defer { lock.unlock() }
        return storedResult
    }
}
