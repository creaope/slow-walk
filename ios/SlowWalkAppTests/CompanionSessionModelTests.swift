import Testing
import Foundation
@testable import SlowWalkApp

/// Tests for `CompanionSessionModel`.
///
/// The session model is where the stale-read race lives, so these tests use a
/// `ControllableReadDelay` to park each read on a continuation and release it
/// only after the session has moved on. Asserting `pendingReadTask` and
/// `SpyScanSimulator.outcomeCalls` — not just the final state — is what makes
/// the generation guard observable: the reducer can hide a stale result by
/// refusing the transition, but it cannot hide that the simulator was
/// consulted.
@MainActor
struct CompanionSessionModelTests {

    // MARK: - Starting a session

    @Test func startCompanionReturnsTrue() {
        let session = makeSession()
        #expect(session.startCompanion() == true)
        #expect(session.state == .preDepartureCheck)
    }

    @Test func activeStateRejectsRepeatedStart() {
        let session = makeSession()
        #expect(session.startCompanion() == true)
        // preDepartureCheck is active; a second start is refused.
        #expect(session.startCompanion() == false)
    }

    @Test func refusedStartWritesNoDayPlanItemStarted() {
        let store = RecordingCareRecordStore()
        let session = CompanionSessionModel(
            records: store,
            simulator: SpyScanSimulator(),
            plan: .demo,
            readDelay: ControllableReadDelay(),
            capabilities: .phase0
        )

        session.startCompanion()
        session.startCompanion() // refused

        let startedCount = store.kinds.filter { kind in
            if case .dayPlanItemStarted = kind { return true }
            return false
        }.count
        #expect(startedCount == 1)
    }

    // MARK: - A normal read resolves once

    @Test func normalReadConsultsSimulatorOnce() async {
        let spy = SpyScanSimulator(
            scriptedOutcome: .doesNotSucceed(.textNotLegible)
        )
        let delay = ControllableReadDelay()
        let session = CompanionSessionModel(
            records: RecordingCareRecordStore(),
            simulator: spy,
            plan: .demo,
            readDelay: delay,
            capabilities: .phase0
        )

        session.startCompanion()
        session.beginMedicineRead()
        await delay.waitForInstall()
        delay.release()
        if let task = session.pendingReadTask { await task.value }

        #expect(spy.outcomeCalls == [1])
    }

    @Test func normalFailingReadWritesDidNotSucceed() async {
        let spy = SpyScanSimulator(
            scriptedOutcome: .doesNotSucceed(.textNotLegible)
        )
        let delay = ControllableReadDelay()
        let store = RecordingCareRecordStore()
        let session = CompanionSessionModel(
            records: store, simulator: spy, plan: .demo, readDelay: delay,
            capabilities: .phase0
        )

        session.startCompanion()
        session.beginMedicineRead()
        await delay.waitForInstall()
        delay.release()
        if let task = session.pendingReadTask { await task.value }

        let failed = store.kinds.contains { kind in
            if case .medicineReadDidNotSucceed(.textNotLegible) = kind { return true }
            return false
        }
        #expect(failed)
    }

    // MARK: - Stale reads never reach the simulator

    @Test func endEarlyAbortsStaleReadBeforeSimulator() async {
        let spy = SpyScanSimulator(
            scriptedOutcome: .doesNotSucceed(.textNotLegible)
        )
        let delay = ControllableReadDelay()
        let store = RecordingCareRecordStore()
        let session = CompanionSessionModel(
            records: store, simulator: spy, plan: .demo, readDelay: delay,
            capabilities: .phase0
        )

        session.startCompanion()
        session.beginMedicineRead()
        await delay.waitForInstall()

        // Capture the exact task whose staleness we are probing.
        let staleTask = session.pendingReadTask
        // The session moves on while the read is still parked...
        session.endEarly()
        // ...then the read is allowed to resume.
        delay.release()
        if let staleTask { await staleTask.value }

        // The simulator was never consulted — the stale read stopped at the
        // generation guard, before finishRead.
        #expect(spy.outcomeCalls.isEmpty)

        // And no read-result record landed. medicineReadStarted was written by
        // the legitimate start (synchronously, before the task); the stale
        // resolution must add nothing.
        let readResults = store.kinds.filter { kind in
            if case .medicineReadDidNotSucceed = kind { return true }
            if case .medicineReadFoundCandidates = kind { return true }
            return false
        }
        #expect(readResults.isEmpty)
    }

    @Test func chooseFromFrequentListAbortsStaleReadBeforeSimulator() async {
        let spy = SpyScanSimulator(
            scriptedOutcome: .doesNotSucceed(.textNotLegible)
        )
        let delay = ControllableReadDelay()
        let store = RecordingCareRecordStore()
        let session = CompanionSessionModel(
            records: store, simulator: spy, plan: .demo, readDelay: delay,
            capabilities: .phase0
        )

        session.startCompanion()
        session.beginMedicineRead()
        await delay.waitForInstall()

        let staleTask = session.pendingReadTask
        session.chooseFromFrequentList()
        delay.release()
        if let staleTask { await staleTask.value }

        #expect(spy.outcomeCalls.isEmpty)
    }

