import Foundation
import SlowWalkDataInterfaces
import SlowWalkDomain
@testable import SlowWalkServer
import XCTest

final class RemoteMedicineCandidateResolverTests: XCTestCase {
    func testExactControlledProductNameResolvesThroughCanonicalResolver()
        throws
    {
        let resolver = try makeResolver(metadata: [
            acetaminophenMetadata(productNames: ["Paracetamol"]),
        ])

        let result = resolver.resolve(
            evidence: try makeEvidence(
                probableProductNames: ["  pArAcEtAmOl  "]
            ),
            capturedAt: Self.capturedAt
        )

        XCTAssertEqual(result.assurance, .exact)
        XCTAssertEqual(result.searchResult.candidates.map(\.medicine.id), [
            "demo-acetaminophen",
        ])
        XCTAssertEqual(
            result.searchResult.candidates[0].exactEvidence.map(\.catalogField),
            [.productName]
        )
        XCTAssertEqual(
            result.resolution.selectedMedicine?.id,
            "demo-acetaminophen"
        )
        XCTAssertEqual(result.resolution.status, .resolved)
        XCTAssertEqual(
            result.resolution.evidence.rawConfidence,
            RemoteMedicineCandidateResolver.resolverEligibilityThreshold
        )
    }

    func testGenericNameUsesCaseSpaceAndChinesePunctuationNormalization()
        throws
    {
        let resolver = try makeResolver(metadata: [
            acetaminophenMetadata(genericNames: ["对乙酰氨基酚"]),
        ])

        let result = resolver.resolve(
            evidence: try makeEvidence(
                probableGenericNames: ["  【对乙酰氨基酚（片）】  "]
            ),
            capturedAt: Self.capturedAt
        )

        XCTAssertEqual(result.assurance, .exact)
        XCTAssertEqual(
            result.searchResult.candidates.first?.exactEvidence.first?
                .catalogField,
            .genericName
        )
        XCTAssertEqual(
            result.resolution.selectedMedicine?.id,
            "demo-acetaminophen"
        )
    }

    func testApprovalIdentifierMatchesCandidateButIsNotInjectedAsName()
        throws
    {
        let resolver = try makeResolver(metadata: [
            acetaminophenMetadata(
                approvalIdentifiers: ["国药准字 H12345678"]
            ),
        ])

        let result = resolver.resolve(
            evidence: try makeEvidence(
                approvalIdentifiers: ["国药准字 h12345678"]
            ),
            capturedAt: Self.capturedAt
        )

        XCTAssertEqual(result.assurance, .exact)
        XCTAssertEqual(result.searchResult.candidates.map(\.medicine.id), [
            "demo-acetaminophen",
        ])
        XCTAssertEqual(
            result.searchResult.candidates[0].exactEvidence.map(\.catalogField),
            [.approvalIdentifier]
        )
        XCTAssertNil(result.resolution.selectedMedicine)
        XCTAssertEqual(result.resolution.status, .recognitionFailed)
        XCTAssertTrue(result.resolution.evidence.recognizedTexts.isEmpty)
    }

    func testApprovalComparisonDoesNotStripRequiredPrefix() throws {
        let resolver = try makeResolver(metadata: [
            acetaminophenMetadata(approvalIdentifiers: ["H12345678"]),
        ])

        let result = resolver.resolve(
            evidence: try makeEvidence(
                approvalIdentifiers: ["国药准字 H12345678"]
            ),
            capturedAt: Self.capturedAt
        )

        XCTAssertTrue(result.searchResult.candidates.isEmpty)
        XCTAssertNil(result.resolution.selectedMedicine)
    }

    func testManufacturerOnlyCannotRecallOrResolveMedicine() throws {
        let resolver = try makeResolver(metadata: [
            acetaminophenMetadata(manufacturerNames: ["Example Pharma"]),
        ])

        let result = resolver.resolve(
            evidence: try makeEvidence(
                manufacturerNames: ["EXAMPLE PHARMA"]
            ),
            capturedAt: Self.capturedAt
        )

        XCTAssertTrue(result.searchResult.candidates.isEmpty)
        XCTAssertNil(result.resolution.selectedMedicine)
        XCTAssertEqual(result.assurance, .unresolved)
    }

    func testManufacturerCorroboratesButDoesNotReplaceAliasEvidence()
        throws
    {
        let resolver = try makeResolver(metadata: [
            acetaminophenMetadata(manufacturerNames: ["Example Pharma"]),
        ])

        let result = resolver.resolve(
            evidence: try makeEvidence(
                probableProductNames: ["Paracetamol"],
                manufacturerNames: ["example pharma"]
            ),
            capturedAt: Self.capturedAt
        )

        XCTAssertEqual(result.assurance, .corroborated)
        XCTAssertEqual(
            Set(result.searchResult.candidates[0].supportingEvidence.map(
                \.catalogField
            )),
            [.alias, .manufacturerName]
        )
        XCTAssertEqual(
            result.resolution.selectedMedicine?.id,
            "demo-acetaminophen"
        )
    }

