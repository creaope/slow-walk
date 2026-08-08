import Foundation
import SlowWalkAPIContracts
import SlowWalkDomain
import XCTest

final class APIContractsTests: XCTestCase {
    private let timestamp = Date(
        timeIntervalSince1970: 1_735_689_600
    )

    func testMedicineAssessmentRequestRoundTripsWithISO8601Coding()
        throws
    {
        let request = makeRequest()
        let data = try SlowWalkJSONCoding.makeEncoder()
            .encode(request)
        let decoded = try SlowWalkJSONCoding.makeDecoder()
            .decode(
                MedicineAssessmentRequestDTO.self,
                from: data
            )

        XCTAssertEqual(decoded, request)
        let json = try XCTUnwrap(
            String(data: data, encoding: .utf8)
        )
        XCTAssertTrue(
            json.contains("2025-01-01T00:00:00.000Z")
        )
        XCTAssertFalse(
            json.contains("RiskAssessmentRequestDTO")
        )
        XCTAssertFalse(json.contains("\"medicine\":"))
        XCTAssertFalse(
            json.contains("\"sourceReferences\":")
        )
    }

    func testEncoderUsesFractionalISO8601AndDecoderPreservesMilliseconds()
        throws
    {
        let date = Date(
            timeIntervalSince1970: 1_735_689_600.123
        )
        let data = try SlowWalkJSONCoding.makeEncoder()
            .encode(DateBox(date: date))
        let json = try XCTUnwrap(
            String(data: data, encoding: .utf8)
        )
        let decoded = try SlowWalkJSONCoding.makeDecoder()
            .decode(DateBox.self, from: data)

        XCTAssertTrue(
            json.contains("2025-01-01T00:00:00.123Z")
        )
        XCTAssertEqual(
            decoded.date.timeIntervalSince1970,
            date.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testDecoderAcceptsISO8601WithoutFractionalSeconds()
        throws
    {
        let data = Data(
            #"{"date":"2025-01-01T00:00:00Z"}"#.utf8
        )

        let decoded = try SlowWalkJSONCoding.makeDecoder()
            .decode(DateBox.self, from: data)

        XCTAssertEqual(decoded.date, timestamp)
    }

    func testDecoderRejectsNonISO8601Date() {
        let data = Data(
            #"{"date":"01/01/2025"}"#.utf8
        )

        XCTAssertThrowsError(
            try SlowWalkJSONCoding.makeDecoder().decode(
                DateBox.self,
                from: data
            )
        )
    }

    func testAPIErrorRoundTripsWithTypedCode() throws {
        let error = APIErrorDTO(
            code: .validationError,
            message: "The request is invalid.",
            requestID: fixedUUID(lastByte: 9),
            details: [
                APIErrorDetailDTO(
                    field: "input.rawConfidence",
                    code: "out_of_range",
                    message:
                        "Confidence must be between zero and one."
                ),
            ]
        )

        let data = try SlowWalkJSONCoding.makeEncoder()
            .encode(error)
        let decoded = try SlowWalkJSONCoding.makeDecoder()
            .decode(APIErrorDTO.self, from: data)
        let json = try XCTUnwrap(
            String(data: data, encoding: .utf8)
        )

        XCTAssertEqual(decoded, error)
        XCTAssertTrue(
            json.contains("\"code\":\"VALIDATION_ERROR\"")
        )
    }

    func testLegacyLowercaseErrorAliasDecodesCentrally()
        throws
    {
        let data = Data(
            """
            {
              "code": "invalid_json",
              "message": "Legacy response.",
              "requestID": "00000000-0000-0000-0000-000000000009"
            }
            """.utf8
        )

        let decoded = try SlowWalkJSONCoding.makeDecoder()
            .decode(APIErrorDTO.self, from: data)

        XCTAssertEqual(decoded.code, .malformedRequest)
        XCTAssertEqual(
            decoded.code.rawValue,
            "MALFORMED_REQUEST"
        )
    }

    func testEveryAPIErrorCodeIsCanonicalUpperSnakeCase() {
        XCTAssertFalse(APIErrorCode.allCases.isEmpty)
        for code in APIErrorCode.allCases {
            XCTAssertEqual(
                code.rawValue,
                code.rawValue.uppercased()
            )
            XCTAssertNotNil(
                code.rawValue.range(
                    of: #"^[A-Z][A-Z0-9_]*$"#,
                    options: .regularExpression
                )
            )
        }
    }

    func testEndpointErrorCodeSnapshots() {
        let snapshots: [
            SlowWalkAPI.Endpoint: [String]
        ] = [
            .medicineSearch: [
                "UNSUPPORTED_MEDIA_TYPE",
                "MALFORMED_REQUEST",
                "UNSUPPORTED_API_VERSION",
                "VALIDATION_ERROR",
                "KNOWLEDGE_SOURCE_UNAVAILABLE",
                "KNOWLEDGE_SOURCE_TIMEOUT",
                "INVALID_SOURCE_RESPONSE",
                "SOURCE_VERSION_UNSUPPORTED",
                "MEDICINE_NOT_FOUND",
                "SOURCE_CONFLICT",
                "OFFLINE_CACHE_UNAVAILABLE",
            ],
            .medicineResolve: [
                "UNSUPPORTED_MEDIA_TYPE",
                "MALFORMED_REQUEST",
                "UNSUPPORTED_API_VERSION",
                "VALIDATION_ERROR",
                "KNOWLEDGE_SOURCE_UNAVAILABLE",
                "KNOWLEDGE_SOURCE_TIMEOUT",
                "INVALID_SOURCE_RESPONSE",
                "SOURCE_VERSION_UNSUPPORTED",
                "MEDICINE_NOT_FOUND",
                "SOURCE_CONFLICT",
                "OFFLINE_CACHE_UNAVAILABLE",
                "MEDICINE_AMBIGUOUS",
                "MEDICINE_RECOGNITION_FAILED",
                "MEDICINE_INSUFFICIENT_EVIDENCE",
                "INTERNAL_ERROR",
            ],
            .medicineRecognize: [
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
            ],
            .medicineAssess: [
                "UNSUPPORTED_MEDIA_TYPE",
                "MALFORMED_REQUEST",
                "UNSUPPORTED_API_VERSION",
                "VALIDATION_ERROR",
                "KNOWLEDGE_SOURCE_UNAVAILABLE",
                "KNOWLEDGE_SOURCE_TIMEOUT",
                "INVALID_SOURCE_RESPONSE",
                "SOURCE_VERSION_UNSUPPORTED",
                "MEDICINE_NOT_FOUND",
                "SOURCE_CONFLICT",
                "OFFLINE_CACHE_UNAVAILABLE",
                "INVALID_USER_PROFILE",
                "UNSUPPORTED_PROFILE_SCHEMA",
                "INVALID_MEDICATION_RECORD",
                "FUTURE_MEDICATION_RECORD",
                "INVALID_BODY_METRICS",
                "INTERNAL_ERROR",
            ],
            .locationAssess: [
                "UNSUPPORTED_MEDIA_TYPE",
                "MALFORMED_REQUEST",
                "UNSUPPORTED_API_VERSION",
                "VALIDATION_ERROR",
                "INVALID_LOCATION_SAMPLE",
                "LOCATION_DATA_STALE",
                "LOCATION_ACCURACY_INSUFFICIENT",
                "INSUFFICIENT_LOCATION_HISTORY",
            ],
        ]

        for endpoint in SlowWalkAPI.Endpoint.allCases {
            XCTAssertEqual(
                endpoint.errorCodes.map(\.rawValue),
                snapshots[endpoint] ?? []
            )
        }
    }

    private func makeRequest()
        -> MedicineAssessmentRequestDTO
    {
        MedicineAssessmentRequestDTO(
            input: MedicineRecognitionInput(
                recognizedTexts: ["Demo Medicine"],
                capturedAt: timestamp,
                languageCode: "en",
                rawConfidence: 0.99
            ),
            userProfile: UserHealthProfileDTO(
                id: fixedUUID(lastByte: 1),
                age: 70,
                allergies: [],
                diagnosedConditions: [],
                currentMedicineIngredientIDs: [],
                bodyMetrics: BodyMetricsDTO(
                    systolicBloodPressure: 120,
                    diastolicBloodPressure: 80,
                    heartRate: 70,
                    measuredAt: timestamp,
                    source: "demo_data",
                    deviceIdentifier: nil
                ),
                createdAt: timestamp,
                updatedAt: timestamp,
                schemaVersion: 1
            ),
            recentRecords: [],
            requestID: fixedUUID(lastByte: 3),
            apiVersion: SlowWalkAPI.version
        )
    }

    private func fixedUUID(lastByte: UInt8) -> UUID {
        UUID(
            uuid: (
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, lastByte
            )
        )
    }
}

private struct DateBox: Codable {
    let date: Date
}
