import Foundation
import SlowWalkDomain
import XCTest

final class LocalUserProfileTests: XCTestCase {
    private let id = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 42)
    )
    private let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let updatedAt = Date(timeIntervalSince1970: 1_700_000_060)

    func testValidDraftConvertsToLocalBundle() throws {
        let draft = UserProfileDraft(
            preferredName: "  Lin  ",
            ageText: " 72 ",
            allergies: [" Penicillin "],
            diagnosedConditions: [" Hypertension "],
            currentMedicineNames: [" Daily Tablet "]
        )

        let bundle = try validate(draft)

        XCTAssertEqual(bundle.schemaVersion, 1)
        XCTAssertEqual(bundle.source, .userEnteredLocal)
        XCTAssertEqual(bundle.preferredName, "Lin")
        XCTAssertEqual(bundle.createdAt, createdAt)
        XCTAssertEqual(bundle.updatedAt, updatedAt)
        XCTAssertEqual(bundle.healthProfile.id, id)
        XCTAssertEqual(bundle.healthProfile.age, 72)
        XCTAssertEqual(bundle.healthProfile.allergies, ["Penicillin"])
        XCTAssertEqual(
            bundle.healthProfile.diagnosedConditions,
            ["Hypertension"]
        )
        XCTAssertNil(bundle.healthProfile.bodyMetrics)
        XCTAssertEqual(bundle.healthProfile.createdAt, createdAt)
        XCTAssertEqual(bundle.healthProfile.updatedAt, updatedAt)
    }

    func testEmptyPreferredNameIsRejected() {
        assertIssue(
            .emptyPreferredName,
            for: UserProfileDraft(preferredName: " \n\t ", ageText: "72")
        )
    }

    func testNonNumericAgeIsRejected() {
        assertIssue(
            .ageNotANumber,
            for: UserProfileDraft(
                preferredName: "Lin",
                ageText: "seventy two"
            )
        )
    }

    func testOutOfRangeAgesAreRejected() {
        assertIssue(
            .ageOutOfRange,
            for: UserProfileDraft(preferredName: "Lin", ageText: "0")
        )
        assertIssue(
            .ageOutOfRange,
            for: UserProfileDraft(preferredName: "Lin", ageText: "121")
        )
    }

    func testArraysAreCleanedAndDeduplicatedStably() throws {
        let draft = UserProfileDraft(
            preferredName: "Lin",
            ageText: "72",
            allergies: [
                "  Penicillin ",
                "",
                "penicillin",
                " Pollen ",
                "POLLEN",
            ],
            diagnosedConditions: [
                " Hypertension ",
                "hypertension",
                " Diabetes ",
            ],
            currentMedicineNames: [
                " Daily Tablet ",
                "daily tablet",
                " Night Capsule ",
                " \n ",
            ]
        )

        let bundle = try validate(draft)

        XCTAssertEqual(
            bundle.healthProfile.allergies,
            ["Penicillin", "Pollen"]
        )
        XCTAssertEqual(
            bundle.healthProfile.diagnosedConditions,
            ["Hypertension", "Diabetes"]
        )
        XCTAssertEqual(
            bundle.unresolvedMedicineNames,
            ["Daily Tablet", "Night Capsule"]
        )
    }

    func testMedicineNamesRemainUnresolved() throws {
        let bundle = try validate(
            UserProfileDraft(
                preferredName: "Lin",
                ageText: "72",
                currentMedicineNames: ["  Unknown Medicine  "]
            )
        )

        XCTAssertEqual(
            bundle.unresolvedMedicineNames,
            ["Unknown Medicine"]
        )
        XCTAssertEqual(
            bundle.healthProfile.currentMedicineIngredientIDs,
            []
        )
    }

    func testTextAndGroupLimitsAreEnforced() {
        assertIssue(
            .preferredNameTooLong,
            for: UserProfileDraft(
                preferredName: String(repeating: "a", count: 31),
                ageText: "72"
            )
        )
        assertIssue(
            .allergyTooLong(index: 1),
            for: UserProfileDraft(
                preferredName: "Lin",
                ageText: "72",
                allergies: ["short", String(repeating: "a", count: 81)]
            )
        )
        assertIssue(
            .tooManyCurrentMedicineNames,
            for: UserProfileDraft(
                preferredName: "Lin",
                ageText: "72",
                currentMedicineNames: (0 ... 30).map { "medicine-\($0)" }
            )
        )
    }

    func testValidationDescriptionDoesNotContainSensitiveInput() {
        let sensitiveText = "private-health-detail"
        let draft = UserProfileDraft(
            preferredName: "Lin",
            ageText: "72",
            diagnosedConditions: [
                String(repeating: sensitiveText, count: 5),
            ]
        )

        do {
            _ = try validate(draft)
            XCTFail("Expected a validation issue.")
        } catch let issue as UserProfileValidationIssue {
            XCTAssertEqual(
                issue,
                .diagnosedConditionTooLong(index: 0)
            )
            XCTAssertFalse(issue.description.contains(sensitiveText))
            XCTAssertFalse(String(describing: issue).contains(sensitiveText))
            XCTAssertFalse(
                issue.localizedDescription.contains(sensitiveText)
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBundleEncodingRoundTripPreservesEquality() throws {
        let original = try validate(
            UserProfileDraft(
                preferredName: "Lin",
                ageText: "72",
                allergies: ["Pollen"],
                currentMedicineNames: ["Daily Tablet"]
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(
            LocalUserProfileBundle.self,
            from: data
        )

        XCTAssertEqual(decoded, original)
    }

    private func validate(
        _ draft: UserProfileDraft
    ) throws -> LocalUserProfileBundle {
        try UserProfileDraftValidator().validate(
            draft,
            id: id,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func assertIssue(
        _ expected: UserProfileValidationIssue,
        for draft: UserProfileDraft,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try validate(draft),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? UserProfileValidationIssue,
                expected,
                file: file,
                line: line
            )
        }
    }
}
