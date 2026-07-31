import Foundation

/// Cache policy for OCR persistence.
///
/// No medical meaning, dose, frequency, or safety conclusion belongs here.
struct VisionOCRPersistenceConfiguration: Sendable, Equatable {
    var maximumRecordCount: Int
    var recordLifetime: TimeInterval

    init(maximumRecordCount: Int, recordLifetime: TimeInterval) {
        // A non-positive capacity or lifetime would silently drop every record.
        self.maximumRecordCount = max(maximumRecordCount, 1)
        self.recordLifetime = max(recordLifetime, 1)
    }

    static let `default` = Self(
        maximumRecordCount: 100,
        recordLifetime: 60 * 60 * 24 * 30
    )
}
