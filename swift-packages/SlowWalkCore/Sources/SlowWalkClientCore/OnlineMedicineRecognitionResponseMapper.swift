import Foundation
import SlowWalkAPIContracts
import SlowWalkDomain
import SlowWalkMedicinePipeline

/// Validates the medicine-recognition API response before it can enter the
/// existing canonical pipeline.
public struct OnlineMedicineRecognitionResponseMapper: Sendable {
    private static let maximumProductNameCount = 16
    private static let maximumGenericNameCount = 16
    private static let maximumManufacturerNameCount = 16
    private static let maximumApprovalIdentifierCount = 16
    private static let maximumDosageFormTextCount = 16
    private static let maximumVisibleTextCount = 64
    private static let maximumPackagingFeatureCount = 24
    private static let maximumSearchQueryCount = 8
    private static let maximumNamedEvidenceLength = 160
    private static let maximumVisibleTextLength = 256
    private static let maximumPackagingFeatureLength = 256
    private static let maximumSearchQueryLength = 96
    private static let maximumSearchQueryCharacterCount = 384
    private static let maximumPackageEvidenceCharacterCount = 4_096
    private static let maximumCandidateCount = 8
    private static let maximumMatchesPerCategory = 16
    private static let maximumUnresolvedObservationCount = 32
    private static let maximumObservationLength = 256
    private static let maximumNormalizedObservationLength = 2_048
    private static let maximumCatalogTextLength = 256
    private static let maximumCanonicalIDLength = 128
    private static let maximumCanonicalNameLength = 160

    private let normalizer: any MedicineNameNormalizing

    public init(
        normalizer: any MedicineNameNormalizing = MedicineNameNormalizer()
    ) {
        self.normalizer = normalizer
    }

    public func map(
        _ response: MedicineRecognitionAPIResponseDTO,
        for request: OnlineMedicineRecognitionRequest
    ) throws -> OnlineMedicineRecognitionResult {
        guard response.requestID == request.requestID,
              response.apiVersion == SlowWalkAPI.version
        else {
            throw OnlineMedicineRecognitionFailure.invalidResponse
        }

        switch response.status {
        case .recognized:
            return try mapRecognized(response, for: request)
        case .ambiguous:
            try validateAmbiguous(response)
            throw OnlineMedicineRecognitionFailure.ambiguous
        case .unreadable:
            try validateUnreadable(response)
            throw OnlineMedicineRecognitionFailure.unreadable
        case .noCandidate:
            try validateNoCandidate(response)
            throw OnlineMedicineRecognitionFailure.noCandidate
        case .providerUnavailable:
            throw try providerFailure(response)
        }
    }

    private func mapRecognized(
        _ response: MedicineRecognitionAPIResponseDTO,
        for request: OnlineMedicineRecognitionRequest
    ) throws -> OnlineMedicineRecognitionResult {
        guard let evidence = response.packageEvidence,
              evidence.imageReadable,
              !evidence.uncertainRegionsPresent,
              let canonical = response.canonicalResolution,
              canonical.status == .resolved,
              response.unresolvedReason == nil,
              response.errorCode == nil,
              !response.allowsLocalFallback
        else {
            throw OnlineMedicineRecognitionFailure.invalidResponse
        }

        let canonicalID = try validatedIdentityValue(
            canonical.canonicalMedicineID,
            maximumLength: Self.maximumCanonicalIDLength
        )
        let canonicalName = try validatedIdentityValue(
            canonical.canonicalName,
            maximumLength: Self.maximumCanonicalNameLength
        )
        try validatePackageEvidence(evidence)
        try validateCandidates(response.candidates, evidence: evidence)
        try validateUnresolvedEvidence(
            response.unresolvedEvidence,
            evidence: evidence,
            candidates: response.candidates
        )
        let assurance = evidenceAssurance(
            evidence: evidence,
            candidates: response.candidates,
            unresolvedEvidence: response.unresolvedEvidence
        )
        guard let selectedCandidate = response.candidates.first(where: {
            $0.canonicalMedicineID == canonicalID
                && $0.canonicalName == canonicalName
        }),
        assurance.recognizedCandidateID == canonicalID,
        !selectedCandidate.exactEvidence.isEmpty
            || isCorroborated(selectedCandidate)
        else {
            throw OnlineMedicineRecognitionFailure.invalidResponse
        }

        let recognizedTexts = try resolverTexts(from: evidence)
        guard !recognizedTexts.isEmpty else {
            throw OnlineMedicineRecognitionFailure.invalidResponse
        }

        return OnlineMedicineRecognitionResult(
            requestID: request.requestID,
            recognitionInput: MedicineRecognitionInput(
                recognizedTexts: recognizedTexts,
                capturedAt: request.image.capturedAt,
                languageCode: nil,
                rawConfidence: ResolverConfiguration.standard
                    .minimumRecognitionConfidence
            ),
            expectedCanonicalMedicineID: canonicalID,
            expectedCanonicalMedicineName: canonicalName
        )
    }

