import Foundation
import SlowWalkDataInterfaces
import SlowWalkDomain
import XCTest

final class FileLocalUserProfileStoreTests: XCTestCase {
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    func testSavedProfileCanBeLoadedByNewStore() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = makeBundle(token: 1, preferredName: "Lin")

        try await makeStore(at: directory).saveCurrentProfile(profile)
        let loaded = try await makeStore(at: directory).loadCurrentProfile()

        XCTAssertEqual(loaded, profile)
    }

    func testSecondSaveOverwritesCurrentProfile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(at: directory)
        let first = makeBundle(token: 1, preferredName: "First")
        let second = makeBundle(token: 2, preferredName: "Second")

        try await store.saveCurrentProfile(first)
        try await store.saveCurrentProfile(second)
        let loaded = try await makeStore(at: directory).loadCurrentProfile()

        XCTAssertEqual(loaded, second)
    }

    func testDeleteRemovesCurrentProfile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(at: directory)
        try await store.saveCurrentProfile(
            makeBundle(token: 1, preferredName: "Lin")
        )

        try await store.deleteCurrentProfile()
        let loaded = try await makeStore(at: directory).loadCurrentProfile()

        XCTAssertNil(loaded)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(
                    FileLocalUserProfileStore.fileName
                ).path
            )
        )
    }

    func testMissingFileReturnsNil() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let loaded = try await makeStore(at: directory).loadCurrentProfile()

        XCTAssertNil(loaded)
    }

    func testCorruptedJSONReturnsStableError() async throws {
        let directory = try preparedDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"schemaVersion":"#.utf8).write(
            to: profileURL(in: directory)
        )

        do {
            _ = try await makeStore(at: directory).loadCurrentProfile()
            XCTFail("Expected a corrupted JSON error.")
        } catch {
            XCTAssertEqual(error as? JSONRepositoryError, .corruptedJSON)
        }
    }

    func testUnsupportedEnvelopeSchemaIsRejected() async throws {
        let directory = try preparedDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(
            #"{"records":[],"schemaVersion":99}"#.utf8
        ).write(to: profileURL(in: directory))

        do {
            _ = try await makeStore(at: directory).loadCurrentProfile()
            XCTFail("Expected an unsupported schema error.")
        } catch {
            XCTAssertEqual(
                error as? JSONRepositoryError,
                .unsupportedSchemaVersion(found: 99)
            )
        }
    }

    func testUnsupportedBundleSchemaIsRejectedOnSaveAndLoad()
        async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let unsupported = makeBundle(
            token: 1,
            preferredName: "Lin",
            schemaVersion: 99
        )

        do {
            try await makeStore(at: directory)
                .saveCurrentProfile(unsupported)
            XCTFail("Expected an unsupported schema error on save.")
        } catch {
            XCTAssertEqual(
                error as? JSONRepositoryError,
                .unsupportedSchemaVersion(found: 99)
            )
        }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let envelope = TestEnvelope(
            schemaVersion: LocalUserProfileBundle.currentSchemaVersion,
            records: [unsupported]
        )
        try encoder.encode(envelope).write(to: profileURL(in: directory))

        do {
            _ = try await makeStore(at: directory).loadCurrentProfile()
            XCTFail("Expected an unsupported schema error on load.")
        } catch {
            XCTAssertEqual(
                error as? JSONRepositoryError,
                .unsupportedSchemaVersion(found: 99)
            )
        }
    }

    private func makeStore(
        at directory: URL
    ) -> FileLocalUserProfileStore {
        FileLocalUserProfileStore(
            baseDirectory: directory,
            uuidProvider: FixedUUIDProvider(
                fixedUUID: fixedUUID(token: 99)
            )
        )
    }

    private func makeBundle(
        token: UInt8,
        preferredName: String,
        schemaVersion: Int = LocalUserProfileBundle.currentSchemaVersion
    ) -> LocalUserProfileBundle {
        let healthProfile = UserHealthProfile(
            id: fixedUUID(token: token),
            age: 72,
            allergies: ["Pollen"],
            diagnosedConditions: [],
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
            unresolvedMedicineNames: ["Daily Tablet"],
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "slowwalk-local-profile-\(UUID().uuidString)",
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
            FileLocalUserProfileStore.fileName,
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

private struct TestEnvelope<Value: Codable>: Codable {
    let schemaVersion: Int
    let records: [Value]
}
