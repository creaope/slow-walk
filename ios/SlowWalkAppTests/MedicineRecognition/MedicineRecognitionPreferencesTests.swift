import Foundation
import SlowWalkClientCore
import Testing

@testable import SlowWalkApp

@Suite(
    "Medicine recognition preferences",
    .serialized
)
@MainActor
struct MedicineRecognitionPreferencesTests {
    @Test func defaultsToRemotePreferred() throws {
        let isolated = try makeIsolatedDefaults()
        defer { isolated.remove() }

        let preferences = MedicineRecognitionPreferences(
            defaults: isolated.defaults
        )

        #expect(preferences.onDeviceOnly == false)
        #expect(preferences.mode == .remotePreferred)
        #expect(
            isolated.defaults.object(
                forKey: MedicineRecognitionPreferences
                    .onDeviceOnlyDefaultsKey
            ) == nil
        )
    }

    @Test func switchingModePersistsAcrossInstances() throws {
        let isolated = try makeIsolatedDefaults()
        defer { isolated.remove() }
        let preferences = MedicineRecognitionPreferences(
            defaults: isolated.defaults
        )

        preferences.onDeviceOnly = true

        #expect(preferences.mode == .onDeviceOnly)
        let restored = MedicineRecognitionPreferences(
            defaults: isolated.defaults
        )
        #expect(restored.onDeviceOnly)
        #expect(restored.mode == .onDeviceOnly)

        restored.onDeviceOnly = false
        #expect(
            MedicineRecognitionPreferences(
                defaults: isolated.defaults
            ).mode == .remotePreferred
        )
    }

    @Test func userDefaultsSuitesRemainIsolated() throws {
        let first = try makeIsolatedDefaults()
        let second = try makeIsolatedDefaults()
        defer {
            first.remove()
            second.remove()
        }

        let changed = MedicineRecognitionPreferences(
            defaults: first.defaults
        )
        changed.onDeviceOnly = true

        let untouched = MedicineRecognitionPreferences(
            defaults: second.defaults
        )
        #expect(untouched.onDeviceOnly == false)
        #expect(untouched.mode == .remotePreferred)
    }

    @Test func anEarlierModeSnapshotDoesNotChangeRetroactively() throws {
        let isolated = try makeIsolatedDefaults()
        defer { isolated.remove() }
        let preferences = MedicineRecognitionPreferences(
            defaults: isolated.defaults
        )
        let submittedMode = preferences.mode

        preferences.onDeviceOnly = true

        #expect(submittedMode == .remotePreferred)
        #expect(preferences.mode == .onDeviceOnly)
    }

    private func makeIsolatedDefaults() throws -> IsolatedDefaults {
        let suiteName =
            "com.creaope.slowwalk.tests.medicine-recognition.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return IsolatedDefaults(
            defaults: defaults,
            suiteName: suiteName
        )
    }
}

@MainActor
private struct IsolatedDefaults {
    let defaults: UserDefaults
    let suiteName: String

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
