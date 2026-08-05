/// Stable API metadata and the canonical mapping between body versions and
/// versioned HTTP paths.
public enum SlowWalkAPI {
    public static let version = "v1"
    public static let routePrefix = "/api/\(version)"

    public enum Endpoint: String, Sendable, CaseIterable, Hashable {
        case medicineSearch = "/medicine/search"
        case medicineResolve = "/medicine/resolve"
        case medicineRecognize = "/medicine/recognize"
        case medicineAssess = "/medicine/assess"
        case locationAssess = "/location/assess"

        public var path: String {
            SlowWalkAPI.routePrefix + rawValue
        }

        public var errorCodes: [APIErrorCode] {
            let transport: [APIErrorCode] = [
                .unsupportedMediaType,
                .malformedRequest,
                .unsupportedAPIVersion,
                .validationError,
            ]
            let knowledge: [APIErrorCode] = [
                .knowledgeSourceUnavailable,
                .knowledgeSourceTimeout,
                .invalidSourceResponse,
                .sourceVersionUnsupported,
                .medicineNotFound,
                .sourceConflict,
                .offlineCacheUnavailable,
            ]
            switch self {
            case .medicineSearch:
                return transport + knowledge
            case .medicineResolve:
                return transport + knowledge + [
                    .medicineAmbiguous,
                    .medicineRecognitionFailed,
                    .medicineInsufficientEvidence,
                    .internalError,
                ]
            case .medicineRecognize:
                return transport + [
                    .requestBodyTooLarge,
                    .imageTooLarge,
                    .medicineAmbiguous,
                    .medicineRecognitionFailed,
                    .medicineInsufficientEvidence,
                    .medicineNotFound,
                    .sourceConflict,
                    .providerRateLimited,
                    .providerUnavailable,
                    .providerTimeout,
                    .invalidProviderResponse,
                    .internalError,
                ]
            case .medicineAssess:
                return transport + knowledge + [
                    .invalidUserProfile,
                    .unsupportedProfileSchema,
                    .invalidMedicationRecord,
                    .futureMedicationRecord,
                    .invalidBodyMetrics,
                    .internalError,
                ]
            case .locationAssess:
                return transport + [
                    .invalidLocationSample,
                    .locationDataStale,
                    .locationAccuracyInsufficient,
                    .insufficientLocationHistory,
                ]
            }
        }
    }

    public static func supports(
        bodyVersion: String,
        for endpoint: Endpoint
    ) -> Bool {
        bodyVersion == version
            && endpoint.path.hasPrefix(routePrefix + "/")
    }
}
