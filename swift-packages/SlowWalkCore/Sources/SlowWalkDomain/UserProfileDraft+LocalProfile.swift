public extension UserProfileDraft {
    init(profile: LocalUserProfileBundle) {
        self.init(
            preferredName: profile.preferredName,
            ageText: String(profile.healthProfile.age),
            allergies: profile.unresolvedAllergyDescriptions,
            diagnosedConditions:
                profile.healthProfile.diagnosedConditions,
            currentMedicineNames:
                profile.unresolvedMedicineNames
        )
    }
}
