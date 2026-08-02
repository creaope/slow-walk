import Foundation

/// Records that a medicine care action was displayed.
///
/// The caller owns display eligibility and supplies the request identifier and
/// medicine name. This recorder only deduplicates request identifiers for its
/// own lifetime and appends the supplied medicine name unchanged. Separate
/// recorder instances do not share deduplication state, even when they append
/// to the same store.
@MainActor
final class CareActionShownRecorder {
    private let records: any CareRecordStoring
    private var displayedRequestIDs: Set<UUID> = []

    init(records: any CareRecordStoring) {
        self.records = records
    }

    @discardableResult
    func recordDisplayed(
        requestID: UUID,
        medicineName: String
    ) -> Bool {
        guard displayedRequestIDs.insert(requestID).inserted else {
            return false
        }

        records.append(.careActionShown(medicineName: medicineName))
        return true
    }
}
