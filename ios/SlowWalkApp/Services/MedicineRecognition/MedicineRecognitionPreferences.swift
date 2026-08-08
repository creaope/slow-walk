import Foundation
import SlowWalkClientCore

/// User-controlled recognition routing preference.
///
/// The value is read as a snapshot when a new assessment is submitted. A
/// change never mutates or reclassifies an operation that is already running.
@Observable
@MainActor
final class MedicineRecognitionPreferences {
    static let onDeviceOnlyDefaultsKey =
        "com.creaope.slowwalk.medicine-recognition.on-device-only"

    private let defaults: UserDefaults

    var onDeviceOnly: Bool {
        didSet {
            defaults.set(
                onDeviceOnly,
                forKey: Self.onDeviceOnlyDefaultsKey
            )
        }
    }

    var mode: MedicineRecognitionMode {
        onDeviceOnly ? .onDeviceOnly : .remotePreferred
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        onDeviceOnly = defaults.bool(
            forKey: Self.onDeviceOnlyDefaultsKey
        )
    }
}
