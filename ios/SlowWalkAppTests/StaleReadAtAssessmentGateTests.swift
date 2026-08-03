import Testing
@testable import SlowWalkApp

/// Tests that a read still in flight cannot overwrite the assessment gate.
///
/// This is the specific race the gate introduces: confirming a candidate is a
/// decision, and a read that was already running when the decision was made
/// must not land afterwards and drag the session back to a candidate list — or
/// worse, past the gate. The `ControllableReadDelay` seam parks the read on a
/// continuation so the ordering is exact, with no sleeping and no polling.
///
/// Every path here goes through `chooseFromFrequentList`, because that is the
/// only reachable way to be holding a confirmation prompt while a read is still
/// in flight. Reads are otherwise strictly serialized: the read's own result is
/// what moves the session to `awaitingMedicineConfirmation`, so by the time a
/// candidate can be confirmed that read has already finished. Choosing from the
/// list is the one transition that leaves the confirmation step reachable with a
/// read still parked — so it is the one that can produce a stale result landing
/// after the gate is entered.
///
/// The assertions are on `SpyScanSimulator.outcomeCalls`, not just the final
/// state: the reducer independently refuses read results from the gate, so the
/// state alone would look correct even with the generation guard removed.
/// Proving the stale read stopped *before* consulting the simulator is what
/// makes these tests fail if the guard goes away.
@MainActor
struct StaleReadAtAssessmentGateTests {

    // MARK: - 6. A stale read cannot overwrite the waiting-for-assessment state

