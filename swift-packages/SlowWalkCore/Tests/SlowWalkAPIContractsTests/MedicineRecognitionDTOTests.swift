import Foundation
import SlowWalkAPIContracts
import XCTest

final class MedicineRecognitionDTOTests: XCTestCase {
    func testRequestRoundTripsWithOneImageAndOptionalCapabilities()
        throws
    {
        let request = MedicineRecognitionAPIRequestDTO(
            imageBase64: "c2FuaXRpemVkLWltYWdlLWJ5dGVz",
            mimeType: "image/jpeg",
            requestID: fixedRequestID,
            clientCapabilities:
                MedicineRecognitionClientCapabilitiesDTO(
                    supportsLocalFallback: true
                ),
            apiVersion: SlowWalkAPI.version
        )

        let data = try SlowWalkJSONCoding.makeEncoder()
            .encode(request)
        let decoded = try SlowWalkJSONCoding.makeDecoder()
            .decode(
                MedicineRecognitionAPIRequestDTO.self,
                from: data
            )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(
            Set(object.keys),
            [
                "apiVersion",
                "clientCapabilities",
                "imageBase64",
                "mimeType",
                "requestID",
            ]
        )
        XCTAssertEqual(object["mimeType"] as? String, "image/jpeg")
        XCTAssertNil(object["userProfile"])
        XCTAssertNil(object["recentRecords"])
        XCTAssertNil(object["healthContext"])
    }

    func testRequestWithoutClientCapabilitiesOmitsOptionalField()
        throws
    {
        let request = MedicineRecognitionAPIRequestDTO(
            imageBase64: "aW1hZ2U=",
            mimeType: "image/png",
            requestID: fixedRequestID,
            clientCapabilities: nil,
            apiVersion: SlowWalkAPI.version
        )

        let data = try SlowWalkJSONCoding.makeEncoder()
            .encode(request)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        )

