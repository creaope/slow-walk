import Testing
import Foundation
import SlowWalkDomain
@testable import SlowWalkApp

/// Tests for the production `InMemoryCareRecordStore`.
///
/// These prove the store keeps append order, stamps every event with the
/// injected time and UUID, records each event kind correctly, and that a
/// recorded event never carries a risk level, dose, or clinical conclusion.
@MainActor
struct CareRecordStoreTests {

    // MARK: - Order and injection

    @Test func appendPreservesOrder() {
        let store = InMemoryCareRecordStore(
            clock: AppFixedClock(fixedDate: Date(timeIntervalSince1970: 1_000))
        )

        store.append(.dayPlanItemStarted(title: "A"))
        store.append(.medicineReadStarted(attemptNumber: 1))
        store.append(.companionFinished(.arrivedSafely))

        let kinds = store.events.map(\.kind)
        #expect(kinds == [
            .dayPlanItemStarted(title: "A"),
            .medicineReadStarted(attemptNumber: 1),
            .companionFinished(.arrivedSafely),
        ])
    }

    @Test func timeAndUUIDAreInjectable() {
        let fixed = Date(timeIntervalSince1970: 1_753_000_000)
        var counter = 0
        let makeID: () -> UUID = {
            let n = counter
            counter += 1
            let suffix = String(format: "%012d", n)
            return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
        }

        let store = InMemoryCareRecordStore(clock: AppFixedClock(fixedDate: fixed), makeID: makeID)

        store.append(.dayPlanItemStarted(title: "A"))
        store.append(.medicineReadStarted(attemptNumber: 1))

        // Every event shares the injected time...
        #expect(store.events.allSatisfy { $0.occurredAt == fixed })
        // ...and the injected UUIDs are unique and in order.
        let ids = store.events.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids[0].uuidString < ids[1].uuidString)
    }

    // MARK: - Each event kind records correctly, without clinical payload

    @Test func startedRecordCarriesOnlyAttemptNumber() {
        let store = InMemoryCareRecordStore(clock: AppFixedClock(fixedDate: .init(timeIntervalSince1970: 1)))
        store.append(.medicineReadStarted(attemptNumber: 2))

        guard case let .medicineReadStarted(attemptNumber)? = store.events.first?.kind
        else {
            Issue.record("expected medicineReadStarted")
            return
        }
        #expect(attemptNumber == 2)
    }

    @Test func failedRecordCarriesSetbackNotConclusion() {
        let store = InMemoryCareRecordStore(clock: AppFixedClock(fixedDate: .init(timeIntervalSince1970: 1)))
        store.append(.medicineReadDidNotSucceed(.textNotLegible))

        // A setback describes what happened, never a medicine conclusion,
        // dose, or risk level — the enum carries only the setback reason.
        guard case let .medicineReadDidNotSucceed(setback)? = store.events.first?.kind
        else {
            Issue.record("expected medicineReadDidNotSucceed")
            return
        }
        #expect(setback == .textNotLegible)
    }

    @Test func candidateRecordCarriesCountNotIdentity() {
        let store = InMemoryCareRecordStore(clock: AppFixedClock(fixedDate: .init(timeIntervalSince1970: 1)))
        store.append(.medicineReadFoundCandidates(candidateCount: 3))

        // Only the count is recorded — never which medicine it is.
        guard case let .medicineReadFoundCandidates(count)? = store.events.first?.kind
        else {
            Issue.record("expected medicineReadFoundCandidates")
            return
        }
        #expect(count == 3)
    }

    @Test func confirmedRecordCarriesNameAndOriginNotDose() {
        let store = InMemoryCareRecordStore(clock: AppFixedClock(fixedDate: .init(timeIntervalSince1970: 1)))
        store.append(.medicineConfirmed(medicineName: "二甲双胍片", origin: .readFromPhoto))

        guard case let .medicineConfirmed(name, origin)? = store.events.first?.kind
        else {
            Issue.record("expected medicineConfirmed")
            return
        }
        #expect(name == "二甲双胍片")
        #expect(origin == .readFromPhoto)
    }

    @Test func actionRecordCarriesNameOnly() {
        let store = InMemoryCareRecordStore(clock: AppFixedClock(fixedDate: .init(timeIntervalSince1970: 1)))
        store.append(.careActionShown(medicineName: "格列美脲片"))

        guard case let .careActionShown(name)? = store.events.first?.kind
        else {
            Issue.record("expected careActionShown")
            return
        }
        #expect(name == "格列美脲片")
    }

    @Test func finishedRecordCarriesCompletion() {
        let store = InMemoryCareRecordStore(clock: AppFixedClock(fixedDate: .init(timeIntervalSince1970: 1)))
        store.append(.companionFinished(.arrivedSafely))

        guard case let .companionFinished(completion)? = store.events.first?.kind
        else {
            Issue.record("expected companionFinished")
            return
        }
        #expect(completion == .arrivedSafely)
    }
}
