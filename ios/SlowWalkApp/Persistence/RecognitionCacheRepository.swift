import Foundation
import SlowWalkClientCore
import SwiftData

struct RecognitionCacheSnapshot: Sendable, Equatable {
    let requestID: UUID
    let capturedAt: Date
    let ocrVersion: String
    let isOfflineRecognition: Bool
    /// Raw platform-neutral observations in the persisted `sortIndex`
    /// order. Trimming, clamping, and canonical ordering are owned solely
    /// by `MedicineRecognitionInputMapper` in SlowWalkCore and are applied
    /// at the assessment boundary, never by this cache.
    let observations: [RecognizedTextObservation]
}

@MainActor
final class RecognitionCacheRepository {
    private let context: ModelContext
    private let configuration: VisionOCRPersistenceConfiguration

    init(
        context: ModelContext,
        configuration: VisionOCRPersistenceConfiguration = .default
    ) {
        self.context = context
        self.configuration = configuration
    }

    /// `capturedAt` records when the image was taken; the expiry clock always
    /// starts from the moment the record is persisted (`now`), so a device
    /// clock change cannot make a freshly saved record look already expired.
    ///
    /// Observations are stored verbatim, in the order supplied by the
    /// caller; `sortIndex` only preserves that persistence order.
    func save(
        requestID: UUID,
        capturedAt: Date,
        observations: [RecognizedTextObservation],
        ocrVersion: String,
        isOfflineRecognition: Bool,
        now: Date = Date()
    ) throws {
        try deleteRecords(requestID: requestID)

        let record = RecognitionCacheRecord(
            requestID: requestID,
            capturedAt: capturedAt,
            createdAt: now,
            expiresAt: now.addingTimeInterval(
                configuration.recordLifetime
            ),
            ocrVersion: ocrVersion,
            isOfflineRecognition: isOfflineRecognition
        )
        record.observations = observations.enumerated().map {
            index, observation in
            RecognitionCacheObservationRecord(
                sortIndex: index,
                text: observation.text,
                confidence: observation.confidence,
                boundingX: observation.boundingRegion?.x,
                boundingY: observation.boundingRegion?.y,
                boundingWidth: observation.boundingRegion?.width,
                boundingHeight: observation.boundingRegion?.height,
                languageCode: observation.languageCode,
                observedAt: observation.observedAt,
                record: record
            )
        }
        context.insert(record)
        try deleteExpiredRecords(now: now)
        try enforceRecordLimit()
        try context.save()
    }

    func fetch(
        requestID: UUID,
        now: Date = Date()
    ) throws -> RecognitionCacheSnapshot? {
        let predicate = #Predicate<RecognitionCacheRecord> {
            $0.requestID == requestID && $0.expiresAt > now
        }
        guard let record = try context.fetch(
            FetchDescriptor(predicate: predicate)
        ).first else {
            return nil
        }
        return snapshot(record)
    }

    func delete(requestID: UUID) throws {
        try deleteRecords(requestID: requestID)
        try context.save()
    }

    func deleteExpired(now: Date = Date()) throws {
        try deleteExpiredRecords(now: now)
        try context.save()
    }

    private func deleteRecords(requestID: UUID) throws {
        let predicate = #Predicate<RecognitionCacheRecord> {
            $0.requestID == requestID
        }
        for record in try context.fetch(
            FetchDescriptor(predicate: predicate)
        ) {
            context.delete(record)
        }
    }

    private func deleteExpiredRecords(now: Date) throws {
        let predicate = #Predicate<RecognitionCacheRecord> {
            $0.expiresAt <= now
        }
        for record in try context.fetch(
            FetchDescriptor(predicate: predicate)
        ) {
            context.delete(record)
        }
    }

    private func enforceRecordLimit() throws {
        let records = try context.fetch(
            FetchDescriptor<RecognitionCacheRecord>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
        )
        for record in records.dropFirst(
            configuration.maximumRecordCount
        ) {
            context.delete(record)
        }
    }

    private func snapshot(
        _ record: RecognitionCacheRecord
    ) -> RecognitionCacheSnapshot {
        let sorted = record.observations.sorted {
            $0.sortIndex < $1.sortIndex
        }
        return RecognitionCacheSnapshot(
            requestID: record.requestID,
            capturedAt: record.capturedAt,
            ocrVersion: record.ocrVersion,
            isOfflineRecognition: record.isOfflineRecognition,
            observations: sorted.map { observation in
                let region: OCRBoundingRegion?
                if let x = observation.boundingX,
                   let y = observation.boundingY,
                   let width = observation.boundingWidth,
                   let height = observation.boundingHeight
                {
                    region = OCRBoundingRegion(
                        x: x,
                        y: y,
                        width: width,
                        height: height
                    )
                } else {
                    region = nil
                }
                return RecognizedTextObservation(
                    text: observation.text,
                    confidence: observation.confidence,
                    boundingRegion: region,
                    languageCode: observation.languageCode,
                    observedAt: observation.observedAt
                )
            }
        )
    }
}
