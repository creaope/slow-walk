import Foundation
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

    func testNonRetryableHTTPErrorCallsTransportOnce() async throws {
        let execution = try await run(
            [.response(status(401)), .response(status(200))],
            maxAttempts: 3
        )
        XCTAssertEqual(
            execution.result,
            .failure(.unauthorized(
                providerIdentifier: "zhipu", statusCode: 401
            ))
        )
        XCTAssertEqual(execution.callCount, 1)
    }

    func test429AndAllowed5xxStatusesRetry() async throws {
        for retryableStatus in [429, 500, 502, 503, 504] {
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

    private func run(
        _ steps: [StubVisionTransport.Step],
        image: VisionImagePayload? = nil,
        maxAttempts: Int = 1
    ) async throws -> Execution {
        let configuration = try VisionProviderConfiguration(
            providerIdentifier: "zhipu",
            baseURL: URL(string: "https://vision.example.com/v4")!,
            model: "vision-model",
            requestTimeout: 1,
            maxImageBytes: 4_096,
            maxAttempts: maxAttempts
        )
        let runtime = ZhipuVisionRuntimeConfiguration(
            primary: configuration,
            fallback: configuration,
            credential: VisionCredential(apiKey: secret)
        )
        let transport = StubVisionTransport(steps: steps)
        let client = ZhipuVisionClient(
            runtimeConfiguration: runtime,
            transport: transport,
            retryDelay: { _ in }
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
        case .failure: throw StubError.transportFailure
        }
    }

    func callCount() -> Int { requests.count }
    func firstRequest() -> VisionTransportRequest? { requests.first }
}
