import Foundation
import SlowWalkAPIContracts

/// Typed API failure received from a transport implementation.
public struct ClientAPIError:
    Error,
    Sendable,
    Equatable
{
    public let error: APIErrorDTO

    public init(error: APIErrorDTO) {
        self.error = error
    }
}

/// Non-HTTP-status transport failures shared by future URLSession adapters
/// and deterministic mocks.
public enum ClientTransportError:
    Error,
    Sendable,
    Equatable
{
    case malformedResponse
    case timedOut(ClientRequestTimeout)
    case unavailable
}

public struct ClientRequestTimeout:
    Sendable,
    Equatable,
    Hashable
{
    public let endpoint: SlowWalkAPI.Endpoint
    public let timeoutSeconds: TimeInterval?

    public init(
        endpoint: SlowWalkAPI.Endpoint,
        timeoutSeconds: TimeInterval?
    ) {
        self.endpoint = endpoint
        self.timeoutSeconds = timeoutSeconds
    }
}

public enum OCRRecognitionError:
    Error,
    Sendable,
    Equatable
{
    case unavailable
    case invalidInput
    case recognitionFailed
}

/// Presentation-safe failure categories.
///
/// Server messages and field details are deliberately not retained because
/// they may contain OCR, health-profile, or location values.
public enum ClientFailureKind:
    String,
    Codable,
    Sendable,
    CaseIterable,
    Hashable
{
    case api
    case timeout
    case malformedResponse = "malformed_response"
    case transportUnavailable = "transport_unavailable"
    case recognition
    case unknown
}

public struct ClientFailure:
    Sendable,
    Equatable,
    Hashable
{
    public let kind: ClientFailureKind
    public let apiErrorCode: APIErrorCode?
    public let requestID: UUID?
    public let endpoint: SlowWalkAPI.Endpoint?
    public let isRecoverable: Bool

    public init(
        kind: ClientFailureKind,
        apiErrorCode: APIErrorCode?,
        requestID: UUID?,
        endpoint: SlowWalkAPI.Endpoint?,
        isRecoverable: Bool
    ) {
        self.kind = kind
        self.apiErrorCode = apiErrorCode
        self.requestID = requestID
        self.endpoint = endpoint
        self.isRecoverable = isRecoverable
    }
}

/// The only client-side mapping from thrown errors to canonical API codes.
public enum ClientFailureMapper {
    public static func map(
        _ error: any Error
    ) -> ClientFailure {
        if let apiError = error as? ClientAPIError {
            if apiError.error.code == .knowledgeSourceTimeout
                || apiError.error.code == .providerTimeout
            {
                return ClientFailure(
                    kind: .timeout,
                    apiErrorCode: apiError.error.code,
                    requestID: apiError.error.requestID,
                    endpoint: nil,
                    isRecoverable: true
                )
            }
            return ClientFailure(
                kind: .api,
                apiErrorCode: apiError.error.code,
                requestID: apiError.error.requestID,
                endpoint: nil,
                isRecoverable: isRecoverable(
                    apiError.error.code
                )
            )
        }

        if let transportError =
            error as? ClientTransportError
        {
            switch transportError {
            case .malformedResponse:
                return ClientFailure(
                    kind: .malformedResponse,
                    apiErrorCode: nil,
                    requestID: nil,
                    endpoint: nil,
                    isRecoverable: false
                )
            case let .timedOut(timeout):
                return ClientFailure(
                    kind: .timeout,
                    apiErrorCode: nil,
                    requestID: nil,
                    endpoint: timeout.endpoint,
                    isRecoverable: true
                )
            case .unavailable:
                return ClientFailure(
                    kind: .transportUnavailable,
                    apiErrorCode: nil,
                    requestID: nil,
                    endpoint: nil,
                    isRecoverable: true
                )
            }
        }

        if error is OCRRecognitionError {
            return ClientFailure(
                kind: .recognition,
                apiErrorCode: nil,
                requestID: nil,
                endpoint: nil,
                isRecoverable: true
            )
        }

        if error is MedicineAssessmentResponseValidationError {
            return ClientFailure(
                kind: .malformedResponse,
                apiErrorCode: nil,
                requestID: nil,
                endpoint: .medicineAssess,
                isRecoverable: false
            )
        }

        return ClientFailure(
            kind: .unknown,
            apiErrorCode: nil,
            requestID: nil,
            endpoint: nil,
            isRecoverable: false
        )
    }

    private static func isRecoverable(
        _ code: APIErrorCode
    ) -> Bool {
        switch code {
        case .knowledgeSourceUnavailable,
             .knowledgeSourceTimeout,
             .offlineCacheUnavailable,
             .providerRateLimited,
             .providerUnavailable,
             .providerTimeout,
             .invalidProviderResponse,
             .internalError:
            return true
        case .malformedRequest,
             .unsupportedMediaType,
             .unsupportedAPIVersion,
             .validationError,
             .requestBodyTooLarge,
             .imageTooLarge,
             .invalidUserProfile,
             .unsupportedProfileSchema,
             .invalidMedicationRecord,
             .futureMedicationRecord,
             .invalidBodyMetrics,
             .invalidSourceResponse,
             .sourceVersionUnsupported,
             .medicineNotFound,
             .sourceConflict,
             .medicineAmbiguous,
             .medicineRecognitionFailed,
             .medicineInsufficientEvidence,
             .invalidLocationSample,
             .locationDataStale,
             .locationAccuracyInsufficient,
             .insufficientLocationHistory:
            return false
        }
    }
}
