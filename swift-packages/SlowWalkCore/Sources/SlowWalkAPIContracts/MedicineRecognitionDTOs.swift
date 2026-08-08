import Foundation

/// Optional client behavior understood by the medicine-recognition endpoint.
public struct MedicineRecognitionClientCapabilitiesDTO:
    Codable,
    Sendable,
    Equatable,
    Hashable
{
    public let supportsLocalFallback: Bool

    public init(supportsLocalFallback: Bool) {
        self.supportsLocalFallback = supportsLocalFallback
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case supportsLocalFallback
    }

    public init(from decoder: any Decoder) throws {
        try decoder.validateMedicineRecognitionKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        supportsLocalFallback = try container.decode(
            Bool.self,
            forKey: .supportsLocalFallback
        )
    }
}

/// API v1 request containing one medicine-package image and no health data.
public struct MedicineRecognitionAPIRequestDTO:
    Codable,
    Sendable,
    Equatable,
    Hashable
{
    public let imageBase64: String
    public let mimeType: String
    public let requestID: UUID
    public let clientCapabilities:
        MedicineRecognitionClientCapabilitiesDTO?
    public let apiVersion: String

    public init(
        imageBase64: String,
        mimeType: String,
        requestID: UUID,
        clientCapabilities:
            MedicineRecognitionClientCapabilitiesDTO?,
        apiVersion: String
    ) {
        self.imageBase64 = imageBase64
        self.mimeType = mimeType
        self.requestID = requestID
        self.clientCapabilities = clientCapabilities
        self.apiVersion = apiVersion
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case imageBase64
        case mimeType
        case requestID
        case clientCapabilities
        case apiVersion
    }

    public init(from decoder: any Decoder) throws {
        try decoder.validateMedicineRecognitionKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        imageBase64 = try container.decode(
            String.self,
            forKey: .imageBase64
        )
        mimeType = try container.decode(String.self, forKey: .mimeType)
        requestID = try container.decode(UUID.self, forKey: .requestID)
        clientCapabilities = try container.decodeIfPresent(
            MedicineRecognitionClientCapabilitiesDTO.self,
            forKey: .clientCapabilities
        )
        apiVersion = try container.decode(String.self, forKey: .apiVersion)
    }
}

/// Stable result states for remote package recognition.
public enum MedicineRecognitionStatusDTO:
    String,
    Codable,
    Sendable,
    CaseIterable,
    Hashable
{
    case recognized
    case ambiguous
    case unreadable
    case noCandidate = "no_candidate"
    case providerUnavailable = "provider_unavailable"
}

/// Why a canonical identity could not be returned.
public enum MedicineRecognitionUnresolvedReasonDTO:
    String,
    Codable,
    Sendable,
    CaseIterable,
    Hashable
{
    case imageUnreadable = "image_unreadable"
    case noEvidence = "no_evidence"
    case noCandidate = "no_candidate"
    case supportingEvidenceOnly = "supporting_evidence_only"
    case ambiguousCandidates = "ambiguous_candidates"
    case conflictingEvidence = "conflicting_evidence"
    case uncertainEvidence = "uncertain_evidence"
    case canonicalResolutionFailed = "canonical_resolution_failed"
    case providerUnavailable = "provider_unavailable"
}

/// Stable, non-clinical status projected from the canonical resolver.
public enum MedicineCanonicalResolutionStatusDTO:
    String,
    Codable,
    Sendable,
    CaseIterable,
    Hashable
{
    case resolved
    case ambiguous
    case insufficientEvidence = "insufficient_evidence"
    case notFound = "not_found"
    case recognitionFailed = "recognition_failed"
}

