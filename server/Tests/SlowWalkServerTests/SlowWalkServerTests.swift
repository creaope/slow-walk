import Foundation
import Hummingbird
import HummingbirdTesting
import SlowWalkAPIContracts
import SlowWalkDataInterfaces
@testable import SlowWalkServer
import XCTest

final class SlowWalkServerTests:
    XCTestCase,
    @unchecked Sendable
{
    private let now = Date(
        timeIntervalSince1970: 1_735_689_600
    )

    func testHealthReturnsContractJSON() async throws {
        let application = try makeTestApplication()

        try await application.test(.router) { client in
            try await client.execute(
                uri: "/health",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(
                    response.headers[.contentType],
                    "application/json; charset=utf-8"
                )
                let health = try self.decode(
                    HealthResponseDTO.self,
                    from: response.body
                )
                XCTAssertEqual(
                    health,
                    HealthResponseDTO(
                        status: "ok",
                        service: "slow-walk-server",
                        apiVersion: SlowWalkAPI.version
                    )
                )
            }
        }
    }

    func testRawRiskRouteIsNotRegisteredForForgedMedicine()
        async throws
    {
        let application = try makeTestApplication()
        let forgedPayload = ByteBuffer(
            string:
                """
                {
                  "medicine": {
                    "id": "forged",
                    "activeIngredientIDs": [],
                    "sourceReferences": [{
                      "sourceName": "forged",
                      "documentTitle": "forged",
                      "retrievedAt": "2025-01-01T00:00:00Z",
                      "versionOrDate": "forged"
                    }]
                  }
                }
                """
        )

        try await application.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/risk/assess",
                method: .post,
                headers: [
                    .contentType: "application/json",
                ],
                body: forgedPayload
            ) { response in
                XCTAssertEqual(response.status, .notFound)
                let body = String(
                    decoding:
                        response.body.readableBytesView,
                    as: UTF8.self
                )
                XCTAssertFalse(body.contains("\"green\""))
                XCTAssertFalse(
                    body.contains("sourceReferences")
                )
            }
        }
    }

    func testCanonicalRoutesExcludeRawRiskPath() {
        let paths = SlowWalkAPI.Endpoint.allCases
            .map(\.path)

        XCTAssertEqual(Set(paths).count, 5)
        XCTAssertTrue(
            paths.allSatisfy {
                $0.hasPrefix(
                    SlowWalkAPI.routePrefix + "/"
                )
            }
        )
        XCTAssertFalse(
            paths.contains("/api/v1/risk/assess")
        )
    }

    func testEveryPOSTEndpointUsesCanonicalMediaTypeError()
        async throws
    {
        let application = try makeTestApplication()

        try await application.test(.router) { client in
            for endpoint in SlowWalkAPI.Endpoint.allCases {
                try await client.execute(
                    uri: endpoint.path,
                    method: .post,
                    body: ByteBuffer(string: "{}")
                ) { response in
                    XCTAssertEqual(
                        response.status,
                        .badRequest,
                        endpoint.path
                    )
                    let error = try self.decode(
                        APIErrorDTO.self,
                        from: response.body
                    )
                    XCTAssertEqual(
                        error.code,
                        .unsupportedMediaType,
                        endpoint.path
                    )
                    XCTAssertEqual(
                        error.code.rawValue,
                        "UNSUPPORTED_MEDIA_TYPE"
                    )
                    XCTAssertEqual(
                        error.requestID,
                        self.fallbackRequestID
                    )
                }
            }
        }
    }

    func testPathAndBodyVersionMappingIsCentralized() {
        for endpoint in SlowWalkAPI.Endpoint.allCases {
            XCTAssertTrue(
                SlowWalkAPI.supports(
                    bodyVersion: SlowWalkAPI.version,
                    for: endpoint
                )
            )
            XCTAssertFalse(
                SlowWalkAPI.supports(
                    bodyVersion: "v999",
                    for: endpoint
                )
            )
            XCTAssertEqual(
                endpoint.path,
                SlowWalkAPI.routePrefix
                    + endpoint.rawValue
            )
        }
    }

    private func makeTestApplication()
        throws -> some ApplicationProtocol
    {
        try makeSlowWalkApplication(
            configuration: .init(port: 0),
            dateProvider: FixedDateProvider(
                fixedDate: now
            ),
            uuidProvider: FixedUUIDProvider(
                fixedUUID: fallbackRequestID
            )
        )
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from buffer: ByteBuffer
    ) throws -> Value {
        try SlowWalkJSONCoding.makeDecoder().decode(
            type,
            from: Data(buffer.readableBytesView)
        )
    }

    private var fallbackRequestID: UUID {
        UUID(
            uuid: (
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 99
            )
        )
    }
}
