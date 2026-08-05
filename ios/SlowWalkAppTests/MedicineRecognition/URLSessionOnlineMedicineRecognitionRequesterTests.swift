import Foundation
import os
import SlowWalkAPIContracts
import SlowWalkClientCore
import Testing

@testable import SlowWalkApp

nonisolated private enum StubImagePreparerBehavior: Sendable {
    case success(PreparedMedicineRecognitionImage)
    case failure(MedicineRecognitionImagePreparationError)
    case foreignFailure
}

nonisolated private enum StubImagePreparerError: Error, Sendable {
    case failed
}

nonisolated private struct StubMedicineRecognitionImagePreparer:
    MedicineRecognitionImagePreparing,
    Sendable
{
    let behavior: StubImagePreparerBehavior

    func prepare(
        _ input: OCRImageInput
    ) async throws -> PreparedMedicineRecognitionImage {
        switch behavior {
        case .success(let image):
            return image
        case .failure(let error):
            throw error
        case .foreignFailure:
            throw StubImagePreparerError.failed
        }
    }
}

nonisolated private final class MockMedicineRecognitionURLProtocol:
    URLProtocol,
    @unchecked Sendable
{
    typealias Handler = @Sendable (
        URLRequest,
        MockMedicineRecognitionURLProtocol
    ) -> Void

    struct Snapshot: Sendable {
        let requests: [URLRequest]
        let requestBodies: [Data?]
        let startCount: Int
        let stopCount: Int
        let deliveredResponseBodyBytes: Int
    }

    private struct State: @unchecked Sendable {
        var handler: Handler?
        var requests: [URLRequest] = []
        var requestBodies: [Data?] = []
        var startCount = 0
        var stopCount = 0
        var deliveredResponseBodyBytes = 0
    }

    private struct LifecycleState: Sendable {
        var stopped = false
        var requestBody: Data?
    }

    private static let state = OSAllocatedUnfairLock(
        initialState: State()
    )
    private let lifecycle = OSAllocatedUnfairLock(
        initialState: LifecycleState()
    )

    static func install(_ handler: @escaping Handler) {
        state.withLock { state in
            state.handler = handler
            state.requests = []
            state.requestBodies = []
            state.startCount = 0
            state.stopCount = 0
            state.deliveredResponseBodyBytes = 0
        }
    }

    static var snapshot: Snapshot {
        state.withLock { state in
            Snapshot(
                requests: state.requests,
                requestBodies: state.requestBodies,
                startCount: state.startCount,
                stopCount: state.stopCount,
                deliveredResponseBodyBytes:
                    state.deliveredResponseBodyBytes
            )
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = bodyData(from: request)
        lifecycle.withLock { state in
            state.requestBody = body
        }
        let handler = Self.state.withLock { state -> Handler? in
            state.requests.append(request)
            state.requestBodies.append(body)
            state.startCount += 1
            return state.handler
        }
        guard let handler else {
            fail(with: URLError(.badServerResponse))
            return
        }
        handler(request, self)
    }

    override func stopLoading() {
        let didStop = lifecycle.withLock { state in
            guard !state.stopped else { return false }
            state.stopped = true
            return true
        }
        if didStop {
            Self.state.withLock { state in
                state.stopCount += 1
            }
        }
    }

    var capturedRequestBody: Data? {
        lifecycle.withLock { $0.requestBody }
    }

    var isStopped: Bool {
        lifecycle.withLock { $0.stopped }
    }

    func complete(
        statusCode: Int = 200,
        data: Data,
        headers: [String: String] = [:],
        responseURL: URL? = nil
    ) {
        respond(
            statusCode: statusCode,
            headers: headers,
            responseURL: responseURL
        )
        _ = send(data)
        finish()
    }

    func respond(
        statusCode: Int = 200,
        headers: [String: String] = [:],
        responseURL: URL? = nil
    ) {
        var responseHeaders = ["Content-Type": "application/json"]
        responseHeaders.merge(headers) { _, new in new }
        guard let response = HTTPURLResponse(
            url: responseURL ?? request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: responseHeaders
        ) else {
            fail(with: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
    }

    @discardableResult
    func send(_ data: Data) -> Bool {
        guard !isStopped else { return false }
        Self.state.withLock { state in
            state.deliveredResponseBodyBytes += data.count
        }
        client?.urlProtocol(self, didLoad: data)
        return true
    }

    func finish() {
        guard !isStopped else { return }
        client?.urlProtocolDidFinishLoading(self)
    }

    func startStreaming(
        chunk: Data,
        count: Int
    ) {
        for _ in 0 ..< count {
            guard send(chunk) else { return }
        }
        finish()
    }

    func fail(with error: Error) {
        client?.urlProtocol(self, didFailWithError: error)
    }
}

nonisolated private func bodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 {
            return nil
        }
        if count == 0 {
            return result
        }
        result.append(contentsOf: buffer.prefix(count))
    }
}

@Suite(
    "URLSession online medicine recognition requester",
    .serialized,
    .timeLimit(.minutes(1))
)
struct URLSessionOnlineMedicineRecognitionRequesterTests {
    private let baseURL = URL(string: "https://medicine.test/gateway/")!

    @Test func recognizedResponseUsesCanonicalMapperAndPreservesRequestID()
        async throws
    {
        let requestID = testUUID(1)
        let capturedAt = Date(timeIntervalSince1970: 1_711_111_111)
        let responseData = encodedResponse(
            recognizedResponse(requestID: requestID)
        )
        MockMedicineRecognitionURLProtocol.install { _, transport in
            transport.complete(data: responseData)
        }
        let requester = makeRequester()

        let result = try await requester.recognize(
            request: makeRequest(
                requestID: requestID,
                capturedAt: capturedAt
            )
        )

        #expect(result.requestID == requestID)
        #expect(result.expectedCanonicalMedicineID == "demo-acetaminophen")
        #expect(result.expectedCanonicalMedicineName == "Acetaminophen")
        #expect(
            result.recognitionInput.recognizedTexts
                == ["Tylenol", "Acetaminophen", "500 mg"]
        )
        #expect(result.recognitionInput.capturedAt == capturedAt)
        #expect(MockMedicineRecognitionURLProtocol.snapshot.startCount == 1)
    }

    @Test func mapsAmbiguousUnreadableAndNoCandidateSemanticStatuses()
        async
    {
        let requestID = testUUID(2)
        let cases: [(
            MedicineRecognitionAPIResponseDTO,
            OnlineMedicineRecognitionFailure
        )] = [
            (ambiguousResponse(requestID: requestID), .ambiguous),
            (unreadableResponse(requestID: requestID), .unreadable),
            (noCandidateResponse(requestID: requestID), .noCandidate),
        ]

        for (response, expectedFailure) in cases {
            let responseData = encodedResponse(response)
            MockMedicineRecognitionURLProtocol.install { _, transport in
                transport.complete(data: responseData)
            }

            await expectFailure(
                expectedFailure,
                requester: makeRequester(),
                request: makeRequest(requestID: requestID)
            )
            #expect(
                MockMedicineRecognitionURLProtocol.snapshot.startCount == 1
            )
        }
    }

    @Test func mapsOfflineAndTimeoutTransportErrors() async {
        let cases: [(URLError.Code, OnlineMedicineRecognitionFailure)] = [
            (.notConnectedToInternet, .offline),
            (.networkConnectionLost, .offline),
            (.timedOut, .timeout),
            (.badServerResponse, .invalidResponse),
        ]

        for (code, expectedFailure) in cases {
            MockMedicineRecognitionURLProtocol.install { _, transport in
                transport.fail(with: URLError(code))
            }
            await expectFailure(
                expectedFailure,
                requester: makeRequester(),
                request: makeRequest(requestID: testUUID(3))
            )
        }
    }

    @Test func cancellationPropagatesAsCancellationError() async {
        MockMedicineRecognitionURLProtocol.install { _, _ in
            // Intentionally pending until URLSession cancellation calls stop.
        }
        let requester = makeRequester()
        let task = Task {
            try await requester.recognize(
                request: makeRequest(requestID: testUUID(4))
            )
        }

        #expect(await waitForStartCount(1))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // Cancellation remains distinct from recoverable remote failures.
        } catch {
            Issue.record("unexpected error: \(type(of: error))")
        }
        #expect(await waitForStopCount(1))
    }

    @Test func preCancelledRequestNeverStartsNetwork() async {
        MockMedicineRecognitionURLProtocol.install { _, transport in
            transport.fail(with: URLError(.unknown))
        }
        let requester = makeRequester()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await requester.recognize(
                request: makeRequest(requestID: testUUID(41))
            )
        }

        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // Expected before image preparation or URLSession work starts.
        } catch {
            Issue.record("unexpected error: \(type(of: error))")
        }
        #expect(MockMedicineRecognitionURLProtocol.snapshot.startCount == 0)
    }

    @Test func cancellationWinsOverPending429Response() async {
        MockMedicineRecognitionURLProtocol.install { _, transport in
            transport.respond(statusCode: 429)
        }
        let requester = makeRequester()
        let task = Task {
            try await requester.recognize(
                request: makeRequest(requestID: testUUID(42))
            )
        }

        #expect(await waitForStartCount(1))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // The HTTP status never replaces task cancellation.
        } catch {
            Issue.record("unexpected error: \(type(of: error))")
        }
        #expect(await waitForStopCount(1))
    }

    @Test func mapsValidated429AndGeneric5xxWithoutRetry() async {
        let requestID = testUUID(5)
        let cases: [(
            Int,
            Data,
            OnlineMedicineRecognitionFailure
        )] = [
            (
                429,
                encodedResponse(
                    providerResponse(
                        requestID: requestID,
                        errorCode: .providerRateLimited
                    )
                ),
                .rateLimited
            ),
            (500, Data("provider-secret-body".utf8), .serverUnavailable),
        ]
        for (statusCode, responseBody, expectedFailure) in cases {
            MockMedicineRecognitionURLProtocol.install { _, transport in
                transport.complete(
                    statusCode: statusCode,
                    data: responseBody
                )
            }
            let requester = makeRequester()
            do {
                _ = try await requester.recognize(
                    request: makeRequest(requestID: requestID)
                )
                Issue.record("expected HTTP failure")
            } catch let failure as OnlineMedicineRecognitionFailure {
                #expect(failure == expectedFailure)
                #expect(!String(reflecting: failure).contains("provider-secret"))
            } catch {
                Issue.record("unexpected error: \(type(of: error))")
            }
            #expect(
                MockMedicineRecognitionURLProtocol.snapshot.startCount == 1
            )
        }
    }

    @Test func mapsStableProviderFailuresFromGatewayHTTPStatuses() async {
        let requestID = testUUID(6)
        let cases: [(
            Int,
            APIErrorCode,
            OnlineMedicineRecognitionFailure
        )] = [
            (429, .providerRateLimited, .rateLimited),
            (502, .invalidProviderResponse, .providerUnavailable),
            (503, .providerUnavailable, .providerUnavailable),
            (504, .providerTimeout, .timeout),
        ]

        for (statusCode, errorCode, expectedFailure) in cases {
            let responseData = encodedResponse(
                providerResponse(
                    requestID: requestID,
                    errorCode: errorCode
                )
            )
            MockMedicineRecognitionURLProtocol.install { _, transport in
                transport.complete(
                    statusCode: statusCode,
                    data: responseData
                )
            }

            await expectFailure(
                expectedFailure,
                requester: makeRequester(),
                request: makeRequest(requestID: requestID)
            )
            #expect(
                MockMedicineRecognitionURLProtocol.snapshot.startCount == 1
            )
        }
    }

    @Test func rejectsMalformedAndMismatchedGatewayResponses() async {
        let requestID = testUUID(7)
        let cases: [(Int, Data)] = [
            (503, Data("not-json".utf8)),
            (
                429,
                encodedResponse(
                    providerResponse(
                        requestID: requestID,
                        errorCode: .providerUnavailable
                    )
                )
            ),
            (
                502,
                encodedResponse(
                    providerResponse(
                        requestID: requestID,
                        errorCode: .providerTimeout
                    )
                )
            ),
            (
                503,
                encodedResponse(
                    providerResponse(
                        requestID: testUUID(70),
                        errorCode: .providerUnavailable
                    )
                )
            ),
            (
                504,
                encodedResponse(
                    providerResponse(
                        requestID: requestID,
                        errorCode: .providerTimeout,
                        apiVersion: "v2"
                    )
                )
            ),
        ]

        for (statusCode, data) in cases {
            MockMedicineRecognitionURLProtocol.install { _, transport in
                transport.complete(statusCode: statusCode, data: data)
            }
            await expectFailure(
                .invalidResponse,
                requester: makeRequester(),
                request: makeRequest(requestID: requestID)
            )
        }
    }

    @Test func rejectsProviderStatusOn200AndRecognizedBodyOn201() async {
        let requestID = testUUID(71)
        let cases: [(Int, Data)] = [
            (
                200,
                encodedResponse(
                    providerResponse(
                        requestID: requestID,
                        errorCode: .providerUnavailable
                    )
                )
            ),
            (
                201,
                encodedResponse(recognizedResponse(requestID: requestID))
            ),
        ]

        for (statusCode, data) in cases {
            MockMedicineRecognitionURLProtocol.install { _, transport in
                transport.complete(statusCode: statusCode, data: data)
            }
            await expectFailure(
                .invalidResponse,
                requester: makeRequester(),
                request: makeRequest(requestID: requestID)
            )
        }
    }

    @Test func malformedGeneric502IsInvalidResponse() async {
        MockMedicineRecognitionURLProtocol.install { _, transport in
            transport.complete(
                statusCode: 502,
                data: Data("not-json".utf8)
            )
        }

        await expectFailure(
            .invalidResponse,
            requester: makeRequester(),
            request: makeRequest(requestID: testUUID(72))
        )
    }

    @Test func rejectsInvalidJSONAndNonJSONSuccessResponses() async {
        let requestID = testUUID(8)
        let cases: [(Data, [String: String])] = [
            (Data("{\"status\":".utf8), [:]),
            (
                encodedResponse(recognizedResponse(requestID: requestID)),
                ["Content-Type": "text/plain"]
            ),
        ]

        for (data, headers) in cases {
            MockMedicineRecognitionURLProtocol.install { _, transport in
                transport.complete(data: data, headers: headers)
            }
            await expectFailure(
                .invalidResponse,
                requester: makeRequester(),
                request: makeRequest(requestID: requestID)
            )
        }
    }

    @Test func declaredOverlimitCancelsBeforeConsumingResponseBody() async {
        let requestID = testUUID(9)
        MockMedicineRecognitionURLProtocol.install { _, transport in
            transport.respond(
                headers: [
                    "Content-Length": String(
                        URLSessionOnlineMedicineRecognitionRequester
                            .maximumResponseBytes + 1
                    ),
                ]
            )
        }

        await expectFailure(
            .invalidResponse,
            requester: makeRequester(),
            request: makeRequest(requestID: requestID)
        )

        #expect(await waitForStopCount(1))
        #expect(
            MockMedicineRecognitionURLProtocol.snapshot
                .deliveredResponseBodyBytes == 0
        )
    }

    @Test func undeclaredStreamOverlimitCancelsUnderlyingTask() async {
        MockMedicineRecognitionURLProtocol.install { _, transport in
            transport.respond()
            transport.startStreaming(
                chunk: Data(repeating: 0x20, count: 64 * 1_024),
                count: 17
            )
        }

        await expectFailure(
            .invalidResponse,
            requester: makeRequester(),
            request: makeRequest(requestID: testUUID(91))
        )

        #expect(await waitForStopCount(1))
        #expect(
            MockMedicineRecognitionURLProtocol.snapshot
                .deliveredResponseBodyBytes
                > URLSessionOnlineMedicineRecognitionRequester
                    .maximumResponseBytes
        )
    }

    @Test func mapperRejectsMismatchedEnvelopeAndCanonicalCandidate()
        async
    {
        let requestID = testUUID(10)
        let cases = [
            recognizedResponse(requestID: testUUID(11)),
            recognizedResponse(requestID: requestID, apiVersion: "v2"),
            recognizedResponse(
                requestID: requestID,
                canonicalMedicineID: "demo-acetaminophen",
                candidateMedicineID: "different-medicine"
            ),
        ]

        for response in cases {
            let responseData = encodedResponse(response)
            MockMedicineRecognitionURLProtocol.install { _, transport in
                transport.complete(data: responseData)
            }
            await expectFailure(
                .invalidResponse,
                requester: makeRequester(),
                request: makeRequest(requestID: requestID)
            )
        }
    }

    @Test func rejectsRedirectStatusForeignResponseURLAndRedirectTarget()
        async
    {
        MockMedicineRecognitionURLProtocol.install { _, transport in
            transport.complete(
                statusCode: 302,
                data: Data(),
                headers: ["Location": "https://redirected.test/upload"]
            )
        }
        await expectFailure(
            .invalidResponse,
            requester: makeRequester(),
            request: makeRequest(requestID: testUUID(12))
        )
        #expect(MockMedicineRecognitionURLProtocol.snapshot.startCount == 1)

        let responseData = encodedResponse(
            recognizedResponse(requestID: testUUID(13))
        )
        MockMedicineRecognitionURLProtocol.install { _, transport in
            transport.complete(
                data: responseData,
                responseURL: URL(string: "https://redirected.test/upload")!
            )
        }
        await expectFailure(
            .invalidResponse,
            requester: makeRequester(),
            request: makeRequest(requestID: testUUID(13))
        )

        let delegate = MedicineRecognitionRedirectRejectingDelegate()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(
            with: URL(string: "https://medicine.test/original")!
        )
        let redirectResponse = HTTPURLResponse(
            url: task.originalRequest!.url!,
            statusCode: 307,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        let redirectedRequest = URLRequest(
            url: URL(string: "https://redirected.test/upload")!
        )
        let decision: URLRequest? = await withCheckedContinuation {
            continuation in
            delegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: redirectResponse,
                newRequest: redirectedRequest
            ) { acceptedRequest in
                continuation.resume(returning: acceptedRequest)
            }
        }
        #expect(decision == nil)
        task.cancel()
        session.invalidateAndCancel()
    }

    @Test func concurrentRequestsKeepIndependentCorrelationIDs() async throws {
        MockMedicineRecognitionURLProtocol.install { _, transport in
            guard let body = transport.capturedRequestBody,
                  let requestDTO = try? SlowWalkJSONCoding.makeDecoder()
                    .decode(
                        MedicineRecognitionAPIRequestDTO.self,
                        from: body
                    )
            else {
                transport.fail(with: URLError(.badServerResponse))
                return
            }
            transport.complete(
                data: encodedResponse(
                    recognizedResponse(requestID: requestDTO.requestID)
                )
            )
        }
        let requester = makeRequester()
        let firstID = testUUID(14)
        let secondID = testUUID(15)

        async let first = requester.recognize(
            request: makeRequest(requestID: firstID)
        )
        async let second = requester.recognize(
            request: makeRequest(requestID: secondID)
        )
        let results = try await [first, second]

        #expect(Set(results.map(\.requestID)) == [firstID, secondID])
        let capturedIDs = Set(
            MockMedicineRecognitionURLProtocol.snapshot.requestBodies
                .compactMap { body in
                body.flatMap {
                    try? SlowWalkJSONCoding.makeDecoder().decode(
                        MedicineRecognitionAPIRequestDTO.self,
                        from: $0
                    ).requestID
                }
            }
        )
        #expect(capturedIDs == [firstID, secondID])
        #expect(MockMedicineRecognitionURLProtocol.snapshot.startCount == 2)
    }

    @Test func requestUsesVersionedEndpointTimeoutAndImageOnlyDTO()
        async throws
    {
        let requestID = testUUID(16)
        let preparedBytes = Data([0xFF, 0xD8, 0xFF])
            + Data("normalized-image-bytes".utf8)
            + Data([0xFF, 0xD9])
        let responseData = encodedResponse(
            recognizedResponse(requestID: requestID)
        )
        MockMedicineRecognitionURLProtocol.install { _, transport in
            transport.complete(data: responseData)
        }
        let requester = makeRequester(preparedBytes: preparedBytes)

        _ = try await requester.recognize(
            request: makeRequest(requestID: requestID)
        )

        let request = try #require(
            MockMedicineRecognitionURLProtocol.snapshot.requests.first
        )
        #expect(request.url?.absoluteString ==
            "https://medicine.test/gateway/api/v1/medicine/recognize")
        #expect(request.httpMethod == "POST")
        #expect(
            request.timeoutInterval
                == URLSessionOnlineMedicineRecognitionRequester.requestTimeout
        )
        #expect(
            request.value(forHTTPHeaderField: "Content-Type")
                == "application/json"
        )
        #expect(
            request.value(forHTTPHeaderField: "Accept")
                == "application/json"
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)

        let body = try #require(
            MockMedicineRecognitionURLProtocol.snapshot.requestBodies.first
                ?? nil
        )
        let requestDTO = try SlowWalkJSONCoding.makeDecoder().decode(
            MedicineRecognitionAPIRequestDTO.self,
            from: body
        )
        #expect(requestDTO.requestID == requestID)
        #expect(requestDTO.imageBase64 == preparedBytes.base64EncodedString())
        #expect(requestDTO.mimeType == "image/jpeg")
        #expect(requestDTO.apiVersion == SlowWalkAPI.version)
        #expect(
            requestDTO.clientCapabilities?.supportsLocalFallback == true
        )

        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(
            Set(object.keys) == [
                "apiVersion",
                "clientCapabilities",
                "imageBase64",
                "mimeType",
                "requestID",
            ]
        )
        let bodyText = String(decoding: body, as: UTF8.self).lowercased()
        for forbidden in [
            "authorization",
            "health",
            "profile",
            "medicationhistory",
            "risklevel",
            "actioncard",
        ] {
            #expect(!bodyText.contains(forbidden))
        }
    }

    @Test func mapsImagePreparationFailuresWithoutStartingNetwork() async {
        let cases: [(
            StubImagePreparerBehavior,
            OnlineMedicineRecognitionFailure
        )] = [
            (.failure(.invalidImage), .invalidImage),
            (.failure(.imageTooLarge), .imageTooLarge),
            (.foreignFailure, .invalidImage),
            (
                .success(PreparedMedicineRecognitionImage(data: Data())),
                .invalidImage
            ),
            (
                .success(PreparedMedicineRecognitionImage(
                    data: Data([0xFF, 0xD8, 0xFF]),
                    mimeType: "image/png"
                )),
                .invalidImage
            ),
            (
                .success(PreparedMedicineRecognitionImage(data: Data([1]))),
                .invalidImage
            ),
            (
                .success(PreparedMedicineRecognitionImage(
                    data: Data([0xFF, 0xD8, 0xFF]) + Data(
                        repeating: 0,
                        count: URLSessionOnlineMedicineRecognitionRequester
                            .maximumUploadBytes
                    )
                )),
                .imageTooLarge
            ),
        ]

        for (behavior, expectedFailure) in cases {
            MockMedicineRecognitionURLProtocol.install { _, transport in
                transport.fail(with: URLError(.unknown))
            }
            let requester = URLSessionOnlineMedicineRecognitionRequester(
                baseURL: baseURL,
                imagePreparer: StubMedicineRecognitionImagePreparer(
                    behavior: behavior
                ),
                protocolClasses: [
                    MockMedicineRecognitionURLProtocol.self,
                ]
            )

            await expectFailure(
                expectedFailure,
                requester: requester,
                request: makeRequest(requestID: testUUID(17))
            )
            #expect(
                MockMedicineRecognitionURLProtocol.snapshot.startCount == 0
            )
        }
    }

    @Test func invalidAndPlaintextRemoteBaseURLsFailBeforeNetwork() async {
        let invalidURLs = [
            URL(string: "https://user:secret@medicine.test")!,
            URL(string: "http://medicine.test")!,
        ]

        for baseURL in invalidURLs {
            MockMedicineRecognitionURLProtocol.install { _, transport in
                transport.fail(with: URLError(.unknown))
            }
            let requester = URLSessionOnlineMedicineRecognitionRequester(
                baseURL: baseURL,
                imagePreparer: StubMedicineRecognitionImagePreparer(
                    behavior: .success(
                        PreparedMedicineRecognitionImage(
                            data: Data([0xFF, 0xD8, 0xFF, 0xD9])
                        )
                    )
                ),
                protocolClasses: [MockMedicineRecognitionURLProtocol.self]
            )

            await expectFailure(
                .invalidResponse,
                requester: requester,
                request: makeRequest(requestID: testUUID(18))
            )
            #expect(
                MockMedicineRecognitionURLProtocol.snapshot.startCount == 0
            )
        }
    }

    private func makeRequester(
        preparedBytes: Data = Data([0xFF, 0xD8, 0xFF, 0xD9])
    ) -> URLSessionOnlineMedicineRecognitionRequester {
        URLSessionOnlineMedicineRecognitionRequester(
            baseURL: baseURL,
            imagePreparer: StubMedicineRecognitionImagePreparer(
                behavior: .success(
                    PreparedMedicineRecognitionImage(data: preparedBytes)
                )
            ),
            protocolClasses: [MockMedicineRecognitionURLProtocol.self]
        )
    }

    private func expectFailure(
        _ expected: OnlineMedicineRecognitionFailure,
        requester: URLSessionOnlineMedicineRecognitionRequester,
        request: OnlineMedicineRecognitionRequest
    ) async {
        do {
            _ = try await requester.recognize(request: request)
            Issue.record("expected \(expected)")
        } catch let failure as OnlineMedicineRecognitionFailure {
            #expect(failure == expected)
        } catch {
            Issue.record("unexpected error: \(type(of: error))")
        }
    }

    private func waitForStartCount(_ expectedCount: Int) async -> Bool {
        for _ in 0 ..< 200 {
            if MockMedicineRecognitionURLProtocol.snapshot.startCount
                >= expectedCount
            {
                return true
            }
            try? await Task<Never, Never>.sleep(
                for: .milliseconds(5)
            )
        }
        return false
    }

    private func waitForStopCount(_ expectedCount: Int) async -> Bool {
        for _ in 0 ..< 200 {
            if MockMedicineRecognitionURLProtocol.snapshot.stopCount
                >= expectedCount
            {
                return true
            }
            try? await Task<Never, Never>.sleep(
                for: .milliseconds(5)
            )
        }
        return false
    }
}