    private func validateAmbiguous(
        _ response: MedicineRecognitionAPIResponseDTO
    ) throws {
        guard let evidence = response.packageEvidence,
              evidence.imageReadable,
              response.canonicalResolution == nil,
              !response.allowsLocalFallback,
              let reason = response.unresolvedReason,
              let errorCode = response.errorCode,
              isValidAmbiguousPair(reason: reason, errorCode: errorCode),
              !response.candidates.isEmpty
                || reason == .uncertainEvidence,
              evidence.uncertainRegionsPresent
                == (reason == .uncertainEvidence)
        else {
            throw OnlineMedicineRecognitionFailure.invalidResponse
        }
        try validatePackageEvidence(evidence)
        try validateCandidates(response.candidates, evidence: evidence)
        try validateUnresolvedEvidence(
            response.unresolvedEvidence,
            evidence: evidence,
            candidates: response.candidates
        )
        let assurance = evidenceAssurance(
            evidence: evidence,
            candidates: response.candidates,
            unresolvedEvidence: response.unresolvedEvidence
        )
        guard isValidAmbiguousAssurance(
            assurance,
            reason: reason,
            errorCode: errorCode,
            candidateCount: response.candidates.count
        ) else {
            throw OnlineMedicineRecognitionFailure.invalidResponse
        }
    }

    private func validateUnreadable(
        _ response: MedicineRecognitionAPIResponseDTO
    ) throws {
        guard let evidence = response.packageEvidence,
              !evidence.imageReadable,
              response.canonicalResolution == nil,
              response.candidates.isEmpty,
              response.unresolvedReason == .imageUnreadable,
              !response.allowsLocalFallback,
              response.errorCode == .medicineRecognitionFailed
        else {
            throw OnlineMedicineRecognitionFailure.invalidResponse
        }
        try validatePackageEvidence(evidence)
        try validateUnresolvedEvidence(
            response.unresolvedEvidence,
            evidence: evidence,
            candidates: []
        )
        guard response.unresolvedEvidence
                == Array(
                    expectedObservations(from: evidence)
                        .prefix(Self.maximumUnresolvedObservationCount)
                )
        else {
            throw OnlineMedicineRecognitionFailure.invalidResponse
        }
    }

