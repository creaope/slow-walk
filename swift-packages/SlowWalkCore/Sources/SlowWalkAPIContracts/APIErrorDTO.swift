import Foundation

/// Stable machine-readable API v1 error codes.
///
/// Encoding always emits canonical `UPPER_SNAKE_CASE`. Decoding accepts the
/// small set of lowercase values emitted by early API v1 builds so clients can
/// migrate in one place.
public enum APIErrorCode:
    String,
    Codable,
    Sendable,
    CaseIterable,
    Hashable
{
    case malformedRequest = "MALFORMED_REQUEST"
    case unsupportedMediaType = "UNSUPPORTED_MEDIA_TYPE"
    case unsupportedAPIVersion = "UNSUPPORTED_API_VERSION"
    case validationError = "VALIDATION_ERROR"
    case requestBodyTooLarge = "REQUEST_BODY_TOO_LARGE"
    case imageTooLarge = "IMAGE_TOO_LARGE"
    case internalError = "INTERNAL_ERROR"
    case invalidUserProfile = "INVALID_USER_PROFILE"
    case unsupportedProfileSchema = "UNSUPPORTED_PROFILE_SCHEMA"
    case invalidMedicationRecord = "INVALID_MEDICATION_RECORD"
    case futureMedicationRecord = "FUTURE_MEDICATION_RECORD"
    case invalidBodyMetrics = "INVALID_BODY_METRICS"
    case knowledgeSourceUnavailable = "KNOWLEDGE_SOURCE_UNAVAILABLE"
    case knowledgeSourceTimeout = "KNOWLEDGE_SOURCE_TIMEOUT"
    case invalidSourceResponse = "INVALID_SOURCE_RESPONSE"
    case sourceVersionUnsupported = "SOURCE_VERSION_UNSUPPORTED"
    case medicineNotFound = "MEDICINE_NOT_FOUND"
    case sourceConflict = "SOURCE_CONFLICT"
    case offlineCacheUnavailable = "OFFLINE_CACHE_UNAVAILABLE"
    case medicineAmbiguous = "MEDICINE_AMBIGUOUS"
    case medicineRecognitionFailed = "MEDICINE_RECOGNITION_FAILED"
    case medicineInsufficientEvidence = "MEDICINE_INSUFFICIENT_EVIDENCE"
    case providerRateLimited = "PROVIDER_RATE_LIMITED"
    case providerUnavailable = "PROVIDER_UNAVAILABLE"
    case providerTimeout = "PROVIDER_TIMEOUT"
    case invalidProviderResponse = "INVALID_PROVIDER_RESPONSE"
    case invalidLocationSample = "INVALID_LOCATION_SAMPLE"
    case locationDataStale = "LOCATION_DATA_STALE"
    case locationAccuracyInsufficient = "LOCATION_ACCURACY_INSUFFICIENT"
    case insufficientLocationHistory = "INSUFFICIENT_LOCATION_HISTORY"

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if let canonical = Self(rawValue: value) {
            self = canonical
            return
        }

        switch value {
        case "invalid_json", "malformed_request":
            self = .malformedRequest
        case "unsupported_media_type":
            self = .unsupportedMediaType
        case "unsupported_api_version":
            self = .unsupportedAPIVersion
        case "validation_error", "validation_failed":
            self = .validationError
        case "request_body_too_large":
            self = .requestBodyTooLarge
        case "image_too_large":
            self = .imageTooLarge
        case "internal_error":
            self = .internalError
        case "medicine_ambiguous":
            self = .medicineAmbiguous
        case "medicine_not_found":
            self = .medicineNotFound
        case "medicine_recognition_failed":
            self = .medicineRecognitionFailed
        case "medicine_insufficient_evidence":
            self = .medicineInsufficientEvidence
        case "provider_rate_limited":
            self = .providerRateLimited
        case "provider_unavailable":
            self = .providerUnavailable
        case "provider_timeout":
            self = .providerTimeout
        case "invalid_provider_response":
            self = .invalidProviderResponse
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription:
                    "Unsupported API error code: \(value)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Typed, field-level API validation detail.
public struct APIErrorDetailDTO: Codable, Sendable, Equatable, Hashable {
    public let field: String?
    public let code: String
    public let message: String

    public init(field: String?, code: String, message: String) {
        self.field = field
        self.code = code
        self.message = message
    }
}

/// Uniform API v1 error body.
public struct APIErrorDTO: Codable, Sendable, Equatable, Hashable {
    public let code: APIErrorCode
    public let message: String
    public let requestID: UUID
    public let details: [APIErrorDetailDTO]?

    public init(
        code: APIErrorCode,
        message: String,
        requestID: UUID,
        details: [APIErrorDetailDTO]?
    ) {
        self.code = code
        self.message = message
        self.requestID = requestID
        self.details = details
    }
}
