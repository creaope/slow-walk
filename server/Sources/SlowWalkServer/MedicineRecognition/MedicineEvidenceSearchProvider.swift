import Foundation
import SlowWalkDataInterfaces
import SlowWalkDomain
import SlowWalkMedicinePipeline

enum MedicineEvidenceSource: String, Codable, Sendable, CaseIterable, Hashable {
    case probableProductName = "probable_product_name"
    case probableGenericName = "probable_generic_name"
    case manufacturerName = "manufacturer_name"
    case approvalIdentifier = "approval_identifier"
    case visibleText = "visible_text"
    case dosageFormText = "dosage_form_text"
    case packagingFeature = "packaging_feature"
    case searchQuery = "search_query"
}

enum MedicineCatalogEvidenceField: String, Codable, Sendable, CaseIterable, Hashable {
    case canonicalName = "canonical_name"
    case productName = "product_name"
    case genericName = "generic_name"
    case alias
    case manufacturerName = "manufacturer_name"
    case approvalIdentifier = "approval_identifier"
    case packagingText = "packaging_text"
}

struct MedicineEvidenceQuery: Codable, Sendable, Equatable, Hashable {
    let source: MedicineEvidenceSource
    let normalizedText: String
}

struct MedicineEvidenceObservation: Codable, Sendable, Equatable, Hashable {
    let source: MedicineEvidenceSource
    let observedText: String
    let normalizedText: String
}

struct MedicineEvidenceMatch: Codable, Sendable, Equatable, Hashable {
    let source: MedicineEvidenceSource
    let observedText: String
    let normalizedObservedText: String
    let catalogField: MedicineCatalogEvidenceField
    let catalogText: String
}

/// Optional controlled packaging metadata. `medicineID` is only a foreign key
/// to the canonical `Medicine`; this type never defines another identity.
struct MedicineEvidenceCatalogMetadata: Sendable, Equatable, Hashable {
    let medicineID: String
    let productNames: [String]
    let genericNames: [String]
    let manufacturerNames: [String]
    let approvalIdentifiers: [String]
    let packagingTexts: [String]

    init(
        medicineID: String,
        productNames: [String] = [],
        genericNames: [String] = [],
        manufacturerNames: [String] = [],
        approvalIdentifiers: [String] = [],
        packagingTexts: [String] = []
    ) {
        self.medicineID = medicineID
        self.productNames = productNames
        self.genericNames = genericNames
        self.manufacturerNames = manufacturerNames
        self.approvalIdentifiers = approvalIdentifiers
        self.packagingTexts = packagingTexts
    }
}

enum MedicineEvidenceSearchConfigurationError: Error, Sendable, Equatable {
    case duplicateMetadataMedicineID(String)
    case unknownMetadataMedicineID(String)
}

struct MedicineEvidenceCandidate: Sendable, Equatable, Hashable {
    /// The existing canonical catalog value, not a remote/model identity.
    let medicine: Medicine
    let exactEvidence: [MedicineEvidenceMatch]
    let supportingEvidence: [MedicineEvidenceMatch]
    let conflictingEvidence: [MedicineEvidenceMatch]
    let unresolvedEvidence: [MedicineEvidenceMatch]
}

struct MedicineEvidenceSearchResult: Sendable, Equatable {
    let queries: [MedicineEvidenceQuery]
    let candidates: [MedicineEvidenceCandidate]
    let unresolvedEvidence: [MedicineEvidenceObservation]
}

protocol MedicineEvidenceSearching: Sendable {
    func search(
        evidence: RemoteMedicinePackageEvidence
    ) -> MedicineEvidenceSearchResult
}

/// Searches only a validated, in-memory medicine catalog and an optional
/// catalog-owned metadata overlay. It performs no network or open-web lookup.
struct MedicineEvidenceSearchProvider: MedicineEvidenceSearching, Sendable {
    static let maximumQueryCount = 32
    static let maximumNormalizedQueryLength = 96

    private let medicines: [Medicine]
    private let metadataByMedicineID: [String: MedicineEvidenceCatalogMetadata]
    private let normalizer: any MedicineNameNormalizing