        XCTAssertNil(object["clientCapabilities"])
        XCTAssertEqual(
            try SlowWalkJSONCoding.makeDecoder().decode(
                MedicineRecognitionAPIRequestDTO.self,
                from: data
            ),
            request
        )
    }

    func testRequestRejectsHealthDataAndUnknownCapabilityFields() {
        let requestWithHealthData = Data(
            """
            {
              "imageBase64": "aW1hZ2U=",
              "mimeType": "image/png",
              "requestID": "00000000-0000-0000-0000-000000000201",
              "apiVersion": "v1",
              "userProfile": {"age": 70}
            }
            """.utf8
        )
        let requestWithUnknownCapability = Data(
            """
            {
              "imageBase64": "aW1hZ2U=",
              "mimeType": "image/png",
              "requestID": "00000000-0000-0000-0000-000000000201",
              "apiVersion": "v1",
              "clientCapabilities": {
                "supportsLocalFallback": true,
                "uploadsHealthContext": true
              }
            }
            """.utf8
        )

        XCTAssertThrowsError(
            try SlowWalkJSONCoding.makeDecoder().decode(
                MedicineRecognitionAPIRequestDTO.self,
                from: requestWithHealthData
            )
        )
        XCTAssertThrowsError(
            try SlowWalkJSONCoding.makeDecoder().decode(
                MedicineRecognitionAPIRequestDTO.self,
                from: requestWithUnknownCapability
            )
        )
    }

    func testRecognizedResponseRoundTripsWithExplainableEvidence()
        throws
    {
        let response = makeRecognizedResponse()

        let data = try SlowWalkJSONCoding.makeEncoder()
            .encode(response)
        let decoded = try SlowWalkJSONCoding.makeDecoder()
            .decode(
                MedicineRecognitionAPIResponseDTO.self,
                from: data
            )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        )
        let candidates = try XCTUnwrap(
            object["candidates"] as? [[String: Any]]
        )
        let candidate = try XCTUnwrap(candidates.first)

        XCTAssertEqual(decoded, response)
        XCTAssertEqual(Set([response]).count, 1)
        XCTAssertNotNil(candidate["exactEvidence"])
        XCTAssertNotNil(candidate["supportingEvidence"])
        XCTAssertNotNil(candidate["conflictingEvidence"])
        XCTAssertNotNil(candidate["unresolvedEvidence"])
        XCTAssertEqual(
            decoded.canonicalResolution?.canonicalMedicineID,
            "medicine-acetaminophen"
        )
        XCTAssertEqual(decoded.unresolvedEvidence.count, 1)
    }

    func testResponseWireFormatExcludesImagesClinicalDataAndProviderInternals()
        throws
    {
        let data = try SlowWalkJSONCoding.makeEncoder()
            .encode(makeRecognizedResponse())
        let object = try JSONSerialization.jsonObject(with: data)
        let keys = allKeys(in: object)
        let forbiddenKeys: Set<String> = [
            "actionCard",
            "assessment",
            "authorization",
            "dosageAdvice",
            "healthContext",
            "imageBase64",
            "providerResponse",
            "rawResponse",
            "recentRecords",
            "riskLevel",
            "safeToTake",
            "selectedMedicine",
            "userProfile",
        ]
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(keys.isDisjoint(with: forbiddenKeys))
        XCTAssertFalse(json.contains("c2FuaXRpemVkLWltYWdlLWJ5dGVz"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("base64"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("bearer"))
    }

    func testProviderUnavailableResponseRoundTripsWithoutImageOrIdentity()
        throws
    {
        let response = MedicineRecognitionAPIResponseDTO(
            status: .providerUnavailable,
            requestID: fixedRequestID,
            packageEvidence: nil,
            canonicalResolution: nil,
            candidates: [],
            unresolvedEvidence: [],
            unresolvedReason: .providerUnavailable,
            allowsLocalFallback: true,
            errorCode: .providerRateLimited,
            apiVersion: SlowWalkAPI.version
        )

        let data = try SlowWalkJSONCoding.makeEncoder()
            .encode(response)
        let decoded = try SlowWalkJSONCoding.makeDecoder()
            .decode(
                MedicineRecognitionAPIResponseDTO.self,
                from: data
            )
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(decoded, response)
        XCTAssertTrue(decoded.allowsLocalFallback)
        XCTAssertTrue(
            json.contains("\"status\":\"provider_unavailable\"")
        )
        XCTAssertTrue(
            json.contains("\"errorCode\":\"PROVIDER_RATE_LIMITED\"")
        )
        XCTAssertFalse(json.localizedCaseInsensitiveContains("base64"))
    }

    func testResponseRejectsFallbackForSemanticOutcomes() throws {
        for status in [
            "recognized",
            "ambiguous",
            "unreadable",
            "no_candidate",
        ] {
            let data = Data(
                """
                {
                  "status": "\(status)",
                  "requestID": "00000000-0000-0000-0000-000000000201",
                  "candidates": [],
                  "unresolvedEvidence": [],
                  "allowsLocalFallback": true,
                  "apiVersion": "v1"
                }
                """.utf8
            )

            XCTAssertThrowsError(
                try SlowWalkJSONCoding.makeDecoder().decode(
                    MedicineRecognitionAPIResponseDTO.self,
                    from: data
                ),
                "Status \(status) must not permit local fallback."
            )
        }
    }

    func testRecognitionStatusesAreExactStableSnakeCaseValues() {
        XCTAssertEqual(
            MedicineRecognitionStatusDTO.allCases.map(\.rawValue),
            [
                "recognized",
                "ambiguous",
                "unreadable",
                "no_candidate",
                "provider_unavailable",
            ]
        )

        let lowerSnakeValues =
            MedicineRecognitionUnresolvedReasonDTO.allCases.map(\.rawValue)
                + MedicineCanonicalResolutionStatusDTO.allCases.map(\.rawValue)
                + MedicineRecognitionEvidenceSourceDTO.allCases.map(\.rawValue)
                + MedicineRecognitionCatalogFieldDTO.allCases.map(\.rawValue)
        for value in lowerSnakeValues {
            XCTAssertNotNil(
                value.range(
                    of: #"^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$"#,
                    options: .regularExpression
                )
            )
        }
    }

    func testMedicineRecognitionEndpointPathAndErrorCodesAreStable() {
        let endpoint = SlowWalkAPI.Endpoint.medicineRecognize

        XCTAssertEqual(endpoint.path, "/api/v1/medicine/recognize")
        XCTAssertTrue(
            SlowWalkAPI.supports(
                bodyVersion: SlowWalkAPI.version,
                for: endpoint
            )
        )
        XCTAssertEqual(
            endpoint.errorCodes.map(\.rawValue),
            [
                "UNSUPPORTED_MEDIA_TYPE",
                "MALFORMED_REQUEST",
                "UNSUPPORTED_API_VERSION",
                "VALIDATION_ERROR",
                "REQUEST_BODY_TOO_LARGE",
                "IMAGE_TOO_LARGE",
                "MEDICINE_AMBIGUOUS",
                "MEDICINE_RECOGNITION_FAILED",
                "MEDICINE_INSUFFICIENT_EVIDENCE",
                "MEDICINE_NOT_FOUND",
                "SOURCE_CONFLICT",
                "PROVIDER_RATE_LIMITED",
                "PROVIDER_UNAVAILABLE",
                "PROVIDER_TIMEOUT",
                "INVALID_PROVIDER_RESPONSE",
                "INTERNAL_ERROR",
            ]
        )
    }

    private func makeRecognizedResponse()
        -> MedicineRecognitionAPIResponseDTO
    {
        let exact = MedicineRecognitionEvidenceMatchDTO(
            source: .approvalIdentifier,
            observedText: "国药准字 H20000001",
            normalizedObservedText: "国药准字h20000001",
            catalogField: .approvalIdentifier,
            catalogText: "国药准字H20000001"
        )
        let supporting = MedicineRecognitionEvidenceMatchDTO(
            source: .probableProductName,
            observedText: "Acetaminophen",
            normalizedObservedText: "acetaminophen",
            catalogField: .alias,
            catalogText: "Acetaminophen"
        )
        let conflicting = MedicineRecognitionEvidenceMatchDTO(
            source: .manufacturerName,
            observedText: "示例制药",
            normalizedObservedText: "示例制药",
            catalogField: .manufacturerName,
            catalogText: "另一制药"
        )
        let unresolved = MedicineRecognitionEvidenceMatchDTO(
            source: .packagingFeature,
            observedText: "白色圆片",
            normalizedObservedText: "白色圆片",
            catalogField: .packagingText,
            catalogText: "白色药片"
        )
        let candidate = MedicineEvidenceCandidateSummaryDTO(
            canonicalMedicineID: "medicine-acetaminophen",
            canonicalName: "对乙酰氨基酚",
            exactEvidence: [exact],
            supportingEvidence: [supporting],
            conflictingEvidence: [conflicting],
            unresolvedEvidence: [unresolved]
        )
        let evidence = MedicinePackageEvidenceDTO(
            visibleTexts: ["Acetaminophen", "500 mg"],
            probableProductNames: ["Acetaminophen"],
            probableGenericNames: ["对乙酰氨基酚"],
            manufacturerNames: ["示例制药"],
            approvalIdentifiers: ["国药准字H20000001"],
            dosageFormTexts: ["片剂"],
            packagingFeatures: ["白色包装"],
            searchQueries: ["对乙酰氨基酚 国药准字H20000001"],
            imageReadable: true,
            uncertainRegionsPresent: false
        )

        return MedicineRecognitionAPIResponseDTO(
            status: .recognized,
            requestID: fixedRequestID,
            packageEvidence: evidence,
            canonicalResolution:
                MedicineCanonicalResolutionSummaryDTO(
                    canonicalMedicineID: "medicine-acetaminophen",
                    canonicalName: "对乙酰氨基酚",
                    status: .resolved
                ),
            candidates: [candidate],
            unresolvedEvidence: [
                MedicineRecognitionEvidenceObservationDTO(
                    source: .visibleText,
                    observedText: "LOT 20260805",
                    normalizedText: "lot 20260805"
                ),
            ],
            unresolvedReason: nil,
            allowsLocalFallback: false,
            errorCode: nil,
            apiVersion: SlowWalkAPI.version
        )
    }

    private func allKeys(in object: Any) -> Set<String> {
        if let dictionary = object as? [String: Any] {
            return dictionary.reduce(into: Set(dictionary.keys)) {
                result, entry in
                result.formUnion(allKeys(in: entry.value))
            }
        }
        if let array = object as? [Any] {
            return array.reduce(into: Set<String>()) {
                result, value in
                result.formUnion(allKeys(in: value))
            }
        }
        return []
    }

    private var fixedRequestID: UUID {
        UUID(
            uuidString:
                "00000000-0000-0000-0000-000000000201"
        )!
    }
}
