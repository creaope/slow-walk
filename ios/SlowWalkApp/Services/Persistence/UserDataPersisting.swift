import Foundation
import SlowWalkDataInterfaces
import SlowWalkDomain

/// Local persistence boundary for the current profile and medication history.
protocol UserDataPersisting: LocalUserProfileStore {
    func loadMedicationHistory() async throws -> [MedicationRecord]
    func saveMedicationRecord(_ record: MedicationRecord) async throws
}

enum ProtectedLocalUserProfileStoreError:
    Error,
    Sendable,
    Equatable
{
    case corruptedJSON
    case unsupportedSchemaVersion(found: Int)
    case readFailed
    case directoryCreationFailed
    case directoryProtectionFailed
    case encodingFailed
    case atomicWriteFailed
    case protectionFailed
    case backupExclusionFailed
    case deleteFailed
}

actor ProtectedFileLocalUserProfileStore: LocalUserProfileStore {
    static let fileName = "current-user-profile.json"

    private let baseDirectory: URL

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    func loadCurrentProfile() async throws -> LocalUserProfileBundle? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            guard manager.fileExists(atPath: fileURL.path) else {
                return nil
            }
            throw ProtectedLocalUserProfileStoreError.readFailed
        }

        let profile: LocalUserProfileBundle
        do {
            profile = try Self.makeDecoder().decode(
                LocalUserProfileBundle.self,
                from: data
            )
        } catch {
            throw ProtectedLocalUserProfileStoreError.corruptedJSON
        }
        try ensureSupportedSchema(profile)
        return profile
    }

    func saveCurrentProfile(
        _ profile: LocalUserProfileBundle
    ) async throws {
        try ensureSupportedSchema(profile)

        let data: Data
        do {
            data = try Self.makeEncoder().encode(profile)
        } catch {
            throw ProtectedLocalUserProfileStoreError.encodingFailed
        }

        try prepareProtectedDirectory()
        do {
            try data.write(
                to: fileURL,
                options: [.atomic, .completeFileProtection]
            )
        } catch {
            throw ProtectedLocalUserProfileStoreError.atomicWriteFailed
        }

        do {
            try applyAndVerifyCompleteProtection(to: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw ProtectedLocalUserProfileStoreError.protectionFailed
        }
        do {
            try excludeAndVerifyBackup(for: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw ProtectedLocalUserProfileStoreError
                .backupExclusionFailed
        }
    }

    func deleteCurrentProfile() async throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else {
            return
        }
        do {
            try manager.removeItem(at: fileURL)
        } catch {
            guard manager.fileExists(atPath: fileURL.path) else {
                return
            }
            throw ProtectedLocalUserProfileStoreError.deleteFailed
        }
    }

    private var fileURL: URL {
        baseDirectory.appendingPathComponent(
            Self.fileName,
            isDirectory: false
        )
    }

    private func ensureSupportedSchema(
        _ profile: LocalUserProfileBundle
    ) throws {
        guard profile.schemaVersion
            == LocalUserProfileBundle.currentSchemaVersion else {
            throw ProtectedLocalUserProfileStoreError
                .unsupportedSchemaVersion(found: profile.schemaVersion)
        }
    }

    private func prepareProtectedDirectory() throws {
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: baseDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw ProtectedLocalUserProfileStoreError
                .directoryCreationFailed
        }
        do {
            try applyAndVerifyCompleteProtection(to: baseDirectory)
        } catch {
            throw ProtectedLocalUserProfileStoreError
                .directoryProtectionFailed
        }
    }

    private func applyAndVerifyCompleteProtection(to url: URL) throws {
        try (url as NSURL).setResourceValue(
            URLFileProtection.complete,
            forKey: .fileProtectionKey
        )
        let values = try url.resourceValues(
            forKeys: [.fileProtectionKey]
        )
        guard values.fileProtection == .complete else {
            throw ProtectedLocalUserProfileStoreError.protectionFailed
        }
    }

    private func excludeAndVerifyBackup(for url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)

        let storedValues = try mutableURL.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        )
        guard storedValues.isExcludedFromBackup == true else {
            throw ProtectedLocalUserProfileStoreError
                .backupExclusionFailed
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
