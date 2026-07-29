import Foundation
@testable import SlowWalkApp

/// A `CareRecordStoring` double that records events in memory with a fixed
/// time and deterministic UUIDs, so tests can assert event order without a
/// clock or disk.
///
/// It does not reproduce the production store's clock/UUID injection; it only
/// gives the session something stable to append to. Nothing is persisted.
@MainActor
final class RecordingCareRecordStore: CareRecordStoring {
    private(set) var events: [CareRecordEvent] = []

    private let fixedDate: Date
    private var counter = 0

    init(fixedDate: Date = Date(timeIntervalSince1970: 1_753_000_000)) {
        self.fixedDate = fixedDate
    }

    func append(_ kind: CareRecordEventKind) {
        events.append(
            CareRecordEvent(id: nextUUID(), occurredAt: fixedDate, kind: kind)
        )
    }

    /// The kinds appended, in order — the convenience most tests actually want.
    var kinds: [CareRecordEventKind] {
        events.map(\.kind)
    }

    private func nextUUID() -> UUID {
        let n = counter
        counter += 1
        // Deterministic, unique, valid UUID: zero-padded counter in the node
        // field, the rest fixed. Keeps ordering obvious in failure output.
        let suffix = String(format: "%012d", n)
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)") ?? UUID()
    }
}
