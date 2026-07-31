import Foundation
@testable import SlowWalkServer
import XCTest

final class VisionProviderConfigurationTests:
    XCTestCase,
    @unchecked Sendable
{
    private let validBaseURL = URL(
        string: "https://vision.example.com/v1"
    )!

    func testValidConfigurationNormalizesInputs() throws {
        let configuration = try VisionProviderConfiguration(
            providerIdentifier: "  example-vision  ",
            baseURL: validBaseURL,
            model: "  vision-model  ",
            requestTimeout: 12,
            maxImageBytes: 2_048,
            maxAttempts: 3,
            allowedMimeTypes: ["  IMAGE/JPEG  ", "image/png", ""]
        )

        XCTAssertEqual(
            configuration.providerIdentifier,
            "example-vision"
        )
        XCTAssertEqual(configuration.model, "vision-model")
        XCTAssertEqual(configuration.requestTimeout, 12)
        XCTAssertEqual(configuration.maxImageBytes, 2_048)
        XCTAssertEqual(configuration.maxAttempts, 3)
        XCTAssertEqual(
            configuration.allowedMimeTypes,
            ["image/jpeg", "image/png"]
        )
    }

    func testDefaultsAllowAtMostTwoRetries() throws {
        let configuration = try VisionProviderConfiguration(
            providerIdentifier: "example",
            baseURL: validBaseURL,
            model: "vision-model"
        )

        // One initial attempt plus at most two retries.
        XCTAssertEqual(configuration.maxAttempts, 3)
        XCTAssertEqual(
            VisionProviderConfiguration
                .maximumSupportedAttempts,
            3
        )
    }

    func testNonHTTPSBaseURLIsRejected() {
        assertThrows(.baseURLNotHTTPS) {
            try VisionProviderConfiguration(
                providerIdentifier: "example",
                baseURL: URL(
                    string: "http://vision.example.com/v1"
                )!,
                model: "vision-model"
            )
        }
    }

    func testBaseURLWithoutHostIsRejected() {
        assertThrows(.baseURLNotHTTPS) {
            try VisionProviderConfiguration(
                providerIdentifier: "example",
                baseURL: URL(string: "https:///v1")!,
                model: "vision-model"
            )
        }
    }

    func testBlankProviderIdentifierIsRejected() {
        assertThrows(.providerIdentifierEmpty) {
            try VisionProviderConfiguration(
                providerIdentifier: "   ",
                baseURL: validBaseURL,
                model: "vision-model"
            )
        }
    }

    func testBlankModelIsRejected() {
        assertThrows(.modelEmpty) {
            try VisionProviderConfiguration(
                providerIdentifier: "example",
                baseURL: validBaseURL,
                model: "  "
            )
        }
    }

    func testNonPositiveOrNonFiniteTimeoutIsRejected() {
        for timeout in [0, -1, TimeInterval.infinity,
                        TimeInterval.nan] {
            assertThrows(.requestTimeoutOutOfRange) {
                try VisionProviderConfiguration(
                    providerIdentifier: "example",
                    baseURL: self.validBaseURL,
                    model: "vision-model",
                    requestTimeout: timeout
                )
            }
        }
    }

    func testNonPositiveMaxImageBytesIsRejected() {
        for byteCount in [0, -1] {
            assertThrows(.maxImageBytesOutOfRange) {
                try VisionProviderConfiguration(
                    providerIdentifier: "example",
                    baseURL: self.validBaseURL,
                    model: "vision-model",
                    maxImageBytes: byteCount
                )
            }
        }
    }

    func testOutOfRangeMaxAttemptsIsRejected() {
        // Zero attempts would never call, and four would exceed the two-retry
        // ceiling this gateway is allowed to spend.
        for attempts in [0, -1, 4, 10] {
            assertThrows(.maxAttemptsOutOfRange) {
                try VisionProviderConfiguration(
                    providerIdentifier: "example",
                    baseURL: self.validBaseURL,
                    model: "vision-model",
                    maxAttempts: attempts
                )
            }
        }
    }

    func testEmptyAllowedMimeTypesIsRejected() {
        assertThrows(.allowedMimeTypesEmpty) {
            try VisionProviderConfiguration(
                providerIdentifier: "example",
                baseURL: self.validBaseURL,
                model: "vision-model",
                allowedMimeTypes: ["  ", ""]
            )
        }
    }

    func testMimeTypeAndByteCountGates() throws {
        let configuration = try VisionProviderConfiguration(
            providerIdentifier: "example",
            baseURL: validBaseURL,
            model: "vision-model",
            maxImageBytes: 1_000,
            allowedMimeTypes: ["image/jpeg"]
        )

        XCTAssertTrue(
            configuration.allowsMimeType("  IMAGE/JPEG ")
        )
        XCTAssertFalse(
            configuration.allowsMimeType("image/gif")
        )
        XCTAssertFalse(
            configuration.allowsMimeType("application/pdf")
        )
        XCTAssertTrue(configuration.allowsByteCount(1_000))
        XCTAssertFalse(configuration.allowsByteCount(1_001))
    }

    /// No stored property may hold a credential: a configuration is a value
    /// that gets logged and compared, so a key must not be able to reach one.
    func testConfigurationHasNoCredentialCarryingProperty() throws {
        let configuration = try VisionProviderConfiguration(
            providerIdentifier: "example",
            baseURL: validBaseURL,
            model: "vision-model"
        )

        let propertyNames = Mirror(reflecting: configuration)
            .children
            .compactMap(\.label)
        for name in propertyNames {
            let lowered = name.lowercased()
            XCTAssertFalse(lowered.contains("key"), name)
            XCTAssertFalse(lowered.contains("secret"), name)
            XCTAssertFalse(lowered.contains("token"), name)
            XCTAssertFalse(
                lowered.contains("credential"),
                name
            )
        }
    }

    private func assertThrows(
        _ expected: VisionConfigurationError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> VisionProviderConfiguration
    ) {
        do {
            _ = try body()
            XCTFail(
                "Expected \(expected)",
                file: file,
                line: line
            )
        } catch let error as VisionConfigurationError {
            XCTAssertEqual(
                error,
                expected,
                file: file,
                line: line
            )
        } catch {
            XCTFail(
                "Unexpected error: \(error)",
                file: file,
                line: line
            )
        }
    }
}
