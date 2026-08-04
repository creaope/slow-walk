import Foundation

public enum UserProfileSource: String, Codable, Sendable {
    case bundledDemo
    case userEnteredLocal
}

public struct LocalUserProfileBundle:
    Codable,
    Sendable,
    Equatable
{
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let source: UserProfileSource
    public let preferredName: String
    public let healthProfile: UserHealthProfile
    public let unresolvedAllergyDescriptions: [String]
    public let unresolvedMedicineNames: [String]
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        schemaVersion: Int = LocalUserProfileBundle.currentSchemaVersion,
        source: UserProfileSource,
        preferredName: String,
        healthProfile: UserHealthProfile,
        unresolvedAllergyDescriptions: [String],
        unresolvedMedicineNames: [String],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.source = source
        self.preferredName = preferredName
        self.healthProfile = healthProfile
        self.unresolvedAllergyDescriptions =
            unresolvedAllergyDescriptions
        self.unresolvedMedicineNames = unresolvedMedicineNames
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct UserProfileDraft: Sendable, Equatable {
    public var preferredName: String
    public var ageText: String
    public var allergies: [String]
    public var diagnosedConditions: [String]
    public var currentMedicineNames: [String]

    public init(
        preferredName: String = "",
        ageText: String = "",
        allergies: [String] = [],
        diagnosedConditions: [String] = [],
        currentMedicineNames: [String] = []
    ) {
        self.preferredName = preferredName
        self.ageText = ageText
        self.allergies = allergies
        self.diagnosedConditions = diagnosedConditions
        self.currentMedicineNames = currentMedicineNames
    }
}

public enum UserProfileValidationIssue:
    Error,
    Sendable,
    Equatable,
    CustomStringConvertible
{
    case emptyPreferredName
    case preferredNameTooLong
    case ageNotANumber
    case ageOutOfRange
    case tooManyAllergies
    case allergyTooLong(index: Int)
    case tooManyDiagnosedConditions
    case diagnosedConditionTooLong(index: Int)
    case tooManyCurrentMedicineNames
    case currentMedicineNameTooLong(index: Int)

    public var description: String {
        switch self {
        case .emptyPreferredName:
            "emptyPreferredName"
        case .preferredNameTooLong:
            "preferredNameTooLong"
        case .ageNotANumber:
            "ageNotANumber"
        case .ageOutOfRange:
            "ageOutOfRange"
        case .tooManyAllergies:
            "tooManyAllergies"
        case let .allergyTooLong(index):
            "allergyTooLong(index: \(index))"
        case .tooManyDiagnosedConditions:
            "tooManyDiagnosedConditions"
        case let .diagnosedConditionTooLong(index):
            "diagnosedConditionTooLong(index: \(index))"
        case .tooManyCurrentMedicineNames:
            "tooManyCurrentMedicineNames"
        case let .currentMedicineNameTooLong(index):
            "currentMedicineNameTooLong(index: \(index))"
        }
    }
}

public struct UserProfileDraftValidator: Sendable {
    public static let maximumPreferredNameLength = 30
    public static let maximumItemLength = 80
    public static let maximumItemsPerGroup = 30
    public static let validAgeRange = 1 ... 120

    public init() {}

    public func validate(
        _ draft: UserProfileDraft,
        id: UUID,
        createdAt: Date,
        updatedAt: Date
    ) throws -> LocalUserProfileBundle {
        let preferredName = clean(draft.preferredName)
        guard !preferredName.isEmpty else {
            throw UserProfileValidationIssue.emptyPreferredName
        }
        guard preferredName.count <= Self.maximumPreferredNameLength else {
            throw UserProfileValidationIssue.preferredNameTooLong
        }

        let ageText = clean(draft.ageText)
        guard let age = Int(ageText) else {
            throw UserProfileValidationIssue.ageNotANumber
        }
        guard Self.validAgeRange.contains(age) else {
            throw UserProfileValidationIssue.ageOutOfRange
        }

        // Free-form allergy text is preserved for later review/resolution.
        // It is not treated as canonical risk-engine input.
        let unresolvedAllergyDescriptions = try cleanItems(
            draft.allergies,
            tooLongIssue: UserProfileValidationIssue.allergyTooLong,
            tooManyIssue: .tooManyAllergies
        )
        let diagnosedConditions = try cleanItems(
            draft.diagnosedConditions,
            tooLongIssue:
                UserProfileValidationIssue.diagnosedConditionTooLong,
            tooManyIssue: .tooManyDiagnosedConditions
        )
        let medicineNames = try cleanItems(
            draft.currentMedicineNames,
            tooLongIssue:
                UserProfileValidationIssue.currentMedicineNameTooLong,
            tooManyIssue: .tooManyCurrentMedicineNames
        )

        let healthProfile = UserHealthProfile(
            id: id,
            age: age,
            allergies: [],
            diagnosedConditions: diagnosedConditions,
            currentMedicineIngredientIDs: [],
            bodyMetrics: nil,
            updatedAt: updatedAt,
            createdAt: createdAt
        )
        return LocalUserProfileBundle(
            source: .userEnteredLocal,
            preferredName: preferredName,
            healthProfile: healthProfile,
            unresolvedAllergyDescriptions:
                unresolvedAllergyDescriptions,
            unresolvedMedicineNames: medicineNames,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func cleanItems(
        _ items: [String],
        tooLongIssue: (Int) -> UserProfileValidationIssue,
        tooManyIssue: UserProfileValidationIssue
    ) throws -> [String] {
        var result = [String]()
        var seenKeys = Set<String>()

        for (index, item) in items.enumerated() {
            let cleaned = clean(item)
            guard !cleaned.isEmpty else { continue }
            guard cleaned.count <= Self.maximumItemLength else {
                throw tooLongIssue(index)
            }

            let key = cleaned.lowercased()
            if seenKeys.insert(key).inserted {
                result.append(cleaned)
            }
        }

        guard result.count <= Self.maximumItemsPerGroup else {
            throw tooManyIssue
        }
        return result
    }

    private func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