    func testManufacturerForAnotherMedicineConflictsWithoutBeingRecalled()
        throws
    {
        let resolver = try makeResolver(metadata: [
            MedicineEvidenceCatalogMetadata(
                medicineID: "demo-ibuprofen",
                manufacturerNames: ["Ibuprofen Example Pharma"]
            ),
        ])

        let result = resolver.resolve(
            evidence: try makeEvidence(
                probableProductNames: ["Acetaminophen"],
                manufacturerNames: ["Ibuprofen Example Pharma"]
            ),
            capturedAt: Self.capturedAt
        )

        XCTAssertEqual(result.assurance, .conflicting)
        XCTAssertEqual(result.searchResult.candidates.map(\.medicine.id), [
            "demo-acetaminophen",
        ])
        XCTAssertEqual(
            result.searchResult.candidates[0].conflictingEvidence.map(
                \.catalogField
            ),
            [.manufacturerName]
        )
        XCTAssertFalse(result.searchResult.unresolvedEvidence.contains {
            $0.source == .manufacturerName
        })
        XCTAssertNil(result.resolution.evidence.rawConfidence)
        XCTAssertNil(result.resolution.selectedMedicine)
    }

    func testPackagingTextCanCorroborateExistingAliasCandidate() throws {
        let resolver = try makeResolver(metadata: [
            acetaminophenMetadata(packagingTexts: ["red white carton"]),
        ])

        let result = resolver.resolve(
            evidence: try makeEvidence(
                probableProductNames: ["Paracetamol"],
                packagingFeatures: ["Red，White Carton"]
            ),
            capturedAt: Self.capturedAt
        )

        XCTAssertEqual(result.assurance, .corroborated)
        XCTAssertEqual(
            result.resolution.selectedMedicine?.id,
            "demo-acetaminophen"
        )
    }

    func testAliasOnlyRemainsBelowResolverSelectionGate() throws {
        let result = try makeResolver().resolve(
            evidence: makeEvidence(probableProductNames: ["Paracetamol"]),
            capturedAt: Self.capturedAt
        )

        XCTAssertEqual(result.assurance, .supportingOnly)
        XCTAssertEqual(result.searchResult.candidates.map(\.medicine.id), [
            "demo-acetaminophen",
        ])
        XCTAssertNil(result.resolution.evidence.rawConfidence)
        XCTAssertNil(result.resolution.selectedMedicine)
    }

    func testOverlayOnlyProductMatchCannotBypassCanonicalResolver() throws {
        let resolver = try makeResolver(metadata: [
            acetaminophenMetadata(productNames: ["Demo Brand X"]),
        ])

        let result = resolver.resolve(
            evidence: try makeEvidence(
                probableProductNames: ["Demo Brand X"]
            ),
            capturedAt: Self.capturedAt
        )

        XCTAssertEqual(result.assurance, .exact)
        XCTAssertEqual(result.searchResult.candidates.map(\.medicine.id), [
            "demo-acetaminophen",
        ])
        XCTAssertNil(result.resolution.selectedMedicine)
        XCTAssertEqual(result.resolution.status, .notFound)
    }

    func testOverlayExactCannotUnlockAnotherMedicinesAlias() throws {
        let resolver = try makeResolver(metadata: [
            MedicineEvidenceCatalogMetadata(
                medicineID: "demo-ibuprofen",
                productNames: ["Paracetamol"]
            ),
        ])

        let result = resolver.resolve(
            evidence: try makeEvidence(
                probableProductNames: ["Paracetamol"]
            ),
            capturedAt: Self.capturedAt
        )

        XCTAssertEqual(result.assurance, .ambiguous)
        XCTAssertEqual(Set(result.searchResult.candidates.map(\.medicine.id)), [
            "demo-acetaminophen", "demo-ibuprofen",
        ])
        XCTAssertNil(result.resolution.evidence.rawConfidence)
        XCTAssertNil(result.resolution.selectedMedicine)
    }

    func testSearchQueryOnlyNeverEntersCanonicalResolverInput() throws {
        let result = try makeResolver().resolve(
            evidence: makeEvidence(searchQueries: ["Acetaminophen"]),
            capturedAt: Self.capturedAt
        )

        XCTAssertEqual(result.assurance, .supportingOnly)
        XCTAssertEqual(result.searchResult.candidates.map(\.medicine.id), [
            "demo-acetaminophen",
        ])
        XCTAssertTrue(result.resolution.evidence.recognizedTexts.isEmpty)
        XCTAssertNil(result.resolution.selectedMedicine)
    }

