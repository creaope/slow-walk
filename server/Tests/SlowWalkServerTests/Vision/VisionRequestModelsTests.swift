import Foundation
@testable import SlowWalkServer
import XCTest

final class VisionRequestModelsTests:
    XCTestCase,
    @unchecked Sendable
{
    /// A distinctive literal so a leak is unambiguous wherever it surfaces.
    private let secret = "sk-test-LEAK-CANARY-0123456789"

    private func makeConfiguration(
        maxImageBytes: Int = 4_096
    ) throws -> VisionProviderConfiguration {
        try VisionProviderConfiguration(
            providerIdentifier: "example",
            baseURL: URL(
                string: "https://vision.example.com/v1"
            )!,
            model: "vision-model",
            requestTimeout: 20,
            maxImageBytes: maxImageBytes
        )
    }

    private func makeImage() -> VisionImagePayload {
        VisionImagePayload(
            data: Data([0xFF, 0xD8, 0xFF, 0xE0]),
            mimeType: "  IMAGE/JPEG  "
        )
    }

    // MARK: - Credential redaction

    func testCredentialDescriptionsDoNotContainKey() {
        let credential = VisionCredential(apiKey: secret)

        for rendering in [
            credential.description,
            credential.debugDescription,
            String(describing: credential),
            String(reflecting: credential),
            "\(credential)",
        ] {
            XCTAssertFalse(rendering.contains(secret))
            XCTAssertEqual(
                rendering,
                VisionCredential.redactionMarker
            )
        }
    }

    func testCredentialMirrorDoesNotExposeKey() {
        let credential = VisionCredential(apiKey: secret)

        // `dump(_:)` and similar diagnostics walk the mirror, so the mirror is
        // a real leak path and not merely decorative.
        var dumped = String()
        dump(credential, to: &dumped)
        XCTAssertFalse(dumped.contains(secret))

        let children = Mirror(reflecting: credential).children
        XCTAssertEqual(children.count, 1)
        for child in children {
            XCTAssertEqual(
                child.value as? String,
                VisionCredential.redactionMarker
            )
        }
    }

    func testCredentialHeaderValueIsBearerScheme() {
        let credential = VisionCredential(apiKey: secret)

        XCTAssertEqual(
            credential.headerValue,
            "Bearer \(secret)"
        )
    }

    // MARK: - Request construction

    private func makeRequest() throws -> VisionTransportRequest {

        try VisionTransportRequest.chatCompletion(
            configuration: makeConfiguration(),
            image: makeImage(),
            credential: VisionCredential(apiKey: secret)
        )
    }

    func testRequestDescriptionsAndDumpDoNotLeakSecret() throws {
        let request = try makeRequest()
        var dumped = String()
        dump(request, to: &dumped)
        for rendering in [
            request.description,
            request.debugDescription,
            String(describing: request),
            String(reflecting: request),
            "\(request)",
            dumped,
        ] {
            XCTAssertFalse(rendering.contains(secret)
                || rendering.lowercased().contains("bearer"), rendering)
        }
    }

    func testRequestMirrorRedactsAuthorizationButRetainsRealValue() throws {
        let request = try makeRequest()
        let children = Mirror(reflecting: request).children
        for child in children {
            XCTAssertFalse(String(describing: child.value).contains(secret))
        }
        let headers = children.first { $0.label == "headers" }?.value
            as? [String: String]
        XCTAssertEqual(
            headers?[VisionTransportRequest.authorizationHeaderName],
            VisionTransportRequest.redactionMarker
        )
        XCTAssertEqual(headers?["Content-Type"], "application/json")
        XCTAssertEqual(
            request.headers[
                VisionTransportRequest.authorizationHeaderName
            ],
            "Bearer \(secret)"
        )
    }

    func testAuthorizationHeaderIsSetAtCallerBoundary() throws {
        let request = try VisionTransportRequest.chatCompletion(
            configuration: makeConfiguration(),
            image: makeImage(),
            credential: VisionCredential(apiKey: secret)
        )

        XCTAssertEqual(
            request.headers[
                VisionTransportRequest
                    .authorizationHeaderName
            ],
            "Bearer \(secret)"
        )
        XCTAssertEqual(
            request.headers["Content-Type"],
            "application/json"
        )
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(
            request.url.absoluteString,
            "https://vision.example.com/v1/chat/completions"
        )
        XCTAssertEqual(request.timeout, 20)
    }

    /// The key must reach exactly one place. If it ever appears in the body,
    /// it would be persisted by any provider that logs request payloads.
    func testKeyDoesNotAppearInRequestBody() throws {
        let request = try VisionTransportRequest.chatCompletion(
            configuration: makeConfiguration(),
            image: makeImage(),
            credential: VisionCredential(apiKey: secret)
        )

        let bodyText = String(
            decoding: request.body,
            as: UTF8.self
        )
        XCTAssertFalse(bodyText.contains(secret))
        XCTAssertFalse(bodyText.lowercased().contains("bearer"))
        XCTAssertFalse(
            bodyText.lowercased().contains("authorization")
        )

        let headersExceptAuthorization = request.headers
            .filter {
                $0.key != VisionTransportRequest
                    .authorizationHeaderName
            }
        for value in headersExceptAuthorization.values {
            XCTAssertFalse(value.contains(secret))
        }
    }

    func testImagePayloadNormalizesMimeTypeAndEncodesDataURI() {
        let image = makeImage()

        XCTAssertEqual(image.mimeType, "image/jpeg")
        XCTAssertEqual(
            image.dataURIString,
            "data:image/jpeg;base64,/9j/4A=="
        )
    }

    // MARK: - Request-level image boundaries

    func testChatCompletionAcceptsValidImages() throws {
        _ = try VisionTransportRequest.chatCompletion(
            configuration: makeConfiguration(maxImageBytes: 4_096),
            image: VisionImagePayload(
                data: Data([0x89, 0x50, 0x4E, 0x47]),
                mimeType: "Image/PNG"
            ),
            credential: VisionCredential(apiKey: secret)
        )
        _ = try VisionTransportRequest.chatCompletion(
            configuration: makeConfiguration(maxImageBytes: 4_096),
            image: VisionImagePayload(
                data: Data(repeating: 0xFF, count: 4_096),
                mimeType: "image/jpeg"
            ),
            credential: VisionCredential(apiKey: secret)
        )
    }

    func testChatCompletionRejectsInvalidImagesWithoutLeaking() {
        let cases: [(VisionImagePayload, VisionRequestError)] = [
            (VisionImagePayload(
                data: Data([0x00, 0x01]), mimeType: "image/gif"),
             .unsupportedMimeType(mimeType: "image/gif")),
            (VisionImagePayload(
                data: Data(repeating: 0xAB, count: 4_097),
                mimeType: "image/jpeg"),
             .imageTooLarge(byteCount: 4_097, maxImageBytes: 4_096)),
            (VisionImagePayload(
                data: Data(), mimeType: "image/png"),
             .emptyImageData),
        ]
        for (image, expected) in cases {
            XCTAssertThrowsError(
                try VisionTransportRequest.chatCompletion(
                    configuration: makeConfiguration(maxImageBytes: 4_096),
                    image: image,
                    credential: VisionCredential(apiKey: secret)
                )
            ) { error in
                XCTAssertEqual(error as? VisionRequestError, expected, "\(error)")
                let rendering = "\(error)"
                XCTAssertFalse(rendering.contains(secret) || rendering.contains("0xAB"))
            }
        }
    }

    func testRequestBodyCarriesModelAndInlineImage() throws {
        let request = try VisionTransportRequest.chatCompletion(
            configuration: makeConfiguration(),
            image: makeImage(),
            credential: VisionCredential(apiKey: secret)
        )

        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: request.body
            ) as? [String: Any]
        )
        XCTAssertEqual(json["model"] as? String, "vision-model")
        XCTAssertEqual(json["temperature"] as? Double, 0)
        let responseFormat = json["response_format"]
            as? [String: Any]
        XCTAssertEqual(
            responseFormat?["type"] as? String,
            "json_object"
        )

        let messages = try XCTUnwrap(
            json["messages"] as? [[String: Any]]
        )
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        let parts = try XCTUnwrap(
            messages[0]["content"] as? [[String: Any]]
        )
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0]["type"] as? String, "text")
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        let imageURL = parts[1]["image_url"] as? [String: Any]
        XCTAssertEqual(
            imageURL?["url"] as? String,
            "data:image/jpeg;base64,/9j/4A=="
        )
    }

    /// The instruction must not invite a clinical reading, or a compliant
    /// provider would return conclusions this gateway is not allowed to carry.
    ///
    /// The expected keys are spelled out here rather than read from a shared
    /// constant: this asserts the wire contract the provider is asked for, and
    /// it should fail if that contract silently changes.
    func testInstructionForbidsMedicalInterpretation() {
        let instruction = VisionChatCompletionRequestBody
            .instruction
            .lowercased()

        for allowedKey in ["visibletexts", "imagereadable",
                           "uncertainregionspresent"] {
            XCTAssertTrue(
                instruction.contains(allowedKey),
                allowedKey
            )
        }
        for forbidden in ["diagnose", "risk", "recommend",
                          "infer"] {
            XCTAssertTrue(
                instruction.contains(forbidden),
                forbidden
            )
        }
        for forbiddenField in ["medicine", "safetotake", "dose"] {
            XCTAssertFalse(
                instruction.contains(forbiddenField),
                forbiddenField
            )
        }
    }
}
