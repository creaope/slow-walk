import Testing
import Foundation
import SlowWalkDomain
@testable import SlowWalkApp

@MainActor
struct BundledDemoUserProfileTests {

    // MARK: - Source and identity

    @Test func sourceAndSchemasIdentifyTheBundledDemo() {
        let profile = BundledDemoUserProfile.profile

        #expect(profile.source == .bundledDemo)
        #expect(profile.source != .userEnteredLocal)
        #expect(
            profile.schemaVersion
                == LocalUserProfileBundle.currentSchemaVersion
        )
        #expect(
            profile.healthProfile.schemaVersion
                == UserHealthProfile.currentSchemaVersion
        )
    }

    @Test func fixedIdentityAndPersonFieldsMatchTheSyntheticProfile() {
        let profile = BundledDemoUserProfile.profile
        let expectedID = UUID(
            uuid: (
                0x60, 0x00, 0x00, 0x00,
                0x00, 0x00,
                0x00, 0x00,
                0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x01
            )
        )

        #expect(profile.healthProfile.id == expectedID)
        #expect(profile.preferredName == "演示用户")
        #expect(profile.healthProfile.age == 72)
    }

    // MARK: - Fixed health data

    @Test func timestampsAreFixedAndSharedAcrossTheBundle() throws {
        let profile = BundledDemoUserProfile.profile
        let expectedCreatedAt = Date(
            timeIntervalSince1970: 1_752_969_600
        )
        let expectedUpdatedAt = Date(
            timeIntervalSince1970: 1_753_314_900
        )
        let bodyMetrics = try #require(profile.healthProfile.bodyMetrics)

        #expect(profile.createdAt == expectedCreatedAt)
        #expect(profile.updatedAt == expectedUpdatedAt)
        #expect(profile.healthProfile.createdAt == profile.createdAt)
        #expect(profile.healthProfile.updatedAt == profile.updatedAt)
        #expect(bodyMetrics.measuredAt == profile.updatedAt)
    }

    @Test func syntheticHealthFieldsMatchTheBundledDemoContract() throws {
        let profile = BundledDemoUserProfile.profile
        let healthProfile = profile.healthProfile
        let bodyMetrics = try #require(healthProfile.bodyMetrics)

        #expect(healthProfile.allergies.isEmpty)
        #expect(
            profile.unresolvedAllergyDescriptions
                == ["花粉（未解析演示）"]
        )
        #expect(
            healthProfile.diagnosedConditions
                == ["高血压（演示数据）"]
        )
        #expect(bodyMetrics.systolicBloodPressure == 120)
        #expect(bodyMetrics.diastolicBloodPressure == 80)
        #expect(bodyMetrics.heartRate == 70)
        #expect(bodyMetrics.source == "demo_data")
        #expect(
            bodyMetrics.deviceIdentifier
                == "slowwalk-synthetic-demo-profile"
        )
    }

    // MARK: - Medicine boundary and determinism

    @Test func canonicalIngredientIdentityDoesNotReplaceUnresolvedMedicineText() {
        let profile = BundledDemoUserProfile.profile
        let ingredientIDs = profile.healthProfile
            .currentMedicineIngredientIDs

        #expect(ingredientIDs == ["amlodipine"])
        #expect(
            profile.unresolvedMedicineNames
                == ["家庭药盒标签（未解析演示）"]
        )
        #expect(ingredientIDs != profile.unresolvedMedicineNames)
    }

    @Test func repeatedReadsReturnTheSameImmutableValue() {
        let first = BundledDemoUserProfile.profile
        let second = BundledDemoUserProfile.profile

        #expect(first == second)
    }
}
