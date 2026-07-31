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

    private func observation(_ text: String) -> VisionObservationNormalizer
        .NormalizedObservation
    {
        VisionObservationNormalizer.NormalizedObservation(
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

    @Test func medicineReferenceSchemaStartsEmpty() throws {
        let repository = try makeRepository()
        #expect(try repository.medicineReferenceCount() == 0)
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
            FetchDescriptor<LocalMedicineReference>()
        )
        #expect(count == 0)
    }
}