/// Structured visual evidence extracted from medicine packaging.
///
/// This DTO deliberately cannot carry a canonical identity or clinical advice.
public struct MedicinePackageEvidenceDTO:
    Codable,
    Sendable,
    Equatable,
    Hashable
{
    public let visibleTexts: [String]
    public let probableProductNames: [String]
    public let probableGenericNames: [String]
    public let manufacturerNames: [String]
    public let approvalIdentifiers: [String]
    public let dosageFormTexts: [String]
    public let packagingFeatures: [String]
    public let searchQueries: [String]
    public let imageReadable: Bool
    public let uncertainRegionsPresent: Bool

    public init(
        visibleTexts: [String],
        probableProductNames: [String],
        probableGenericNames: [String],
        manufacturerNames: [String],
        approvalIdentifiers: [String],
        dosageFormTexts: [String],
        packagingFeatures: [String],
        searchQueries: [String],
        imageReadable: Bool,
        uncertainRegionsPresent: Bool
    ) {
        self.visibleTexts = visibleTexts
        self.probableProductNames = probableProductNames
        self.probableGenericNames = probableGenericNames
        self.manufacturerNames = manufacturerNames
        self.approvalIdentifiers = approvalIdentifiers
        self.dosageFormTexts = dosageFormTexts
        self.packagingFeatures = packagingFeatures
        self.searchQueries = searchQueries
        self.imageReadable = imageReadable
        self.uncertainRegionsPresent = uncertainRegionsPresent
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case visibleTexts
        case probableProductNames
        case probableGenericNames
        case manufacturerNames
        case approvalIdentifiers
        case dosageFormTexts
        case packagingFeatures
        case searchQueries
        case imageReadable
        case uncertainRegionsPresent
    }

    public init(from decoder: any Decoder) throws {
        try decoder.validateMedicineRecognitionKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        visibleTexts = try container.decode(
            [String].self,
            forKey: .visibleTexts
        )
        probableProductNames = try container.decode(
            [String].self,
            forKey: .probableProductNames
        )
        probableGenericNames = try container.decode(
            [String].self,
            forKey: .probableGenericNames
        )
        manufacturerNames = try container.decode(
            [String].self,
            forKey: .manufacturerNames
        )
        approvalIdentifiers = try container.decode(
            [String].self,
            forKey: .approvalIdentifiers
        )
        dosageFormTexts = try container.decode(
            [String].self,
            forKey: .dosageFormTexts
        )
        packagingFeatures = try container.decode(
            [String].self,
            forKey: .packagingFeatures
        )
        searchQueries = try container.decode(
            [String].self,
            forKey: .searchQueries
        )
        imageReadable = try container.decode(Bool.self, forKey: .imageReadable)
        uncertainRegionsPresent = try container.decode(
            Bool.self,
            forKey: .uncertainRegionsPresent
        )
    }
}

/// Origin of one observed piece of package evidence.
public enum MedicineRecognitionEvidenceSourceDTO:
    String,
    Codable,
    Sendable,
    CaseIterable,
    Hashable
{
    case probableProductName = "probable_product_name"
    case probableGenericName = "probable_generic_name"
    case manufacturerName = "manufacturer_name"
    case approvalIdentifier = "approval_identifier"
    case visibleText = "visible_text"
    case dosageFormText = "dosage_form_text"
    case packagingFeature = "packaging_feature"
    case searchQuery = "search_query"
}

/// Controlled-catalog field compared with observed package evidence.
public enum MedicineRecognitionCatalogFieldDTO:
    String,
    Codable,
    Sendable,
    CaseIterable,
    Hashable
{
    case canonicalName = "canonical_name"
    case productName = "product_name"
    case genericName = "generic_name"
    case alias
    case manufacturerName = "manufacturer_name"
    case approvalIdentifier = "approval_identifier"
    case packagingText = "packaging_text"
}

/// Explainable comparison between observed text and a controlled-catalog field.
public struct MedicineRecognitionEvidenceMatchDTO:
    Codable,
    Sendable,
    Equatable,
    Hashable
{
    public let source: MedicineRecognitionEvidenceSourceDTO
    public let observedText: String
    public let normalizedObservedText: String
    public let catalogField: MedicineRecognitionCatalogFieldDTO
    public let catalogText: String

    public init(
        source: MedicineRecognitionEvidenceSourceDTO,
        observedText: String,
        normalizedObservedText: String,
        catalogField: MedicineRecognitionCatalogFieldDTO,
        catalogText: String
    ) {
        self.source = source
        self.observedText = observedText
        self.normalizedObservedText = normalizedObservedText
        self.catalogField = catalogField
        self.catalogText = catalogText
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case source
        case observedText
        case normalizedObservedText
        case catalogField
        case catalogText
    }

    public init(from decoder: any Decoder) throws {
        try decoder.validateMedicineRecognitionKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(
            MedicineRecognitionEvidenceSourceDTO.self,
            forKey: .source
        )
        observedText = try container.decode(
            String.self,
            forKey: .observedText
        )
        normalizedObservedText = try container.decode(
            String.self,
            forKey: .normalizedObservedText
        )
        catalogField = try container.decode(
            MedicineRecognitionCatalogFieldDTO.self,
            forKey: .catalogField
        )
        catalogText = try container.decode(String.self, forKey: .catalogText)
    }
}