    init(
        catalog: MedicineCatalog,
        metadata: [MedicineEvidenceCatalogMetadata] = [],
        normalizer: any MedicineNameNormalizing = MedicineNameNormalizer()
    ) throws {
        let medicineIDs = Set(catalog.medicines.map(\.id))
        var metadataByMedicineID =
            [String: MedicineEvidenceCatalogMetadata]()
        for entry in metadata {
            guard medicineIDs.contains(entry.medicineID) else {
                throw MedicineEvidenceSearchConfigurationError
                    .unknownMetadataMedicineID(entry.medicineID)
            }
            guard metadataByMedicineID[entry.medicineID] == nil else {
                throw MedicineEvidenceSearchConfigurationError
                    .duplicateMetadataMedicineID(entry.medicineID)
            }
            metadataByMedicineID[entry.medicineID] = entry
        }

        medicines = catalog.medicines.sorted(by: Self.medicineOrder)
        self.metadataByMedicineID = metadataByMedicineID
        self.normalizer = normalizer
    }

    func search(
        evidence: RemoteMedicinePackageEvidence
    ) -> MedicineEvidenceSearchResult {
        let observations = makeObservations(evidence)
        let queries = makeQueries(evidence)
        guard evidence.imageReadable else {
            return MedicineEvidenceSearchResult(
                queries: queries,
                candidates: [],
                unresolvedEvidence: observations
            )
        }

        var accumulators = [String: CandidateAccumulator]()
        for observation in observations {
            for medicine in medicines {
                let metadata = metadataByMedicineID[medicine.id]
                let fields = catalogFields(
                    for: observation.source,
                    medicine: medicine,
                    metadata: metadata
                )
                for field in fields {
                    if isExact(observation.normalizedText, field) {
                        let match = makeMatch(observation, field)
                        accumulators[medicine.id, default: .init(medicine: medicine)]
                            .appendExact(
                                match,
                                isStrong: isStrongExact(match)
                            )
                    }
                }
            }
        }

        // Auxiliary-only matches participate in conflict detection, but are
        // filtered from candidate recall.
        let allAccumulators = accumulators
        accumulators = accumulators.filter { _, accumulator in
            accumulator.hasIdentityEvidence
        }
        var matchedObservations = Set(
            accumulators.values.flatMap { accumulator in
                (
                    accumulator.exactEvidence
                        + accumulator.supportingEvidence
                        + accumulator.unresolvedEvidence
                ).map(ObservationKey.init)
            }
        )

        let conflict = conflictEvidence(in: allAccumulators)
        for medicineID in accumulators.keys {
            matchedObservations.formUnion(
                conflict.matchesByMedicineID[medicineID, default: []]
                    .map(ObservationKey.init)
            )
        }
        let candidates = accumulators.values
            .map { accumulator in
                MedicineEvidenceCandidate(
                    medicine: accumulator.medicine,
                    exactEvidence: stableMatches(accumulator.exactEvidence),
                    supportingEvidence: stableMatches(
                        accumulator.supportingEvidence
                    ),
                    conflictingEvidence: conflict.matchesByMedicineID[
                        accumulator.medicine.id,
                        default: []
                    ],
                    unresolvedEvidence: stableMatches(
                        accumulator.unresolvedEvidence
                    )
                )
            }
            .sorted(by: Self.candidateOrder)

        return MedicineEvidenceSearchResult(
            queries: queries,
            candidates: candidates,
            unresolvedEvidence: observations.filter {
                !matchedObservations.contains(ObservationKey($0))
            }
        )
    }

    private func makeQueries(
        _ evidence: RemoteMedicinePackageEvidence
    ) -> [MedicineEvidenceQuery] {
        let sourceValues: [(MedicineEvidenceSource, [String])] = [
            (.probableProductName, evidence.probableProductNames),
            (.probableGenericName, evidence.probableGenericNames),
            (.manufacturerName, evidence.manufacturerNames),
            (.approvalIdentifier, evidence.approvalIdentifiers),
            (.searchQuery, evidence.searchQueries),
        ]
        var seen = Set<String>()
        var result = [MedicineEvidenceQuery]()

        for (source, values) in sourceValues {
            for value in values {
                let normalized = normalizer.normalizeName(value)
                guard !normalized.isEmpty,
                      normalized.count <= Self.maximumNormalizedQueryLength,
                      seen.insert(normalized).inserted else {
                    continue
                }
                result.append(
                    MedicineEvidenceQuery(
                        source: source,
                        normalizedText: normalized
                    )
                )
                if result.count == Self.maximumQueryCount {
                    return result
                }
            }
        }
        return result
    }