    private func validateNoCandidate(
        _ response: MedicineRecognitionAPIResponseDTO
    ) throws {
        guard let evidence = response.packageEvidence,
              evidence.imageReadable,
              !evidence.uncertainRegionsPresent,
              response.canonicalResolution == nil,
              response.candidates.isEmpty,
              response.unresolvedReason == .noEvidence
                || response.unresolvedReason == .noCandidate,
              !response.allowsLocalFallback,
              response.errorCode == .medicineNotFound
        else {
            throw OnlineMedicineRecognitionFailure.invalidResponse
        }
        try validatePackageEvidence(evidence)
        try validateUnresolvedEvidence(
            response.unresolvedEvidence,
            evidence: evidence,
            candidates: []
        )
        guard response.unresolvedEvidence
                == Array(
                    expectedObservations(from: evidence)
                        .prefix(Self.maximumUnresolvedObservationCount)
                )
        else {
            throw OnlineMedicineRecognitionFailure.invalidResponse
        }
        let assurance = evidenceAssurance(
            evidence: evidence,
            candidates: response.candidates,
            unresolvedEvidence: response.unresolvedEvidence
        )
        let expectedAssurance: ResponseEvidenceAssurance =
            response.unresolvedReason == .noEvidence
            ? .noEvidence
            : .unresolved
        guard assurance == expectedAssurance else {
            throw OnlineMedicineRecognitionFailure.invalidResponse
        }
    }

    private func providerFailure(
        _ response: MedicineRecognitionAPIResponseDTO
    ) throws -> OnlineMedicineRecognitionFailure {
        guard response.packageEvidence == nil,
              response.canonicalResolution == nil,
              response.candidates.isEmpty,
              response.unresolvedEvidence.isEmpty,
              response.unresolvedReason == .providerUnavailable,
              let errorCode = response.errorCode
        else {
            throw OnlineMedicineRecognitionFailure.invalidResponse
        }

        switch errorCode {
        case .providerRateLimited:
            guard response.allowsLocalFallback else {
                throw OnlineMedicineRecognitionFailure.invalidResponse
            }
            return .rateLimited
        case .providerTimeout:
            guard response.allowsLocalFallback else {
                throw OnlineMedicineRecognitionFailure.invalidResponse
            }
            return .timeout
        case .providerUnavailable:
            guard response.allowsLocalFallback else {
                throw OnlineMedicineRecognitionFailure.invalidResponse
            }
            return .providerUnavailable
        case .invalidProviderResponse:
            guard !response.allowsLocalFallback else {
                throw OnlineMedicineRecognitionFailure.invalidResponse
            }
            return .invalidResponse
        default:
            throw OnlineMedicineRecognitionFailure.invalidResponse
        }
    }

    private func isValidAmbiguousPair(
        reason: MedicineRecognitionUnresolvedReasonDTO,
        errorCode: APIErrorCode
    ) -> Bool {
        switch reason {
        case .supportingEvidenceOnly, .uncertainEvidence:
            return errorCode == .medicineInsufficientEvidence
        case .ambiguousCandidates:
            return errorCode == .medicineAmbiguous
        case .conflictingEvidence:
            return errorCode == .sourceConflict
        case .canonicalResolutionFailed:
            return errorCode == .medicineInsufficientEvidence
                || errorCode == .medicineRecognitionFailed
        case .imageUnreadable, .noEvidence, .noCandidate,
             .providerUnavailable:
            return false
        }
    }

    private func isValidAmbiguousAssurance(
        _ assurance: ResponseEvidenceAssurance,
        reason: MedicineRecognitionUnresolvedReasonDTO,
        errorCode: APIErrorCode,
        candidateCount: Int
    ) -> Bool {
        switch reason {
        case .supportingEvidenceOnly:
            return assurance == .supportingOnly
        case .ambiguousCandidates:
            return assurance == .ambiguous && candidateCount >= 2
        case .conflictingEvidence:
            return assurance == .conflicting
        case .uncertainEvidence:
            return assurance == .uncertain
        case .canonicalResolutionFailed:
            if errorCode == .medicineInsufficientEvidence {
                return assurance == .unresolved
            }
            return assurance.isResolverEligible
        case .imageUnreadable, .noEvidence, .noCandidate,
             .providerUnavailable:
            return false
        }
    }