    func testConflictingIdentityEvidenceBlocksSelection() throws {
        let result = try makeResolver().resolve(
            evidence: makeEvidence(
                probableProductNames: ["Acetaminophen", "Ibuprofen"]
            ),
            capturedAt: Self.capturedAt
        )

        XCTAssertEqual(result.assurance, .conflicting)
        XCTAssertEqual(result.searchResult.candidates.map(\.medicine.id), [
            "demo-acetaminophen", "demo-ibuprofen",
        ])
        XCTAssertTrue(result.searchResult.candidates.allSatisfy {
            !$0.conflictingEvidence.isEmpty
        })
        XCTAssertNil(result.resolution.evidence.rawConfidence)
        XCTAssertNil(result.resolution.selectedMedicine)
    }

    func testSharedAliasProducesStableAmbiguousCandidates() throws {
        let result = try makeResolver().resolve(
            evidence: makeEvidence(probableProductNames: ["Cold Relief"]),
            capturedAt: Self.capturedAt
        )

        XCTAssertEqual(result.assurance, .ambiguous)
        XCTAssertEqual(result.searchResult.candidates.map(\.medicine.id), [
            "demo-chlorpheniramine", "demo-dextromethorphan",
        ])
        XCTAssertTrue(result.searchResult.candidates.allSatisfy {
            $0.conflictingEvidence.isEmpty
        })
        XCTAssertNil(result.resolution.selectedMedicine)
    }

    func testNoCandidateDoesNotFallBackToDemoMedicine() throws {
        let result = try makeResolver().resolve(
            evidence: makeEvidence(probableProductNames: ["Madeupzol"]),
            capturedAt: Self.capturedAt
        )

        XCTAssertTrue(result.searchResult.candidates.isEmpty)
        XCTAssertEqual(
            result.searchResult.unresolvedEvidence.map(\.observedText),
            ["Madeupzol"]
        )
        XCTAssertNil(result.resolution.selectedMedicine)
        XCTAssertEqual(result.resolution.status, .notFound)
    }

    func testUnreadableImageIgnoresOtherwiseExactText() throws {
        let result = try makeResolver().resolve(
            evidence: makeEvidence(
                probableProductNames: ["Acetaminophen"],
                imageReadable: false
            ),
            capturedAt: Self.capturedAt
        )

        XCTAssertEqual(result.assurance, .unreadable)
        XCTAssertTrue(result.searchResult.candidates.isEmpty)
        XCTAssertNil(result.resolution.selectedMedicine)
        XCTAssertEqual(result.resolution.status, .recognitionFailed)
    }

    func testFuzzyTextIsUnresolvedAndNeverUpgraded() throws {
        let result = try makeResolver().resolve(
            evidence: makeEvidence(probableProductNames: ["Acetaminophe"]),
            capturedAt: Self.capturedAt
        )

        XCTAssertEqual(result.assurance, .unresolved)
        XCTAssertTrue(result.searchResult.candidates.isEmpty)
        XCTAssertEqual(
            result.searchResult.unresolvedEvidence.map(\.observedText),
            ["Acetaminophe"]
        )
        XCTAssertNil(result.resolution.selectedMedicine)
    }

    func testUncertainRegionsKeepExactEvidenceBelowSelectionGate() throws {
        let result = try makeResolver().resolve(
            evidence: makeEvidence(
                probableProductNames: ["Acetaminophen"],
                uncertainRegionsPresent: true
            ),
            capturedAt: Self.capturedAt
        )

        XCTAssertEqual(result.assurance, .uncertain)
        XCTAssertNil(result.resolution.evidence.rawConfidence)
        XCTAssertNil(result.resolution.selectedMedicine)
    }

