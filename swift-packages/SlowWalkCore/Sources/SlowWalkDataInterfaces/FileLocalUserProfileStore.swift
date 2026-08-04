import Foundation
import SlowWalkDomain

/// Actor-isolated JSON store for the current local user profile.
public actor FileLocalUserProfileStore: LocalUserProfileStore {
    public static let fileName = "current-user-profile.json"

    private let file: JSONRepositoryFile<LocalUserProfileBundle>

    public init(
        baseDirectory: URL,
        uuidProvider: any UUIDProviding = SystemUUIDProvider()
    ) {
        file = JSONRepositoryFile(
            baseDirectory: baseDirectory,
            fileName: Self.fileName,
            schemaVersion: LocalUserProfileBundle.currentSchemaVersion,
            uuidProvider: uuidProvider
        )
    }

    public func loadCurrentProfile() async throws
        -> LocalUserProfileBundle? {
        let profiles: [LocalUserProfileBundle]
        do {
            profiles = try file.load()
        } catch JSONRepositoryError.fileNotFound {
            return nil
        }

        guard profiles.count == 1 else {
            throw JSONRepositoryError.corruptedJSON
        }
        let profile = profiles[0]
        try ensureSupportedSchema(profile)
        return profile
    }

    public func saveCurrentProfile(
        _ profile: LocalUserProfileBundle
    ) async throws {
        try ensureSupportedSchema(profile)
        try file.write([profile])
    }

    public func deleteCurrentProfile() async throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: file.fileURL.path) else {
            return
        }
        try manager.removeItem(at: file.fileURL)
    }

    private func ensureSupportedSchema(
        _ profile: LocalUserProfileBundle
    ) throws {
        guard profile.schemaVersion
            == LocalUserProfileBundle.currentSchemaVersion else {
            throw JSONRepositoryError.unsupportedSchemaVersion(
                found: profile.schemaVersion
            )
        }
    }
}
