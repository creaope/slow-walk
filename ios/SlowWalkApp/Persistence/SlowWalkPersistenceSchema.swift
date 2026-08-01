import Foundation
import SwiftData

/// Versioned persistence schema for the offline OCR cache.
///
/// The container is created without the original image and without any
/// remote API credentials.
enum SlowWalkPersistenceSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            RecognitionCacheRecord.self,
            RecognitionCacheObservationRecord.self,
        ]
    }
}

enum SlowWalkPersistenceSchema {
    static func makeInMemoryContainer() throws -> ModelContainer {
        try makeContainer(
            ModelConfiguration(
                isStoredInMemoryOnly: true,
                allowsSave: true
            )
        )
    }

    static func makeContainer(
        _ configuration: ModelConfiguration = ModelConfiguration()
    ) throws -> ModelContainer {
        try ModelContainer(
            for: Schema(
                versionedSchema: SlowWalkPersistenceSchemaV1.self
            ),
            migrationPlan: nil,
            configurations: [configuration]
        )
    }
}
