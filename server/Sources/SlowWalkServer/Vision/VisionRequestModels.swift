import Foundation

/// A runtime-injected provider credential.
///
/// The secret is reachable only through ``headerValue``, at the single point
/// where the outgoing `Authorization` header is built. Every description
/// channel is overridden so that logging, string interpolation, `dump(_:)`, and
/// test snapshots print a redaction marker instead of the secret. The type is
/// intentionally neither `Codable` nor `Equatable`, so it cannot be encoded
/// into a request body or compared against a literal in a snapshot.
struct VisionCredential:
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    static let redactionMarker = "[REDACTED]"

    private let secret: String

    init(apiKey: String) {
        secret = apiKey
    }

    /// The `Authorization` header value. This is the only read path.
    var headerValue: String {
        "Bearer \(secret)"
    }

    var description: String {
        Self.redactionMarker
    }

    var debugDescription: String {
        Self.redactionMarker
    }

    var customMirror: Mirror {
        Mirror(
            self,
            children: ["secret": Self.redactionMarker],
            displayStyle: .struct
        )
    }
}

/// One inline image to be inspected for visible text.
struct VisionImagePayload:
    Sendable,
    Equatable
{
    let data: Data
    /// Normalised to lowercase without surrounding whitespace on init, so
    /// comparisons against a configuration's allowed set are stable.
    let mimeType: String

    init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// RFC 2397 data URI, the form OpenAI-compatible providers accept for
    /// inline images.
    var dataURIString: String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }
}

// MARK: - OpenAI-compatible request body

/// Encodable mirror of the OpenAI-compatible chat-completions request used to
/// ask a provider for one of the gateway's bounded visual-evidence contracts.
struct VisionChatCompletionRequestBody: Encodable, Sendable {
    struct ImageURL: Encodable, Sendable {
        let url: String
    }

    enum ContentPart: Encodable, Sendable {
        case text(String)
        case imageURL(ImageURL)

        private enum CodingKeys: String, CodingKey {
            case type
            case text
            case imageURL = "image_url"
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(
                keyedBy: CodingKeys.self
            )
            switch self {
            case .text(let value):
                try container.encode("text", forKey: .type)
                try container.encode(value, forKey: .text)
            case .imageURL(let value):
                try container.encode("image_url", forKey: .type)
                try container.encode(value, forKey: .imageURL)
            }
        }
    }

    struct Message: Encodable, Sendable {
        let role: String
        let content: [ContentPart]
    }

    struct ResponseFormat: Encodable, Sendable {
        let type: String
    }

    let model: String
    let messages: [Message]
    let responseFormat: ResponseFormat
    let temperature: Double

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case responseFormat = "response_format"
        case temperature
    }

    /// Instruction text constraining the provider to transcription of visible
    /// text, with no medical interpretation of any kind.
    static let instruction = """
        Transcribe only the text that is literally visible in the image. \
        Reply with a single JSON object containing exactly these keys: \
        "visibleTexts" (array of strings, verbatim visible text runs), \
        "imageReadable" (boolean), and \
        "uncertainRegionsPresent" (boolean). \
        Do not identify products, do not infer, summarise, translate, \
        diagnose, assess risk, or recommend anything. \
        Add no other keys and no prose outside the JSON object.
        """

    /// Evidence-only contract used for medicine package inspection. Product
    /// and generic names remain search clues; the provider must never select a
    /// canonical medicine or make a clinical judgement.
    static let medicinePackageEvidenceInstruction = """
        Inspect only the visible medicine packaging in this image. Reply with \
        one complete JSON object and no Markdown, code fence, or surrounding \
        prose. The object must contain exactly these keys: \
        "visibleTexts", "probableProductNames", "probableGenericNames", \
        "manufacturerNames", "approvalIdentifiers", "dosageFormTexts", \
        "packagingFeatures", and "searchQueries" as arrays of strings; and \
        "imageReadable" and "uncertainRegionsPresent" as booleans. Preserve \
        literally visible text in "visibleTexts". Put only visually supported \
        packaging evidence or bounded catalog-search clues in the other \
        arrays. Product and generic names are hypotheses, not canonical facts. \
        Use empty arrays when no evidence is present. Do not return a canonical \
        medicine ID, selected medicine, risk level, diagnosis, dosage or \
        frequency advice, treatment duration, stop-medication advice, \
        safe-to-take judgement, action card, or user health judgement. Add no \
        other keys.
        """

    init(
        model: String,
        image: VisionImagePayload,
        instruction: String = Self.instruction
    ) {
        self.model = model
        messages = [
            Message(
                role: "user",
                content: [
                    .text(instruction),
                    .imageURL(
                        ImageURL(url: image.dataURIString)
                    ),
                ]
            ),
        ]
        responseFormat = ResponseFormat(type: "json_object")
        temperature = 0
    }
}

