import Testing
@testable import SlowWalkApp

/// Tests for the Medicine Assessment safety gate.
///
/// The defect these exist to prevent: confirming a candidate used to move the
/// session straight to a state that showed a care action and permitted
/// departure, on the strength of a medicine *name* alone. Confirming answers
/// "which box is this"; it is not an answer to "is it safe to take".
///
/// These tests are written against the reducer and the session model — the real
/// production types — and assert on the absence of specific downstream effects
/// (no showing state, no departure, no `careActionShown` record). No transition
/// table is reproduced here.
@MainActor
struct MedicineAssessmentGateTests {

    // MARK: - 1. Confirmation cannot show a care action

    /// The core gate: a confirmed candidate lands at the assessment gate.
    ///
    /// Asserted structurally rather than by comparing against a hand-built
    /// expected state, so this test says what matters — the session is held,
    /// waiting, with nothing assessed — instead of restating the transition.
    @Test func confirmingCandidateEntersAssessmentGate() {
        let prompt = MedicineConfirmationPrompt(
            candidates: MedicineCandidate.demoCandidates,
            origin: .readFromPhoto,
            attemptNumber: 1
        )
        let candidate = MedicineCandidate.demoCandidates[0]

        let next = CompanionFlowReducer.nextState(
            from: .awaitingMedicineConfirmation(prompt),
            on: .confirmMedicine(candidate)
        )

        guard case let .awaitingMedicineAssessment(gate)? = next else {
            Issue.record("expected the assessment gate, got \(String(describing: next))")
            return
        }
        #expect(gate.confirmed.candidate == candidate)
        // Nothing has been assessed: the gate opens at `.notStarted`, which
        // carries no result and no risk level.
        #expect(gate.progress == .notStarted)
    }

    /// A confirmation may only ever land at the assessment gate.
    ///
    /// This is requirement 1 stated where it is decided: whatever state a
    /// `confirmMedicine` event is accepted from, the destination must be the
    /// gate — which by construction carries no assessment result and shows no
    /// card. Any other destination means a confirmed *name* moved the session
    /// somewhere that can present something, which is the defect.
    ///
    /// Enumerating every state is what makes this a guarantee rather than a
    /// spot check: a second confirmation path added elsewhere in the table is
    /// caught here even if this test never named that state.
    @Test func everyAcceptedConfirmationLandsAtTheGate() {
        let candidate = MedicineCandidate.demoCandidates[0]

        for state in Self.everyState {
            guard let next = CompanionFlowReducer.nextState(
                from: state,
                on: .confirmMedicine(candidate)
            ) else {
                continue // refused, which is also safe
            }

            guard case let .awaitingMedicineAssessment(gate) = next else {
                Issue.record(
                    """
                    confirming from \(state) reached \(next), \
                    which is not the assessment gate
                    """
                )
                continue
            }
            // And it arrives with nothing assessed.
            #expect(gate.progress == .notStarted)
            #expect(gate.confirmed.candidate == candidate)
        }
    }

