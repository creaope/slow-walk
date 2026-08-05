import Foundation
import SlowWalkDomain
import XCTest

final class UserProfileDraftMappingTests: XCTestCase {
    func testMapsEveryDraftField() {
        let profile = makeBundle(
            preferredName: "李阿姨",
            age: 72,
            canonicalAllergies: ["canonical-allergy-hidden"],
            unresolvedAllergyDescriptions: ["花粉", "青霉素"],
            diagnosedConditions: ["高血压", "糖尿病"],
            currentMedicineIngredientIDs: [
                "acetaminophen",
                "amlodipine",
            ],
            unresolvedMedicineNames: ["泰诺", "降压片"]
        )

        let draft = UserProfileDraft(profile: profile)

        XCTAssertEqual(draft.preferredName, "李阿姨")
        XCTAssertEqual(draft.ageText, "72")
        XCTAssertEqual(draft.allergies, ["花粉", "青霉素"])
        XCTAssertEqual(draft.diagnosedConditions, ["高血压", "糖尿病"])
        XCTAssertEqual(draft.currentMedicineNames, ["泰诺", "降压片"])
    }

    func testPreservesPreferredNameWhitespaceAndCase() {
        let profile = makeBundle(preferredName: " LiN ")

        let draft = UserProfileDraft(profile: profile)

        XCTAssertEqual(draft.preferredName, " LiN ")
    }

    func testCanonicalAllergyIdentityDoesNotPolluteDraft() {
        let profile = makeBundle(
            canonicalAllergies: [
                "canonical-penicillin",
                "canonical-pollen",
            ],
            unresolvedAllergyDescriptions: [
                "我填写的花粉描述",
                "不确定的抗生素",
            ]
        )

        let draft = UserProfileDraft(profile: profile)

        XCTAssertFalse(profile.healthProfile.allergies.isEmpty)
        XCTAssertEqual(
            draft.allergies,
            profile.unresolvedAllergyDescriptions
        )
        XCTAssertNotEqual(
            draft.allergies,
            profile.healthProfile.allergies
        )
    }

    func testMedicineIdentityDoesNotPolluteDraft() {
        let profile = makeBundle(
            currentMedicineIngredientIDs: [
                "ingredient-acetaminophen",
                "ingredient-amlodipine",
            ],
            unresolvedMedicineNames: ["泰诺", "络活喜"]
        )

        let draft = UserProfileDraft(profile: profile)

        XCTAssertEqual(draft.currentMedicineNames, ["泰诺", "络活喜"])
        XCTAssertNotEqual(
            draft.currentMedicineNames,
            profile.healthProfile.currentMedicineIngredientIDs
        )
    }

    func testPreservesOrderDuplicatesAndWhitespace() {
        let profile = makeBundle(
            unresolvedAllergyDescriptions: [
                " 第一项 ",
                "第二项",
                " 第一项 ",
            ],
            diagnosedConditions: [
                " Condition B ",
                "Condition A",
                " Condition B ",
            ],
            unresolvedMedicineNames: ["药品 B", " 药品 A ", "药品 B"]
        )

        let draft = UserProfileDraft(profile: profile)

        XCTAssertEqual(
            draft.allergies,
            profile.unresolvedAllergyDescriptions
        )
        XCTAssertEqual(
            draft.diagnosedConditions,
            [
                " Condition B ",
                "Condition A",
                " Condition B ",
            ]
        )
        XCTAssertEqual(
            draft.currentMedicineNames,
            profile.unresolvedMedicineNames
        )
    }

    func testSourceDoesNotChangeMapping() {
        let demo = makeBundle(source: .bundledDemo)
        let userEntered = makeBundle(source: .userEnteredLocal)

        XCTAssertEqual(
            UserProfileDraft(profile: demo),
            UserProfileDraft(profile: userEntered)
        )
    }

    func testEmptyArraysRemainEmpty() {
        let profile = makeBundle(
            canonicalAllergies: ["canonical-hidden"],
            unresolvedAllergyDescriptions: [],
            diagnosedConditions: [],
            currentMedicineIngredientIDs: ["ingredient-hidden"],
            unresolvedMedicineNames: []
        )

        let draft = UserProfileDraft(profile: profile)

        XCTAssertTrue(draft.allergies.isEmpty)
        XCTAssertTrue(draft.diagnosedConditions.isEmpty)
        XCTAssertTrue(draft.currentMedicineNames.isEmpty)
    }

    func testMappingDoesNotModifyProfile() {
        let profile = makeBundle(
            canonicalAllergies: ["canonical-pollen"],
            unresolvedAllergyDescriptions: [" pollen "],
            diagnosedConditions: [" condition "],
            unresolvedMedicineNames: [" medicine "]
        )
        let original = profile

        _ = UserProfileDraft(profile: profile)

        XCTAssertEqual(profile, original)
    }

    private func makeBundle(
        source: UserProfileSource = .userEnteredLocal,
        preferredName: String = "Lin",
        age: Int = 70,
        canonicalAllergies: [String] = ["canonical-pollen"],
        unresolvedAllergyDescriptions: [String] = ["Pollen"],
        diagnosedConditions: [String] = ["Hypertension"],
        currentMedicineIngredientIDs: [String] = ["ingredient-hidden"],
        unresolvedMedicineNames: [String] = ["Daily Tablet"],
        bundleSchemaVersion: Int =
            LocalUserProfileBundle.currentSchemaVersion,
        healthProfileSchemaVersion: Int =
            UserHealthProfile.currentSchemaVersion,
        healthProfileCreatedAt: Date = Date(
            timeIntervalSince1970: 1_700_000_000
        ),
        healthProfileUpdatedAt: Date = Date(
            timeIntervalSince1970: 1_700_000_060
        ),
        bundleCreatedAt: Date = Date(
            timeIntervalSince1970: 1_700_000_120
        ),
        bundleUpdatedAt: Date = Date(
            timeIntervalSince1970: 1_700_000_180
        )
    ) -> LocalUserProfileBundle {
        let healthProfile = UserHealthProfile(
            id: UUID(
                uuid: (
                    0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 42
                )
            ),
            age: age,
            allergies: canonicalAllergies,
            diagnosedConditions: diagnosedConditions,
            currentMedicineIngredientIDs: currentMedicineIngredientIDs,
            bodyMetrics: nil,
            updatedAt: healthProfileUpdatedAt,
            createdAt: healthProfileCreatedAt,
            schemaVersion: healthProfileSchemaVersion
        )
        return LocalUserProfileBundle(
            schemaVersion: bundleSchemaVersion,
            source: source,
            preferredName: preferredName,
            healthProfile: healthProfile,
            unresolvedAllergyDescriptions:
                unresolvedAllergyDescriptions,
            unresolvedMedicineNames: unresolvedMedicineNames,
            createdAt: bundleCreatedAt,
            updatedAt: bundleUpdatedAt
        )
    }
}
