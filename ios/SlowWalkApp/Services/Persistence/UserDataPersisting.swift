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

protocol LocalProfileFileProtecting: Sendable {
    func protectDirectory(at url: URL) async throws
    func protectFile(at url: URL) async throws
    func excludeFromBackup(_ url: URL) async throws
}

struct AppleLocalProfileFileProtector: LocalProfileFileProtecting {
    func protectDirectory(at url: URL) async throws {
        try applyAndVerifyCompleteProtection(to: url)
    }

    func protectFile(at url: URL) async throws {
        try applyAndVerifyCompleteProtection(to: url)
    }

    func excludeFromBackup(_ url: URL) async throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)

        let storedValues = try mutableURL.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        )
        guard storedValues.isExcludedFromBackup == true else {
            throw VerificationError.failed
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
            throw VerificationError.failed
        }
    }

    private enum VerificationError: Error {
        case failed
    }
}

actor ProtectedFileLocalUserProfileStore: LocalUserProfileStore {
    static let fileName = "current-user-profile.json"

    private let baseDirectory: URL
    let fileProtector: any LocalProfileFileProtecting

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        fileProtector = AppleLocalProfileFileProtector()
    }

    init(
        baseDirectory: URL,
        fileProtector: any LocalProfileFileProtecting
    ) {
        self.baseDirectory = baseDirectory
        self.fileProtector = fileProtector
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

        try await prepareProtectedDirectory()
        do {
            try data.write(
                to: fileURL,
                options: [.atomic, .completeFileProtection]
            )
        } catch {
            throw ProtectedLocalUserProfileStoreError.atomicWriteFailed
        }

        do {
            try await fileProtector.protectFile(at: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw ProtectedLocalUserProfileStoreError.protectionFailed
        }
        do {
            try await fileProtector.excludeFromBackup(fileURL)
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

    private func prepareProtectedDirectory() async throws {
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
            try await fileProtector.protectDirectory(at: baseDirectory)
        } catch {
            throw ProtectedLocalUserProfileStoreError
                .directoryProtectionFailed
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