    private func resolverTexts(
        from evidence: MedicinePackageEvidenceDTO
    ) throws -> [String] {
        try validatePackageEvidence(evidence)
        var seen = Set<String>()
        var result: [String] = []
        for value in evidence.probableProductNames
            + evidence.probableGenericNames
            + evidence.visibleTexts
        {
            let trimmed = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let key = normalizer.normalizeName(trimmed)
            if !key.isEmpty, seen.insert(key).inserted {
                result.append(trimmed)
            }
        }
        return result
    }

    private func validatePackageEvidence(
        _ evidence: MedicinePackageEvidenceDTO
    ) throws {
        let collections = [
            EvidenceCollection(
                values: evidence.visibleTexts,
                maximumCount: Self.maximumVisibleTextCount,
                maximumLength: Self.maximumVisibleTextLength
            ),
            EvidenceCollection(
                values: evidence.probableProductNames,
                maximumCount: Self.maximumProductNameCount,
                maximumLength: Self.maximumNamedEvidenceLength
            ),
            EvidenceCollection(
                values: evidence.probableGenericNames,
                maximumCount: Self.maximumGenericNameCount,
                maximumLength: Self.maximumNamedEvidenceLength
            ),
            EvidenceCollection(
                values: evidence.manufacturerNames,
                maximumCount: Self.maximumManufacturerNameCount,
                maximumLength: Self.maximumNamedEvidenceLength
            ),
            EvidenceCollection(
                values: evidence.approvalIdentifiers,
                maximumCount: Self.maximumApprovalIdentifierCount,
                maximumLength: Self.maximumNamedEvidenceLength
            ),
            EvidenceCollection(
                values: evidence.dosageFormTexts,
                maximumCount: Self.maximumDosageFormTextCount,
                maximumLength: Self.maximumNamedEvidenceLength
            ),
            EvidenceCollection(
                values: evidence.packagingFeatures,
                maximumCount: Self.maximumPackagingFeatureCount,
                maximumLength: Self.maximumPackagingFeatureLength
            ),
            EvidenceCollection(
                values: evidence.searchQueries,
                maximumCount: Self.maximumSearchQueryCount,
                maximumLength: Self.maximumSearchQueryLength
            ),
        ]
        let searchQueryCharacterCount = evidence.searchQueries.reduce(0) {
            $0 + $1.count
        }
        guard searchQueryCharacterCount
                <= Self.maximumSearchQueryCharacterCount
        else {
            throw OnlineMedicineRecognitionFailure.invalidResponse
        }
        var totalCharacterCount = 0
        for collection in collections {
            guard collection.values.count <= collection.maximumCount else {
                throw OnlineMedicineRecognitionFailure.invalidResponse
            }
            for value in collection.values {
                let length = value.count
                guard !value.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty,
                length <= collection.maximumLength,
                totalCharacterCount
                    <= Self.maximumPackageEvidenceCharacterCount - length
                else {
                    throw OnlineMedicineRecognitionFailure.invalidResponse
                }
                totalCharacterCount += length
            }
        }
    }

    private func validateCandidates(
        _ candidates: [MedicineEvidenceCandidateSummaryDTO],
        evidence: MedicinePackageEvidenceDTO
    ) throws {
        guard candidates.count <= Self.maximumCandidateCount else {
            throw OnlineMedicineRecognitionFailure.invalidResponse
        }
        var candidateIDs = Set<String>()
        for candidate in candidates {
            let identifier = try validatedIdentityValue(
                candidate.canonicalMedicineID,
                maximumLength: Self.maximumCanonicalIDLength
            )
            _ = try validatedIdentityValue(
                candidate.canonicalName,
                maximumLength: Self.maximumCanonicalNameLength
            )
            guard candidateIDs.insert(identifier).inserted else {
                throw OnlineMedicineRecognitionFailure.invalidResponse
            }
            try validateMatches(
                candidate.exactEvidence,
                category: .exact,
                evidence: evidence
            )
            try validateMatches(
                candidate.supportingEvidence,
                category: .supporting,
                evidence: evidence
            )
            try validateMatches(
                candidate.conflictingEvidence,
                category: .conflicting,
                evidence: evidence
            )
            try validateMatches(
                candidate.unresolvedEvidence,
                category: .unresolved,
                evidence: evidence
            )
        }
    }

