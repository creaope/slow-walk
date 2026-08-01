import Foundation
import SlowWalkClientCore
import SwiftData
import Testing

@testable import SlowWalkApp

@Suite("SwiftData OCR cache")
@MainActor
struct RecognitionCacheRepositoryTests {
    private func makeRepository(
        lifetime: TimeInterval = 100
    ) throws -> RecognitionCacheRepository {
        RecognitionCacheRepository(
            context: ModelContext(
                try SlowWalkPersistenceSchema.makeInMemoryContainer()
            ),
            configuration: VisionOCRPersistenceConfiguration(
                maximumRecordCount: 2,
                recordLifetime: lifetime
            )
        )
    }

    private func observation(_ text: String) -> RecognizedTextObservation {
        RecognizedTextObservation(
            text: text,
            confidence: 0.5,
            boundingRegion: OCRBoundingRegion(
                x: 0,
                y: 0,
                width: 1,
                height: 1
            ),
            languageCode: nil,
            observedAt: Date(timeIntervalSince1970: 10)
        )
    }

    @Test func createReadUpdateDeleteUsesRequestID() throws {
        let repository = try makeRepository()
        let requestID = UUID()
        let base = Date()

        try repository.save(
            requestID: requestID,
            capturedAt: base,
            observations: [observation("first")],
            ocrVersion: "vision-1",
            isOfflineRecognition: true,
            now: base
        )
        #expect(
            try repository.fetch(requestID: requestID, now: base)?
                .observations.map(\.text) == ["first"]
        )

        let replacementTime = base.addingTimeInterval(10)
        try repository.save(
            requestID: requestID,
            capturedAt: base,
            observations: [observation("replacement")],
            ocrVersion: "vision-1",
            isOfflineRecognition: true,
            now: replacementTime
        )
        let snapshot = try repository.fetch(
            requestID: requestID,
            now: replacementTime
        )
        #expect(snapshot?.observations.map(\.text) == ["replacement"])
        #expect(snapshot?.isOfflineRecognition == true)