/// Package evidence that did not match any controlled-catalog candidate.
public struct MedicineRecognitionEvidenceObservationDTO:
    Codable,
    Sendable,
    Equatable,
    Hashable
{
    public let source: MedicineRecognitionEvidenceSourceDTO
    public let observedText: String
    public let normalizedText: String

    public init(
        source: MedicineRecognitionEvidenceSourceDTO,
        observedText: String,
        normalizedText: String
    ) {
        self.source = source
        self.observedText = observedText
        self.normalizedText = normalizedText
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case source
        case observedText
        case normalizedText
    }

    public init(from decoder: any Decoder) throws {
        try decoder.validateMedicineRecognitionKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(
            MedicineRecognitionEvidenceSourceDTO.self,
            forKey: .source
        )
        observedText = try container.decode(
            String.self,
            forKey: .observedText
        )
        normalizedText = try container.decode(
            String.self,
            forKey: .normalizedText
        )
    }
}

/// Non-clinical candidate projection backed by the controlled catalog.
public struct MedicineEvidenceCandidateSummaryDTO:
    Codable,
    Sendable,
    Equatable,
    Hashable
{
    public let canonicalMedicineID: String
    public let canonicalName: String
    public let exactEvidence: [MedicineRecognitionEvidenceMatchDTO]
    public let supportingEvidence: [MedicineRecognitionEvidenceMatchDTO]
    public let conflictingEvidence: [MedicineRecognitionEvidenceMatchDTO]
    public let unresolvedEvidence: [MedicineRecognitionEvidenceMatchDTO]

    public init(
        canonicalMedicineID: String,
        canonicalName: String,
        exactEvidence: [MedicineRecognitionEvidenceMatchDTO],
        supportingEvidence: [MedicineRecognitionEvidenceMatchDTO],
        conflictingEvidence: [MedicineRecognitionEvidenceMatchDTO],
        unresolvedEvidence: [MedicineRecognitionEvidenceMatchDTO]
    ) {
        self.canonicalMedicineID = canonicalMedicineID
        self.canonicalName = canonicalName
        self.exactEvidence = exactEvidence
        self.supportingEvidence = supportingEvidence
        self.conflictingEvidence = conflictingEvidence
        self.unresolvedEvidence = unresolvedEvidence
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case canonicalMedicineID
        case canonicalName
        case exactEvidence
        case supportingEvidence
        case conflictingEvidence
        case unresolvedEvidence
    }

    public init(from decoder: any Decoder) throws {
        try decoder.validateMedicineRecognitionKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        canonicalMedicineID = try container.decode(
            String.self,
            forKey: .canonicalMedicineID
        )
        canonicalName = try container.decode(
            String.self,
            forKey: .canonicalName
        )
        exactEvidence = try container.decode(
            [MedicineRecognitionEvidenceMatchDTO].self,
            forKey: .exactEvidence
        )
        supportingEvidence = try container.decode(
            [MedicineRecognitionEvidenceMatchDTO].self,
            forKey: .supportingEvidence
        )
        conflictingEvidence = try container.decode(
            [MedicineRecognitionEvidenceMatchDTO].self,
            forKey: .conflictingEvidence
        )
        unresolvedEvidence = try container.decode(
            [MedicineRecognitionEvidenceMatchDTO].self,
            forKey: .unresolvedEvidence
        )
    }
}

/// Minimal identity projection from the existing canonical resolver.
public struct MedicineCanonicalResolutionSummaryDTO:
    Codable,
    Sendable,
    Equatable,
    Hashable
{
    public let canonicalMedicineID: String
    public let canonicalName: String
    public let status: MedicineCanonicalResolutionStatusDTO

    public init(
        canonicalMedicineID: String,
        canonicalName: String,
        status: MedicineCanonicalResolutionStatusDTO
    ) {
        self.canonicalMedicineID = canonicalMedicineID
        self.canonicalName = canonicalName
        self.status = status
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case canonicalMedicineID
        case canonicalName
        case status
    }

    public init(from decoder: any Decoder) throws {
        try decoder.validateMedicineRecognitionKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        canonicalMedicineID = try container.decode(
            String.self,
            forKey: .canonicalMedicineID
        )
        canonicalName = try container.decode(
            String.self,
            forKey: .canonicalName
        )
        status = try container.decode(
            MedicineCanonicalResolutionStatusDTO.self,
            forKey: .status
        )
    }
}

