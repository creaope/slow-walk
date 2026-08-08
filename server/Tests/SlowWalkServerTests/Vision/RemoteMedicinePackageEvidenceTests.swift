import Foundation

@testable import SlowWalkServer
import XCTest

final class RemoteMedicinePackageEvidenceTests: XCTestCase {
    func testCompleteChineseAndEnglishEvidenceDecodes() throws {
        let evidence = try decode(baseObject())

        XCTAssertEqual(evidence.visibleTexts, [
            "泰诺", "对乙酰氨基酚片", "TYLENOL", "国药准字 H12345678",
        ])
        XCTAssertEqual(evidence.probableProductNames, ["泰诺", "TYLENOL"])
        XCTAssertEqual(evidence.probableGenericNames, ["对乙酰氨基酚", "acetaminophen"])
        XCTAssertEqual(evidence.manufacturerNames, ["示例制药 Example Pharma"])
        XCTAssertEqual(evidence.approvalIdentifiers, ["国药准字 H12345678"])
        XCTAssertEqual(evidence.dosageFormTexts, ["薄膜衣片", "caplet"])
        XCTAssertEqual(evidence.packagingFeatures, ["红白纸盒", "red and white carton"])
        XCTAssertEqual(evidence.searchQueries, ["泰诺 对乙酰氨基酚 H12345678"])
        XCTAssertTrue(evidence.imageReadable)
        XCTAssertTrue(evidence.uncertainRegionsPresent)
    }

    func testEmptyCandidatesAreAccepted() throws {
        var object = baseObject()
        for key in Self.arrayKeys where key != "visibleTexts" {
            object[key] = []
        }

        let evidence = try decode(object)

        XCTAssertEqual(evidence.visibleTexts.count, 4)
        XCTAssertTrue(evidence.probableProductNames.isEmpty)
        XCTAssertTrue(evidence.probableGenericNames.isEmpty)
        XCTAssertTrue(evidence.manufacturerNames.isEmpty)
        XCTAssertTrue(evidence.approvalIdentifiers.isEmpty)
        XCTAssertTrue(evidence.dosageFormTexts.isEmpty)
        XCTAssertTrue(evidence.packagingFeatures.isEmpty)
        XCTAssertTrue(evidence.searchQueries.isEmpty)
    }

    func testUnreadableImageWithNoEvidenceIsAccepted() throws {
        var object = baseObject()
        for key in Self.arrayKeys {
            object[key] = []
        }
        object["imageReadable"] = false
        object["uncertainRegionsPresent"] = true

        let evidence = try decode(object)

        XCTAssertFalse(evidence.imageReadable)
        XCTAssertTrue(evidence.uncertainRegionsPresent)
        XCTAssertTrue(evidence.visibleTexts.isEmpty)
        XCTAssertTrue(evidence.searchQueries.isEmpty)
    }

    func testUnknownFieldIsRejected() throws {
        var object = baseObject()
        object["providerConfidence"] = 0.99

        assertInvalid(object)
    }

    func testEveryMissingFieldIsRejected() throws {
        for key in Self.allKeys {
            var object = baseObject()
            object.removeValue(forKey: key)

            assertInvalid(object, key)
        }
    }

    func testWrongFieldTypesAreRejected() throws {
        let replacements: [(String, Any)] = [
            ("visibleTexts", "not-an-array"),
            ("probableProductNames", [1]),
            ("probableGenericNames", [true]),
            ("manufacturerNames", ["valid", 2]),
            ("approvalIdentifiers", ["valid", NSNull()]),
            ("dosageFormTexts", [[:]]),
            ("packagingFeatures", [1.5]),
            ("searchQueries", "not-an-array"),
            ("imageReadable", "true"),
            ("uncertainRegionsPresent", 0),
        ]

        for (key, replacement) in replacements {
            var object = baseObject()
            object[key] = replacement

            assertInvalid(object, key)
        }
    }

    func testMarkdownCodeFenceAndTrailingProseAreRejected() throws {
        let json = try jsonString(baseObject())

        assertInvalidContent("```json\n\(json)\n```")
        assertInvalidContent("\(json)\nmodel commentary")
    }

    func testMedicalAndCanonicalOverreachFieldsAreRejected() throws {
        let forbiddenFields = [
            "canonicalMedicineID",
            "selectedMedicine",
            "riskLevel",
            "diagnosis",
            "dosageAdvice",
            "safeToTake",
            "frequency",
            "treatmentDuration",
            "stopMedication",
            "actionCard",
            "userHealthJudgement",
        ]

        for field in forbiddenFields {
            var object = baseObject()
            object[field] = "must be rejected"

            assertInvalid(object, field)
        }
    }

    func testEveryArrayCountLimitIsEnforced() throws {
        let limits = [
            "visibleTexts": RemoteMedicinePackageEvidence.maximumVisibleTextCount,
            "probableProductNames": RemoteMedicinePackageEvidence.maximumNamedEvidenceCount,
            "probableGenericNames": RemoteMedicinePackageEvidence.maximumNamedEvidenceCount,
            "manufacturerNames": RemoteMedicinePackageEvidence.maximumNamedEvidenceCount,
            "approvalIdentifiers": RemoteMedicinePackageEvidence.maximumNamedEvidenceCount,
            "dosageFormTexts": RemoteMedicinePackageEvidence.maximumNamedEvidenceCount,
            "packagingFeatures": RemoteMedicinePackageEvidence.maximumPackagingFeatureCount,
            "searchQueries": RemoteMedicinePackageEvidence.maximumSearchQueryCount,
        ]

        for (key, limit) in limits {
            var object = emptyObject()
            object[key] = Array(repeating: "x", count: limit + 1)

            assertInvalid(object, key)
        }
    }