nonisolated private func makeRequest(
    requestID: UUID,
    capturedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> OnlineMedicineRecognitionRequest {
    OnlineMedicineRecognitionRequest(
        image: OCRImageInput(
            data: Data([1, 2, 3]),
            orientation: .right,
            capturedAt: capturedAt
        ),
        requestID: requestID
    )
}

nonisolated private func testUUID(_ value: UInt8) -> UUID {
    UUID(uuid: (
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00,
        0x40, value,
        0x80, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, value
    ))
}

nonisolated private func encodedResponse(
    _ response: MedicineRecognitionAPIResponseDTO
) -> Data {
    try! SlowWalkJSONCoding.makeEncoder().encode(response)
}

nonisolated private func recognizedResponse(
    requestID: UUID,
    apiVersion: String = SlowWalkAPI.version,
    canonicalMedicineID: String = "demo-acetaminophen",
    candidateMedicineID: String = "demo-acetaminophen"
) -> MedicineRecognitionAPIResponseDTO {
    MedicineRecognitionAPIResponseDTO(
        status: .recognized,
        requestID: requestID,
        packageEvidence: readableEvidence(),
        canonicalResolution: MedicineCanonicalResolutionSummaryDTO(
            canonicalMedicineID: canonicalMedicineID,
            canonicalName: "Acetaminophen",
            status: .resolved
        ),
        candidates: [
            candidate(
                canonicalMedicineID: candidateMedicineID,
                canonicalName: "Acetaminophen"
            ),
        ],
        unresolvedEvidence: [],
        unresolvedReason: nil,
        allowsLocalFallback: false,
        errorCode: nil,
        apiVersion: apiVersion
    )
}

nonisolated private func ambiguousResponse(
    requestID: UUID
) -> MedicineRecognitionAPIResponseDTO {
    MedicineRecognitionAPIResponseDTO(
        status: .ambiguous,
        requestID: requestID,
        packageEvidence: MedicinePackageEvidenceDTO(
            visibleTexts: [],
            probableProductNames: ["Cold Relief"],
            probableGenericNames: [],
            manufacturerNames: [],
            approvalIdentifiers: [],
            dosageFormTexts: [],
            packagingFeatures: [],
            searchQueries: [],
            imageReadable: true,
            uncertainRegionsPresent: false
        ),
        canonicalResolution: nil,
        candidates: [
            MedicineEvidenceCandidateSummaryDTO(
                canonicalMedicineID: "demo-dextromethorphan",
                canonicalName: "Dextromethorphan",
                exactEvidence: [],
                supportingEvidence: [
                    MedicineRecognitionEvidenceMatchDTO(
                        source: .probableProductName,
                        observedText: "Cold Relief",
                        normalizedObservedText: "cold relief",
                        catalogField: .alias,
                        catalogText: "Cold Relief"
                    ),
                ],
                conflictingEvidence: [],
                unresolvedEvidence: []
            ),
            MedicineEvidenceCandidateSummaryDTO(
                canonicalMedicineID: "demo-chlorpheniramine",
                canonicalName: "Chlorpheniramine",
                exactEvidence: [],
                supportingEvidence: [
                    MedicineRecognitionEvidenceMatchDTO(
                        source: .probableProductName,
                        observedText: "Cold Relief",
                        normalizedObservedText: "cold relief",
                        catalogField: .alias,
                        catalogText: "Cold Relief"
                    ),
                ],
                conflictingEvidence: [],
                unresolvedEvidence: []
            ),
        ],
        unresolvedEvidence: [],
        unresolvedReason: .ambiguousCandidates,
        allowsLocalFallback: false,
        errorCode: .medicineAmbiguous,
        apiVersion: SlowWalkAPI.version
    )
}

nonisolated private func unreadableResponse(
    requestID: UUID
) -> MedicineRecognitionAPIResponseDTO {
    MedicineRecognitionAPIResponseDTO(
        status: .unreadable,
        requestID: requestID,
        packageEvidence: MedicinePackageEvidenceDTO(
            visibleTexts: [],
            probableProductNames: [],
            probableGenericNames: [],
            manufacturerNames: [],
            approvalIdentifiers: [],
            dosageFormTexts: [],
            packagingFeatures: [],
            searchQueries: [],
            imageReadable: false,
            uncertainRegionsPresent: false
        ),
        canonicalResolution: nil,
        candidates: [],
        unresolvedEvidence: [],
        unresolvedReason: .imageUnreadable,
        allowsLocalFallback: false,
        errorCode: .medicineRecognitionFailed,
        apiVersion: SlowWalkAPI.version
    )
}

nonisolated private func noCandidateResponse(
    requestID: UUID
) -> MedicineRecognitionAPIResponseDTO {
    MedicineRecognitionAPIResponseDTO(
        status: .noCandidate,
        requestID: requestID,
        packageEvidence: MedicinePackageEvidenceDTO(
            visibleTexts: ["Unknown package"],
            probableProductNames: [],
            probableGenericNames: [],
            manufacturerNames: [],
            approvalIdentifiers: [],
            dosageFormTexts: [],
            packagingFeatures: [],
            searchQueries: [],
            imageReadable: true,
            uncertainRegionsPresent: false
        ),
        canonicalResolution: nil,
        candidates: [],
        unresolvedEvidence: [
            MedicineRecognitionEvidenceObservationDTO(
                source: .visibleText,
                observedText: "Unknown package",
                normalizedText: "unknown package"
            ),
        ],
        unresolvedReason: .noCandidate,
        allowsLocalFallback: false,
        errorCode: .medicineNotFound,
        apiVersion: SlowWalkAPI.version
    )
}

nonisolated private func providerResponse(
    requestID: UUID,
    errorCode: APIErrorCode,
    apiVersion: String = SlowWalkAPI.version
) -> MedicineRecognitionAPIResponseDTO {
    MedicineRecognitionAPIResponseDTO(
        status: .providerUnavailable,
        requestID: requestID,
        packageEvidence: nil,
        canonicalResolution: nil,
        candidates: [],
        unresolvedEvidence: [],
        unresolvedReason: .providerUnavailable,
        allowsLocalFallback: true,
        errorCode: errorCode,
        apiVersion: apiVersion
    )
}

nonisolated private func readableEvidence()
    -> MedicinePackageEvidenceDTO
{
    MedicinePackageEvidenceDTO(
        visibleTexts: ["Tylenol", "500 mg"],
        probableProductNames: ["Tylenol"],
        probableGenericNames: ["Acetaminophen"],
        manufacturerNames: [],
        approvalIdentifiers: [],
        dosageFormTexts: [],
        packagingFeatures: [],
        searchQueries: [],
        imageReadable: true,
        uncertainRegionsPresent: false
    )
}

nonisolated private func candidate(
    canonicalMedicineID: String = "demo-acetaminophen",
    canonicalName: String = "Acetaminophen"
) -> MedicineEvidenceCandidateSummaryDTO {
    MedicineEvidenceCandidateSummaryDTO(
        canonicalMedicineID: canonicalMedicineID,
        canonicalName: canonicalName,
        exactEvidence: [
            MedicineRecognitionEvidenceMatchDTO(
                source: .probableGenericName,
                observedText: "Acetaminophen",
                normalizedObservedText: "acetaminophen",
                catalogField: .canonicalName,
                catalogText: "Acetaminophen"
            ),
        ],
        supportingEvidence: [],
        conflictingEvidence: [],
        unresolvedEvidence: []
    )
}
