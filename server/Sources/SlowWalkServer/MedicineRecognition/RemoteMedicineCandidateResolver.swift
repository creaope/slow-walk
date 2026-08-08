import Foundation
import SlowWalkDataInterfaces
import SlowWalkDomain
import SlowWalkMedicinePipeline

enum MedicineEvidenceAssurance: String, Codable, Sendable, Equatable {
    case unreadable
    case noEvidence = "no_evidence"
    case unresolved
    case supportingOnly = "supporting_only"
    case ambiguous
    case conflicting
    case uncertain
    case corroborated
    case exact

    var permitsResolverSelection: Bool {
        self == .exact || self == .corroborated
    }
}

struct RemoteMedicineCandidateResolution: Sendable, Equatable {
    let assurance: MedicineEvidenceAssurance
    let searchResult: MedicineEvidenceSearchResult
    let resolution: MedicineResolution
}

/// Applies a local evidence-assurance gate, then delegates canonical selection
/// to the existing `MedicineResolver`. Provider/model confidence is never
/// inferred. The resolver confidence field is used only as a binary eligibility
/// adapter after controlled evidence passes this policy.
struct RemoteMedicineCandidateResolver: Sendable {
    /// Binary adapter for the existing resolver gate. This is not a model or
    /// provider probability and deliberately grants no margin above the gate.
    static let resolverEligibilityThreshold =
        ResolverConfiguration.standard.minimumRecognitionConfidence

    private let searchProvider: MedicineEvidenceSearchProvider
    private let normalizer: any MedicineNameNormalizing
    private let resolver: MedicineResolver

    init(
        catalog: MedicineCatalog,
        metadata: [MedicineEvidenceCatalogMetadata] = [],
        normalizer: any MedicineNameNormalizing = MedicineNameNormalizer()
    ) throws {
        searchProvider = try MedicineEvidenceSearchProvider(
            catalog: catalog,
            metadata: metadata,
            normalizer: normalizer
        )
        self.normalizer = normalizer
        resolver = MedicineResolver(normalizer: normalizer)
    }

    init(
        catalogLoader: any MedicineCatalogLoading =
            BundledDemoMedicineCatalogLoader(),
        normalizer: any MedicineNameNormalizing = MedicineNameNormalizer()
    ) throws {
        try self.init(
            catalog: catalogLoader.loadCatalog(),
            metadata: [],
            normalizer: normalizer
        )
    }

    func resolve(
        evidence: RemoteMedicinePackageEvidence,
        capturedAt: Date = Date()
    ) -> RemoteMedicineCandidateResolution {
        let searchResult = searchProvider.search(evidence: evidence)
        let assurance = assurance(
            evidence: evidence,
            searchResult: searchResult
        )
        let input = MedicineRecognitionInput(
            recognizedTexts: resolverTexts(evidence),
            capturedAt: capturedAt,
            languageCode: nil,
            rawConfidence: assurance.permitsResolverSelection
                ? Self.resolverEligibilityThreshold
                : nil
        )
        let normalizedName = normalizer.normalize(input)
        let resolution = resolver.resolve(
            input: input,
            normalizedName: normalizedName,
            medicines: searchResult.candidates.map(\.medicine)
        )

        return RemoteMedicineCandidateResolution(
            assurance: assurance,
            searchResult: searchResult,
            resolution: resolution
        )
    }

    private func resolverTexts(
        _ evidence: RemoteMedicinePackageEvidence
    ) -> [String] {
        guard evidence.imageReadable else { return [] }
        return stableUnique(
            evidence.probableProductNames
                + evidence.probableGenericNames
                + evidence.visibleTexts
        )
    }

    private func assurance(
        evidence: RemoteMedicinePackageEvidence,
        searchResult: MedicineEvidenceSearchResult
    ) -> MedicineEvidenceAssurance {
        guard evidence.imageReadable else { return .unreadable }
        guard !evidence.uncertainRegionsPresent else { return .uncertain }
        guard !searchResult.candidates.isEmpty else {
            return searchResult.unresolvedEvidence.isEmpty
                ? .noEvidence
                : .unresolved
        }
        guard !searchResult.candidates.contains(where: {
            !$0.conflictingEvidence.isEmpty
        }) else {
            return .conflicting
        }

        // An exact overlay match must never unlock a different medicine whose
        // ordinary alias matched the same observation.
        let identityCandidateIDs = Set(searchResult.candidates.compactMap {
            candidate -> String? in
            let hasDirectIdentityEvidence = (
                candidate.exactEvidence + candidate.supportingEvidence
            ).contains {
                $0.source != .searchQuery
                    && [
                        MedicineCatalogEvidenceField.canonicalName,
                        .productName,
                        .genericName,
                        .alias,
                        .approvalIdentifier,
                    ].contains($0.catalogField)
            }
            return hasDirectIdentityEvidence ? candidate.medicine.id : nil
        })
        if identityCandidateIDs.count > 1 {
            return .ambiguous
        }

        let exactIDs = Set(searchResult.candidates.compactMap {
            $0.exactEvidence.isEmpty ? nil : $0.medicine.id
        })
        if exactIDs.count == 1 {
            return .exact
        }
        if exactIDs.count > 1 {
            return .ambiguous
        }

        let corroboratedIDs = searchResult.candidates.compactMap {
            candidate -> String? in
            let hasAlias = candidate.supportingEvidence.contains {
                $0.catalogField == .alias && $0.source != .searchQuery
            }
            let hasIndependentPackagingEvidence =
                candidate.supportingEvidence.contains {
                    [.manufacturerName, .packagingText]
                        .contains($0.catalogField)
                        && $0.source != .searchQuery
                }
            return hasAlias && hasIndependentPackagingEvidence
                ? candidate.medicine.id
                : nil
        }
        if Set(corroboratedIDs).count == 1 {
            return .corroborated
        }

        if searchResult.candidates.contains(where: {
            !$0.supportingEvidence.isEmpty
        }) {
            let supportingCandidateCount = searchResult.candidates.filter {
                !$0.supportingEvidence.isEmpty
            }.count
            return supportingCandidateCount > 1 ? .ambiguous : .supportingOnly
        }
        return .unresolved
    }

    private func stableUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter {
            let key = normalizer.normalizeName($0)
            return !key.isEmpty && seen.insert(key).inserted
        }
    }
}