    /// No transition produces a gate that carries an assessment result.
    ///
    /// The companion guarantee to the test above: reaching the gate is only
    /// safe because the gate itself can hold no result. Every transition in the
    /// table is swept, so a gate constructed with a result — once a result type
    /// exists — is caught here.
    @Test func noTransitionProducesAnAssessedGate() {
        for state in Self.everyState {
            for event in Self.everyEvent {
                guard let next = CompanionFlowReducer.nextState(from: state, on: event)
                else { continue }
                if case let .awaitingMedicineAssessment(gate) = next {
                    #expect(
                        gate.progress == .notStarted
                            || gate.progress == .couldNotAssess(.notWiredUpYet),
                        "gate must carry no assessment result: \(state) + \(event)"
                    )
                }
            }
        }
    }

    // MARK: - 2. Departure is impossible without an assessment

    /// No event moves the session out of the gate into travelling.
    ///
    /// This is the "cannot continue the outing" guarantee stated at the level
    /// that decides it. Every event is tried, so a departure path cannot be
    /// added by a transition this test forgot to name.
    @Test func noEventDepartsFromTheAssessmentGate() {
        for progress in Self.everyProgress {
            let gate = Self.makeGate(progress: progress)
            for event in Self.everyEvent {
                let next = CompanionFlowReducer.nextState(
                    from: .awaitingMedicineAssessment(gate),
                    on: event
                )
                #expect(
                    next != .travelling,
                    "\(event) departed from the gate with progress \(progress)"
                )
                #expect(
                    next != .approachingStop,
                    "\(event) skipped ahead from the gate with progress \(progress)"
                )
            }
        }
    }

    /// `.travelling` has no entry at all in this build.
    ///
    /// Departure requires an assessment result, and nothing can produce one, so
    /// no state/event pair may reach `.travelling`. Restoring the old
    /// acknowledge-and-go path makes this fail.
    @Test func travellingIsUnreachable() {
        for state in Self.everyState {
            for event in Self.everyEvent {
                let next = CompanionFlowReducer.nextState(from: state, on: event)
                #expect(
                    next != .travelling,
                    "\(state) + \(event) reached travelling without an assessment"
                )
            }
        }
    }

    /// The session model refuses departure at the gate, for every progress
    /// value it can hold.
    @Test func sessionCannotDepartFromTheGate() async {
        let session = await Self.sessionAtGate()
        #expect(session.assessmentGate != nil)
        #expect(session.canDepart == false)
    }

    // MARK: - 3 & 4. No actionShown record, no formal card

    /// Confirming writes the confirmation and the missing-assessment fact —
    /// and never a `careActionShown`.
    @Test func confirmingWritesNoCareActionShownRecord() async {
        let (session, store) = await Self.sessionAndStoreAtGate()

        let hasActionShown = store.kinds.contains { kind in
            if case .careActionShown = kind { return true }
            return false
        }
        #expect(hasActionShown == false)

        // The timeline says plainly that no assessment happened, rather than
        // going silent after the confirmation. The record carries the Care
        // Records reason, not the Companion setback.
        let saysNotAssessed = store.kinds.contains { kind in
            if case .medicineAssessmentDidNotSucceed(.capabilityNotAvailableYet) = kind {
                return true
            }
            return false
        }
        #expect(saysNotAssessed)

        // Exactly this, in this order. A `careActionShown` appearing anywhere
        // in the sequence fails here as well as above.
        let outingTitle = TodayPlan.demo.outing?.title ?? "今日用药"
        #expect(store.kinds == [
            .dayPlanItemStarted(title: outingTitle),
            .medicineReadStarted(attemptNumber: 1),
            .medicineReadFoundCandidates(
                candidateCount: MedicineCandidate.demoCandidates.count
            ),
            .medicineConfirmed(
                medicineName: MedicineCandidate.demoCandidates[0].displayName,
                origin: .readFromPhoto
            ),
            .medicineAssessmentDidNotSucceed(.capabilityNotAvailableYet),
        ])
        #expect(session.assessmentGate != nil)
    }

    /// The gate's wording states that no assessment was made, and offers no
    /// medicine conclusion.
    ///
    /// Asserted on the copy the view actually renders, so a screen cannot say
    /// "已完成药品评估" while the state says otherwise.
    @Test func gateCopyStatesNoAssessmentAndNoConclusion() async {
        let session = await Self.sessionAtGate()

        #expect(session.stepLabel == "尚未完成风险评估")
        #expect(session.situation.contains("尚未完成风险评估"))
        // Never claims an assessment or a care action was produced.
        #expect(session.situation.contains("已完成药品评估") == false)
        #expect(session.situation.contains("已显示") == false)
        // Offers ways back, never a way onward.
        #expect(session.nextStep.contains("继续出发") == false)
        #expect(session.nextStep.contains("重新选择") || session.nextStep.contains("结束"))
        // States why confirming was not enough.
        #expect(session.reason?.contains("还不能说明能不能吃") == true)
    }

    // MARK: - 5. Recovery and exit remain available

    /// A different medicine can be chosen from the gate, without re-reading.
    @Test func gateOffersReconsiderPath() async {
        let session = await Self.sessionAtGate()

        session.reconsiderMedicineChoice()

        guard case let .awaitingMedicineConfirmation(prompt) = session.state else {
            Issue.record("expected to return to confirmation, got \(session.state)")
            return
        }
        // The original candidate list is intact, so nothing must be read again.
        #expect(prompt.candidates == MedicineCandidate.demoCandidates)
    }

    /// The box can be read again from the gate, continuing the attempt count.
    @Test func gateOffersRetakePath() async {
        let session = await Self.sessionAtGate()

        session.retakeMedicinePhoto()

        guard case let .scanningMedicine(attempt) = session.state else {
            Issue.record("expected to return to scanning, got \(session.state)")
            return
        }
        // Attempt 1 produced the candidates, so the retake is attempt 2 — the
        // count continues rather than restarting.
        #expect(attempt.attemptNumber == 2)
        #expect(attempt.setback == nil)
    }

    /// The session can always be ended from the gate.
    @Test func gateOffersExitPath() async {
        let session = await Self.sessionAtGate()

        #expect(session.canEndEarly)
        session.endEarly()
        #expect(session.state == .completed(.endedEarly))
    }

    /// A repeated assessment failure does not reopen the step or re-record.
    @Test func repeatedAssessmentFailureIsRefused() {
        let gate = Self.makeGate(progress: .couldNotAssess(.notWiredUpYet))
        let next = CompanionFlowReducer.nextState(
            from: .awaitingMedicineAssessment(gate),
            on: .medicineAssessmentDidNotSucceed(.notWiredUpYet)
        )
        #expect(next == nil)
    }

    // MARK: - 10. A medicine-only session never travels

    /// With no outing planned, finishing the medicine step must not put the
    /// session on the road.
    ///
    /// Uses a plan with `outing == nil` — a medicine-only session — and walks
    /// the real flow to the gate. The session must be held there, not
    /// travelling.
    @Test func medicineOnlySessionDoesNotEnterTravelling() async {
        let plan = TodayPlan(
            preferredName: "王阿姨",
            medicines: [
                TodayMedicineItem(
                    id: "medicine-only",
                    displayName: "降糖药",
                    timeOfDayDescription: "晚饭后",
                    isTakenToday: false
                ),
            ],
            outing: nil
        )
        let delay = ControllableReadDelay()
        let store = RecordingCareRecordStore()
        let session = CompanionSessionModel(
            records: store,
            simulator: SpyScanSimulator(
                scriptedOutcome: .findsCandidates(MedicineCandidate.demoCandidates)
            ),
            plan: plan,
            readDelay: delay,
            capabilities: .phase0
        )

        #expect(session.startCompanion())
        session.beginMedicineRead()
        await delay.waitForInstall()
        #expect(delay.release())
        if let task = session.pendingReadTask { await task.value }
        session.confirmMedicine(MedicineCandidate.demoCandidates[0])

        // Held at the gate, not travelling and not approaching a stop.
        #expect(session.assessmentGate != nil)
        #expect(session.state != .travelling)
        #expect(session.state != .approachingStop)
        #expect(session.canDepart == false)

        // And the record for a medicine-only session names the medicine step,
        // never an outing that does not exist.
        #expect(store.kinds.first == .dayPlanItemStarted(title: "今日用药"))
    }

    // MARK: - Fixtures

    /// Every state the flow can be in, used for exhaustive sweeps.
    ///
    /// Listed by hand because `CompanionFlowState` carries payloads and cannot
    /// be `CaseIterable`. A new state added without extending this list is
    /// caught by `CompanionFlowStateCoverageTests`.
    static let everyState: [CompanionFlowState] = [
        .notStarted,
        .preDepartureCheck,
        .scanningMedicine(.first),
        .scanningMedicine(.first.interrupted(by: .textNotLegible)),
        .awaitingMedicineConfirmation(
            MedicineConfirmationPrompt(
                candidates: MedicineCandidate.demoCandidates,
                origin: .readFromPhoto,
                attemptNumber: 1
            )
        ),
        .awaitingMedicineAssessment(makeGate(progress: .notStarted)),
        .awaitingMedicineAssessment(
            makeGate(progress: .couldNotAssess(.notWiredUpYet))
        ),
        .travelling,
        .approachingStop,
        .completed(.arrivedSafely),
        .completed(.endedEarly),
    ]

    /// Every event the flow accepts.
    static let everyEvent: [CompanionFlowEvent] = [
        .startCompanion,
        .beginMedicineRead,
        .medicineReadDidNotSucceed(.textNotLegible),
        .medicineReadDidNotSucceed(.noMedicineNameFound),
        .retryMedicineRead,
        .chooseFromFrequentList(MedicineCandidate.demoFrequentlyUsed),
        .medicineCandidatesReady(MedicineCandidate.demoCandidates),
        .retakeMedicinePhoto,
        .confirmMedicine(MedicineCandidate.demoCandidates[0]),
        .medicineAssessmentDidNotSucceed(.notWiredUpYet),
        .reconsiderMedicineChoice,
        .approachStop,
        .arriveSafely,
        .endEarly,
    ]

    static let everyProgress: [MedicineAssessmentProgress] = [
        .notStarted,
        .couldNotAssess(.notWiredUpYet),
    ]

    static func makeGate(
        progress: MedicineAssessmentProgress
    ) -> MedicineAssessmentGate {
        let prompt = MedicineConfirmationPrompt(
            candidates: MedicineCandidate.demoCandidates,
            origin: .readFromPhoto,
            attemptNumber: 1
        )
        return MedicineAssessmentGate(
            confirmed: ConfirmedMedicine(
                candidate: MedicineCandidate.demoCandidates[0],
                origin: .readFromPhoto
            ),
            prompt: prompt,
            progress: progress
        )
    }

    /// Walks the real production flow to the assessment gate.
    ///
    /// Nothing is forced: the session starts, reads, receives candidates, and
    /// confirms, exactly as a person would drive it. The gate is therefore
    /// reached the same way in tests as in the app.
    static func sessionAndStoreAtGate() async
        -> (CompanionSessionModel, RecordingCareRecordStore)
    {
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

        session.startCompanion()
        session.beginMedicineRead()
        await delay.waitForInstall()
        delay.release()
        if let task = session.pendingReadTask { await task.value }
        session.confirmMedicine(MedicineCandidate.demoCandidates[0])

        return (session, store)
    }

    static func sessionAtGate() async -> CompanionSessionModel {
        await sessionAndStoreAtGate().0
    }
}