    private func makeObservations(
        _ evidence: RemoteMedicinePackageEvidence
    ) -> [MedicineEvidenceObservation] {
        let sourceValues: [(MedicineEvidenceSource, [String])] = [
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
        var result = [MedicineEvidenceObservation]()

        for (source, values) in sourceValues {
            for value in values {
                let normalized = normalizer.normalizeName(value)
                guard !normalized.isEmpty else { continue }
                let observation = MedicineEvidenceObservation(
                    source: source,
                    observedText: value,
                    normalizedText: normalized
                )
                guard seen.insert(ObservationKey(observation)).inserted else {
                    continue
                }
                result.append(observation)
            }
        }
        return result
    }

    private func catalogFields(
        for source: MedicineEvidenceSource,
        medicine: Medicine,
        metadata: MedicineEvidenceCatalogMetadata?
    ) -> [CatalogFieldValue] {
        let canonical = [CatalogFieldValue(
            field: .canonicalName,
            text: medicine.canonicalName
        )]
        let aliases = medicine.aliases.map {
            CatalogFieldValue(field: .alias, text: $0)
        }
        let productNames = (metadata?.productNames ?? []).map {
            CatalogFieldValue(field: .productName, text: $0)
        }
        let genericNames = (metadata?.genericNames ?? []).map {
            CatalogFieldValue(field: .genericName, text: $0)
        }
        let manufacturers = (metadata?.manufacturerNames ?? []).map {
            CatalogFieldValue(field: .manufacturerName, text: $0)
        }
        let approvals = (metadata?.approvalIdentifiers ?? []).map {
            CatalogFieldValue(field: .approvalIdentifier, text: $0)
        }
        let packaging = (metadata?.packagingTexts ?? []).map {
            CatalogFieldValue(field: .packagingText, text: $0)
        }

        return switch source {
        case .probableProductName:
            canonical + productNames + aliases
        case .probableGenericName:
            canonical + genericNames + aliases
        case .manufacturerName:
            manufacturers
        case .approvalIdentifier:
            approvals
        case .visibleText:
            canonical + productNames + genericNames + aliases
                + manufacturers + approvals + packaging
        case .dosageFormText, .packagingFeature:
            packaging
        case .searchQuery:
            canonical + productNames + genericNames + aliases
                + manufacturers + approvals + packaging
        }
    }

    private func isExact(
        _ normalizedObservation: String,
        _ field: CatalogFieldValue
    )
        -> Bool
    {
        let normalizedCatalogText = normalizer.normalizeName(field.text)
        // These controlled identifiers must retain every token. In particular,
        // normalizeQuery intentionally removes manufacturer/approval markers
        // and is therefore too permissive for these fields.
        if [.manufacturerName, .approvalIdentifier].contains(field.field) {
            return normalizedObservation == normalizedCatalogText
        }
        let observationVariants = comparisonVariants(normalizedObservation)
        let catalogVariants = comparisonVariants(
            normalizedCatalogText
        )
        return !observationVariants.isDisjoint(with: catalogVariants)
    }

    private func comparisonVariants(_ normalizedText: String) -> Set<String> {
        var variants = Set([normalizedText])
        let query = normalizer.normalizeQuery(normalizedText)
        if !query.isEmpty {
            variants.insert(query)
        }
        return Set(variants.filter { !$0.isEmpty })
    }

    private func makeMatch(
        _ observation: MedicineEvidenceObservation,
        _ field: CatalogFieldValue
    ) -> MedicineEvidenceMatch {
        MedicineEvidenceMatch(
            source: observation.source,
            observedText: observation.observedText,
            normalizedObservedText: observation.normalizedText,
            catalogField: field.field,
            catalogText: field.text
        )
    }

    private func isStrongExact(_ match: MedicineEvidenceMatch) -> Bool {
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
            true
        default:
            false
        }
    }

    private func conflictEvidence(
        in accumulators: [String: CandidateAccumulator]
    ) -> ConflictEvidence {
        let grouped = Dictionary(grouping: accumulators.values.flatMap { value in
            (value.exactEvidence + value.supportingEvidence)
                .filter { $0.source != .searchQuery }
                .map { GroupedMatch(medicineID: value.medicine.id, match: $0) }
        }) { ObservationKey($0.match) }
        let groups = grouped.values.map { Set($0.map(\.medicineID)) }
        guard groups.count > 1 else { return .none }

        let sharedCandidates = groups.dropFirst().reduce(groups[0]) {
            $0.intersection($1)
        }
        guard sharedCandidates.isEmpty else { return .none }

        var matchesByMedicineID = [String: [MedicineEvidenceMatch]]()
        let allMatches = grouped.values.flatMap { $0 }
        for candidate in accumulators.values {
            matchesByMedicineID[candidate.medicine.id] = stableMatches(
                allMatches
                    .filter { $0.medicineID != candidate.medicine.id }
                    .map(\.match)
            )
        }
        return ConflictEvidence(matchesByMedicineID: matchesByMedicineID)
    }

