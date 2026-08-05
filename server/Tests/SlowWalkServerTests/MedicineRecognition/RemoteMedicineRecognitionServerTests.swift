import Foundation
import Hummingbird
import HummingbirdTesting
import SlowWalkAPIContracts
import SlowWalkDataInterfaces
import SlowWalkDomain
@testable import SlowWalkServer
import XCTest

final class RemoteMedicineRecognitionServerTests:
    XCTestCase,
    @unchecked Sendable
{
    private let requestID = UUID(
        uuidString: "00000000-0000-0000-0000-0000000002c0"
    )!
    private let fallbackRequestID = UUID(
        uuidString: "00000000-0000-0000-0000-0000000002cf"
    )!
    private let now = Date(timeIntervalSince1970: 1_786_000_000)

    func testRecognizedResponseUsesCanonicalResolverAndExcludesSensitiveData()
        async throws
    {
        let extractor = FakeMedicinePackageEvidenceExtractor(
            result: .success(
                try evidence(
                    visibleTexts: ["Acetaminophen", "500 mg"],
                    probableGenericNames: ["Acetaminophen"]
                )
            )
        )
        let application = try makeApplication(extractor: extractor)

        try await application.test(.router) { client in
            try await client.execute(
                uri: SlowWalkAPI.Endpoint.medicineRecognize.path,
                method: .post,
                headers: [.contentType: "application/json"],
                body: try self.requestBody()
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let output = try self.decodeRecognition(response.body)
                XCTAssertEqual(output.status, .recognized)
                XCTAssertEqual(output.requestID, self.requestID)
                XCTAssertEqual(
                    output.canonicalResolution?.canonicalMedicineID,
                    "demo-acetaminophen"
                )
                XCTAssertEqual(
                    output.canonicalResolution?.status,
                    .resolved
                )
                XCTAssertFalse(output.allowsLocalFallback)
                XCTAssertNil(output.errorCode)
                XCTAssertFalse(output.candidates.isEmpty)

                let body = String(
                    decoding: response.body.readableBytesView,
                    as: UTF8.self
                )
                for forbidden in [
                    "imageBase64", "userProfile", "healthContext",
                    "riskLevel", "actionCard", "safeToTake",
                    "Authorization", "Bearer ", "providerResponse",
                ] {
                    XCTAssertFalse(body.contains(forbidden), forbidden)
                }
                XCTAssertFalse(
                    body.contains(
                        Data("private-image-marker".utf8)
                            .base64EncodedString()
                    )
                )
            }
        }
    }

    func testBoundedSupportingEvidencePreservesCorroborationWitnesses() {
        let aliases = (0 ..< 16).map { index in
            MedicineEvidenceMatch(
                source: .probableProductName,
                observedText: "Alias \(index)",
                normalizedObservedText: "alias \(index)",
                catalogField: .alias,
                catalogText: "Alias \(index)"
            )
        }
        let manufacturer = MedicineEvidenceMatch(
            source: .manufacturerName,
            observedText: "Example Pharma",
            normalizedObservedText: "example pharma",
            catalogField: .manufacturerName,
            catalogText: "Example Pharma"
        )

        let projected = RemoteMedicineRecognitionController
            .boundedSupportingMatches(aliases + [manufacturer])

        XCTAssertEqual(
            projected.count,
            RemoteMedicineRecognitionController.maximumMatchesPerCategory
        )
        XCTAssertTrue(projected.contains(aliases[0]))
        XCTAssertTrue(projected.contains(manufacturer))
        XCTAssertFalse(projected.contains(aliases[15]))
    }

    func testBoundedCandidatesAlwaysIncludeCanonicalSelection() {
        let candidates = (0 ..< 9).map { index in
            MedicineEvidenceCandidate(
                medicine: Medicine(
                    id: "medicine-\(index)",
                    canonicalName: "Medicine \(index)",
                    aliases: [],
                    activeIngredientIDs: [],
                    medicineCategory: .other,
                    sourceReferences: [],
                    dosageTextFromSource: nil,
                    contraindicationTags: []
                ),
                exactEvidence: [],
                supportingEvidence: [],
                conflictingEvidence: [],
                unresolvedEvidence: []
            )
        }

        let projected = RemoteMedicineRecognitionController
            .boundedCandidates(
                candidates,
                selectedMedicineID: "medicine-8"
            )

        XCTAssertEqual(
            projected.count,
            RemoteMedicineRecognitionController.maximumCandidateCount
        )
        XCTAssertEqual(projected.first?.medicine.id, "medicine-8")
        XCTAssertEqual(Set(projected.map(\.medicine.id)).count, 8)
        XCTAssertFalse(projected.contains(where: {
            $0.medicine.id == "medicine-7"
        }))
    }

    func testAmbiguousEvidenceIsNotPromotedOrFallbackEligible()
        async throws
    {
        let extractor = FakeMedicinePackageEvidenceExtractor(
            result: .success(
                try evidence(
                    probableProductNames: ["Cold Relief"]
                )
            )
        )
        let application = try makeApplication(extractor: extractor)

        try await assertRecognition(
            application: application,
            expectedHTTPStatus: .ok
        ) { output in
            XCTAssertEqual(output.status, .ambiguous)
            XCTAssertEqual(
                output.unresolvedReason,
                .ambiguousCandidates
            )
            XCTAssertEqual(output.errorCode, .medicineAmbiguous)
            XCTAssertNil(output.canonicalResolution)
            XCTAssertGreaterThanOrEqual(output.candidates.count, 2)
            XCTAssertFalse(output.allowsLocalFallback)
        }
    }

    func testUnreadableImageIsExplicitAndNotFallbackEligible()
        async throws
    {
        let extractor = FakeMedicinePackageEvidenceExtractor(
            result: .success(
                try evidence(
                    imageReadable: false,
                    uncertainRegionsPresent: true
                )
            )
        )
        let application = try makeApplication(extractor: extractor)

        try await assertRecognition(application: application) { output in
            XCTAssertEqual(output.status, .unreadable)
            XCTAssertEqual(output.unresolvedReason, .imageUnreadable)
            XCTAssertNil(output.canonicalResolution)
            XCTAssertFalse(output.allowsLocalFallback)
        }
    }

    func testNoCandidateDoesNotFallBackToDemoMedicine()
        async throws
    {
        let extractor = FakeMedicinePackageEvidenceExtractor(
            result: .success(
                try evidence(visibleTexts: ["Unknown Package 98765"])
            )
        )
        let application = try makeApplication(extractor: extractor)

        try await assertRecognition(application: application) { output in
            XCTAssertEqual(output.status, .noCandidate)
            XCTAssertEqual(output.errorCode, .medicineNotFound)
            XCTAssertNil(output.canonicalResolution)
            XCTAssertTrue(output.candidates.isEmpty)
            XCTAssertFalse(output.allowsLocalFallback)
        }
    }

    func testMissingProviderDoesNotPreventApplicationStartup()
        async throws
    {
        let application = try makeApplication(
            extractor: UnavailableMedicinePackageEvidenceExtractor()
        )

        try await assertRecognition(
            application: application,
            expectedHTTPStatus: .serviceUnavailable
        ) { output in
            XCTAssertEqual(output.status, .providerUnavailable)
            XCTAssertEqual(output.errorCode, .providerUnavailable)
            XCTAssertTrue(output.allowsLocalFallback)
            XCTAssertNil(output.packageEvidence)
        }
    }

    func testProvider429And5xxHaveStableSafeMappings()
        async throws
    {
        let cases: [(ZhipuVisionClientError, HTTPResponse.Status, APIErrorCode)] = [
            (
                .rateLimited(providerIdentifier: "fake", statusCode: 429),
                .tooManyRequests,
                .providerRateLimited
            ),
            (
                .serverFailure(providerIdentifier: "fake", statusCode: 503),
                .serviceUnavailable,
                .providerUnavailable
            ),
        ]

        for (providerError, status, code) in cases {
            let extractor = FakeMedicinePackageEvidenceExtractor(
                result: .failure(providerError)
            )
            let application = try makeApplication(extractor: extractor)
            try await assertRecognition(
                application: application,
                expectedHTTPStatus: status
            ) { output in
                XCTAssertEqual(output.status, .providerUnavailable)
                XCTAssertEqual(output.errorCode, code)
                XCTAssertTrue(output.allowsLocalFallback)
                XCTAssertNil(output.packageEvidence)
                XCTAssertTrue(output.candidates.isEmpty)
            }
        }
    }

    func testProviderTimeoutAndMalformedPayloadHaveStableMappings()
        async throws
    {
        let cases: [(ZhipuVisionClientError, HTTPResponse.Status, APIErrorCode)] = [
            (
                .timeout(providerIdentifier: "fake"),
                .gatewayTimeout,
                .providerTimeout
            ),
            (
                .malformedProviderResponse(providerIdentifier: "fake"),
                .badGateway,
                .invalidProviderResponse
            ),
        ]

        for (providerError, status, code) in cases {
            let extractor = FakeMedicinePackageEvidenceExtractor(
                result: .failure(providerError)
            )
            let application = try makeApplication(extractor: extractor)
            try await assertRecognition(
                application: application,
                expectedHTTPStatus: status
            ) { output in
                XCTAssertEqual(output.status, .providerUnavailable)
                XCTAssertEqual(output.errorCode, code)
                XCTAssertTrue(output.allowsLocalFallback)
            }
        }
    }

    func testProviderFailureDoesNotEchoErrorImageOrCredentialMaterial()
        async throws
    {
        let secret = "provider-body-secret Bearer api-key-secret"
        let extractor = ClosureMedicinePackageEvidenceExtractor { _ in
            throw SensitiveFakeProviderError(secret: secret)
        }
        let application = try makeApplication(extractor: extractor)

        try await application.test(.router) { client in
            try await client.execute(
                uri: SlowWalkAPI.Endpoint.medicineRecognize.path,
                method: .post,
                headers: [.contentType: "application/json"],
                body: try self.requestBody(
                    imageData: Data("private-image-marker".utf8)
                )
            ) { response in
                XCTAssertEqual(response.status, .serviceUnavailable)
                let body = String(
                    decoding: response.body.readableBytesView,
                    as: UTF8.self
                )
                XCTAssertFalse(body.contains(secret))
                XCTAssertFalse(body.contains("api-key-secret"))
                XCTAssertFalse(body.contains("private-image-marker"))
                XCTAssertFalse(body.localizedCaseInsensitiveContains("base64"))
            }
        }
    }

    func testUnsupportedMIMEAndMalformedBase64AreRejectedBeforeProvider()
        async throws
    {
        let extractor = FakeMedicinePackageEvidenceExtractor(
            result: .success(try evidence())
        )
        let application = try makeApplication(extractor: extractor)
        let cases: [(String, String, String)] = [
            ("image/gif", Data([1]).base64EncodedString(), "mimeType"),
            ("image/png", "not+strict/base64!", "imageBase64"),
        ]

        try await application.test(.router) { client in
            for (mimeType, imageBase64, expectedField) in cases {
                let request = MedicineRecognitionAPIRequestDTO(
                    imageBase64: imageBase64,
                    mimeType: mimeType,
                    requestID: self.requestID,
                    clientCapabilities: nil,
                    apiVersion: SlowWalkAPI.version
                )
                try await client.execute(
                    uri: SlowWalkAPI.Endpoint.medicineRecognize.path,
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: try self.encode(request)
                ) { response in
                    XCTAssertEqual(response.status, .unprocessableContent)
                    let error = try self.decodeError(response.body)
                    XCTAssertEqual(error.code, .validationError)
                    XCTAssertEqual(error.details?.first?.field, expectedField)
                }
            }
        }
        let callCount = await extractor.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testDecodedImageLimitIsEnforcedBeforeProvider()
        async throws
    {
        let extractor = FakeMedicinePackageEvidenceExtractor(
            result: .success(try evidence())
        )
        let application = try makeApplication(extractor: extractor)
        let oversized = Data(
            count: MedicineRecognitionAPIRequestValidator
                .maximumDecodedImageBytes + 1
        )

        try await application.test(.router) { client in
            try await client.execute(
                uri: SlowWalkAPI.Endpoint.medicineRecognize.path,
                method: .post,
                headers: [.contentType: "application/json"],
                body: try self.requestBody(imageData: oversized)
            ) { response in
                XCTAssertEqual(response.status, .contentTooLarge)
                XCTAssertEqual(
                    try self.decodeError(response.body).code,
                    .imageTooLarge
                )
            }
        }
        let callCount = await extractor.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testRouteSpecificRequestBodyLimitIsEnforced()
        async throws
    {
        let extractor = FakeMedicinePackageEvidenceExtractor(
            result: .success(try evidence())
        )
        let application = try makeApplication(extractor: extractor)
        var oversizedBody = ByteBuffer()
        oversizedBody.writeRepeatingByte(
            0x61,
            count: MedicineRecognitionAPIRequestValidator
                .maximumRequestBodyBytes + 1
        )
        let requestBody = oversizedBody

        try await application.test(.router) { client in
            try await client.execute(
                uri: SlowWalkAPI.Endpoint.medicineRecognize.path,
                method: .post,
                headers: [.contentType: "application/json"],
                body: requestBody
            ) { response in
                XCTAssertEqual(response.status, .contentTooLarge)
                XCTAssertEqual(
                    try self.decodeError(response.body).code,
                    .requestBodyTooLarge
                )
            }
        }
        let callCount = await extractor.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testUnknownHealthAndCapabilityFieldsAreRejected()
        async throws
    {
        let extractor = FakeMedicinePackageEvidenceExtractor(
            result: .success(try evidence())
        )
        let application = try makeApplication(extractor: extractor)
        let payloads = [
            """
            {"apiVersion":"v1","imageBase64":"aW1hZ2U=",\
            "mimeType":"image/png","requestID":"\(requestID.uuidString)",\
            "userProfile":{"age":72}}
            """,
            """
            {"apiVersion":"v1","imageBase64":"aW1hZ2U=",\
            "mimeType":"image/png","requestID":"\(requestID.uuidString)",\
            "clientCapabilities":{"supportsLocalFallback":true,\
            "healthContext":true}}
            """,
        ]

        try await application.test(.router) { client in
            for payload in payloads {
                try await client.execute(
                    uri: SlowWalkAPI.Endpoint.medicineRecognize.path,
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(string: payload)
                ) { response in
                    XCTAssertEqual(response.status, .badRequest)
                    XCTAssertEqual(
                        try self.decodeError(response.body).code,
                        .malformedRequest
                    )
                }
            }
        }
        let callCount = await extractor.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testContentTypeAndAPIVersionValidationAreStable()
        async throws
    {
        let extractor = FakeMedicinePackageEvidenceExtractor(
            result: .success(try evidence())
        )
        let application = try makeApplication(extractor: extractor)

        try await application.test(.router) { client in
            try await client.execute(
                uri: SlowWalkAPI.Endpoint.medicineRecognize.path,
                method: .post,
                body: try self.requestBody()
            ) { response in
                XCTAssertEqual(response.status, .badRequest)
                XCTAssertEqual(
                    try self.decodeError(response.body).code,
                    .unsupportedMediaType
                )
            }
            try await client.execute(
                uri: SlowWalkAPI.Endpoint.medicineRecognize.path,
                method: .post,
                headers: [.contentType: "application/json"],
                body: try self.requestBody(apiVersion: "v999")
            ) { response in
                XCTAssertEqual(response.status, .badRequest)
                XCTAssertEqual(
                    try self.decodeError(response.body).code,
                    .unsupportedAPIVersion
                )
            }
        }
        let callCount = await extractor.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testRepeatedRequestIDIsCorrelationOnlyAndRunsTwice()
        async throws
    {
        let extractor = FakeMedicinePackageEvidenceExtractor(
            result: .success(
                try evidence(
                    probableGenericNames: ["Acetaminophen"]
                )
            )
        )
        let application = try makeApplication(extractor: extractor)

        try await application.test(.router) { client in
            for _ in 0 ..< 2 {
                try await client.execute(
                    uri: SlowWalkAPI.Endpoint.medicineRecognize.path,
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: try self.requestBody()
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                    XCTAssertEqual(
                        try self.decodeRecognition(response.body).requestID,
                        self.requestID
                    )
                }
            }
        }
        let callCount = await extractor.callCount
        XCTAssertEqual(callCount, 2)
    }

    func testServiceTimeoutDoesNotAwaitExtractorIgnoringCancellation()
        async throws
    {
        let delayedExtractor = ClosureMedicinePackageEvidenceExtractor { _ in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .milliseconds(300))
            while clock.now < deadline {
                try? await Task<Never, Never>.sleep(
                    for: .milliseconds(10)
                )
            }
            return try self.evidence()
        }
        let service = try makeService(
            extractor: delayedExtractor,
            timeoutTask: {
                try await Task<Never, Never>.sleep(
                    for: .milliseconds(20)
                )
            }
        )
        let clock = ContinuousClock()
        let start = clock.now

        do {
            _ = try await service.recognize(
                image: VisionImagePayload(
                    data: Data([1]),
                    mimeType: "image/png"
                )
            )
            XCTFail("Expected timeout")
        } catch let error as RemoteMedicineRecognitionServiceError {
            XCTAssertEqual(error, .timedOut)
        }
        XCTAssertLessThan(
            start.duration(to: clock.now),
            .milliseconds(150)
        )
    }

    func testServiceCancellationPropagatesWithoutLateWait()
        async throws
    {
        let delayedExtractor = ClosureMedicinePackageEvidenceExtractor { _ in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .milliseconds(300))
            while clock.now < deadline {
                try? await Task<Never, Never>.sleep(
                    for: .milliseconds(10)
                )
            }
            return try self.evidence()
        }
        let service = try makeService(
            extractor: delayedExtractor,
            timeoutTask: {
                try await Task<Never, Never>.sleep(for: .seconds(2))
            }
        )
        let task = Task {
            try await service.recognize(
                image: VisionImagePayload(
                    data: Data([1]),
                    mimeType: "image/png"
                )
            )
        }
        try await Task<Never, Never>.sleep(for: .milliseconds(20))
        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertLessThan(
            start.duration(to: clock.now),
            .milliseconds(150)
        )
    }

    private func makeApplication(
        extractor: any MedicinePackageEvidenceExtracting
    ) throws -> some ApplicationProtocol {
        try makeSlowWalkApplication(
            configuration: .init(port: 0),
            dateProvider: FixedDateProvider(fixedDate: now),
            uuidProvider: FixedUUIDProvider(
                fixedUUID: fallbackRequestID
            ),
            medicinePackageEvidenceExtractor: extractor,
            medicineRecognitionTimeout: .seconds(2)
        )
    }

    private func makeService(
        extractor: any MedicinePackageEvidenceExtracting,
        timeoutTask: @escaping RemoteMedicineRecognitionService.TimeoutTask
    ) throws -> RemoteMedicineRecognitionService {
        RemoteMedicineRecognitionService(
            extractor: extractor,
            resolver: try RemoteMedicineCandidateResolver(),
            timeoutTask: timeoutTask
        )
    }

    private func assertRecognition<Application: ApplicationProtocol>(
        application: Application,
        expectedHTTPStatus: HTTPResponse.Status = .ok,
        verify:
            @escaping @Sendable
            (MedicineRecognitionAPIResponseDTO) throws -> Void
    ) async throws {
        try await application.test(.router) { client in
            try await client.execute(
                uri: SlowWalkAPI.Endpoint.medicineRecognize.path,
                method: .post,
                headers: [.contentType: "application/json"],
                body: try self.requestBody()
            ) { response in
                XCTAssertEqual(response.status, expectedHTTPStatus)
                try verify(try self.decodeRecognition(response.body))
            }
        }
    }

    private func requestBody(
        imageData: Data = Data("private-image-marker".utf8),
        apiVersion: String = SlowWalkAPI.version
    ) throws -> ByteBuffer {
        try encode(
            MedicineRecognitionAPIRequestDTO(
                imageBase64: imageData.base64EncodedString(),
                mimeType: "image/png",
                requestID: requestID,
                clientCapabilities:
                    MedicineRecognitionClientCapabilitiesDTO(
                        supportsLocalFallback: true
                    ),
                apiVersion: apiVersion
            )
        )
    }

    private func evidence(
        visibleTexts: [String] = [],
        probableProductNames: [String] = [],
        probableGenericNames: [String] = [],
        imageReadable: Bool = true,
        uncertainRegionsPresent: Bool = false
    ) throws -> RemoteMedicinePackageEvidence {
        try RemoteMedicinePackageEvidence(
            visibleTexts: visibleTexts,
            probableProductNames: probableProductNames,
            probableGenericNames: probableGenericNames,
            manufacturerNames: [],
            approvalIdentifiers: [],
            dosageFormTexts: [],
            packagingFeatures: [],
            searchQueries: [],
            imageReadable: imageReadable,
            uncertainRegionsPresent: uncertainRegionsPresent
        )
    }

    private func encode<Value: Encodable>(
        _ value: Value
    ) throws -> ByteBuffer {
        ByteBuffer(
            bytes: try SlowWalkJSONCoding.makeEncoder().encode(value)
        )
    }

    private func decodeRecognition(
        _ body: ByteBuffer
    ) throws -> MedicineRecognitionAPIResponseDTO {
        try SlowWalkJSONCoding.makeDecoder().decode(
            MedicineRecognitionAPIResponseDTO.self,
            from: Data(body.readableBytesView)
        )
    }

    private func decodeError(
        _ body: ByteBuffer
    ) throws -> APIErrorDTO {
        try SlowWalkJSONCoding.makeDecoder().decode(
            APIErrorDTO.self,
            from: Data(body.readableBytesView)
        )
    }
}

private actor FakeMedicinePackageEvidenceExtractor:
    MedicinePackageEvidenceExtracting
{
    private let result:
        Result<RemoteMedicinePackageEvidence, ZhipuVisionClientError>
    private(set) var callCount = 0

    init(
        result:
            Result<RemoteMedicinePackageEvidence, ZhipuVisionClientError>
    ) {
        self.result = result
    }

    func extractMedicinePackageEvidence(
        from image: VisionImagePayload
    ) async throws -> RemoteMedicinePackageEvidence {
        callCount += 1
        return try result.get()
    }
}

private struct ClosureMedicinePackageEvidenceExtractor:
    MedicinePackageEvidenceExtracting
{
    let operation:
        @Sendable (VisionImagePayload) async throws
        -> RemoteMedicinePackageEvidence

    init(
        operation:
            @escaping @Sendable (VisionImagePayload) async throws
            -> RemoteMedicinePackageEvidence
    ) {
        self.operation = operation
    }

    func extractMedicinePackageEvidence(
        from image: VisionImagePayload
    ) async throws -> RemoteMedicinePackageEvidence {
        try await operation(image)
    }
}

private struct SensitiveFakeProviderError: Error, Sendable {
    let secret: String
}
