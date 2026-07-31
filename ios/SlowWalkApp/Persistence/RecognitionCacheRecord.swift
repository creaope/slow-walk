import Foundation
import SwiftData

@Model
final class RecognitionCacheRecord {
    @Attribute(.unique) var requestID: UUID
    var capturedAt: Date
    var createdAt: Date
    var expiresAt: Date
    var ocrVersion: String
    var isOfflineRecognition: Bool
    @Relationship(deleteRule: .cascade, inverse: \RecognitionCacheObservationRecord.record)
    var observations: [RecognitionCacheObservationRecord]

    init(
        requestID: UUID,
        capturedAt: Date,
        createdAt: Date,
        expiresAt: Date,
        ocrVersion: String,
        isOfflineRecognition: Bool,
        observations: [RecognitionCacheObservationRecord] = []
    ) {
        self.requestID = requestID
        self.capturedAt = capturedAt
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.ocrVersion = ocrVersion
        self.isOfflineRecognition = isOfflineRecognition
        self.observations = observations
    }
}

@Model
final class RecognitionCacheObservationRecord {
    var sortIndex: Int
    var text: String
    var confidence: Double
    var boundingX: Double?
    var boundingY: Double?
    var boundingWidth: Double?
    var boundingHeight: Double?
    var languageCode: String?
    var observedAt: Date
    var record: RecognitionCacheRecord?

    init(
        sortIndex: Int,
        text: String,
        confidence: Double,
        boundingX: Double?,
        boundingY: Double?,
        boundingWidth: Double?,
        boundingHeight: Double?,
        languageCode: String?,
        observedAt: Date,
        record: RecognitionCacheRecord? = nil
    ) {
        self.sortIndex = sortIndex
        self.text = text
        self.confidence = confidence
        self.boundingX = boundingX
        self.boundingY = boundingY
        self.boundingWidth = boundingWidth
        self.boundingHeight = boundingHeight
        self.languageCode = languageCode
        self.observedAt = observedAt
        self.record = record
    }
}