    private func validateUnresolvedEvidence(
        _ observations: [MedicineRecognitionEvidenceObservationDTO],
        evidence: MedicinePackageEvidenceDTO,
        candidates: [MedicineEvidenceCandidateSummaryDTO]
    ) throws {
        guard observations.count <= Self.maximumUnresolvedObservationCount
        else {
            throw OnlineMedicineRecognitionFailure.invalidResponse
        }
        var observationKeys = Set<ObservationKey>()
        for observation in observations {
            guard !observation.observedText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty,
            observation.observedText.count <= Self.maximumObservationLength,
            !observation.normalizedText.isEmpty,
            observation.normalizedText.count
                <= Self.maximumNormalizedObservationLength
            else {
                throw OnlineMedicineRecognitionFailure.invalidResponse
            }
            guard evidenceValues(
                for: observation.source,
                in: evidence
            ).contains(observation.observedText),
            normalizer.normalizeName(observation.observedText)
                == observation.normalizedText,
            observationKeys.insert(
                ObservationKey(
                    source: observation.source,
                    normalizedText: observation.normalizedText
                )
            ).inserted
            else {
                throw OnlineMedicineRecognitionFailure.invalidResponse
            }
            let returnedMatches = candidates.flatMap {
                $0.exactEvidence
                    + $0.supportingEvidence
                    + $0.conflictingEvidence
                    + $0.unresolvedEvidence
            }
            guard !returnedMatches.contains(where: {
                $0.source == observation.source
                    && $0.normalizedObservedText
                        == observation.normalizedText
            }) else {
                throw OnlineMedicineRecognitionFailure.invalidResponse
            }
        }
    }

    private func validateMatches(
        _ matches: [MedicineRecognitionEvidenceMatchDTO],
        category: MatchCategory,
        evidence: MedicinePackageEvidenceDTO
    ) throws {
        guard matches.count <= Self.maximumMatchesPerCategory,
              Set(matches).count == matches.count
        else {
            throw OnlineMedicineRecognitionFailure.invalidResponse
        }
        for match in matches {
            let normalized = normalizer.normalizeName(match.observedText)
            guard !match.observedText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty,
            match.observedText.count <= Self.maximumObservationLength,
            !match.normalizedObservedText.isEmpty,
            match.normalizedObservedText.count
                <= Self.maximumNormalizedObservationLength,
            normalized == match.normalizedObservedText,
            !match.catalogText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty,
            match.catalogText.count <= Self.maximumCatalogTextLength,
            evidenceValues(for: match.source, in: evidence)
                .contains(match.observedText),
            isEmittablePair(match),
            matchesCatalog(match)
            else {
                throw OnlineMedicineRecognitionFailure.invalidResponse
            }

            switch category {
            case .exact:
                guard isStrongExact(match) else {
                    throw OnlineMedicineRecognitionFailure.invalidResponse
                }
            case .supporting:
                guard !isStrongExact(match) else {
                    throw OnlineMedicineRecognitionFailure.invalidResponse
                }
            case .conflicting:
                guard match.source != .searchQuery else {
                    throw OnlineMedicineRecognitionFailure.invalidResponse
                }
            case .unresolved:
                break
            }
        }
    }