/// API v1 response for package recognition and canonical identity resolution.
///
/// The response contains no image bytes, health context, risk result, dosage
/// advice, action card, or provider response body.
public struct MedicineRecognitionAPIResponseDTO:
    Codable,
    Sendable,
    Equatable,
    Hashable
{
    public let status: MedicineRecognitionStatusDTO
    public let requestID: UUID
    public let packageEvidence: MedicinePackageEvidenceDTO?
    public let canonicalResolution:
        MedicineCanonicalResolutionSummaryDTO?
    public let candidates: [MedicineEvidenceCandidateSummaryDTO]
    public let unresolvedEvidence:
        [MedicineRecognitionEvidenceObservationDTO]
    public let unresolvedReason:
        MedicineRecognitionUnresolvedReasonDTO?
    public let allowsLocalFallback: Bool
    public let errorCode: APIErrorCode?
    public let apiVersion: String

    public init(
        status: MedicineRecognitionStatusDTO,
        requestID: UUID,
        packageEvidence: MedicinePackageEvidenceDTO?,
        canonicalResolution:
            MedicineCanonicalResolutionSummaryDTO?,
        candidates: [MedicineEvidenceCandidateSummaryDTO],
        unresolvedEvidence:
            [MedicineRecognitionEvidenceObservationDTO],
        unresolvedReason:
            MedicineRecognitionUnresolvedReasonDTO?,
        allowsLocalFallback: Bool,
        errorCode: APIErrorCode?,
        apiVersion: String
    ) {
        self.status = status
        self.requestID = requestID
        self.packageEvidence = packageEvidence
        self.canonicalResolution = canonicalResolution
        self.candidates = candidates
        self.unresolvedEvidence = unresolvedEvidence
        self.unresolvedReason = unresolvedReason
        self.allowsLocalFallback = allowsLocalFallback
        self.errorCode = errorCode
        self.apiVersion = apiVersion
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case status
        case requestID
        case packageEvidence
        case canonicalResolution
        case candidates
        case unresolvedEvidence
        case unresolvedReason
        case allowsLocalFallback
        case errorCode
        case apiVersion
    }

    public init(from decoder: any Decoder) throws {
        try decoder.validateMedicineRecognitionKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(
            MedicineRecognitionStatusDTO.self,
            forKey: .status
        )
        requestID = try container.decode(UUID.self, forKey: .requestID)
        packageEvidence = try container.decodeIfPresent(
            MedicinePackageEvidenceDTO.self,
            forKey: .packageEvidence
        )
        canonicalResolution = try container.decodeIfPresent(
            MedicineCanonicalResolutionSummaryDTO.self,
            forKey: .canonicalResolution
        )
        candidates = try container.decode(
            [MedicineEvidenceCandidateSummaryDTO].self,
            forKey: .candidates
        )
        unresolvedEvidence = try container.decode(
            [MedicineRecognitionEvidenceObservationDTO].self,
            forKey: .unresolvedEvidence
        )
        unresolvedReason = try container.decodeIfPresent(
            MedicineRecognitionUnresolvedReasonDTO.self,
            forKey: .unresolvedReason
        )
        allowsLocalFallback = try container.decode(
            Bool.self,
            forKey: .allowsLocalFallback
        )
        errorCode = try container.decodeIfPresent(
            APIErrorCode.self,
            forKey: .errorCode
        )
        apiVersion = try container.decode(String.self, forKey: .apiVersion)

        guard !allowsLocalFallback || status == .providerUnavailable else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription:
                    "Local fallback is not allowed for this recognition status."
            ))
        }
    }
}

private extension Decoder {
    func validateMedicineRecognitionKeys<Key>(
        _ keyType: Key.Type
    ) throws where Key: CodingKey & CaseIterable {
        let rawContainer = try container(
            keyedBy: MedicineRecognitionAnyCodingKey.self
        )
        let actualKeys = Set(rawContainer.allKeys.map(\.stringValue))
        let allowedKeys = Set(Key.allCases.map(\.stringValue))
        guard actualKeys.isSubset(of: allowedKeys) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: codingPath,
                debugDescription:
                    "Unexpected medicine recognition contract field."
            ))
        }
    }
}

private struct MedicineRecognitionAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
