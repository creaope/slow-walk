import Foundation
import Testing
@testable import SlowWalkApp

@MainActor
struct CareActionShownRecorderTests {
    @Test func firstRequestWritesEventAndReturnsTrue() {
        let store = RecordingCareRecordStore()
        let recorder = CareActionShownRecorder(records: store)

        let didRecord = recorder.recordDisplayed(
            requestID: Self.requestA,
            medicineName: "Medicine A"
        )

        #expect(didRecord)
        #expect(store.kinds == [
            .careActionShown(medicineName: "Medicine A"),
        ])
    }

    @Test func repeatedRequestReturnsFalseAndWritesOnlyOnce() {
        let store = RecordingCareRecordStore()
        let recorder = CareActionShownRecorder(records: store)

        #expect(
            recorder.recordDisplayed(
                requestID: Self.requestA,
                medicineName: "Medicine A"
            )
        )
        #expect(
            !recorder.recordDisplayed(
                requestID: Self.requestA,
                medicineName: "Medicine A"
            )
        )
        #expect(store.kinds == [
            .careActionShown(medicineName: "Medicine A"),
        ])
    }

    @Test func repeatedRequestWithDifferentNameDoesNotOverwriteFirstEvent() {
        let store = RecordingCareRecordStore()
        let recorder = CareActionShownRecorder(records: store)

        #expect(
            recorder.recordDisplayed(
                requestID: Self.requestA,
                medicineName: "First name"
            )
        )
        #expect(
            !recorder.recordDisplayed(
                requestID: Self.requestA,
                medicineName: "Replacement name"
            )
        )
        #expect(store.kinds == [
            .careActionShown(medicineName: "First name"),
        ])
    }

    @Test func sameNameWithDifferentRequestsWritesTwoEvents() {
        let store = RecordingCareRecordStore()
        let recorder = CareActionShownRecorder(records: store)

        #expect(
            recorder.recordDisplayed(
                requestID: Self.requestA,
                medicineName: "Same medicine"
            )
        )
        #expect(
            recorder.recordDisplayed(
                requestID: Self.requestB,
                medicineName: "Same medicine"
            )
        )
        #expect(store.kinds == [
            .careActionShown(medicineName: "Same medicine"),
            .careActionShown(medicineName: "Same medicine"),
        ])
    }

    @Test func creatingRecorderWithoutCallingItWritesNothing() {
        let store = RecordingCareRecordStore()

        _ = CareActionShownRecorder(records: store)

        #expect(store.kinds.isEmpty)
    }

    @Test func medicineNameIsPassedThroughVerbatim() {
        let store = RecordingCareRecordStore()
        let recorder = CareActionShownRecorder(records: store)
        let unicodeName = "  二甲双胍💊—（缓释片），确认！  "
        let emptyName = ""

        #expect(
            recorder.recordDisplayed(
                requestID: Self.requestA,
                medicineName: unicodeName
            )
        )
        #expect(
            recorder.recordDisplayed(
                requestID: Self.requestB,
                medicineName: emptyName
            )
        )
        #expect(store.kinds == [
            .careActionShown(medicineName: unicodeName),
            .careActionShown(medicineName: emptyName),
        ])
    }

    @Test func threeRequestsPreserveAppendOrder() {
        let store = RecordingCareRecordStore()
        let recorder = CareActionShownRecorder(records: store)

        #expect(
            recorder.recordDisplayed(
                requestID: Self.requestA,
                medicineName: "A"
            )
        )
        #expect(
            recorder.recordDisplayed(
                requestID: Self.requestB,
                medicineName: "B"
            )
        )
        #expect(
            recorder.recordDisplayed(
                requestID: Self.requestC,
                medicineName: "C"
            )
        )
        #expect(store.kinds == [
            .careActionShown(medicineName: "A"),
            .careActionShown(medicineName: "B"),
            .careActionShown(medicineName: "C"),
        ])
    }

    @Test func recorderInstancesHaveIndependentDeduplicationSets() {
        let sharedStore = RecordingCareRecordStore()
        let firstRecorder = CareActionShownRecorder(records: sharedStore)
        let secondRecorder = CareActionShownRecorder(records: sharedStore)

        #expect(
            firstRecorder.recordDisplayed(
                requestID: Self.requestA,
                medicineName: "First recorder"
            )
        )
        #expect(
            secondRecorder.recordDisplayed(
                requestID: Self.requestA,
                medicineName: "Second recorder"
            )
        )
        #expect(
            !firstRecorder.recordDisplayed(
                requestID: Self.requestA,
                medicineName: "First duplicate"
            )
        )
        #expect(
            !secondRecorder.recordDisplayed(
                requestID: Self.requestA,
                medicineName: "Second duplicate"
            )
        )
        #expect(sharedStore.kinds == [
            .careActionShown(medicineName: "First recorder"),
            .careActionShown(medicineName: "Second recorder"),
        ])
    }

    private static let requestA = UUID(
        uuidString: "00000000-0000-0000-0000-00000000000A"
    )!
    private static let requestB = UUID(
        uuidString: "00000000-0000-0000-0000-00000000000B"
    )!
    private static let requestC = UUID(
        uuidString: "00000000-0000-0000-0000-00000000000C"
    )!
}