    private func evidenceAssurance(
        evidence: MedicinePackageEvidenceDTO,
        candidates: [MedicineEvidenceCandidateSummaryDTO],
        unresolvedEvidence: [MedicineRecognitionEvidenceObservationDTO]
    ) -> ResponseEvidenceAssurance {
        guard evidence.imageReadable else { return .unreadable }
        guard !evidence.uncertainRegionsPresent else { return .uncertain }
        guard !candidates.isEmpty else {
            return unresolvedEvidence.isEmpty ? .noEvidence : .unresolved
        }
        guard candidates.allSatisfy({ $0.conflictingEvidence.isEmpty })
        else {
            return .conflicting
        }

        let directIdentityIDs = Set(candidates.compactMap { candidate in
            hasDirectIdentityEvidence(candidate)
                ? candidate.canonicalMedicineID
                : nil
        })
        guard directIdentityIDs.count <= 1 else { return .ambiguous }

        let exactIDs = Set(candidates.compactMap { candidate in
            candidate.exactEvidence.isEmpty
                ? nil
                : candidate.canonicalMedicineID
        })
        if exactIDs.count == 1, let identifier = exactIDs.first {
            return .exact(identifier)
        }
        guard exactIDs.isEmpty else { return .ambiguous }

        let corroboratedIDs = Set(candidates.compactMap { candidate in
            isCorroborated(candidate)
                ? candidate.canonicalMedicineID
                : nil
        })
        if corroboratedIDs.count == 1,
           let identifier = corroboratedIDs.first
        {
            return .corroborated(identifier)
        }

        let supportingCandidateCount = candidates.filter {
            !$0.supportingEvidence.isEmpty
        }.count
        if supportingCandidateCount > 0 {
            return supportingCandidateCount > 1
                ? .ambiguous
                : .supportingOnly
        }
        return .unresolved
    }

    private func hasDirectIdentityEvidence(
        _ candidate: MedicineEvidenceCandidateSummaryDTO
    ) -> Bool {
        (candidate.exactEvidence + candidate.supportingEvidence).contains {
            $0.source != .searchQuery
                && [
                    MedicineRecognitionCatalogFieldDTO.canonicalName,
                    .productName,
                    .genericName,
                    .alias,
                    .approvalIdentifier,
                ].contains($0.catalogField)
        }
    }

    private func isCorroborated(
        _ candidate: MedicineEvidenceCandidateSummaryDTO
    ) -> Bool {
        let hasAlias = candidate.supportingEvidence.contains {
            $0.catalogField == .alias && $0.source != .searchQuery
        }
        let hasIndependentPackagingEvidence =
            candidate.supportingEvidence.contains {
                $0.source != .searchQuery
                    && [
                        MedicineRecognitionCatalogFieldDTO.manufacturerName,
                        .packagingText,
                    ].contains($0.catalogField)
            }
        return hasAlias && hasIndependentPackagingEvidence
    }

    private func isStrongExact(
        _ match: MedicineRecognitionEvidenceMatchDTO
    ) -> Bool {
        switch (match.source, match.catalogField) {
        case (.probableProductName, .canonicalName),
             (.probableProductName, .productName),
             (.probableGenericName, .canonicalName),
             (.probableGenericName, .genericName),
             (.approvalIdentifier, .approvalIdentifier),
             (.visibleText, .canonicalName),
             (.visibleText, .productName),
             (.visibleText, .genericName),
             (.visibleText, .approvalIdentifier):
            return true
        default:
            return false
        }
    }

    private func matchesCatalog(
        _ match: MedicineRecognitionEvidenceMatchDTO
    ) -> Bool {
        let normalizedCatalogText = normalizer.normalizeName(
            match.catalogText
        )
        guard !normalizedCatalogText.isEmpty else { return false }
        if [.manufacturerName, .approvalIdentifier]
            .contains(match.catalogField)
        {
            return match.normalizedObservedText == normalizedCatalogText
        }
        return !comparisonVariants(match.normalizedObservedText)
            .isDisjoint(with: comparisonVariants(normalizedCatalogText))
    }

    private func comparisonVariants(_ normalizedText: String) -> Set<String> {
        var variants = Set([normalizedText])
        let query = normalizer.normalizeQuery(normalizedText)
        if !query.isEmpty {
            variants.insert(query)
        }
        return variants
    }

