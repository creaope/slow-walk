import Foundation
import Observation
import SlowWalkDataInterfaces
import SlowWalkDomain

enum UserProfileSessionState: Equatable, Sendable {
    case idle
    case loading
    case needsOnboarding
    case ready(LocalUserProfileBundle)
    case failed(UserProfileSessionFailure)
}

enum UserProfileSessionFailure:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    case loadFailed
    case saveFailed
    case deleteFailed
    case invalidStoredProfile
    case invalidBundledDemoProfile
    case profileAlreadyExists
    case profileStateUnresolved
    case noCurrentProfile
    case operationInProgress

    var description: String {
        switch self {
        case .loadFailed:
            "loadFailed"
        case .saveFailed:
            "saveFailed"
        case .deleteFailed:
            "deleteFailed"
        case .invalidStoredProfile:
            "invalidStoredProfile"
        case .invalidBundledDemoProfile:
            "invalidBundledDemoProfile"
        case .profileAlreadyExists:
            "profileAlreadyExists"
        case .profileStateUnresolved:
            "profileStateUnresolved"
        case .noCurrentProfile:
            "noCurrentProfile"
        case .operationInProgress:
            "operationInProgress"
        }
    }
}

@Observable
@MainActor
final class UserProfileSession {
    private(set) var state: UserProfileSessionState = .idle

    private let store: any LocalUserProfileStore
    private let validator: UserProfileDraftValidator
    private let bundledDemoProfile: LocalUserProfileBundle
    private let uuidProvider: any UUIDProviding
    private let clock: any SlowWalkDomain.Clock
    private var isOperationInProgress = false

    init(
        store: any LocalUserProfileStore,
        validator: UserProfileDraftValidator,
        bundledDemoProfile: LocalUserProfileBundle,
        uuidProvider: any UUIDProviding,
        clock: any SlowWalkDomain.Clock
    ) {
        self.store = store
        self.validator = validator
        self.bundledDemoProfile = bundledDemoProfile
        self.uuidProvider = uuidProvider
        self.clock = clock
    }

    func load() async {
        guard !isOperationInProgress else { return }
        guard case .ready = state else {
            await performLoad()
            return
        }
    }

    func create(from draft: UserProfileDraft) async throws {
        try ensureProfileCreationCanBegin()

        let id = uuidProvider.makeUUID()
        let now = clock.now()
        let profile = try validator.validate(
            draft,
            id: id,
            createdAt: now,
            updatedAt: now
        )

        try await save(profile)
    }

    func update(from draft: UserProfileDraft) async throws {
        try ensureOperationCanBegin()
        guard case let .ready(existingProfile) = state else {
            throw UserProfileSessionFailure.noCurrentProfile
        }

        var effectiveUpdatedAt = clock.now()
        effectiveUpdatedAt = max(
            effectiveUpdatedAt,
            existingProfile.updatedAt
        )
        effectiveUpdatedAt = max(
            effectiveUpdatedAt,
            existingProfile.healthProfile.updatedAt
        )
        effectiveUpdatedAt = max(
            effectiveUpdatedAt,
            existingProfile.createdAt
        )
        effectiveUpdatedAt = max(
            effectiveUpdatedAt,
            existingProfile.healthProfile.createdAt
        )
        let validatedProfile = try validator.validate(
            draft,
            id: existingProfile.healthProfile.id,
            createdAt: existingProfile.healthProfile.createdAt,
            updatedAt: effectiveUpdatedAt
        )
        let updatedHealthProfile = UserHealthProfile(
            id: existingProfile.healthProfile.id,
            age: validatedProfile.healthProfile.age,
            allergies: existingProfile.healthProfile.allergies,
            diagnosedConditions:
                validatedProfile.healthProfile.diagnosedConditions,
            currentMedicineIngredientIDs:
                existingProfile.healthProfile.currentMedicineIngredientIDs,
            bodyMetrics: existingProfile.healthProfile.bodyMetrics,
            updatedAt: effectiveUpdatedAt,
            createdAt: existingProfile.healthProfile.createdAt,
            schemaVersion: existingProfile.healthProfile.schemaVersion
        )
        let updatedProfile = LocalUserProfileBundle(
            schemaVersion: LocalUserProfileBundle.currentSchemaVersion,
            source: .userEnteredLocal,
            preferredName: validatedProfile.preferredName,
            healthProfile: updatedHealthProfile,
            unresolvedAllergyDescriptions:
                validatedProfile.unresolvedAllergyDescriptions,
            unresolvedMedicineNames:
                validatedProfile.unresolvedMedicineNames,
            createdAt: existingProfile.createdAt,
            updatedAt: effectiveUpdatedAt
        )

        try await save(updatedProfile)
    }

    func useBundledDemoProfile() async throws {
        try ensureProfileCreationCanBegin()
        guard bundledDemoProfile.source == .bundledDemo,
              hasCurrentSchema(bundledDemoProfile)
        else {
            state = .failed(.invalidBundledDemoProfile)
            throw UserProfileSessionFailure.invalidBundledDemoProfile
        }

        try await save(bundledDemoProfile)
    }

    func deleteCurrentProfile() async throws {
        try beginOperation()
        defer { isOperationInProgress = false }

        do {
            try await store.deleteCurrentProfile()
            state = .needsOnboarding
        } catch {
            state = .failed(.deleteFailed)
            throw UserProfileSessionFailure.deleteFailed
        }
    }

    private func performLoad() async {
        beginLoad()
        defer { isOperationInProgress = false }

        do {
            if let profile = try await store.loadCurrentProfile() {
                if hasCurrentSchema(profile) {
                    state = .ready(profile)
                } else {
                    state = .failed(.invalidStoredProfile)
                }
            } else {
                state = .needsOnboarding
            }
        } catch {
            state = .failed(loadFailure(for: error))
        }
    }

    private func loadFailure(
        for error: any Error
    ) -> UserProfileSessionFailure {
        guard let storeError = error as? ProtectedLocalUserProfileStoreError
        else {
            return .loadFailed
        }

        switch storeError {
        case .unsupportedSchemaVersion:
            return .invalidStoredProfile
        default:
            return .loadFailed
        }
    }

    private func hasCurrentSchema(
        _ profile: LocalUserProfileBundle
    ) -> Bool {
        profile.schemaVersion
            == LocalUserProfileBundle.currentSchemaVersion
            && profile.healthProfile.schemaVersion
                == UserHealthProfile.currentSchemaVersion
    }

    private func ensureProfileCreationCanBegin() throws {
        try ensureOperationCanBegin()

        switch state {
        case .needsOnboarding:
            return
        case .ready:
            throw UserProfileSessionFailure.profileAlreadyExists
        case .idle, .failed:
            throw UserProfileSessionFailure.profileStateUnresolved
        case .loading:
            throw UserProfileSessionFailure.operationInProgress
        }
    }

    private func save(_ profile: LocalUserProfileBundle) async throws {
        try beginOperation()
        defer { isOperationInProgress = false }

        do {
            try await store.saveCurrentProfile(profile)
            state = .ready(profile)
        } catch {
            state = .failed(.saveFailed)
            throw UserProfileSessionFailure.saveFailed
        }
    }

    private func ensureOperationCanBegin() throws {
        guard !isOperationInProgress else {
            throw UserProfileSessionFailure.operationInProgress
        }
    }

    private func beginOperation() throws {
        try ensureOperationCanBegin()
        isOperationInProgress = true
        state = .loading
    }

    private func beginLoad() {
        isOperationInProgress = true
        state = .loading
    }
}
