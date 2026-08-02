import Testing
import Foundation
import SlowWalkClientCore
import SlowWalkAPIContracts
import SlowWalkDomain
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
///
/// C1: the gate now stores canonical `MedicineAssessmentStateUpdate` instead
/// of the local `MedicineAssessmentProgress`.
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
        // Nothing has been assessed: the gate opens with `latestUpdate: nil`,
        // which is semantically `.idle`.
        #expect(gate.latestUpdate == nil)
        #expect(gate.assessmentState == .idle)
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
            #expect(gate.latestUpdate == nil)
            #expect(gate.confirmed.candidate == candidate)
        }
    }

    /// No transition produces a gate that carries a `.result` without an
    /// explicit state update.
    ///
    /// The gate opens at `nil` (semantically `.idle`); only the dedicated
    /// `.medicineAssessmentStateDidUpdate` event can carry a result in.
    @Test func noTransitionProducesAGateWithResult() {
        for state in Self.everyState {
            for event in Self.everyEvent {
                guard let next = CompanionFlowReducer.nextState(from: state, on: event)
                else { continue }
                if case let .awaitingMedicineAssessment(gate) = next {
                    if case .result = gate.assessmentState {
                        Issue.record(
                            "gate carries result without explicit update: \(state) + \(event)"
                        )
                    }
                }
            }
        }
    }

    // MARK: - 2. Departure is impossible without an assessment result

    /// No event moves the session out of the gate into travelling.
    ///
    /// This is the "cannot continue the outing" guarantee stated at the level
    /// that decides it. Every event is tried, so a departure path cannot be
    /// added by a transition this test forgot to name.
    @Test func noEventDepartsFromTheAssessmentGate() {
        for update in Self.everyGateUpdate {
            let gate = Self.makeGate(latestUpdate: update)
            for event in Self.everyEvent {
                let next = CompanionFlowReducer.nextState(
                    from: .awaitingMedicineAssessment(gate),
                    on: event
                )
                #expect(
                    next != .travelling,
                    "\(event) departed from the gate with state \(gate.assessmentState)"
                )
                #expect(
                    next != .approachingStop,
                    "\(event) skipped ahead from the gate with state \(gate.assessmentState)"
                )
                #expect(
                    next != .completed(.arrivedSafely),
                    "\(event) completed from the gate with state \(gate.assessmentState)"
                )
            }
        }
    }

    /// `.travelling` has no entry at all in this build from the gate.
    ///
    /// Departure requires a displayed assessment result, and no display path
    /// exists yet, so no state/event pair may reach `.travelling` from the
    /// gate. Non-gate states that previously reached travelling
    /// (`.travelling` → `.approachStop` chain) are excluded.
    @Test func travellingIsUnreachableFromTheGate() {
        for update in Self.everyGateUpdate {
            let gate = Self.makeGate(latestUpdate: update)
            for event in Self.everyEvent {
                let next = CompanionFlowReducer.nextState(
                    from: .awaitingMedicineAssessment(gate),
                    on: event
                )
                #expect(
                    next != .travelling,
                    "gate + \(event) reached travelling without displayed result"
                )
            }
        }
    }

    /// The session model refuses departure at the gate, for every non-result
    /// canonical state.
    @Test func sessionCannotDepartFromNonResultGate() async {
        let session = await Self.sessionAtGate()
        #expect(session.assessmentGate != nil)
        #expect(session.canDepart == false)
    }

    // MARK: - 3 & 4. No actionShown record, no formal card

    /// Confirming writes the confirmation record — and never a `careActionShown`.
    @Test func confirmingWritesNoCareActionShownRecord() async {
        let (session, store) = await Self.sessionAndStoreAtGate()

        let hasActionShown = store.kinds.contains { kind in
            if case .careActionShown = kind { return true }
            return false
        }
        #expect(hasActionShown == false)

        // The timeline records the confirmation but no assessment record
        // (C1 does not fabricate setbacks).
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
        ])
        #expect(session.assessmentGate != nil)
    }

    /// Receiving a `.result` at the gate does not write `careActionShown`.
    ///
    /// C1: `careActionShown` may only be written once a real result has been
    /// *displayed*. Storing the result is not displaying it.
    @Test func resultAtGateDoesNotWriteCareActionShown() async {
        let (session, store) = await Self.sessionAndStoreAtGate()

        let update = Self.makeResultUpdate(sequenceNumber: 1)
        session.applyAssessmentStateUpdate(update)

        let hasActionShown = store.kinds.contains { kind in
            if case .careActionShown = kind { return true }
            return false
        }
        #expect(hasActionShown == false)
        #expect(session.assessmentGate?.assessmentState == .result(Self.presentation))
    }

    /// A generated canonical result is waiting for presentation; it is not an
    /// unfinished assessment and it has not yet been displayed.
    @Test func resultGateCopySaysGeneratedAndWaitingForDisplay() async {
        let session = await Self.sessionAtGate()
        session.applyAssessmentStateUpdate(
            Self.makeResultUpdate(sequenceNumber: 1)
        )

        guard let gate = session.assessmentGate else {
            Issue.record("expected assessment gate after result update")
            return
        }
        let heading = CompanionCopy.assessmentGateHeading(gate)
        #expect(heading == "评估结果已生成，等待展示")
        #expect(session.stepLabel == heading)
        #expect(session.stepLabel.contains("尚未完成") == false)
        #expect(session.situation.contains("正式评估结果已生成，等待展示"))
    }

    /// Every canonical lifecycle state receives a deliberate gate heading.
    /// The panel renders this same production helper directly rather than
    /// maintaining a second state-to-copy mapping.
    @Test func assessmentGateHeadingMatchesCanonicalState() {
        for update in Self.everyGateUpdate {
            let gate = Self.makeGate(latestUpdate: update)
            let heading = CompanionCopy.assessmentGateHeading(gate)

            switch gate.assessmentState {
            case .idle, .recognizing, .assessing:
                #expect(heading == "尚未完成风险评估")
            case .requiresMedicineConfirmation:
                #expect(heading == "需要进一步确认药名")
            case .result:
                #expect(heading == "评估结果已生成，等待展示")
            case .failed:
                #expect(heading == "评估未能完成")
            case .cancelled:
                #expect(heading == "评估已取消")
            }
        }
    }

    /// The gate's wording states that no assessment was made, and offers no
    /// medicine conclusion.
    ///
    /// Asserted on the copy the view actually renders, so a screen cannot say
    /// "已完成药品评估" while the state says otherwise.
    @Test func gateCopyStatesNoAssessmentAndNoConclusion() async {
        let session = await Self.sessionAtGate()

        #expect(session.stepLabel == "尚未完成风险评估")
        #expect(session.situation.contains("尚未开始正式评估"))
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

    // MARK: - 6. Canonical state update — exhaustive acceptance

    /// Every canonical case is accepted by the reducer.
    @Test func allSevenCanonicalCasesAreAccepted() {
        let gate = Self.makeGate(latestUpdate: nil)
        let cases: [MedicineAssessmentViewState] = [
            .idle,
            .recognizing(startedAt: Date(timeIntervalSince1970: 0)),
            .requiresMedicineConfirmation(
                MedicineConfirmationRequirement(
                    reason: .noRecognizedText,
                    recognitionInput: MedicineRecognitionInput(
                        recognizedTexts: [],
                        capturedAt: Date(timeIntervalSince1970: 0),
                        languageCode: nil,
                        rawConfidence: nil
                    ),
                    response: nil
                )
            ),
            .assessing(startedAt: Date(timeIntervalSince1970: 0)),
            .result(Self.presentation),
            .failed(Self.clientFailure),
            .cancelled,
        ]

        for (index, state) in cases.enumerated() {
            let update = MedicineAssessmentStateUpdate(
                sequenceNumber: UInt64(index + 1),
                state: state
            )
            let next = CompanionFlowReducer.nextState(
                from: .awaitingMedicineAssessment(gate),
                on: .medicineAssessmentStateDidUpdate(update)
            )
            #expect(next != nil, "canonical case \(state) was rejected")
        }
    }

    // MARK: - 7. Staleness rejection

    /// A lower generation (sequenceNumber) is rejected — belongs to an old operation.
    @Test func lowerSequenceNumberIsRejected() {
        let gate = Self.makeGate(
            latestUpdate: MedicineAssessmentStateUpdate(
                sequenceNumber: 5,
                state: .idle
            )
        )
        let stale = MedicineAssessmentStateUpdate(
            sequenceNumber: 3,
            state: .assessing(startedAt: Date(timeIntervalSince1970: 0))
        )
        let next = CompanionFlowReducer.nextState(
            from: .awaitingMedicineAssessment(gate),
            on: .medicineAssessmentStateDidUpdate(stale)
        )
        #expect(next == nil, "lower generation must be rejected")
    }

    /// Same sequenceNumber with different state is accepted — normal progression
    /// within one operation (e.g. recognizing → assessing → result).
    @Test func sameSequenceDifferentStateProgressionIsAccepted() {
        let date = Date(timeIntervalSince1970: 0)
        let gate = Self.makeGate(latestUpdate: nil)

        // recognizing(7)
        let recognizing = MedicineAssessmentStateUpdate(
            sequenceNumber: 7,
            state: .recognizing(startedAt: date)
        )
        let r1 = CompanionFlowReducer.nextState(
            from: .awaitingMedicineAssessment(gate),
            on: .medicineAssessmentStateDidUpdate(recognizing)
        )
        #expect(r1 != nil, "recognizing(7) must be accepted")
        guard case let .awaitingMedicineAssessment(g1)? = r1 else {
            Issue.record("expected gate after recognizing")
            return
        }

        // assessing(7) — same operation, different state
        let assessing = MedicineAssessmentStateUpdate(
            sequenceNumber: 7,
            state: .assessing(startedAt: date)
        )
        let r2 = CompanionFlowReducer.nextState(
            from: .awaitingMedicineAssessment(g1),
            on: .medicineAssessmentStateDidUpdate(assessing)
        )
        #expect(r2 != nil, "assessing(7) must be accepted within same operation")
        guard case let .awaitingMedicineAssessment(g2)? = r2 else {
            Issue.record("expected gate after assessing")
            return
        }

        // result(7) — same operation, different state
        let result = Self.makeResultUpdate(sequenceNumber: 7)
        let r3 = CompanionFlowReducer.nextState(
            from: .awaitingMedicineAssessment(g2),
            on: .medicineAssessmentStateDidUpdate(result)
        )
        #expect(r3 != nil, "result(7) must be accepted within same operation")
        guard case let .awaitingMedicineAssessment(g3)? = r3 else {
            Issue.record("expected gate after result")
            return
        }
        #expect(g3.assessmentState == .result(Self.presentation))
    }

    /// Same sequenceNumber with identical state is an exact duplicate — rejected.
    @Test func exactDuplicateUpdateIsRejected() {
        let date = Date(timeIntervalSince1970: 0)
        let assessing1 = MedicineAssessmentStateUpdate(
            sequenceNumber: 7,
            state: .assessing(startedAt: date)
        )
        let gate = Self.makeGate(latestUpdate: assessing1)

        let assessing2 = MedicineAssessmentStateUpdate(
            sequenceNumber: 7,
            state: .assessing(startedAt: date)
        )
        let next = CompanionFlowReducer.nextState(
            from: .awaitingMedicineAssessment(gate),
            on: .medicineAssessmentStateDidUpdate(assessing2)
        )
        #expect(next == nil, "exact duplicate must be rejected")
    }

    /// A late `.assessing` from an older operation does not overwrite a result
    /// from a newer operation.
    @Test func lateAssessingDoesNotOverwriteResult() {
        let resultUpdate = Self.makeResultUpdate(sequenceNumber: 10)
        let gate = Self.makeGate(latestUpdate: resultUpdate)

        let lateAssessing = MedicineAssessmentStateUpdate(
            sequenceNumber: 7,
            state: .assessing(startedAt: Date(timeIntervalSince1970: 0))
        )
        let next = CompanionFlowReducer.nextState(
            from: .awaitingMedicineAssessment(gate),
            on: .medicineAssessmentStateDidUpdate(lateAssessing)
        )
        #expect(next == nil, "late assessing must not overwrite result")

        // The gate still holds the result.
        #expect(gate.assessmentState == .result(Self.presentation))
    }

    /// A late `.failed` from an older operation does not overwrite a result
    /// from a newer operation.
    @Test func lateFailedDoesNotOverwriteResult() {
        let resultUpdate = Self.makeResultUpdate(sequenceNumber: 10)
        let gate = Self.makeGate(latestUpdate: resultUpdate)

        let lateFailed = MedicineAssessmentStateUpdate(
            sequenceNumber: 7,
            state: .failed(Self.clientFailure)
        )
        let next = CompanionFlowReducer.nextState(
            from: .awaitingMedicineAssessment(gate),
            on: .medicineAssessmentStateDidUpdate(lateFailed)
        )
        #expect(next == nil, "late failed must not overwrite result")
        #expect(gate.assessmentState == .result(Self.presentation))
    }

    /// A higher generation starts a new operation — always accepted.
    @Test func higherGenerationStartsNewOperation() {
        let result = Self.makeResultUpdate(sequenceNumber: 8)
        let gate = Self.makeGate(latestUpdate: result)

        let recognizing = MedicineAssessmentStateUpdate(
            sequenceNumber: 9,
            state: .recognizing(startedAt: Date(timeIntervalSince1970: 0))
        )
        let next = CompanionFlowReducer.nextState(
            from: .awaitingMedicineAssessment(gate),
            on: .medicineAssessmentStateDidUpdate(recognizing)
        )
        #expect(next != nil, "higher generation must be accepted")
    }

    /// A new update (higher seq) IS accepted.
    @Test func higherSequenceNumberIsAccepted() {
        let gate = Self.makeGate(
            latestUpdate: MedicineAssessmentStateUpdate(
                sequenceNumber: 5,
                state: .idle
            )
        )
        let newer = MedicineAssessmentStateUpdate(
            sequenceNumber: 6,
            state: .assessing(startedAt: Date(timeIntervalSince1970: 0))
        )
        let next = CompanionFlowReducer.nextState(
            from: .awaitingMedicineAssessment(gate),
            on: .medicineAssessmentStateDidUpdate(newer)
        )
        #expect(next != nil, "higher seq should be accepted")
        if case let .awaitingMedicineAssessment(updatedGate)? = next {
            #expect(updatedGate.latestUpdate?.sequenceNumber == 6)
        }
    }

    /// First update (nil gate) is always accepted.
    @Test func firstUpdateIsAlwaysAccepted() {
        let gate = Self.makeGate(latestUpdate: nil)
        let update = MedicineAssessmentStateUpdate(
            sequenceNumber: 0,
            state: .idle
        )
        let next = CompanionFlowReducer.nextState(
            from: .awaitingMedicineAssessment(gate),
            on: .medicineAssessmentStateDidUpdate(update)
        )
        #expect(next != nil, "first update should be accepted")
    }

    // MARK: - 8. Qualification booleans

    /// Only `.result` earns departure qualification, and only with an outing.
    @Test func onlyResultWithOutingEarnsCanDepart() async {
        // Non-result gate with outing — no departure.
        let nonResultStates: [MedicineAssessmentViewState] = [
            .idle,
            .recognizing(startedAt: Date(timeIntervalSince1970: 0)),
            .requiresMedicineConfirmation(
                MedicineConfirmationRequirement(
                    reason: .noRecognizedText,
                    recognitionInput: MedicineRecognitionInput(
                        recognizedTexts: [],
                        capturedAt: Date(timeIntervalSince1970: 0),
                        languageCode: nil,
                        rawConfidence: nil
                    ),
                    response: nil
                )
            ),
            .assessing(startedAt: Date(timeIntervalSince1970: 0)),
            .failed(Self.clientFailure),
            .cancelled,
        ]

        for state in nonResultStates {
            let session = await Self.sessionAtGate(
                latestUpdate: MedicineAssessmentStateUpdate(
                    sequenceNumber: 1,
                    state: state
                )
            )
            #expect(session.canDepart == false, "\(state) must not allow departure")
            #expect(session.canCompleteMedicineCheck == false,
                    "\(state) must not allow medicine-only completion")
        }
    }

    /// `.result` with outing → canDepart is true, canCompleteMedicineCheck is false.
    @Test func resultWithOutingEnablesCanDepart() async {
        let session = await Self.sessionAtGate(
            latestUpdate: Self.makeResultUpdate(sequenceNumber: 1)
        )
        #expect(session.canDepart == true)
        #expect(session.canCompleteMedicineCheck == false)
    }

    /// `.result` without outing → canDepart is false, canCompleteMedicineCheck true.
    @Test func resultWithoutOutingEnablesCanCompleteMedicineCheck() async {
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

        // Apply result.
        session.applyAssessmentStateUpdate(
            Self.makeResultUpdate(sequenceNumber: 1)
        )

        #expect(session.canDepart == false)
        #expect(session.canCompleteMedicineCheck == true)
        // State stays at the gate, not travelling, not completed.
        #expect(session.assessmentGate != nil)
        #expect(session.state != .travelling)
    }

    // MARK: - 9. MedicineAssessmentPresentation roundtrip

    /// The `.result` payload survives a roundtrip through the gate unchanged.
    @Test func resultPresentationPreservedThroughGate() {
        let update = Self.makeResultUpdate(sequenceNumber: 1)
        let gate = Self.makeGate(latestUpdate: nil)

        let next = CompanionFlowReducer.nextState(
            from: .awaitingMedicineAssessment(gate),
            on: .medicineAssessmentStateDidUpdate(update)
        )

        guard case let .awaitingMedicineAssessment(updatedGate)? = next else {
            Issue.record("expected gate, got \(String(describing: next))")
            return
        }
        #expect(updatedGate.latestUpdate == update)
        #expect(updatedGate.assessmentState == .result(Self.presentation))
    }

    // MARK: - 10. A medicine-only session never travels

    /// With no outing planned, even a `.result` must not enable departure.
    ///
    /// Uses a plan with `outing == nil` — a medicine-only session — and walks
    /// the real flow to the gate. Even after receiving `.result`, the session
    /// must stay at the gate with no departure qualification.
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

        // Apply result — still no departure qualification (no outing).
        session.applyAssessmentStateUpdate(
            Self.makeResultUpdate(sequenceNumber: 1)
        )
        #expect(session.canDepart == false)
        #expect(session.canCompleteMedicineCheck == true)
        #expect(session.assessmentGate != nil)
        #expect(session.state != .travelling)
        #expect(session.state != .approachingStop)

        // And the record for a medicine-only session names the medicine step,
        // never an outing that does not exist.
        #expect(store.kinds.first == .dayPlanItemStarted(title: "今日用药"))
    }

    // MARK: - 11. Outing session only qualifies after result

    /// An outing session must only earn departure qualification after `.result`.
    @Test func outingSessionOnlyQualifiesAfterResult() async {
        let session = await Self.sessionAtGate()

        // At .idle gate (no update yet): no departure.
        #expect(session.canDepart == false)
        #expect(session.canCompleteMedicineCheck == false)

        // Apply .assessing: still no departure.
        session.applyAssessmentStateUpdate(
            MedicineAssessmentStateUpdate(
                sequenceNumber: 1,
                state: .assessing(startedAt: Date(timeIntervalSince1970: 0))
            )
        )
        #expect(session.canDepart == false)

        // Apply .failed: still no departure.
        session.applyAssessmentStateUpdate(
            MedicineAssessmentStateUpdate(
                sequenceNumber: 2,
                state: .failed(Self.clientFailure)
            )
        )
        #expect(session.canDepart == false)
        #expect(session.assessmentGate?.isAwaitingRecovery == true)

        // Apply .result: now departure qualification is earned.
        session.applyAssessmentStateUpdate(
            Self.makeResultUpdate(sequenceNumber: 3)
        )
        #expect(session.canDepart == true)
        #expect(session.canCompleteMedicineCheck == false)
        // But still at the gate — C1 does not transition.
        #expect(session.assessmentGate != nil)
        #expect(session.state != .travelling)
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
        .awaitingMedicineAssessment(makeGate(latestUpdate: nil)),
        .awaitingMedicineAssessment(
            makeGate(latestUpdate: makeResultUpdate(sequenceNumber: 1))
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
        .medicineAssessmentStateDidUpdate(makeIdleUpdate(sequenceNumber: 1)),
        .reconsiderMedicineChoice,
        .approachStop,
        .arriveSafely,
        .endEarly,
    ]

    /// Every gate update used for exhaustive gate sweeps.
    static let everyGateUpdate: [MedicineAssessmentStateUpdate?] = [
        nil,
        makeIdleUpdate(sequenceNumber: 1),
        MedicineAssessmentStateUpdate(
            sequenceNumber: 1,
            state: .recognizing(startedAt: Date(timeIntervalSince1970: 0))
        ),
        MedicineAssessmentStateUpdate(
            sequenceNumber: 1,
            state: .requiresMedicineConfirmation(
                MedicineConfirmationRequirement(
                    reason: .noRecognizedText,
                    recognitionInput: MedicineRecognitionInput(
                        recognizedTexts: [],
                        capturedAt: Date(timeIntervalSince1970: 0),
                        languageCode: nil,
                        rawConfidence: nil
                    ),
                    response: nil
                )
            )
        ),
        MedicineAssessmentStateUpdate(
            sequenceNumber: 1,
            state: .assessing(startedAt: Date(timeIntervalSince1970: 0))
        ),
        makeResultUpdate(sequenceNumber: 1),
        MedicineAssessmentStateUpdate(
            sequenceNumber: 1,
            state: .failed(clientFailure)
        ),
        MedicineAssessmentStateUpdate(
            sequenceNumber: 1,
            state: .cancelled
        ),
    ]

    /// The test `MedicineAssessmentPresentation`, reused across tests.
    static let presentation: MedicineAssessmentPresentation = {
        let card = ActionCard(
            title: "TEST CARD",
            primaryInstruction: "TEST INSTRUCTION",
            warnings: ["TEST WARNING"],
            recommendedActions: [.consultHealthcareProfessional],
            riskLevel: .yellow,
            sourceReferences: [],
            mustConfirmMedicine: false,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let evidence = MedicineResolutionEvidence(
            recognizedTexts: ["test"],
            normalizedText: "test",
            normalizedQuery: "test",
            languageCode: "en",
            rawConfidence: 0.9,
            dosageForms: [],
            removedSpecifications: [],
            discardedNoise: [],
            matcherVersion: "test-v1",
            sourceDataVersions: ["test-v1"]
        )
        let resolution = MedicineResolution(
            status: .resolved,
            candidates: [],
            selectedMedicine: nil,
            evidence: evidence,
            requiresUserConfirmation: false
        )
        let response = MedicineAssessmentResponseDTO(
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            resolution: resolution,
            assessment: nil,
            actionCard: card,
            cacheHit: false,
            resolutionCacheStatus: .miss,
            sourceDataVersion: "test-v1",
            generatedAt: Date(timeIntervalSince1970: 0),
            apiVersion: "v1"
        )
        return MedicineAssessmentPresentation(response: response)
    }()

    /// The test `ClientFailure`, reused across tests.
    static let clientFailure = ClientFailure(
        kind: .unknown,
        apiErrorCode: nil,
        requestID: nil,
        endpoint: nil,
        isRecoverable: false
    )

    static func makeResultUpdate(sequenceNumber: UInt64) -> MedicineAssessmentStateUpdate {
        MedicineAssessmentStateUpdate(
            sequenceNumber: sequenceNumber,
            state: .result(presentation)
        )
    }

    static func makeIdleUpdate(sequenceNumber: UInt64) -> MedicineAssessmentStateUpdate {
        MedicineAssessmentStateUpdate(
            sequenceNumber: sequenceNumber,
            state: .idle
        )
    }

    static func makeGate(
        latestUpdate: MedicineAssessmentStateUpdate?
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
            latestUpdate: latestUpdate
        )
    }

    /// Walks the real production flow to the assessment gate.
    ///
    /// Nothing is forced: the session starts, reads, receives candidates, and
    /// confirms, exactly as a person would drive it. The gate is therefore
    /// reached the same way in tests as in the app.
    static func sessionAndStoreAtGate(
        latestUpdate: MedicineAssessmentStateUpdate? = nil
    ) async -> (CompanionSessionModel, RecordingCareRecordStore) {
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

        if let update = latestUpdate {
            session.applyAssessmentStateUpdate(update)
        }

        return (session, store)
    }

    static func sessionAtGate(
        latestUpdate: MedicineAssessmentStateUpdate? = nil
    ) async -> CompanionSessionModel {
        await sessionAndStoreAtGate(latestUpdate: latestUpdate).0
    }
}
