import Foundation
import SlowWalkDomain

/// Fixed synthetic data for the bundled competition demo.
///
/// This value contains no real user data and is not clinical guidance.
enum BundledDemoUserProfile {
    static let profile: LocalUserProfileBundle = {
        let createdAt = Date(
            timeIntervalSince1970: 1_752_969_600
        )
        let updatedAt = Date(
            timeIntervalSince1970: 1_753_314_900
        )

        let healthProfile = UserHealthProfile(
            id: UUID(
                uuid: (
                    0x60, 0x00, 0x00, 0x00,
                    0x00, 0x00,
                    0x00, 0x00,
                    0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x01
                )
            ),
            age: 72,
            allergies: [],
            diagnosedConditions: ["高血压（演示数据）"],
            currentMedicineIngredientIDs: ["amlodipine"],
            bodyMetrics: BodyMetrics(
                systolicBloodPressure: 120,
                diastolicBloodPressure: 80,
                heartRate: 70,
                measuredAt: updatedAt,
                source: "demo_data",
                deviceIdentifier: "slowwalk-synthetic-demo-profile"
            ),
            updatedAt: updatedAt,
            createdAt: createdAt,
            schemaVersion: UserHealthProfile.currentSchemaVersion
        )

        return LocalUserProfileBundle(
            schemaVersion: LocalUserProfileBundle.currentSchemaVersion,
            source: .bundledDemo,
            preferredName: "演示用户",
            healthProfile: healthProfile,
            unresolvedAllergyDescriptions: [
                "花粉（未解析演示）",
            ],
            unresolvedMedicineNames: [
                "家庭药盒标签（未解析演示）",
            ],
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }()
}