    /// A read parked before the confirmation must not reach the simulator
    /// after it.
    ///
    /// The sequence is: a read starts and parks; the person gives up on it and
    /// picks from the frequent list instead; they confirm from that list,
    /// entering the gate; only then is the abandoned read released. It must die
    /// at the generation guard.
    @Test func staleReadDoesNotOverwriteTheGate() async {
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
        let staleTask = session.pendingReadTask

        // The read is abandoned in favour of the frequent list...
        session.chooseFromFrequentList()
        // ...and a candidate from that list is confirmed, entering the gate,
        // all while the first read is still parked.
        session.confirmMedicine(MedicineCandidate.demoFrequentlyUsed[0])
        #expect(session.assessmentGate != nil)

        // Now let the abandoned read resume.
        #expect(delay.release())
        if let staleTask { await staleTask.value }

        // It never reached the simulator: the generation guard stopped it
        // before `finishRead`.
        #expect(spy.outcomeCalls.isEmpty)

        // The session is still held at the gate — not dragged back to a
        // candidate list, and certainly not past it.
        #expect(session.assessmentGate != nil)
        #expect(session.canDepart == false)
        #expect(session.state != .travelling)

        // And the stale read added no result record.
        let resultRecords = store.kinds.filter { kind in
            if case .medicineReadFoundCandidates = kind { return true }
            if case .medicineReadDidNotSucceed = kind { return true }
            return false
        }
        #expect(resultRecords.isEmpty)

        // Candidate selection is not canonical identity, so only the session
        // and abandoned read start have been recorded at this point.
        let outingTitle = TodayPlan.demo.outing?.title ?? "今日用药"
        #expect(store.kinds == [
            .dayPlanItemStarted(title: outingTitle),
            .medicineReadStarted(attemptNumber: 1),
        ])

        session.applyAssessmentStateUpdate(
            MedicineAssessmentGateTests.makeResultUpdate(sequenceNumber: 1)
        )
        #expect(store.kinds.suffix(1) == [
            .medicineConfirmed(
                medicineName: MedicineAssessmentGateTests
                    .canonicalCandidate.medicine.canonicalName,
                origin: .chosenFromFrequentList
            ),
        ])
    }

    /// The same guarantee when an earlier read already succeeded.
    ///
    /// Read 1 resolves and offers candidates; retaking starts read 2; read 2 is
    /// abandoned for the frequent list and a candidate confirmed. Read 2 must
    /// not resolve afterwards. Distinct from the test above because a
    /// legitimate read has already been consumed, so a guard that compared
    /// against "any read has finished" rather than the current generation would
    /// pass there and fail here.
    @Test func staleReadDoesNotOverwriteTheGateAfterAnEarlierRead() async {
        let spy = SpyScanSimulator(
            scriptedOutcome: .findsCandidates(MedicineCandidate.demoCandidates)
        )
        let delay = ControllableReadDelay()
        let session = CompanionSessionModel(
            records: RecordingCareRecordStore(),
            simulator: spy,
            plan: .demo,
            readDelay: delay,
            capabilities: .phase0
        )

        #expect(session.startCompanion())
        session.beginMedicineRead() // read 1
        await delay.waitForInstall()
        #expect(delay.release())
        if let task = session.pendingReadTask { await task.value }
        #expect(spy.outcomeCalls == [1])

        session.retakeMedicinePhoto() // read 2 starts
        await delay.waitForInstall()
        let staleTask = session.pendingReadTask

        session.chooseFromFrequentList() // read 2 abandoned
        session.confirmMedicine(MedicineCandidate.demoFrequentlyUsed[0])
        #expect(session.assessmentGate != nil)

        #expect(delay.release())
        if let staleTask { await staleTask.value }

        // Attempt 2 never reached the simulator.
        #expect(spy.outcomeCalls == [1])
        #expect(session.assessmentGate != nil)
        #expect(session.canDepart == false)
    }

    /// Reconsidering after the gate is not undone by the stale read either.
    ///
    /// Covers the other order: the read is released while the session sits at
    /// the candidate list it returned to, so a guard that only refused results
    /// while the state *was* the gate would let this through.
    @Test func staleReadDoesNotOverwriteAfterReconsidering() async {
        let spy = SpyScanSimulator(
            scriptedOutcome: .findsCandidates(MedicineCandidate.demoCandidates)
        )
        let delay = ControllableReadDelay()
        let session = CompanionSessionModel(
            records: RecordingCareRecordStore(),
            simulator: spy,
            plan: .demo,
            readDelay: delay,
            capabilities: .phase0
        )

        #expect(session.startCompanion())
        session.beginMedicineRead()
        await delay.waitForInstall()
        let staleTask = session.pendingReadTask

        session.chooseFromFrequentList()
        session.confirmMedicine(MedicineCandidate.demoFrequentlyUsed[0])
        // Back to the list to pick a different medicine.
        session.reconsiderMedicineChoice()

        #expect(delay.release())
        if let staleTask { await staleTask.value }

        #expect(spy.outcomeCalls.isEmpty)

        // Still on the frequent list the person returned to — the stale read
        // did not replace it with the photo candidates.
        guard case let .awaitingMedicineConfirmation(prompt) = session.state else {
            Issue.record("expected the candidate list, got \(session.state)")
            return
        }
        #expect(prompt.origin == .chosenFromFrequentList)
        #expect(prompt.candidates == MedicineCandidate.demoFrequentlyUsed)
    }

    /// Ending the session from the gate is not undone by a stale read.
    @Test func staleReadDoesNotReopenAnEndedSession() async {
        let spy = SpyScanSimulator(
            scriptedOutcome: .findsCandidates(MedicineCandidate.demoCandidates)
        )
        let delay = ControllableReadDelay()
        let session = CompanionSessionModel(
            records: RecordingCareRecordStore(),
            simulator: spy,
            plan: .demo,
            readDelay: delay,
            capabilities: .phase0
        )

        #expect(session.startCompanion())
        session.beginMedicineRead()
        await delay.waitForInstall()
        let staleTask = session.pendingReadTask

        session.chooseFromFrequentList()
        session.confirmMedicine(MedicineCandidate.demoFrequentlyUsed[0])
        #expect(session.assessmentGate != nil)

        // Ended from the gate, then the abandoned read resumes.
        session.endEarly()
        #expect(delay.release())
        if let staleTask { await staleTask.value }

        #expect(spy.outcomeCalls.isEmpty)
        #expect(session.state == .completed(.endedEarly))
        #expect(session.assessmentGate == nil)
    }

    // MARK: - 7. Candidate confirmation waits for canonical identity

    /// Repeated candidate input writes nothing; the canonical result writes once.
    @Test func repeatedConfirmationWritesOnlyCanonicalResult() async {
        let delay = ControllableReadDelay()
        let store = RecordingCareRecordStore()
        let session = CompanionSessionModel(
            records: store,
            simulator: SpyScanSimulator(
                scriptedOutcome: .findsCandidates(MedicineCandidate.demoCandidates)
            ),
            plan: .demo,
            readDelay: delay,
            capabilities: .phase0
        )

        #expect(session.startCompanion())
        session.beginMedicineRead()
        await delay.waitForInstall()
        #expect(delay.release())
        if let task = session.pendingReadTask { await task.value }

        let candidate = MedicineCandidate.demoCandidates[0]
        session.confirmMedicine(candidate)
        session.confirmMedicine(candidate)
        session.confirmMedicine(candidate)

        let confirmed = store.kinds.filter { kind in
            if case .medicineConfirmed = kind { return true }
            return false
        }
        #expect(confirmed.isEmpty)

        let update = MedicineAssessmentGateTests.makeResultUpdate(
            sequenceNumber: 1
        )
        session.applyAssessmentStateUpdate(update)
        session.applyAssessmentStateUpdate(update)
        let canonicalRecords = store.kinds.filter { kind in
            if case .medicineConfirmed = kind { return true }
            return false
        }
        #expect(canonicalRecords == [
            .medicineConfirmed(
                medicineName: MedicineAssessmentGateTests
                    .canonicalCandidate.medicine.canonicalName,
                origin: .readFromPhoto
            ),
        ])

        // C1: no assessment setback record is fabricated.
        let notAssessed = store.kinds.filter { kind in
            if case .medicineAssessmentDidNotSucceed = kind { return true }
            return false
        }
        #expect(notAssessed.count == 0)
    }

    /// Reconsidered candidates remain noncanonical until the current result.
    @Test func reconsideredCandidateRecordsOnlyCanonicalResult() async {
        let delay = ControllableReadDelay()
        let store = RecordingCareRecordStore()
        let session = CompanionSessionModel(
            records: store,
            simulator: SpyScanSimulator(
                scriptedOutcome: .findsCandidates(MedicineCandidate.demoCandidates)
            ),
            plan: .demo,
            readDelay: delay,
            capabilities: .phase0
        )

        #expect(session.startCompanion())
        session.beginMedicineRead()
        await delay.waitForInstall()
        #expect(delay.release())
        if let task = session.pendingReadTask { await task.value }

        session.confirmMedicine(MedicineCandidate.demoCandidates[0])
        session.reconsiderMedicineChoice()
        session.confirmMedicine(MedicineCandidate.demoCandidates[1])

        #expect(store.kinds.contains { kind in
            if case .medicineConfirmed = kind { return true }
            return false
        } == false)

        session.applyAssessmentStateUpdate(
            MedicineAssessmentGateTests.makeResultUpdate(sequenceNumber: 1)
        )
        let canonicalRecords = store.kinds.filter { kind in
            if case .medicineConfirmed = kind { return true }
            return false
        }
        #expect(canonicalRecords == [
            .medicineConfirmed(
                medicineName: MedicineAssessmentGateTests
                    .canonicalCandidate.medicine.canonicalName,
                origin: .readFromPhoto
            ),
        ])
        // Still no care action, for either confirmation.
        let actionShown = store.kinds.contains { kind in
            if case .careActionShown = kind { return true }
            return false
        }
        #expect(actionShown == false)
    }
}
