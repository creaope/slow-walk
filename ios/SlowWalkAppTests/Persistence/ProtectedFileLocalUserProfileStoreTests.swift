import Foundation
import SlowWalkDomain
import Testing

@testable import SlowWalkApp

@Suite("Protected local user profile store")
@MainActor
struct ProtectedFileLocalUserProfileStoreTests {
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func missingFileReturnsNil() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let loaded = try await makeStore(at: directory)
            .loadCurrentProfile()

        #expect(loaded == nil)
    }

    @Test func savedProfileCanBeReadByNewStore() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = makeBundle(token: 1, preferredName: "Lin")

        try await makeStore(at: directory).saveCurrentProfile(profile)
        let loaded = try await makeStore(at: directory)
            .loadCurrentProfile()

        #expect(loaded == profile)
    }

    @Test func secondSaveOverwritesCurrentProfile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(at: directory)
        let first = makeBundle(token: 1, preferredName: "First")
        let second = makeBundle(token: 2, preferredName: "Second")

        try await store.saveCurrentProfile(first)
        try await store.saveCurrentProfile(second)
        let loaded = try await makeStore(at: directory)
            .loadCurrentProfile()

        #expect(loaded == second)
    }

    @Test func deleteRemovesCurrentProfile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(at: directory)
        try await store.saveCurrentProfile(
            makeBundle(token: 1, preferredName: "Lin")
        )

        try await store.deleteCurrentProfile()
        let loaded = try await store.loadCurrentProfile()

        #expect(loaded == nil)
        #expect(!FileManager.default.fileExists(
            atPath: profileURL(in: directory).path
        ))
    }

    @Test func deletingMissingFileIsIdempotent() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(at: directory)

        try await store.deleteCurrentProfile()
        try await store.deleteCurrentProfile()

        let loaded = try await store.loadCurrentProfile()
        #expect(loaded == nil)
    }

    @Test func corruptedJSONReturnsStableError() async throws {
        let directory = try preparedDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"schemaVersion":"#.utf8).write(
            to: profileURL(in: directory)
        )

        do {
            _ = try await makeStore(at: directory).loadCurrentProfile()
            Issue.record("Expected corruptedJSON.")
        } catch {
            #expect(
                error as? ProtectedLocalUserProfileStoreError
                    == .corruptedJSON
            )
        }
    }

    @Test func unsupportedSchemaVersionIsRejected() async throws {
        let directory = try preparedDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let unsupported = makeBundle(
            token: 1,
            preferredName: "Lin",
            schemaVersion: 99
        )
        try encode(unsupported).write(to: profileURL(in: directory))

        do {
            _ = try await makeStore(at: directory).loadCurrentProfile()
            Issue.record("Expected unsupportedSchemaVersion.")
        } catch {
            #expect(
                error as? ProtectedLocalUserProfileStoreError
                    == .unsupportedSchemaVersion(found: 99)
            )
        }

        do {
            try await makeStore(at: directory)
                .saveCurrentProfile(unsupported)
            Issue.record("Expected unsupportedSchemaVersion on save.")
        } catch {
            #expect(
                error as? ProtectedLocalUserProfileStoreError
                    == .unsupportedSchemaVersion(found: 99)
            )
        }
    }

    @Test func fileAndDirectoryUseCompleteProtection() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await makeStore(at: directory).saveCurrentProfile(
            makeBundle(token: 1, preferredName: "Lin")
        )

        let fileValues = try profileURL(in: directory).resourceValues(
            forKeys: [.fileProtectionKey]
        )
        let directoryValues = try directory.resourceValues(
            forKeys: [.fileProtectionKey]
        )

        #expect(fileValues.fileProtection == .complete)
        #expect(directoryValues.fileProtection == .complete)
    }

    @Test func savedFileIsExcludedFromBackup() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(at: directory)

        try await store.saveCurrentProfile(
            makeBundle(token: 1, preferredName: "First")
        )
        try await store.saveCurrentProfile(
            makeBundle(token: 2, preferredName: "Second")
        )

        let values = try profileURL(in: directory).resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        )
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func errorsDoNotContainProfileContents() async throws {
        let directory = try preparedDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sensitiveValues = [
            "Private Name",
            "72",
            "Private condition",
            "Secret allergy",
            "Secret medicine",
        ]
        let damagedBody = """
        {"schemaVersion":1,"preferredName":"Private Name","age":72,
        "condition":"Private condition","allergy":"Secret allergy",
        "medicine":"Secret medicine"
        """
        try Data(damagedBody.utf8).write(to: profileURL(in: directory))

        do {
            _ = try await makeStore(at: directory).loadCurrentProfile()
            Issue.record("Expected corruptedJSON.")
        } catch {
            #expect(
                error as? ProtectedLocalUserProfileStoreError
                    == .corruptedJSON
            )
            let descriptions = [
                String(describing: error),
                error.localizedDescription,
            ]
            for description in descriptions {
                for sensitiveValue in sensitiveValues {
                    #expect(!description.contains(sensitiveValue))
                }
            }
        }
    }

    private func makeStore(
        at directory: URL
    ) -> ProtectedFileLocalUserProfileStore {
        ProtectedFileLocalUserProfileStore(baseDirectory: directory)
    }

    private func makeBundle(
        token: UInt8,
        preferredName: String,
        schemaVersion: Int = LocalUserProfileBundle.currentSchemaVersion
    ) -> LocalUserProfileBundle {
        let healthProfile = UserHealthProfile(
            id: fixedUUID(token: token),
            age: 72,
            allergies: [],
            diagnosedConditions: ["Hypertension"],
            currentMedicineIngredientIDs: [],
            bodyMetrics: nil,
            updatedAt: timestamp,
            createdAt: timestamp
        )
        return LocalUserProfileBundle(
            schemaVersion: schemaVersion,
            source: .userEnteredLocal,
            preferredName: preferredName,
            healthProfile: healthProfile,
            unresolvedAllergyDescriptions: ["Pollen note"],
            unresolvedMedicineNames: ["Daily Tablet"],
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }

    private func encode(_ profile: LocalUserProfileBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(profile)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "slowwalk-protected-profile-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func preparedDirectory() throws -> URL {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func profileURL(in directory: URL) -> URL {
        directory.appendingPathComponent(
            ProtectedFileLocalUserProfileStore.fileName,
            isDirectory: false
        )
    }

    private func fixedUUID(token: UInt8) -> UUID {
        UUID(
            uuid: (
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, token
            )
        )
    }
}
