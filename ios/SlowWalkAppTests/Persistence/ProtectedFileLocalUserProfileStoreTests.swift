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

    @Test func saveRequestsProtectionInSafetyOrder() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let protector = RecordingLocalProfileFileProtector()
        try await makeStore(
            at: directory,
            fileProtector: protector
        ).saveCurrentProfile(
            makeBundle(token: 1, preferredName: "Lin")
        )

        let fileURL = profileURL(in: directory)
        #expect(await protector.recordedOperations() == [
            .protectDirectory(directory),
            .protectFile(fileURL),
            .excludeFromBackup(fileURL),
        ])
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func defaultStoreUsesAppleFileProtector() async {
        let directory = temporaryDirectory()
        let store = ProtectedFileLocalUserProfileStore(
            baseDirectory: directory
        )
        let protector = await store.fileProtector

        #expect(protector is AppleLocalProfileFileProtector)
    }

    @Test func directoryProtectionFailureIsFailClosed() async {
        await assertProtectionFailure(
            .directory,
            expected: .directoryProtectionFailed
        )
    }

    @Test func fileProtectionFailureIsFailClosed() async {
        await assertProtectionFailure(
            .file,
            expected: .protectionFailed
        )
    }

    @Test func backupExclusionFailureIsFailClosed() async {
        await assertProtectionFailure(
            .backup,
            expected: .backupExclusionFailed
        )
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
        at directory: URL,
        fileProtector: any LocalProfileFileProtecting =
            TestLocalProfileFileProtector()
    ) -> ProtectedFileLocalUserProfileStore {
        ProtectedFileLocalUserProfileStore(
            baseDirectory: directory,
            fileProtector: fileProtector
        )
    }

    private func assertProtectionFailure(
        _ failure: RecordingLocalProfileFileProtector.Failure,
        expected: ProtectedLocalUserProfileStoreError
    ) async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let protector = RecordingLocalProfileFileProtector(
            failure: failure
        )
        let store = makeStore(
            at: directory,
            fileProtector: protector
        )
        let sensitiveValues = [
            "Private Name",
            "72",
            "Private condition",
            "Secret allergy",
            "Secret medicine",
        ]
        let profile = makeBundle(
            token: 1,
            preferredName: sensitiveValues[0],
            diagnosedCondition: sensitiveValues[2],
            allergyDescription: sensitiveValues[3],
            medicineName: sensitiveValues[4]
        )

        do {
            try await store.saveCurrentProfile(profile)
            Issue.record("Expected protection failure.")
        } catch {
            #expect(
                error as? ProtectedLocalUserProfileStoreError == expected
            )
            for description in [
                String(describing: error),
                error.localizedDescription,
            ] {
                for sensitiveValue in sensitiveValues {
                    #expect(!description.contains(sensitiveValue))
                }
            }
        }

        let fileURL = profileURL(in: directory)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(
            await protector.recordedOperations()
                == expectedOperations(
                    before: failure,
                    directory: directory,
                    fileURL: fileURL
                )
        )
    }

    private func expectedOperations(
        before failure: RecordingLocalProfileFileProtector.Failure,
        directory: URL,
        fileURL: URL
    ) -> [RecordingLocalProfileFileProtector.Operation] {
        switch failure {
        case .directory:
            [.protectDirectory(directory)]
        case .file:
            [.protectDirectory(directory), .protectFile(fileURL)]
        case .backup:
            [
                .protectDirectory(directory),
                .protectFile(fileURL),
                .excludeFromBackup(fileURL),
            ]
        }
    }

    private func makeBundle(
        token: UInt8,
        preferredName: String,
        schemaVersion: Int = LocalUserProfileBundle.currentSchemaVersion,
        diagnosedCondition: String = "Hypertension",
        allergyDescription: String = "Pollen note",
        medicineName: String = "Daily Tablet"
    ) -> LocalUserProfileBundle {
        let healthProfile = UserHealthProfile(
            id: fixedUUID(token: token),
            age: 72,
            allergies: [],
            diagnosedConditions: [diagnosedCondition],
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
            unresolvedAllergyDescriptions: [allergyDescription],
            unresolvedMedicineNames: [medicineName],
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

private struct TestLocalProfileFileProtector:
    LocalProfileFileProtecting
{
    func protectDirectory(at url: URL) async throws {}
    func protectFile(at url: URL) async throws {}
    func excludeFromBackup(_ url: URL) async throws {}
}

private actor RecordingLocalProfileFileProtector:
    LocalProfileFileProtecting
{
    enum Operation: Sendable, Equatable {
        case protectDirectory(URL)
        case protectFile(URL)
        case excludeFromBackup(URL)
    }

    enum Failure: Error, Sendable, Equatable {
        case directory
        case file
        case backup
    }

    private let failure: Failure?
    private var operations: [Operation] = []

    init(failure: Failure? = nil) {
        self.failure = failure
    }

    func protectDirectory(at url: URL) async throws {
        operations.append(.protectDirectory(url))
        if failure == .directory {
            throw Failure.directory
        }
    }

    func protectFile(at url: URL) async throws {
        operations.append(.protectFile(url))
        if failure == .file {
            throw Failure.file
        }
    }

    func excludeFromBackup(_ url: URL) async throws {
        operations.append(.excludeFromBackup(url))
        if failure == .backup {
            throw Failure.backup
        }
    }

    func recordedOperations() -> [Operation] {
        operations
    }
}