    func testBoundedQueriesAreNormalizedDeduplicatedAndStable() throws {
        let productNames = (0 ..< 16).map { " P\($0) " }
        let genericNames = (0 ..< 16).map { "G\($0)" }
        let evidence = try makeEvidence(
            probableProductNames: productNames,
            probableGenericNames: genericNames,
            manufacturerNames: (0 ..< 16).map { "M\($0)" },
            approvalIdentifiers: (0 ..< 16).map { "A\($0)" },
            searchQueries: (0 ..< 8).map { "Q\($0)" }
        )
        let provider = try MedicineEvidenceSearchProvider(
            catalog: BundledDemoMedicineCatalogLoader().loadCatalog()
        )

        let first = provider.search(evidence: evidence)
        let second = provider.search(evidence: evidence)

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            first.queries.count,
            MedicineEvidenceSearchProvider.maximumQueryCount
        )
        XCTAssertEqual(first.queries.first?.normalizedText, "p0")
        XCTAssertEqual(first.queries.last?.normalizedText, "g15")
        XCTAssertEqual(Set(first.queries).count, first.queries.count)
        XCTAssertTrue(first.queries.allSatisfy {
            $0.normalizedText.count
                <= MedicineEvidenceSearchProvider.maximumNormalizedQueryLength
        })
    }

    func testRepeatedResolutionHasDeterministicCandidateOrdering() throws {
        let resolver = try makeResolver()
        let evidence = try makeEvidence(
            probableProductNames: ["Ibuprofen", "Acetaminophen"],
            searchQueries: ["Cold Relief"]
        )

        let first = resolver.resolve(
            evidence: evidence,
            capturedAt: Self.capturedAt
        )
        for _ in 0 ..< 10 {
            XCTAssertEqual(
                resolver.resolve(
                    evidence: evidence,
                    capturedAt: Self.capturedAt
                ),
                first
            )
        }
    }

    func testDefaultOverlayDoesNotInventManufacturerOrApprovalData()
        throws
    {
        let resolver = try RemoteMedicineCandidateResolver()
        let result = resolver.resolve(
            evidence: try makeEvidence(
                manufacturerNames: ["Example Pharma"],
                approvalIdentifiers: ["H12345678"]
            ),
            capturedAt: Self.capturedAt
        )

        XCTAssertTrue(result.searchResult.candidates.isEmpty)
        XCTAssertNil(result.resolution.selectedMedicine)
    }

    func testMetadataRejectsUnknownAndDuplicateMedicineForeignKeys()
        throws
    {
        let catalog = try BundledDemoMedicineCatalogLoader().loadCatalog()
        XCTAssertThrowsError(
            try MedicineEvidenceSearchProvider(
                catalog: catalog,
                metadata: [
                    MedicineEvidenceCatalogMetadata(
                        medicineID: "not-in-catalog"
                    ),
                ]
            )
        ) {
            XCTAssertEqual(
                $0 as? MedicineEvidenceSearchConfigurationError,
                .unknownMetadataMedicineID("not-in-catalog")
            )
        }

        let duplicate = acetaminophenMetadata()
        XCTAssertThrowsError(
            try MedicineEvidenceSearchProvider(
                catalog: catalog,
                metadata: [duplicate, duplicate]
            )
        ) {
            XCTAssertEqual(
                $0 as? MedicineEvidenceSearchConfigurationError,
                .duplicateMetadataMedicineID("demo-acetaminophen")
            )
        }
    }

    private func makeResolver(
        metadata: [MedicineEvidenceCatalogMetadata] = []
    ) throws -> RemoteMedicineCandidateResolver {
        try RemoteMedicineCandidateResolver(
            catalog: BundledDemoMedicineCatalogLoader().loadCatalog(),
            metadata: metadata
        )
    }

    private func acetaminophenMetadata(
        productNames: [String] = [],
        genericNames: [String] = [],
        manufacturerNames: [String] = [],
        approvalIdentifiers: [String] = [],
        packagingTexts: [String] = []
    ) -> MedicineEvidenceCatalogMetadata {
        MedicineEvidenceCatalogMetadata(
            medicineID: "demo-acetaminophen",
            productNames: productNames,
            genericNames: genericNames,
            manufacturerNames: manufacturerNames,
            approvalIdentifiers: approvalIdentifiers,
            packagingTexts: packagingTexts
        )
    }

    private func makeEvidence(
        visibleTexts: [String] = [],
        probableProductNames: [String] = [],
        probableGenericNames: [String] = [],
        manufacturerNames: [String] = [],
        approvalIdentifiers: [String] = [],
        dosageFormTexts: [String] = [],
        packagingFeatures: [String] = [],
        searchQueries: [String] = [],
        imageReadable: Bool = true,
        uncertainRegionsPresent: Bool = false
    ) throws -> RemoteMedicinePackageEvidence {
        try RemoteMedicinePackageEvidence(
            visibleTexts: visibleTexts,
            probableProductNames: probableProductNames,
            probableGenericNames: probableGenericNames,
            manufacturerNames: manufacturerNames,
            approvalIdentifiers: approvalIdentifiers,
            dosageFormTexts: dosageFormTexts,
            packagingFeatures: packagingFeatures,
            searchQueries: searchQueries,
            imageReadable: imageReadable,
            uncertainRegionsPresent: uncertainRegionsPresent
        )
    }

    private static let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
}