    func testEveryItemLengthLimitIsEnforced() throws {
        let limits = [
            "visibleTexts": RemoteMedicinePackageEvidence.maximumVisibleTextLength,
            "probableProductNames": RemoteMedicinePackageEvidence.maximumEvidenceTextLength,
            "probableGenericNames": RemoteMedicinePackageEvidence.maximumEvidenceTextLength,
            "manufacturerNames": RemoteMedicinePackageEvidence.maximumEvidenceTextLength,
            "approvalIdentifiers": RemoteMedicinePackageEvidence.maximumEvidenceTextLength,
            "dosageFormTexts": RemoteMedicinePackageEvidence.maximumEvidenceTextLength,
            "packagingFeatures": RemoteMedicinePackageEvidence.maximumPackagingFeatureLength,
            "searchQueries": RemoteMedicinePackageEvidence.maximumSearchQueryLength,
        ]

        for (key, limit) in limits {
            var object = emptyObject()
            object[key] = [String(repeating: "x", count: limit + 1)]

            assertInvalid(object, key)
        }
    }

    func testSearchQueryLimitsAreStricterThanOtherEvidenceLimits() {
        XCTAssertLessThan(
            RemoteMedicinePackageEvidence.maximumSearchQueryCount,
            RemoteMedicinePackageEvidence.maximumNamedEvidenceCount
        )
        XCTAssertLessThan(
            RemoteMedicinePackageEvidence.maximumSearchQueryLength,
            RemoteMedicinePackageEvidence.maximumEvidenceTextLength
        )
        XCTAssertLessThan(
            RemoteMedicinePackageEvidence.maximumTotalSearchQueryCharacterCount,
            RemoteMedicinePackageEvidence.maximumSearchQueryCount
                * RemoteMedicinePackageEvidence.maximumSearchQueryLength
        )
    }

    func testTotalSearchQueryLimitAcceptsBoundaryAndRejectsOverflow() throws {
        let queryLength = RemoteMedicinePackageEvidence.maximumSearchQueryLength
        let queryCount = RemoteMedicinePackageEvidence
            .maximumTotalSearchQueryCharacterCount / queryLength
        let boundaryQueries = Array(
            repeating: String(repeating: "q", count: queryLength),
            count: queryCount
        )
        var atBoundary = emptyObject()
        atBoundary["searchQueries"] = boundaryQueries
        XCTAssertNoThrow(try decode(atBoundary))

        var overBoundary = atBoundary
        overBoundary["searchQueries"] = boundaryQueries + ["q"]
        assertInvalid(overBoundary)
    }

    func testTotalCharacterLimitAcceptsBoundaryAndRejectsOverflow() throws {
        var atBoundary = emptyObject()
        atBoundary["visibleTexts"] = Array(
            repeating: String(
                repeating: "x",
                count: RemoteMedicinePackageEvidence.maximumVisibleTextLength
            ),
            count: RemoteMedicinePackageEvidence.maximumTotalCharacterCount
                / RemoteMedicinePackageEvidence.maximumVisibleTextLength
        )
        XCTAssertNoThrow(try decode(atBoundary))

        var overBoundary = atBoundary
        overBoundary["searchQueries"] = ["x"]
        assertInvalid(overBoundary)
    }

    func testBlankItemInEveryArrayIsRejected() throws {
        for key in Self.arrayKeys {
            var object = emptyObject()
            object[key] = [" \t\n "]

            assertInvalid(object, key)
        }
    }

    func testValidatedEvidenceRoundTripsThroughJSON() throws {
        let original = try decode(baseObject())
        let encoded = try JSONEncoder().encode(original)

        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteMedicinePackageEvidence.self,
                from: encoded
            ),
            original
        )
    }

    private static let arrayKeys = [
        "visibleTexts",
        "probableProductNames",
        "probableGenericNames",
        "manufacturerNames",
        "approvalIdentifiers",
        "dosageFormTexts",
        "packagingFeatures",
        "searchQueries",
    ]

    private static let allKeys = arrayKeys + [
        "imageReadable", "uncertainRegionsPresent",
    ]

    private func baseObject() -> [String: Any] {
        [
            "visibleTexts": [
                "泰诺", "对乙酰氨基酚片", "TYLENOL", "国药准字 H12345678",
            ],
            "probableProductNames": ["泰诺", "TYLENOL"],
            "probableGenericNames": ["对乙酰氨基酚", "acetaminophen"],
            "manufacturerNames": ["示例制药 Example Pharma"],
            "approvalIdentifiers": ["国药准字 H12345678"],
            "dosageFormTexts": ["薄膜衣片", "caplet"],
            "packagingFeatures": ["红白纸盒", "red and white carton"],
            "searchQueries": ["泰诺 对乙酰氨基酚 H12345678"],
            "imageReadable": true,
            "uncertainRegionsPresent": true,
        ]
    }

    private func emptyObject() -> [String: Any] {
        var object = baseObject()
        for key in Self.arrayKeys {
            object[key] = []
        }
        return object
    }

    private func decode(_ object: [String: Any]) throws
        -> RemoteMedicinePackageEvidence
    {
        try JSONDecoder().decode(
            RemoteMedicinePackageEvidence.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        String(
            decoding: try JSONSerialization.data(withJSONObject: object),
            as: UTF8.self
        )
    }

    private func assertInvalid(
        _ object: [String: Any],
        _ context: String = "payload",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try decode(object),
            context,
            file: file,
            line: line
        )
    }

    private func assertInvalidContent(
        _ content: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                RemoteMedicinePackageEvidence.self,
                from: Data(content.utf8)
            ),
            file: file,
            line: line
        )
    }
}
