import Foundation
import SlowWalkDomain

/// Read/write boundary for canonical medicine data.
public protocol MedicineRepository: Sendable {
    func medicine(id: String) async throws -> Medicine?
    func allMedicines() async throws -> [Medicine]
    func save(_ medicine: Medicine) async throws
}

/// General multi-record profile boundary for non-iOS or reusable runtimes.
///
/// iOS onboarding, settings, and Medicine runtime must use
/// `LocalUserProfileStore` for the current user instead of maintaining a
/// second current-profile copy through this interface.
public protocol UserHealthProfileRepository: Sendable {
    func fetch(id: UUID) async throws -> UserHealthProfile?
    func fetchAll() async throws -> [UserHealthProfile]
    func save(_ profile: UserHealthProfile) async throws
    func update(_ profile: UserHealthProfile) async throws
    func delete(id: UUID) async throws
}

/// Canonical persistence boundary for the iOS current-user profile bundle.
///
/// This is the single source of truth for the current composite profile.
public protocol LocalUserProfileStore: Sendable {
    func loadCurrentProfile() async throws -> LocalUserProfileBundle?
    func saveCurrentProfile(
        _ profile: LocalUserProfileBundle
    ) async throws
    func deleteCurrentProfile() async throws
}

/// Read/write boundary for medication history.
public protocol MedicationHistoryRepository: Sendable {
    func fetch(id: UUID) async throws -> MedicationRecord?
    func fetchAll() async throws -> [MedicationRecord]
    func fetch(within interval: DateInterval) async throws
        -> [MedicationRecord]
    func append(_ record: MedicationRecord) async throws
    func delete(id: UUID) async throws
    @discardableResult
    func removeDuplicates() async throws -> Int
}

/// Cache boundary kept separate from the source-of-truth repository.
public protocol MedicineCache: Sendable {
    func cachedMedicine(id: String) async throws -> Medicine?
    func store(_ medicine: Medicine) async throws
    func removeMedicine(id: String) async throws
    func removeAll() async throws

    /// Looks up a name-resolution result for the current source-data version.
    ///
    /// A `.hit` reuses only medicine-name resolution. Callers must still build
    /// a fresh risk context and run the risk engine for every request.
    func cachedResolution(
        normalizedQuery: String,
        sourceDataVersion: String,
        now: Date
    ) async throws -> MedicineResolutionCacheLookup

    /// Stores a resolution using the cache actor's configured TTL policy.
    ///
    /// `normalizedQuery` must represent every normalized OCR query variant
    /// that contributed to the resolution. The actor computes `expiresAt`
    /// from `now` and its policy.
    func storeResolution(
        _ resolution: MedicineResolution,
        normalizedQuery: String,
        sourceDataVersion: String,
        now: Date
    ) async throws
}

/// Search boundary for canonical medicine data.
public protocol MedicineSearching: Sendable {
    func searchMedicines(matching query: String) async throws -> [Medicine]
}

/// Typed repository failures with actionable context.
public enum DataInterfaceError: Error, Sendable, Equatable {
    case invalidDateRange(start: Date, end: Date)
    case invalidNormalizedQuery
    case invalidSourceDataVersion
    case profileNotFound(id: UUID)
    case medicationRecordNotFound(id: UUID)
}

public extension UserHealthProfileRepository {
    func profile(id: UUID) async throws -> UserHealthProfile? {
        try await fetch(id: id)
    }

    func allProfiles() async throws -> [UserHealthProfile] {
        try await fetchAll()
    }
}

public extension MedicationHistoryRepository {
    func record(id: UUID) async throws -> MedicationRecord? {
        try await fetch(id: id)
    }

    func records(
        from startDate: Date?,
        through endDate: Date?
    ) async throws -> [MedicationRecord] {
        if let startDate, let endDate {
            guard startDate <= endDate else {
                throw DataInterfaceError.invalidDateRange(
                    start: startDate,
                    end: endDate
                )
            }
            return try await fetch(
                within: DateInterval(
                    start: startDate,
                    end: endDate
                )
            )
        }
        return try await fetchAll().filter { record in
            let afterStart = startDate.map {
                record.recordedAt >= $0
            } ?? true
            let beforeEnd = endDate.map {
                record.recordedAt <= $0
            } ?? true
            return afterStart && beforeEnd
        }
    }

    func save(_ record: MedicationRecord) async throws {
        try await append(record)
    }
}
