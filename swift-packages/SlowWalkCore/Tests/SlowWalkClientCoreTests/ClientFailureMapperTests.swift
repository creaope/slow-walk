import Foundation
import SlowWalkAPIContracts
import SlowWalkClientCore
import XCTest

final class ClientFailureMapperTests: XCTestCase {
    func testProviderRecognitionErrorsAreRecoverable() {
        let recoverableCodes: [APIErrorCode] = [
            .providerRateLimited,
            .providerUnavailable,
            .providerTimeout,
            .invalidProviderResponse,
        ]

        for code in recoverableCodes {
            let failure = ClientFailureMapper.map(
                ClientAPIError(error: makeAPIError(code: code))
            )

            XCTAssertEqual(failure.apiErrorCode, code)
            XCTAssertEqual(failure.requestID, requestID)
            XCTAssertTrue(failure.isRecoverable)
        }
    }

    func testProviderTimeoutUsesTimeoutFailureKind() {
        let failure = ClientFailureMapper.map(
            ClientAPIError(
                error: makeAPIError(code: .providerTimeout)
            )
        )

        XCTAssertEqual(failure.kind, .timeout)
        XCTAssertTrue(failure.isRecoverable)
    }

    func testRecognitionRequestSizeErrorsAreNotRecoverable() {
        for code in [
            APIErrorCode.requestBodyTooLarge,
            .imageTooLarge,
        ] {
            let failure = ClientFailureMapper.map(
                ClientAPIError(error: makeAPIError(code: code))
            )

            XCTAssertEqual(failure.kind, .api)
            XCTAssertEqual(failure.apiErrorCode, code)
            XCTAssertFalse(failure.isRecoverable)
        }
    }

    func testMalformedServerResponseRemainsNonRecoverable() {
        let failure = ClientFailureMapper.map(
            ClientTransportError.malformedResponse
        )

        XCTAssertEqual(failure.kind, .malformedResponse)
        XCTAssertNil(failure.apiErrorCode)
        XCTAssertFalse(failure.isRecoverable)
    }

    private func makeAPIError(code: APIErrorCode) -> APIErrorDTO {
        APIErrorDTO(
            code: code,
            message: "Safe summary.",
            requestID: requestID,
            details: nil
        )
    }

    private var requestID: UUID {
        UUID(
            uuidString:
                "00000000-0000-0000-0000-000000000202"
        )!
    }
}