        try repository.delete(requestID: requestID)
        #expect(
            try repository.fetch(requestID: requestID, now: replacementTime)
                == nil
        )
    }

    @Test func expiredRecordsAreRemoved() throws {
        let repository = try makeRepository()
        let oldID = UUID()
        let currentID = UUID()
        let oldTime = Date()
        let currentTime = oldTime.addingTimeInterval(1_000)

        try repository.save(
            requestID: oldID,
            capturedAt: oldTime,
            observations: [observation("old")],
            ocrVersion: "vision-1",
            isOfflineRecognition: true,
            now: oldTime
        )
        try repository.save(
            requestID: currentID,
            capturedAt: currentTime,
            observations: [observation("current")],
            ocrVersion: "vision-1",
            isOfflineRecognition: true,
            now: currentTime
        )

        #expect(
            try repository.fetch(requestID: oldID, now: currentTime) == nil
        )
        #expect(
            try repository.fetch(requestID: currentID, now: currentTime)?
                .observations.map(\.text) == ["current"]
        )
    }

    @Test func fetchDoesNotReturnExpiredRecord() throws {
        let repository = try makeRepository()
        let requestID = UUID()
        let createdAt = Date()

        try repository.save(
            requestID: requestID,
            capturedAt: createdAt,
            observations: [observation("stale")],
            ocrVersion: "vision-1",
            isOfflineRecognition: true,
            now: createdAt
        )

        let afterExpiry = createdAt.addingTimeInterval(200)
        #expect(
            try repository.fetch(requestID: requestID, now: afterExpiry)
                == nil
        )
        #expect(
            try repository.fetch(requestID: requestID, now: createdAt)?
                .observations.map(\.text) == ["stale"]
        )
    }

    @Test func recordLimitEvictsOldestRecords() throws {
        let repository = try makeRepository()
        let base = Date()
        let ids = (0 ..< 3).map { _ in UUID() }

        for (index, requestID) in ids.enumerated() {
            try repository.save(
                requestID: requestID,
                capturedAt: base,
                observations: [observation("record-\(index)")],
                ocrVersion: "vision-1",
                isOfflineRecognition: true,
                now: base.addingTimeInterval(TimeInterval(index * 10))
            )
        }

        let now = base.addingTimeInterval(30)
        #expect(try repository.fetch(requestID: ids[0], now: now) == nil)
        #expect(
            try repository.fetch(requestID: ids[1], now: now) != nil
        )
        #expect(
            try repository.fetch(requestID: ids[2], now: now) != nil
        )
    }

    @Test func explicitDeleteExpiredRemovesOnlyExpiredRecords() throws {
        let repository = try makeRepository()
        let expiredTime = Date()
        // Fresh record is created later so it outlives the first one.
        let freshTime = expiredTime.addingTimeInterval(80)
        let expiredID = UUID()
        let freshID = UUID()

        try repository.save(
            requestID: expiredID,
            capturedAt: expiredTime,
            observations: [observation("expired")],
            ocrVersion: "vision-1",
            isOfflineRecognition: true,
            now: expiredTime
        )
        try repository.save(
            requestID: freshID,
            capturedAt: freshTime,
            observations: [observation("fresh")],
            ocrVersion: "vision-1",
            isOfflineRecognition: true,
            now: freshTime
        )

        // expired: expiresAt = expiredTime + 100 -> gone.
        // fresh:   expiresAt = freshTime + 100   -> still alive at this now.
        let now = expiredTime.addingTimeInterval(150)
        try repository.deleteExpired(now: now)

        #expect(try repository.fetch(requestID: expiredID, now: now) == nil)
        #expect(try repository.fetch(requestID: freshID, now: now) != nil)
    }

    /// The cache stores observations verbatim: no trimming, no clamping,
    /// no filtering, no reordering. Canonical normalization is owned solely
    /// by `MedicineRecognitionInputMapper` in SlowWalkCore.
    @Test func roundTripPreservesObservationsVerbatim() throws {
        let repository = try makeRepository()
        let requestID = UUID()
        let base = Date()
        let observations = [
            // Deliberately unsorted (bottom row first) and unnormalized.
            RecognizedTextObservation(
                text: "  bottom row  ",
                confidence: 1.7,
                boundingRegion: OCRBoundingRegion(
                    x: 0.7,
                    y: 0.9,
                    width: 0.2,
                    height: 0.1
                ),
                languageCode: " zh-Hans ",
                observedAt: Date(timeIntervalSince1970: 20)
            ),
            RecognizedTextObservation(
                text: " ",
                confidence: -0.4,
                boundingRegion: nil,
                languageCode: nil,
                observedAt: Date(timeIntervalSince1970: 10)
            ),
            RecognizedTextObservation(
                text: "top row",
                confidence: 0.3,
                boundingRegion: OCRBoundingRegion(
                    x: 0.1,
                    y: 0.1,
                    width: 0.2,
                    height: 0.1
                ),
                languageCode: "en",
                observedAt: Date(timeIntervalSince1970: 30)
            ),
        ]

        try repository.save(
            requestID: requestID,
            capturedAt: base,
            observations: observations,
            ocrVersion: "vision-1",
            isOfflineRecognition: true,
            now: base
        )

        let snapshot = try repository.fetch(requestID: requestID, now: base)
        #expect(snapshot?.observations == observations)
        #expect(snapshot?.capturedAt == base)
        #expect(snapshot?.ocrVersion == "vision-1")
        #expect(snapshot?.isOfflineRecognition == true)
    }

    /// SQLite stores NaN as NULL, so a NaN confidence does not round-trip
    /// verbatim and reads back finite. This is behaviorally safe: Core's
    /// canonical mapper maps every non-finite confidence to 0, so the
    /// assessment-boundary result is identical with or without the cache.
    @Test func nanConfidenceKeepsCoreMapperResult() throws {
        let repository = try makeRepository()
        let requestID = UUID()
        let capturedAt = Date(timeIntervalSince1970: 500)
        let observations = [
            RecognizedTextObservation(
                text: "nan",
                confidence: .nan,
                boundingRegion: nil,
                languageCode: nil,
                observedAt: Date(timeIntervalSince1970: 10)
            ),
        ]
        let mapper = MedicineRecognitionInputMapper(
            configuration: try MedicineRecognitionMappingConfiguration(
                minimumConfidence: 0.3,
                lowConfidenceHandling: .retainAsEvidence
            )
        )
        let direct = mapper.map(
            observations: observations,
            capturedAt: capturedAt
        )

        try repository.save(
            requestID: requestID,
            capturedAt: capturedAt,
            observations: observations,
            ocrVersion: "vision-1",
            isOfflineRecognition: true,
            now: capturedAt
        )
        let snapshot = try repository.fetch(
            requestID: requestID,
            now: capturedAt
        )

        #expect(
            snapshot?.observations.first?.confidence.isFinite == true
        )
        let roundTripped = mapper.map(
            observations: try #require(snapshot?.observations),
            capturedAt: try #require(snapshot?.capturedAt)
        )
        #expect(roundTripped == direct)
    }

    /// Contract test: feeding Core's canonical mapper with observations
    /// after a cache round-trip must produce exactly the same
    /// `MedicineRecognitionInput` as feeding it the originals. Together
    /// with `roundTripPreservesObservationsVerbatim` this proves the app
    /// keeps no second copy of the canonical normalization rules.
    @Test func cacheRoundTripPreservesCoreMapperResult() throws {
        let repository = try makeRepository()
        let requestID = UUID()
        let capturedAt = Date(timeIntervalSince1970: 500)
        let observations = [
            RecognizedTextObservation(
                text: "  Second row  ",
                confidence: 0.6,
                boundingRegion: OCRBoundingRegion(
                    x: 0.1,
                    y: 0.5,
                    width: 0.2,
                    height: 0.1
                ),
                languageCode: " zh-Hans ",
                observedAt: Date(timeIntervalSince1970: 100)
            ),
            RecognizedTextObservation(
                text: " \n ",
                confidence: 2,
                boundingRegion: nil,
                languageCode: " ",
                observedAt: Date(timeIntervalSince1970: 100)
            ),
            RecognizedTextObservation(
                text: "First row right",
                confidence: -1,
                boundingRegion: OCRBoundingRegion(
                    x: 0.7,
                    y: 0.1,
                    width: 0.2,
                    height: 0.1
                ),
                languageCode: "zh-Hans",
                observedAt: Date(timeIntervalSince1970: 100)
            ),
            RecognizedTextObservation(
                text: "First row left",
                confidence: 0.8,
                boundingRegion: OCRBoundingRegion(
                    x: 0.1,
                    y: 0.1,
                    width: 0.2,
                    height: 0.1
                ),
                languageCode: "zh-Hans",
                observedAt: Date(timeIntervalSince1970: 100)
            ),
        ]
        let mapper = MedicineRecognitionInputMapper(
            configuration: try MedicineRecognitionMappingConfiguration(
                minimumConfidence: 0.3,
                lowConfidenceHandling: .retainAsEvidence
            )
        )
        let direct = mapper.map(
            observations: observations,
            capturedAt: capturedAt
        )

        try repository.save(
            requestID: requestID,
            capturedAt: capturedAt,
            observations: observations,
            ocrVersion: "vision-1",
            isOfflineRecognition: true,
            now: capturedAt
        )
        let snapshot = try repository.fetch(
            requestID: requestID,
            now: capturedAt
        )
        let roundTripped = mapper.map(
            observations: try #require(snapshot?.observations),
            capturedAt: try #require(snapshot?.capturedAt)
        )

        #expect(roundTripped == direct)
        #expect(roundTripped.recognizedTexts == [
            "First row left",
            "First row right",
            "Second row",
        ])
    }

    /// The persisted schema must not contain any field capable of holding
    /// the original image bytes.
    @Test func persistenceSchemaHasNoImageDataField() throws {
        let container = try SlowWalkPersistenceSchema
            .makeInMemoryContainer()
        let entities = container.schema.entities
        #expect(entities.map(\.name).sorted() == [
            "RecognitionCacheObservationRecord",
            "RecognitionCacheRecord",
        ])
        for entity in entities {
            for property in entity.properties {
                let holdsData =
                    property.valueType == Data.self
                    || property.valueType == Data?.self
                #expect(!holdsData)
                #expect(
                    !property.name.lowercased().contains("image")
                )
            }
        }
    }

    @Test func onDiskContainerIsCreatable() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("store")
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try SlowWalkPersistenceSchema.makeContainer(
            ModelConfiguration(url: url)
        )
        let context = ModelContext(container)
        let count = try context.fetchCount(
            FetchDescriptor<RecognitionCacheRecord>()
        )
        #expect(count == 0)
    }
}