// MARK: - Minimal request contract

/// Request-construction failures raised before any network access;
/// associated values carry no image data or credential.
enum VisionRequestError:
    Error,
    Sendable,
    Equatable
{
    case unsupportedMimeType(mimeType: String)
    case imageTooLarge(byteCount: Int, maxImageBytes: Int)
    case emptyImageData
}

/// A single outgoing HTTP exchange, described but never performed. Nothing in
/// this module sends it, so there is no networking dependency here. The real
/// `Authorization` header lives in ``headers`` for a downstream Transport, but
/// every description channel redacts it. Not `Equatable` (no production use).
struct VisionTransportRequest:
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    static let authorizationHeaderName = "Authorization"
    static let redactionMarker = "[REDACTED]"

    let url: URL
    let method: String
    let headers: [String: String]
    let body: Data
    let timeout: TimeInterval

    init(
        url: URL,
        method: String = "POST",
        headers: [String: String],
        body: Data,
        timeout: TimeInterval
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    private var redactedHeaders: [String: String] {
        Dictionary(uniqueKeysWithValues: headers.map { name, value in
            (name, Self.isAuthorizationHeader(name) ? Self.redactionMarker : value)
        })
    }

    private static func isAuthorizationHeader(_ name: String) -> Bool {
        name.lowercased() == authorizationHeaderName.lowercased()
    }

    var description: String {
        "VisionTransportRequest(method: \(method), url: \(url.absoluteString), "
            + "timeout: \(timeout), bodyBytes: \(body.count), headers: \(redactedHeaders))"
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "url": url, "method": method, "headers": redactedHeaders,
                "bodyBytes": body.count, "timeout": timeout,
            ],
            displayStyle: .struct
        )
    }

    /// Builds the chat-completions request for one image. The credential is
    /// read once into the `Authorization` header and nowhere else. Image
    /// boundaries are enforced before the body is encoded.
    static func chatCompletion(
        configuration: VisionProviderConfiguration,
        image: VisionImagePayload,
        credential: VisionCredential,
        instruction: String = VisionChatCompletionRequestBody.instruction
    ) throws -> VisionTransportRequest {
        guard !image.data.isEmpty else {
            throw VisionRequestError.emptyImageData
        }
        guard configuration.allowsMimeType(image.mimeType) else {
            throw VisionRequestError.unsupportedMimeType(
                mimeType: image.mimeType
            )
        }
        guard configuration.allowsByteCount(image.data.count) else {
            throw VisionRequestError.imageTooLarge(
                byteCount: image.data.count,
                maxImageBytes: configuration.maxImageBytes
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(
            VisionChatCompletionRequestBody(
                model: configuration.model,
                image: image,
                instruction: instruction
            )
        )
        return VisionTransportRequest(
            url: configuration.baseURL
                .appendingPathComponent("chat")
                .appendingPathComponent("completions"),
            headers: [
                "Content-Type": "application/json",
                "Accept": "application/json",
                authorizationHeaderName: credential.headerValue,
            ],
            body: body,
            timeout: configuration.requestTimeout
        )
    }
}
