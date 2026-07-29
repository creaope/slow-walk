import Foundation
import SlowWalkDomain

@available(macOS 14.0, iOS 17.0, *)
public struct MedicineKnowledgeService:
    MedicineKnowledgeSearching,
    Sendable
{
    private let sources: [any MedicineKnowledgeSource]
    private let sourceDescriptors: [String: SourceDescriptor]
    private let policy: SourcePolicy
    private let cache: any MedicineKnowledgeCaching
    private let clock: any Clock

    public init(
        sources: [any MedicineKnowledgeSource],
        policy: SourcePolicy,
        cache: any MedicineKnowledgeCaching =
            InMemoryMedicineKnowledgeCache(),
        clock: any Clock
    ) throws {
        let orderedSources = try policy.orderedSources(sources)
        self.sources = orderedSources
        sourceDescriptors = Dictionary(
            uniqueKeysWithValues: orderedSources.map {
                (
                    $0.identifier,
                    SourceDescriptor(
                        identifier: $0.identifier,
                        priority: $0.priority,
                        isAuthoritative:
                            $0.isAuthoritative
                    )
                )
            }
        )
        self.policy = policy
        self.cache = cache
        self.clock = clock
    }

    public func search(
        query: MedicineKnowledgeQuery
    ) async throws -> MedicineKnowledgeSearchResult {
        let normalizedQuery = query.normalizedQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedQuery.isEmpty else {
            throw MedicineKnowledgeError.malformedRequest
        }

        let now = clock.now()
        let lookup = try await cache.lookup(
            normalizedQuery: normalizedQuery,
            now: now
        )
        if lookup.status == .hit,
            let cachedResult = lookup.entry?.result
        {
            return copy(
                cachedResult,
                cacheStatus: .hit,
                generatedAt: now
            )
        }

        var responses = [
            String: MedicineKnowledgeSourceResponse
        ]()
        var warnings = [MedicineKnowledgeWarning]()
        var failures = [MedicineKnowledgeError]()
        var usedNotModified = false

        for source in sources {
            let cachedResponse =
                lookup.entry?.sourceResponses[source.identifier]
            do {
                let response = try await source.search(
                    query: MedicineKnowledgeSourceQuery(
                        normalizedQuery: normalizedQuery,
                        validationMetadata:
                            cachedResponse?
                                .validationMetadata
                    )
                )
                if response.validationStatus == .notModified {
                    guard let cachedResponse else {
                        let error = MedicineKnowledgeError
                            .invalidSourceResponse(
                                sourceIdentifier:
                                    source.identifier
                            )
                        failures.append(error)
                        warnings.append(warning(for: error))
                        continue
                    }
                    do {
                        warnings.append(
                            contentsOf: try policy.validate(
                                response: response,
                                from: source,
                                now: now
                            )
                        )
                    } catch let error as SourcePolicyError {
                        let knowledgeError = map(
                            policyError: error,
                            sourceIdentifier:
                                source.identifier
                        )
                        failures.append(knowledgeError)
                        warnings.append(
                            warning(for: knowledgeError)
                        )
                        continue
                    }
                    responses[source.identifier] =
                        cachedResponse
                    usedNotModified = true
                    continue
                }
                do {
                    warnings.append(
                        contentsOf: try policy.validate(
                            response: response,
                            from: source,
                            now: now
                        )
                    )
                    responses[source.identifier] = response
                } catch let error as SourcePolicyError {
                    let knowledgeError = map(
                        policyError: error,
                        sourceIdentifier: source.identifier
                    )
                    failures.append(knowledgeError)
                    warnings.append(
                        warning(for: knowledgeError)
                    )
                }
            } catch let error as MedicineKnowledgeError {
                if error == .requestCancelled {
                    throw error
                }
                failures.append(error)
                if error != .medicineNotFound {
                    warnings.append(warning(for: error))
                }
            } catch is CancellationError {
                throw MedicineKnowledgeError.requestCancelled
            } catch {
                let knowledgeError = MedicineKnowledgeError
                    .knowledgeSourceUnavailable(
                        sourceIdentifier: source.identifier
                    )
                failures.append(knowledgeError)
                warnings.append(warning(for: knowledgeError))
            }
        }

        guard !responses.isEmpty else {
            return try offlineResultOrThrow(
                lookup: lookup,
                failures: failures,
                warnings: warnings,
                generatedAt: now
            )
        }

        let cacheStatus = onlineCacheStatus(
            lookup: lookup,
            responses: responses,
            usedNotModified: usedNotModified
        )
        let result = try aggregate(
            normalizedQuery: normalizedQuery,
            responses: responses,
            warnings: warnings,
            cacheStatus: cacheStatus,
            generatedAt: now
        )
        try await cache.store(
            result: result,
            sourceResponses: responses,
            now: now
        )
        return result
    }

    private func offlineResultOrThrow(
        lookup: MedicineKnowledgeCacheLookup,
        failures: [MedicineKnowledgeError],
        warnings: [MedicineKnowledgeWarning],
        generatedAt: Date
    ) throws -> MedicineKnowledgeSearchResult {
        if let entry = lookup.entry, lookup.canUseOffline {
            let offlineWarning = MedicineKnowledgeWarning(
                code: .offlineCacheUsed,
                message:
                    "Live sources were unavailable. Stale cached demo data is being used and is not current authoritative data.",
                sourceIdentifiers: []
            )
            return offlineCopy(
                entry.result,
                warnings: warnings + [offlineWarning],
                generatedAt: generatedAt
            )
        }
        if lookup.entry != nil {
            throw MedicineKnowledgeError.offlineCacheUnavailable
        }
        if failures.allSatisfy({
            $0 == .medicineNotFound
        }), !failures.isEmpty {
            throw MedicineKnowledgeError.medicineNotFound
        }
        if let error = failures.first(where: {
            if case .sourceVersionUnsupported = $0 {
                return true
            }
            return false
        }) {
            throw error
        }
        if failures.contains(where: {
            if case .invalidSourceResponse = $0 {
                return true
            }
            return false
        }) {
            throw MedicineKnowledgeError.invalidSourceResponse(
                sourceIdentifier: nil
            )
        }
        if failures.contains(where: {
            if case .knowledgeSourceTimeout = $0 {
                return true
            }
            return false
        }) {
            throw MedicineKnowledgeError.knowledgeSourceTimeout(
                sourceIdentifier: nil
            )
        }
        throw MedicineKnowledgeError.knowledgeSourceUnavailable(
            sourceIdentifier: nil
        )
    }

    private func onlineCacheStatus(
        lookup: MedicineKnowledgeCacheLookup,
        responses: [String: MedicineKnowledgeSourceResponse],
        usedNotModified: Bool
    ) -> MedicineKnowledgeCacheStatus {
        guard let oldResponses =
            lookup.entry?.sourceResponses
        else {
            return .miss
        }
        let versionChanged = responses.contains { identifier, value in
            guard let oldValue = oldResponses[identifier] else {
                return true
            }
            return oldValue.sourceDocumentVersion
                != value.sourceDocumentVersion
        }
        if versionChanged {
            return .sourceVersionChanged
        }
        if lookup.status == .expired || usedNotModified {
            return .revalidated
        }
        return .miss
    }

    private func aggregate(
        normalizedQuery: String,
        responses: [String: MedicineKnowledgeSourceResponse],
        warnings: [MedicineKnowledgeWarning],
        cacheStatus: MedicineKnowledgeCacheStatus,
        generatedAt: Date
    ) throws -> MedicineKnowledgeSearchResult {
        let records = responses.values.flatMap(\.records)
        guard !records.isEmpty else {
            throw MedicineKnowledgeError.medicineNotFound
        }
        let groupedRecords = Dictionary(
            grouping: records,
            by: \.canonicalMedicineIdentifier
        )
        var allWarnings = warnings
        var candidates = [MedicineKnowledgeCandidate]()

        for identifier in groupedRecords.keys.sorted() {
            guard let values = groupedRecords[identifier] else {
                continue
            }
            let candidate = makeCandidate(
                identifier: identifier,
                records: values,
                responses: responses,
                inheritedWarnings: warnings
            )
            candidates.append(candidate)
            allWarnings.append(contentsOf: candidate.warnings)
        }
        guard !candidates.isEmpty else {
            throw MedicineKnowledgeError.medicineNotFound
        }
        candidates.sort {
            if $0.completeness == $1.completeness {
                return $0.medicine.id < $1.medicine.id
            }
            return $0.completeness > $1.completeness
        }

        allWarnings = stableWarnings(allWarnings)
        let hasConflicts = candidates.contains {
            !$0.conflicts.isEmpty
        }
        let hasAuthoritativeResponse = responses.keys.contains {
            sourceDescriptors[$0]?.isAuthoritative == true
        }
        let hasStaleWarning = allWarnings.contains {
            $0.code == .sourceStale
        }
        let sourceStatus: MedicineKnowledgeSourceStatus
        if hasConflicts {
            sourceStatus = .conflicting
        } else if !hasAuthoritativeResponse || hasStaleWarning {
            sourceStatus = .partial
        } else if responses.count > 1 {
            sourceStatus = .corroborated
        } else {
            sourceStatus = .authoritative
        }

        let sourceReferences = stableSourceReferences(
            responses.values.map(\.sourceReference)
        )
        let sourceVersions = Dictionary(
            uniqueKeysWithValues: responses.map {
                ($0.key, $0.value.sourceDocumentVersion)
            }
        )
        let completeness = candidates
            .map(\.completeness)
            .min() ?? 0

        return MedicineKnowledgeSearchResult(
            normalizedQuery: normalizedQuery,
            candidates: candidates,
            sourceStatus: sourceStatus,
            cacheStatus: cacheStatus,
            completeness: completeness,
            sourceReferences: sourceReferences,
            warnings: allWarnings,
            sourceVersions: sourceVersions,
            generatedAt: generatedAt,
            isOffline: false
        )
    }

    private func makeCandidate(
        identifier: String,
        records: [MedicineKnowledgeRecord],
        responses:
            [String: MedicineKnowledgeSourceResponse],
        inheritedWarnings: [MedicineKnowledgeWarning]
    ) -> MedicineKnowledgeCandidate {
        let orderedRecords = records.sorted {
            let lhs = sourceDescriptors[$0.sourceIdentifier]
            let rhs = sourceDescriptors[$1.sourceIdentifier]
            if lhs?.priority == rhs?.priority {
                return $0.sourceIdentifier
                    < $1.sourceIdentifier
            }
            return (lhs?.priority ?? Int.min)
                > (rhs?.priority ?? Int.min)
        }
        let primary = orderedRecords[0]
        let primaryDescriptor =
            sourceDescriptors[primary.sourceIdentifier]
        var conflicts = [MedicineSourceConflict]()
        for record in orderedRecords.dropFirst() {
            conflicts.append(
                contentsOf: conflictsBetween(
                    primary: primary,
                    other: record
                )
            )
        }
        conflicts.sort {
            if $0.field == $1.field {
                return $0.conflictingSourceIdentifier
                    < $1.conflictingSourceIdentifier
            }
            return $0.field < $1.field
        }

        var candidateWarnings = inheritedWarnings
        if !conflicts.isEmpty {
            candidateWarnings.append(
                MedicineKnowledgeWarning(
                    code: .sourceConflict,
                    message:
                        "Trusted sources disagree on one or more medicine fields. The higher-priority value is retained with conflict evidence and requires confirmation.",
                    sourceIdentifiers: stableStrings(
                        orderedRecords.map(
                            \.sourceIdentifier
                        )
                    )
                )
            )
        }
        let hasAuthoritativeRecord = orderedRecords.contains {
            sourceDescriptors[$0.sourceIdentifier]?
                .isAuthoritative == true
        }
        if !hasAuthoritativeRecord {
            candidateWarnings.append(
                MedicineKnowledgeWarning(
                    code: .authoritativeSourceMissing,
                    message:
                        "No authoritative whitelisted source supplied this candidate.",
                    sourceIdentifiers: stableStrings(
                        orderedRecords.map(
                            \.sourceIdentifier
                        )
                    )
                )
            )
        }
        let hasStaleSource = candidateWarnings.contains {
            $0.code == .sourceStale
                || $0.code == .sourceRecordStale
                || $0.code == .offlineCacheUsed
        }
        let hasValidationConcern =
            orderedRecords.contains {
                $0.validationStatus != .valid
                    || $0.completeness
                    < policy.minimumCompleteness
            }
            || !candidateWarnings.isEmpty
        let mayUseDosage = primaryDescriptor?
            .isAuthoritative == true
            && primary.validationStatus == .valid
            && primary.completeness
            >= policy.minimumCompleteness
            && conflicts.allSatisfy {
                $0.field != "dosageTextFromSource"
            }
            && !hasStaleSource
            && !hasValidationConcern
        let dosageText: String?
        if mayUseDosage {
            dosageText = primary.dosageTextFromSource
        } else {
            dosageText = nil
            if primary.dosageTextFromSource != nil {
                candidateWarnings.append(
                    MedicineKnowledgeWarning(
                        code: .dosageSuppressed,
                        message:
                            "Source-provided dosage text was suppressed because source governance requires confirmation.",
                        sourceIdentifiers: [
                            primary.sourceIdentifier,
                        ]
                    )
                )
            }
        }

        let references = stableSourceReferences(
            orderedRecords.map(\.sourceReference)
                + orderedRecords.compactMap {
                    responses[$0.sourceIdentifier]?
                        .sourceReference
                }
        )
        let versions = orderedRecords.map {
            "\($0.sourceIdentifier)=\($0.sourceDocumentVersion)"
        }
        .sorted()
        let medicine = Medicine(
            id: identifier,
            canonicalName: primary.canonicalName,
            aliases: stableStrings(
                orderedRecords.flatMap(\.aliases)
            ),
            activeIngredientIDs:
                primary.activeIngredientIDs,
            medicineCategory: primary.category,
            sourceReferences: references,
            dosageTextFromSource: dosageText,
            contraindicationTags:
                primary.contraindicationTags,
            warnings: stableStrings(
                orderedRecords.flatMap(\.warnings)
                    + candidateWarnings.map(\.message)
                    + [
                        MedicineKnowledgeSafety
                            .demoDisclaimer,
                    ]
            ),
            dataVersion: versions.joined(separator: ";")
        )
        var completeness = orderedRecords
            .map(\.completeness)
            .min() ?? 0
        if !conflicts.isEmpty {
            completeness = max(
                0,
                completeness - policy.conflictPenalty
            )
        }
        if !hasAuthoritativeRecord || hasStaleSource {
            completeness = min(
                completeness,
                policy.minimumCompleteness
            )
        }
        let requiresConfirmation =
            !conflicts.isEmpty
            || !hasAuthoritativeRecord
            || hasStaleSource
            || hasValidationConcern
            || completeness
            < policy.minimumCompleteness
        let validationStatus:
            MedicineKnowledgeValidationStatus =
                requiresConfirmation ? .warning : .valid
        let stableCandidateWarnings = stableWarnings(
            candidateWarnings
        )
        let hasUnverifiableProvenance =
            !hasAuthoritativeRecord
            || stableCandidateWarnings.contains {
                $0.code == .provenanceUnverifiable
                    || $0.code
                    == .invalidSourceResponse
                    || $0.code
                    == .sourceVersionUnsupported
            }
        let verdict = KnowledgeGovernanceVerdict(
            validationStatus: validationStatus,
            completeness: completeness,
            provenanceStatus: !conflicts.isEmpty
                ? .conflicting
                : hasUnverifiableProvenance
                    ? .unverifiable
                    : .verified,
            freshnessStatus: hasStaleSource
                ? .stale
                : .current,
            requiresConfirmation: requiresConfirmation,
            requiresConservativeAction:
                requiresConfirmation,
            allowsDosageDisplay:
                mayUseDosage
                && !requiresConfirmation,
            warnings: stableCandidateWarnings,
            sourceReferences: references
        )

        return MedicineKnowledgeCandidate(
            medicine: medicine,
            completeness: completeness,
            validationStatus: validationStatus,
            sourceIdentifiers: stableStrings(
                orderedRecords.map(\.sourceIdentifier)
            ),
            conflicts: conflicts,
            warnings: stableCandidateWarnings,
            requiresConfirmation: requiresConfirmation,
            governanceVerdict: verdict
        )
    }

    private func conflictsBetween(
        primary: MedicineKnowledgeRecord,
        other: MedicineKnowledgeRecord
    ) -> [MedicineSourceConflict] {
        var conflicts = [MedicineSourceConflict]()
        appendConflict(
            to: &conflicts,
            medicineIdentifier:
                primary.canonicalMedicineIdentifier,
            field: "canonicalName",
            preferredSource: primary.sourceIdentifier,
            conflictingSource: other.sourceIdentifier,
            preferredValue: primary.canonicalName,
            conflictingValue: other.canonicalName,
            valuesDiffer:
                primary.canonicalName
                    .caseInsensitiveCompare(
                        other.canonicalName
                    ) != .orderedSame
        )
        let primaryIngredients = primary.activeIngredientIDs
            .sorted()
        let otherIngredients = other.activeIngredientIDs
            .sorted()
        appendConflict(
            to: &conflicts,
            medicineIdentifier:
                primary.canonicalMedicineIdentifier,
            field: "activeIngredientIDs",
            preferredSource: primary.sourceIdentifier,
            conflictingSource: other.sourceIdentifier,
            preferredValue:
                primaryIngredients.joined(separator: ","),
            conflictingValue:
                otherIngredients.joined(separator: ","),
            valuesDiffer: primaryIngredients
                != otherIngredients
        )
        appendConflict(
            to: &conflicts,
            medicineIdentifier:
                primary.canonicalMedicineIdentifier,
            field: "category",
            preferredSource: primary.sourceIdentifier,
            conflictingSource: other.sourceIdentifier,
            preferredValue: primary.category.rawValue,
            conflictingValue: other.category.rawValue,
            valuesDiffer: primary.category != other.category
        )
        if let preferredDosage =
            primary.dosageTextFromSource,
            let conflictingDosage =
                other.dosageTextFromSource
        {
            appendConflict(
                to: &conflicts,
                medicineIdentifier:
                    primary.canonicalMedicineIdentifier,
                field: "dosageTextFromSource",
                preferredSource:
                    primary.sourceIdentifier,
                conflictingSource:
                    other.sourceIdentifier,
                preferredValue: preferredDosage,
                conflictingValue: conflictingDosage,
                valuesDiffer: preferredDosage
                    != conflictingDosage
            )
        }
        let primaryTags = primary.contraindicationTags
            .sorted()
        let otherTags = other.contraindicationTags
            .sorted()
        appendConflict(
            to: &conflicts,
            medicineIdentifier:
                primary.canonicalMedicineIdentifier,
            field: "contraindicationTags",
            preferredSource: primary.sourceIdentifier,
            conflictingSource: other.sourceIdentifier,
            preferredValue: primaryTags.joined(separator: ","),
            conflictingValue: otherTags.joined(separator: ","),
            valuesDiffer: primaryTags != otherTags
        )
        return conflicts
    }

    private func appendConflict(
        to conflicts: inout [MedicineSourceConflict],
        medicineIdentifier: String,
        field: String,
        preferredSource: String,
        conflictingSource: String,
        preferredValue: String,
        conflictingValue: String,
        valuesDiffer: Bool
    ) {
        guard valuesDiffer else {
            return
        }
        conflicts.append(
            MedicineSourceConflict(
                medicineIdentifier: medicineIdentifier,
                field: field,
                preferredSourceIdentifier: preferredSource,
                conflictingSourceIdentifier:
                    conflictingSource,
                preferredValue: preferredValue,
                conflictingValue: conflictingValue
            )
        )
    }

    private func map(
        policyError: SourcePolicyError,
        sourceIdentifier: String
    ) -> MedicineKnowledgeError {
        if case let .unsupportedDataVersion(_, version) =
            policyError
        {
            return .sourceVersionUnsupported(
                sourceIdentifier: sourceIdentifier,
                version: version
            )
        }
        return .invalidSourceResponse(
            sourceIdentifier: sourceIdentifier
        )
    }

    private func warning(
        for error: MedicineKnowledgeError
    ) -> MedicineKnowledgeWarning {
        switch error {
        case .knowledgeSourceUnavailable(let identifier):
            return MedicineKnowledgeWarning(
                code: .sourceUnavailable,
                message: "A whitelisted source was unavailable.",
                sourceIdentifiers: identifier.map { [$0] } ?? []
            )
        case .knowledgeSourceTimeout(let identifier):
            return MedicineKnowledgeWarning(
                code: .sourceTimeout,
                message: "A whitelisted source timed out.",
                sourceIdentifiers: identifier.map { [$0] } ?? []
            )
        case .invalidSourceResponse(let identifier):
            return MedicineKnowledgeWarning(
                code: .invalidSourceResponse,
                message:
                    "A source response failed structural or policy validation.",
                sourceIdentifiers: identifier.map { [$0] } ?? []
            )
        case .sourceVersionUnsupported(
            let identifier,
            _
        ):
            return MedicineKnowledgeWarning(
                code: .sourceVersionUnsupported,
                message:
                    "A source data version is not supported and was not trusted or cached.",
                sourceIdentifiers: [identifier]
            )
        case .offlineCacheUnavailable:
            return MedicineKnowledgeWarning(
                code: .offlineCacheUnavailable,
                message: "No offline cache entry is safe to use."
            )
        case .sourceConflict:
            return MedicineKnowledgeWarning(
                code: .sourceConflict,
                message: "Sources contain conflicting medicine data."
            )
        case .medicineNotFound:
            return MedicineKnowledgeWarning(
                code: .sourceUnavailable,
                message: "No medicine matched the normalized query."
            )
        case .malformedRequest:
            return MedicineKnowledgeWarning(
                code: .invalidSourceResponse,
                message: "The normalized query is invalid."
            )
        case .requestCancelled:
            return MedicineKnowledgeWarning(
                code: .sourceUnavailable,
                message: "The knowledge-source request was cancelled."
            )
        }
    }

    private func copy(
        _ result: MedicineKnowledgeSearchResult,
        cacheStatus: MedicineKnowledgeCacheStatus,
        generatedAt: Date
    ) -> MedicineKnowledgeSearchResult {
        MedicineKnowledgeSearchResult(
            normalizedQuery: result.normalizedQuery,
            candidates: result.candidates,
            sourceStatus: result.sourceStatus,
            cacheStatus: cacheStatus,
            completeness: result.completeness,
            sourceReferences: result.sourceReferences,
            warnings: result.warnings,
            sourceVersions: result.sourceVersions,
            generatedAt: generatedAt,
            isOffline: result.isOffline
        )
    }

    private func offlineCopy(
        _ result: MedicineKnowledgeSearchResult,
        warnings: [MedicineKnowledgeWarning],
        generatedAt: Date
    ) -> MedicineKnowledgeSearchResult {
        let candidates = result.candidates.map {
            let medicine = Medicine(
                id: $0.medicine.id,
                canonicalName:
                    $0.medicine.canonicalName,
                aliases: $0.medicine.aliases,
                activeIngredientIDs:
                    $0.medicine.activeIngredientIDs,
                medicineCategory:
                    $0.medicine.medicineCategory,
                sourceReferences:
                    $0.medicine.sourceReferences,
                dosageTextFromSource: nil,
                contraindicationTags:
                    $0.medicine.contraindicationTags,
                warnings: stableStrings(
                    $0.medicine.warnings
                        + [
                            "Offline cached data is stale and is not current authoritative data.",
                        ]
                ),
                dataVersion: $0.medicine.dataVersion
            )
            return MedicineKnowledgeCandidate(
                medicine: medicine,
                completeness: min(
                    $0.completeness,
                    policy.minimumCompleteness
                ),
                validationStatus: .warning,
                sourceIdentifiers:
                    $0.sourceIdentifiers,
                conflicts: $0.conflicts,
                warnings: stableWarnings(
                    $0.warnings + warnings
                ),
                requiresConfirmation: true
            )
        }
        return MedicineKnowledgeSearchResult(
            normalizedQuery: result.normalizedQuery,
            candidates: candidates,
            sourceStatus: .staleOffline,
            cacheStatus: .staleOffline,
            completeness: min(
                result.completeness,
                policy.minimumCompleteness
            ),
            sourceReferences: result.sourceReferences,
            warnings: stableWarnings(
                result.warnings + warnings
            ),
            sourceVersions: result.sourceVersions,
            generatedAt: generatedAt,
            isOffline: true
        )
    }

    private func stableWarnings(
        _ values: [MedicineKnowledgeWarning]
    ) -> [MedicineKnowledgeWarning] {
        var seen = Set<String>()
        return values
            .sorted {
                if $0.code.rawValue == $1.code.rawValue {
                    return $0.sourceIdentifiers
                        .joined(separator: ",")
                        < $1.sourceIdentifiers
                            .joined(separator: ",")
                }
                return $0.code.rawValue < $1.code.rawValue
            }
            .filter {
                let key = [
                    $0.code.rawValue,
                    $0.message,
                    $0.sourceIdentifiers.sorted()
                        .joined(separator: ","),
                ]
                .joined(separator: "|")
                return seen.insert(key).inserted
            }
    }

    private func stableSourceReferences(
        _ values: [SourceReference]
    ) -> [SourceReference] {
        Array(Set(values)).sorted {
            if $0.sourceName == $1.sourceName {
                return $0.versionOrDate
                    < $1.versionOrDate
            }
            return $0.sourceName < $1.sourceName
        }
    }

    private func stableStrings(
        _ values: [String]
    ) -> [String] {
        Array(
            Set(
                values
                    .map {
                        $0.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                    }
                    .filter { !$0.isEmpty }
            )
        )
        .sorted()
    }
}

private struct SourceDescriptor: Sendable {
    let identifier: String
    let priority: Int
    let isAuthoritative: Bool
}
