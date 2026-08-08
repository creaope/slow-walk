import Foundation
@testable import SlowWalkServer
import XCTest

final class ZhipuVisionRuntimeConfigurationTests:
    XCTestCase,
    @unchecked Sendable
{
    private enum TestError: Error {
        case keychainShouldNotBeRead
    }

    private let secret = "zhipu-test-LEAK-CANARY-9876543210"

    private func environment(
        _ overrides: [String: String] = [:]
    ) -> [String: String] {
        [ZhipuVisionRuntimeConfiguration.apiKeyEnvironmentKey: secret]
            .merging(overrides) { _, override in override }
    }

    private func load(
        environment: [String: String],
        keychainAPIKey: String? = nil
    ) throws -> ZhipuVisionRuntimeConfiguration {
        try ZhipuVisionRuntimeConfiguration.load(
            environment: environment,
            keychainAPIKey: { keychainAPIKey }
        )
    }

    func testMissingKeyReturnsClearConfigurationError() {
        XCTAssertThrowsError(try load(environment: [:])) { error in
            XCTAssertEqual(
                error as? ZhipuVisionRuntimeConfigurationError,
                .apiKeyMissing
            )
            let message = String(describing: error)
            XCTAssertTrue(message.contains("ZHIPU_API_KEY"), message)
            XCTAssertTrue(message.contains("Keychain"), message)
        }
    }

    func testEmptyEnvironmentKeyIsRejectedWithoutKeychainFallback() {
        XCTAssertThrowsError(
            try ZhipuVisionRuntimeConfiguration.load(
                environment: [
                    ZhipuVisionRuntimeConfiguration
                        .apiKeyEnvironmentKey: "  \n  ",
                ],
                keychainAPIKey: {
                    throw TestError.keychainShouldNotBeRead
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? ZhipuVisionRuntimeConfigurationError,
                .apiKeyEmpty
            )
        }
    }

    func testEmptyKeychainKeyIsRejected() {
        XCTAssertThrowsError(
            try load(environment: [:], keychainAPIKey: " \t ")
        ) { error in
            XCTAssertEqual(
                error as? ZhipuVisionRuntimeConfigurationError,
                .apiKeyEmpty
            )
        }
    }

    func testKeychainSuppliesKeyWhenEnvironmentKeyIsAbsent() throws {
        let configuration = try load(
            environment: [:],
            keychainAPIKey: secret
        )

        XCTAssertEqual(
            configuration.credential.headerValue,
            "Bearer \(secret)"
        )
    }

    func testDefaultPrimaryAndFallbackModels() throws {
        let configuration = try load(environment: environment())

        XCTAssertEqual(
            configuration.primary.model,
            "glm-4.6v"
        )
        XCTAssertEqual(
            configuration.fallback.model,
            "glm-4.6v-flash"
        )
    }

    func testExplicitPrimaryModel() throws {
        let configuration = try load(
            environment: environment([
                ZhipuVisionRuntimeConfiguration
                    .primaryModelEnvironmentKey:
                    "  custom-primary-vision  ",
            ])
        )

        XCTAssertEqual(
            configuration.primary.model,
            "custom-primary-vision"
        )
    }

    func testExplicitFallbackModel() throws {
        let configuration = try load(
            environment: environment([
                ZhipuVisionRuntimeConfiguration
                    .fallbackModelEnvironmentKey:
                    "custom-fallback-vision",
            ])
        )

        XCTAssertEqual(
            configuration.fallback.model,
            "custom-fallback-vision"
        )
    }

    func testDefaultBaseURL() throws {
        let configuration = try load(environment: environment())

        XCTAssertEqual(
            configuration.primary.baseURL.absoluteString,
            "https://open.bigmodel.cn/api/paas/v4"
        )
        XCTAssertEqual(
            configuration.fallback.baseURL,
            configuration.primary.baseURL
        )
    }

    func testExplicitHTTPSBaseURL() throws {
        let configuration = try load(
            environment: environment([
                ZhipuVisionRuntimeConfiguration
                    .baseURLEnvironmentKey:
                    "  https://vision.example.com/openai/v4  ",
            ])
        )

        XCTAssertEqual(
            configuration.primary.baseURL.absoluteString,
            "https://vision.example.com/openai/v4"
        )
    }

    func testNonHTTPSBaseURLIsRejected() {
        XCTAssertThrowsError(
            try load(
                environment: environment([
                    ZhipuVisionRuntimeConfiguration
                        .baseURLEnvironmentKey:
                        "http://open.bigmodel.cn/api/paas/v4",
                ])
            )
        ) { error in
            XCTAssertEqual(
                error as? VisionConfigurationError,
                .baseURLNotHTTPS
            )
        }
    }

    func testRuntimeLoggingAndReflectionDoNotLeakKey() throws {
        let configuration = try load(environment: environment())
        var dumped = String()
        dump(configuration, to: &dumped)
        let mirrorValues = Mirror(reflecting: configuration)
            .children
            .map { String(reflecting: $0.value) }
            .joined(separator: " ")
        let simulatedLogLine = "Loaded \(configuration)"

        for rendering in [
            configuration.description,
            configuration.debugDescription,
            String(describing: configuration),
            String(reflecting: configuration),
            simulatedLogLine,
            mirrorValues,
            dumped,
        ] {
            XCTAssertFalse(rendering.contains(secret), rendering)
            XCTAssertFalse(
                rendering.lowercased().contains("bearer"),
                rendering
            )
        }
        XCTAssertTrue(
            configuration.description.contains(
                VisionCredential.redactionMarker
            )
        )
    }

    func testConfigurationErrorsDoNotContainKey() {
        XCTAssertThrowsError(
            try load(
                environment: environment([
                    ZhipuVisionRuntimeConfiguration
                        .primaryModelEnvironmentKey: "  ",
                ])
            )
        ) { error in
            var dumped = String()
            dump(error, to: &dumped)
            for rendering in [
                String(describing: error),
                String(reflecting: error),
                (error as NSError).localizedDescription,
                dumped,
            ] {
                XCTAssertFalse(rendering.contains(secret), rendering)
            }
        }
    }

    func testLoadedValuesBuildExistingTransportRequest() throws {
        let configuration = try load(environment: environment())
        let request = try VisionTransportRequest.chatCompletion(
            configuration: configuration.primary,
            image: VisionImagePayload(
                data: Data([0x89, 0x50, 0x4E, 0x47]),
                mimeType: "image/png"
            ),
            credential: configuration.credential
        )
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: request.body)
                as? [String: Any]
        )

        XCTAssertEqual(
            request.url.absoluteString,
            "https://open.bigmodel.cn/api/paas/v4/chat/completions"
        )
        XCTAssertEqual(body["model"] as? String, "glm-4.6v")
    }
}