    private func stableMatches(
        _ matches: [MedicineEvidenceMatch]
    ) -> [MedicineEvidenceMatch] {
        Array(Set(matches)).sorted(by: Self.matchOrder)
    }

    private static func candidateOrder(
        _ lhs: MedicineEvidenceCandidate,
        _ rhs: MedicineEvidenceCandidate
    ) -> Bool {
        if lhs.exactEvidence.count != rhs.exactEvidence.count {
            return lhs.exactEvidence.count > rhs.exactEvidence.count
        }
        if lhs.supportingEvidence.count != rhs.supportingEvidence.count {
            return lhs.supportingEvidence.count > rhs.supportingEvidence.count
        }
        if lhs.unresolvedEvidence.count != rhs.unresolvedEvidence.count {
            return lhs.unresolvedEvidence.count > rhs.unresolvedEvidence.count
        }
        if lhs.medicine.canonicalName != rhs.medicine.canonicalName {
            return lhs.medicine.canonicalName < rhs.medicine.canonicalName
        }
        return lhs.medicine.id < rhs.medicine.id
    }

    private static func matchOrder(
        _ lhs: MedicineEvidenceMatch,
        _ rhs: MedicineEvidenceMatch
    ) -> Bool {
        let sourceOrder = Dictionary(
            uniqueKeysWithValues: MedicineEvidenceSource.allCases
                .enumerated().map { ($0.element, $0.offset) }
        )
        let fieldOrder = Dictionary(
            uniqueKeysWithValues: MedicineCatalogEvidenceField.allCases
                .enumerated().map { ($0.element, $0.offset) }
        )
        let leftKey = (
            sourceOrder[lhs.source, default: .max],
            lhs.normalizedObservedText,
            fieldOrder[lhs.catalogField, default: .max],
            lhs.catalogText
        )
        let rightKey = (
            sourceOrder[rhs.source, default: .max],
            rhs.normalizedObservedText,
            fieldOrder[rhs.catalogField, default: .max],
            rhs.catalogText
        )
        return leftKey < rightKey
    }

    private static func medicineOrder(_ lhs: Medicine, _ rhs: Medicine) -> Bool {
        if lhs.canonicalName != rhs.canonicalName {
            return lhs.canonicalName < rhs.canonicalName
        }
        return lhs.id < rhs.id
    }
}

private struct CatalogFieldValue {
    let field: MedicineCatalogEvidenceField
    let text: String
}

private struct ObservationKey: Hashable {
    let source: MedicineEvidenceSource
    let normalizedText: String

    init(_ observation: MedicineEvidenceObservation) {
        source = observation.source
        normalizedText = observation.normalizedText
    }

    init(_ match: MedicineEvidenceMatch) {
        source = match.source
        normalizedText = match.normalizedObservedText
    }
}

private struct GroupedMatch {
    let medicineID: String
    let match: MedicineEvidenceMatch
}

private struct ConflictEvidence {
    static let none = ConflictEvidence(matchesByMedicineID: [:])

    let matchesByMedicineID: [String: [MedicineEvidenceMatch]]
}

private struct CandidateAccumulator {
    let medicine: Medicine
    var exactEvidence = [MedicineEvidenceMatch]()
    var supportingEvidence = [MedicineEvidenceMatch]()
    var unresolvedEvidence = [MedicineEvidenceMatch]()

    var hasIdentityEvidence: Bool {
        (exactEvidence + supportingEvidence + unresolvedEvidence).contains {
            [
                MedicineCatalogEvidenceField.canonicalName,
                .productName,
                .genericName,
                .alias,
                .approvalIdentifier,
            ].contains($0.catalogField)
        }
    }

    mutating func appendExact(
        _ match: MedicineEvidenceMatch,
        isStrong: Bool
    ) {
        if isStrong {
            exactEvidence.append(match)
        } else {
            supportingEvidence.append(match)
        }
    }

}