    private func isEmittablePair(
        _ match: MedicineRecognitionEvidenceMatchDTO
    ) -> Bool {
        switch match.source {
        case .probableProductName:
            return [.canonicalName, .productName, .alias]
                .contains(match.catalogField)
        case .probableGenericName:
            return [.canonicalName, .genericName, .alias]
                .contains(match.catalogField)
        case .manufacturerName:
            return match.catalogField == .manufacturerName
        case .approvalIdentifier:
            return match.catalogField == .approvalIdentifier
        case .visibleText, .searchQuery:
            return true
        case .dosageFormText, .packagingFeature:
            return match.catalogField == .packagingText
        }
    }

    private func evidenceValues(
        for source: MedicineRecognitionEvidenceSourceDTO,
        in evidence: MedicinePackageEvidenceDTO
    ) -> [String] {
        switch source {
        case .probableProductName:
            return evidence.probableProductNames
        case .probableGenericName:
            return evidence.probableGenericNames
        case .manufacturerName:
            return evidence.manufacturerNames
        case .approvalIdentifier:
            return evidence.approvalIdentifiers
        case .visibleText:
            return evidence.visibleTexts
        case .dosageFormText:
            return evidence.dosageFormTexts
        case .packagingFeature:
            return evidence.packagingFeatures
        case .searchQuery:
            return evidence.searchQueries
        }
    }

    private func expectedObservations(
        from evidence: MedicinePackageEvidenceDTO
    ) -> [MedicineRecognitionEvidenceObservationDTO] {
        let sourceValues: [
            (MedicineRecognitionEvidenceSourceDTO, [String])
        ] = [
            (.probableProductName, evidence.probableProductNames),
            (.probableGenericName, evidence.probableGenericNames),
            (.manufacturerName, evidence.manufacturerNames),
            (.approvalIdentifier, evidence.approvalIdentifiers),
            (.visibleText, evidence.visibleTexts),
            (.dosageFormText, evidence.dosageFormTexts),
            (.packagingFeature, evidence.packagingFeatures),
            (.searchQuery, evidence.searchQueries),
        ]
        var seen = Set<ObservationKey>()
        var result: [MedicineRecognitionEvidenceObservationDTO] = []
        for (source, values) in sourceValues {
            for value in values {
                let normalized = normalizer.normalizeName(value)
                guard !normalized.isEmpty else { continue }
                let key = ObservationKey(
                    source: source,
                    normalizedText: normalized
                )
                guard seen.insert(key).inserted else { continue }
                result.append(
                    MedicineRecognitionEvidenceObservationDTO(
                        source: source,
                        observedText: value,
                        normalizedText: normalized
                    )
                )
            }
        }
        return result
    }

    private func validatedIdentityValue(
        _ value: String,
        maximumLength: Int
    ) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == value,
              value.count <= maximumLength
        else {
            throw OnlineMedicineRecognitionFailure.invalidResponse
        }
        return trimmed
    }
}

private struct EvidenceCollection {
    let values: [String]
    let maximumCount: Int
    let maximumLength: Int
}

private enum MatchCategory {
    case exact
    case supporting
    case conflicting
    case unresolved
}

private enum ResponseEvidenceAssurance: Equatable {
    case unreadable
    case noEvidence
    case unresolved
    case supportingOnly
    case ambiguous
    case conflicting
    case uncertain
    case corroborated(String)
    case exact(String)

    var isResolverEligible: Bool {
        switch self {
        case .corroborated, .exact:
            return true
        case .unreadable, .noEvidence, .unresolved, .supportingOnly,
             .ambiguous, .conflicting, .uncertain:
            return false
        }
    }

    var recognizedCandidateID: String? {
        switch self {
        case let .corroborated(identifier), let .exact(identifier):
            return identifier
        case .unreadable, .noEvidence, .unresolved, .supportingOnly,
             .ambiguous, .conflicting, .uncertain:
            return nil
        }
    }
}

private struct ObservationKey: Hashable {
    let source: MedicineRecognitionEvidenceSourceDTO
    let normalizedText: String
}
