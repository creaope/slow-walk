import Foundation

/// Failures raised while building a provider configuration, before any
/// network access is possible.
enum VisionConfigurationError:
    Error,
    Sendable,
    Equatable
{
    case providerIdentifierEmpty
    case baseURLNotHTTPS
    case modelEmpty
    case requestTimeoutOutOfRange
    case maxImageBytesOutOfRange
    case maxAttemptsOutOfRange
    case allowedMimeTypesEmpty
}

/// Describes one OpenAI-compatible remote vision provider.
///
/// The configuration deliberately has no credential field. API keys are
/// injected per request through ``VisionCredential`` so that they can never be
/// stored on a configuration value, encoded out of one, or printed with one.
struct VisionProviderConfiguration:
    Sendable,
    Equatable
{
    /// Image MIME types this gateway is willing to forward.
    static let defaultAllowedMimeTypes: Set<String> = [
        "image/jpeg",
        "image/png",
        "image/webp",
    ]

    /// One initial attempt plus at most two retries.
    static let maximumSupportedAttempts = 3

    let providerIdentifier: String
    let baseURL: URL
    let model: String
    let requestTimeout: TimeInterval
    let maxImageBytes: Int
    let maxAttempts: Int
    let allowedMimeTypes: Set<String>

    init(
        providerIdentifier: String,
        baseURL: URL,
        model: String,
        requestTimeout: TimeInterval = 30,
        maxImageBytes: Int = 4 * 1_024 * 1_024,
        maxAttempts: Int =
            VisionProviderConfiguration.maximumSupportedAttempts,
        allowedMimeTypes: Set<String> =
            VisionProviderConfiguration.defaultAllowedMimeTypes
    ) throws {
        let trimmedIdentifier = providerIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIdentifier.isEmpty else {
            throw VisionConfigurationError.providerIdentifierEmpty
        }
        guard baseURL.scheme?.lowercased() == "https",
              baseURL.host != nil
        else {
            throw VisionConfigurationError.baseURLNotHTTPS
        }
        let trimmedModel = model
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            throw VisionConfigurationError.modelEmpty
        }
        guard requestTimeout.isFinite, requestTimeout > 0 else {
            throw VisionConfigurationError.requestTimeoutOutOfRange
        }
        guard maxImageBytes > 0 else {
            throw VisionConfigurationError.maxImageBytesOutOfRange
        }
        guard (1 ... Self.maximumSupportedAttempts)
            .contains(maxAttempts)
        else {
            throw VisionConfigurationError.maxAttemptsOutOfRange
        }
        let normalizedMimeTypes = Set(
            allowedMimeTypes.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            }
            .filter { !$0.isEmpty }
        )
        guard !normalizedMimeTypes.isEmpty else {
            throw VisionConfigurationError.allowedMimeTypesEmpty
        }

        self.providerIdentifier = trimmedIdentifier
        self.baseURL = baseURL
        self.model = trimmedModel
        self.requestTimeout = requestTimeout
        self.maxImageBytes = maxImageBytes
        self.maxAttempts = maxAttempts
        self.allowedMimeTypes = normalizedMimeTypes
    }

    /// Whether this provider accepts an image of the given MIME type.
    ///
    /// Comparison is against the normalised set, so a caller may pass a value
    /// with surrounding whitespace or mixed case.
    func allowsMimeType(_ mimeType: String) -> Bool {
        allowedMimeTypes.contains(
            mimeType
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        )
    }

    /// Whether an image of this size is within the configured budget.
    func allowsByteCount(_ byteCount: Int) -> Bool {
        byteCount <= maxImageBytes
    }
}