    @Test func staleReadWritesNoCareRecords() async {
        let spy = SpyScanSimulator(
            scriptedOutcome: .doesNotSucceed(.textNotLegible)
        )
        let delay = ControllableReadDelay()
        let store = RecordingCareRecordStore()
        let session = CompanionSessionModel(
            records: store, simulator: spy, plan: .demo, readDelay: delay,
            capabilities: .phase0
        )

        session.startCompanion()
        session.beginMedicineRead()
        await delay.waitForInstall()

        let staleTask = session.pendingReadTask
        session.endEarly()
        delay.release()
        if let staleTask { await staleTask.value }

        // The record set alone cannot prove the generation guard: from
        // `.completed` the reducer independently refuses every read result, so
        // the timeline stays clean even with the guard removed. Asserting the
        // simulator was never consulted is what makes this test fail if the
        // guard goes away — the stale read must stop *before* finishRead.
        #expect(spy.outcomeCalls.isEmpty)

        // Exactly the legitimate records: the day-plan start, the read start,
        // and the early finish. Nothing from the stale read's resolution.
        let outingTitle = TodayPlan.demo.outing?.title ?? "今日用药"
        #expect(store.kinds == [
            .dayPlanItemStarted(title: outingTitle),
            .medicineReadStarted(attemptNumber: 1),
            .companionFinished(.endedEarly),
        ])
    }

    // MARK: - Repeated events do not double-write

    @Test func repeatedCandidateConfirmationWaitsForCanonicalResult() async {
        let spy = SpyScanSimulator(
            scriptedOutcome: .findsCandidates(MedicineCandidate.demoCandidates)
        )
        let delay = ControllableReadDelay()
        let store = RecordingCareRecordStore()
        let session = CompanionSessionModel(
            records: store, simulator: spy, plan: .demo, readDelay: delay,
            capabilities: .phase0
        )

        session.startCompanion()
        session.beginMedicineRead()
        await delay.waitForInstall()
        delay.release()
        if let task = session.pendingReadTask { await task.value }

        let candidate = MedicineCandidate.demoCandidates[0]
        session.confirmMedicine(candidate)
        session.confirmMedicine(candidate) // repeated, refused

        let confirmedCount = store.kinds.filter { kind in
            if case .medicineConfirmed = kind { return true }
            return false
        }.count

        #expect(confirmedCount == 0)

        let update = MedicineAssessmentGateTests.makeResultUpdate(
            sequenceNumber: 1
        )
        session.applyAssessmentStateUpdate(update)
        session.applyAssessmentStateUpdate(update)
        let confirmed = store.kinds.filter { kind in
            if case .medicineConfirmed = kind { return true }
            return false
        }
        #expect(confirmed == [
            .medicineConfirmed(
                medicineName: MedicineAssessmentGateTests
                    .canonicalCandidate.medicine.canonicalName,
                origin: .readFromPhoto
            ),
        ])

        // No care-action record is written at all: confirming a name is not an
        // assessment, so nothing may claim a care action was shown.
        let actionCount = store.kinds.filter { kind in
            if case .careActionShown = kind { return true }
            return false
        }.count
        #expect(actionCount == 0)

        // C1: no assessment setback record is fabricated.
        let notAssessedCount = store.kinds.filter { kind in
            if case .medicineAssessmentDidNotSucceed = kind { return true }
            return false
        }.count
        #expect(notAssessedCount == 0)
    }

    // MARK: - retry / retake start a fresh read

    /// `retryMedicineRead` requires `awaitingRecovery`, so reads are strictly
    /// serialized and the second read cannot start while the first is parked.
    /// This tests the reachable contract (a fresh read with the next attempt
    /// number), not a stale in-flight read. It does not cover the generation
    /// guard, which is exercised by the endEarly / chooseFromFrequentList
    /// tests above.
    @Test func retryMedicineReadStartsFreshReadWithNextAttempt() async {
        let spy = SpyScanSimulator(
            scriptedOutcome: .doesNotSucceed(.textNotLegible)
        )
        let delay = ControllableReadDelay()
        let store = RecordingCareRecordStore()
        let session = CompanionSessionModel(
            records: store, simulator: spy, plan: .demo, readDelay: delay,
            capabilities: .phase0
        )

        #expect(session.startCompanion())
        session.beginMedicineRead() // attempt 1
        await delay.waitForInstall()
        #expect(delay.release())
        guard let firstTask = session.pendingReadTask else {
            Issue.record("first read task was not started")
            return
        }
        await firstTask.value

        // Read 1 failed -> awaitingRecovery, so retry is now valid.
        session.retryMedicineRead() // attempt 2
        await delay.waitForInstall()
        #expect(delay.release())
        guard let secondTask = session.pendingReadTask else {
            Issue.record("second read task was not started")
            return
        }
        await secondTask.value

        // The simulator was consulted once per read, with the attempt numbers
        // in order.
        #expect(spy.outcomeCalls == [1, 2])

        // Each read started and failed exactly once — no duplicated records,
        // and nothing stale landing after the second read began.
        let outingTitle = TodayPlan.demo.outing?.title ?? "今日用药"
        #expect(store.kinds == [
            .dayPlanItemStarted(title: outingTitle),
            .medicineReadStarted(attemptNumber: 1),
            .medicineReadDidNotSucceed(.textNotLegible),
            .medicineReadStarted(attemptNumber: 2),
            .medicineReadDidNotSucceed(.textNotLegible),
        ])
    }

    /// `retakeMedicinePhoto` requires `awaitingMedicineConfirmation`, so reads
    /// are strictly serialized and it cannot supersede an in-flight read. As
    /// with retry, this tests the reachable contract, not the generation guard
    /// (covered by the endEarly / chooseFromFrequentList tests above).
    @Test func retakeMedicinePhotoStartsFreshReadWithNextAttempt() async {
        let spy = SpyScanSimulator(
            scriptedOutcome: .findsCandidates(MedicineCandidate.demoCandidates)
        )
        let delay = ControllableReadDelay()
        let store = RecordingCareRecordStore()
        let session = CompanionSessionModel(
            records: store, simulator: spy, plan: .demo, readDelay: delay,
            capabilities: .phase0
        )

        #expect(session.startCompanion())
        session.beginMedicineRead() // attempt 1
        await delay.waitForInstall()
        #expect(delay.release())
        guard let firstTask = session.pendingReadTask else {
            Issue.record("first read task was not started")
            return
        }
        await firstTask.value

        // Read 1 found candidates -> awaitingConfirmation, so retake is valid.
        session.retakeMedicinePhoto() // attempt 2
        await delay.waitForInstall()
        #expect(delay.release())
        guard let secondTask = session.pendingReadTask else {
            Issue.record("second read task was not started")
            return
        }
        await secondTask.value

        #expect(spy.outcomeCalls == [1, 2])

        let outingTitle = TodayPlan.demo.outing?.title ?? "今日用药"
        #expect(store.kinds == [
            .dayPlanItemStarted(title: outingTitle),
            .medicineReadStarted(attemptNumber: 1),
            .medicineReadFoundCandidates(candidateCount: MedicineCandidate.demoCandidates.count),
            .medicineReadStarted(attemptNumber: 2),
            .medicineReadFoundCandidates(candidateCount: MedicineCandidate.demoCandidates.count),
        ])
    }

    // MARK: - Confirming a medicine that was never offered

    /// A confirmation is only meaningful for a candidate the person was
    /// actually shown. The reducer refuses an unoffered candidate, and the
    /// records must refuse it too: a `medicineConfirmed` event for a medicine
    /// that was never on screen would put a false medicine in the care
    /// timeline, which is the one thing this record must never do.
    @Test func confirmingUnofferedCandidateWritesNoRecords() async {
        let spy = SpyScanSimulator(
            scriptedOutcome: .findsCandidates(MedicineCandidate.demoCandidates)
        )
        let delay = ControllableReadDelay()
        let store = RecordingCareRecordStore()
        let session = CompanionSessionModel(
            records: store, simulator: spy, plan: .demo, readDelay: delay,
            capabilities: .phase0
        )

        #expect(session.startCompanion())
        session.beginMedicineRead()
        await delay.waitForInstall()
        #expect(delay.release())
        if let task = session.pendingReadTask { await task.value }

        // The read offered demoCandidates; this one was never among them.
        let unoffered = MedicineCandidate(
            id: "not-offered",
            displayName: "未曾出现的药",
            recognitionHint: "不在候选中"
        )
        session.confirmMedicine(unoffered)

        // The state did not move on...
        guard case .awaitingMedicineConfirmation = session.state else {
            Issue.record("expected to stay awaiting confirmation, got \(session.state)")
            return
        }

        // ...and nothing was recorded for it.
        let confirmed = store.kinds.contains { kind in
            if case .medicineConfirmed = kind { return true }
            if case .careActionShown = kind { return true }
            return false
        }
        #expect(confirmed == false)
    }

    // MARK: - Helpers

    private func makeSession() -> CompanionSessionModel {
        CompanionSessionModel(
            records: RecordingCareRecordStore(),
            simulator: SpyScanSimulator(),
            plan: .demo,
            readDelay: ControllableReadDelay(),
            capabilities: .phase0
        )
    }
}
