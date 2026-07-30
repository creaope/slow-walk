import Foundation

/// Owns the live companion session: current state, side effects, and records.
///
/// All transition decisions come from `CompanionFlowReducer`. This type adds
/// only what a pure function cannot do — write care records and run the
/// simulated read — so the two concerns stay separable.
@Observable
@MainActor
final class CompanionSessionModel {
    private(set) var state: CompanionFlowState = .notStarted

    private let records: any CareRecordStoring
    private let simulator: any MedicineScanSimulating
    private let readDelay: any MedicineReadDelaying
    private let plan: TodayPlan

    /// What this build can really do.
    ///
    /// The session's own copy of the table it was assembled with. Every screen
    /// reading capability state for this session reads it from here — see
    /// `CompanionView` — so behaviour and wording cannot describe different
    /// builds. There is no fallback default: the composition root supplies it.
    let capabilities: CapabilityCatalog

    /// Guards against a stale simulated read landing after the person has
    /// already moved on (retried, chosen from the list, or ended the session).
    /// Only `invalidatePendingRead()` moves it.
    private var readGeneration = 0

    /// The in-flight simulated read, exposed read-only so tests can await the
    /// exact task whose staleness they are probing. The setter stays private;
    /// only `recordReadStartedAndRun()` starts a read.
    private(set) var pendingReadTask: Task<Void, Never>?

    init(
        records: any CareRecordStoring,
        simulator: any MedicineScanSimulating = MockMedicineScanSimulator.demo,
        plan: TodayPlan,
        readDelay: any MedicineReadDelaying = ContinuousMedicineReadDelay(),
        capabilities: CapabilityCatalog
    ) {
        self.records = records
        self.simulator = simulator
        self.readDelay = readDelay
        self.plan = plan
        self.capabilities = capabilities
    }

    // MARK: - Derived presentation values

    var stepLabel: String { CompanionCopy.stepLabel(for: state) }
    /// Wording derived from this session's own capability table, so what the
    /// person reads and what the flow does come from one source.
    var situation: String {
        CompanionCopy.situation(for: state, capabilities: capabilities)
    }
    var nextStep: String { CompanionCopy.nextStep(for: state) }
    var reason: String? { CompanionCopy.reason(for: state) }

    var canEndEarly: Bool { state.isActive }

    /// True while the simulated read is running, so the view can show progress.
    var isReadingMedicine: Bool {
        if case let .scanningMedicine(attempt) = state {
            return !attempt.isAwaitingRecovery
        }
        return false
    }

    /// The assessment gate the session is currently held at, if any.
    ///
    /// Exposed so the view can render the "not assessed yet" step and its ways
    /// out without inspecting the state enum itself.
    var assessmentGate: MedicineAssessmentGate? {
        if case let .awaitingMedicineAssessment(gate) = state {
            return gate
        }
        return nil
    }

    /// Whether the session may leave for the outing.
    ///
    /// Departure is only legitimate once a formal assessment has produced a
    /// result. This switch is exhaustive over `MedicineAssessmentProgress`, and
    /// neither of its cases is a result, so the answer today is always `false`.
    /// Written this way on purpose: adding a success case to the progress enum
    /// makes this switch non-exhaustive and forces the departure rule to be
    /// stated deliberately, instead of a `true` appearing by default.
    var canDepart: Bool {
        guard let gate = assessmentGate else { return false }
        switch gate.progress {
        case .notStarted, .couldNotAssess:
            return false
        }
    }

    /// Recovery choices offered when a read did not succeed.
    var recoveryOptions: [CompanionRecoveryOption] {
        guard case let .scanningMedicine(attempt) = state,
              attempt.isAwaitingRecovery
        else {
            return []
        }
        return [.retryPhoto, .chooseFromList, .contactSomeone]
    }

    // MARK: - Intents

    /// Starts a session, reporting whether one actually started.
    ///
    /// The answer matters to the caller: Today navigates to the Companion tab
    /// on the back of this call, and must not move the person when the
    /// transition was refused. The record is written only once a session has
    /// really begun, so a refused start leaves the timeline untouched.
    @discardableResult
    func startCompanion() -> Bool {
        guard send(.startCompanion) else { return false }
        if let outing = plan.outing {
            records.append(.dayPlanItemStarted(title: outing.title))
        } else {
            records.append(.dayPlanItemStarted(title: "今日用药"))
        }
        return true
    }

    func beginMedicineRead() {
        guard send(.beginMedicineRead) else { return }
        recordReadStartedAndRun()
    }

    func retryMedicineRead() {
        guard send(.retryMedicineRead) else { return }
        recordReadStartedAndRun()
    }

    func chooseFromFrequentList() {
        let candidates = MedicineCandidate.demoFrequentlyUsed
        guard send(.chooseFromFrequentList(candidates)) else { return }
        // The read is being abandoned in favour of the list, so its result
        // must not arrive later and overwrite this choice.
        invalidatePendingRead()
    }

    /// Goes back to reading when none of the offered candidates match.
    func retakeMedicinePhoto() {
        guard send(.retakeMedicinePhoto) else { return }
        recordReadStartedAndRun()
    }

    func confirmMedicine(_ candidate: MedicineCandidate) {
        guard case let .awaitingMedicineConfirmation(prompt) = state,
              send(.confirmMedicine(candidate))
        else {
            return
        }
        records.append(
            .medicineConfirmed(
                medicineName: candidate.displayName,
                origin: prompt.origin
            )
        )
        // No `careActionShown` record is written here, and none may be. That
        // record means a care action was actually shown to the person; writing
        // it on confirmation put a claim in the care timeline that nothing had
        // produced. The record is written by whatever presents a real
        // assessment result, which this build has none of.
        //
        // Any pending read is abandoned: a confirmation is a decision, and a
        // result that was in flight when it was made must not land afterwards
        // and reopen a step the person has already left.
        invalidatePendingRead()
        beginMedicineAssessment()
    }

    /// Goes back to the candidate list to choose a different medicine.
    func reconsiderMedicineChoice() {
        guard send(.reconsiderMedicineChoice) else { return }
    }

    func approachStop() {
        guard send(.approachStop) else { return }
    }

    func arriveSafely() {
        guard send(.arriveSafely) else { return }
        records.append(.companionFinished(.arrivedSafely))
    }

    func endEarly() {
        guard send(.endEarly) else { return }
        // The session is over; nothing from the abandoned read may land after
        // it and reopen a step the person has already left.
        invalidatePendingRead()
        records.append(.companionFinished(.endedEarly))
    }

    // MARK: - Medicine assessment
    //
    // This build has no assessment adapter. Rather than let the flow sit at a
    // gate that never resolves, the missing capability is reported as a
    // setback, so the person is offered a way out immediately and the screen
    // states plainly that no assessment was made.

    /// Reports the assessment outcome for the medicine just confirmed.
    ///
    /// The outcome is read from `capabilities`, not hardcoded, so the single
    /// capability table decides what happens here. There is deliberately no
    /// branch that produces a result: `MedicineAssessmentProgress` has no
    /// success case to produce one with, so this method cannot fabricate an
    /// assessment even if the capability table claimed the capability existed.
    private func beginMedicineAssessment() {
        guard capabilities
            .availability(of: .medicineRiskAssessment)
            .isImplemented == false
        else {
            // A capability table claiming assessment works, with no adapter to
            // honour it, must not silently become an assessed medicine. The
            // gate stays at `.notStarted`: no card, no record, no departure.
            return
        }
        guard send(.medicineAssessmentDidNotSucceed(.notWiredUpYet)) else { return }
        // Converted on this side of the boundary: the timeline stores a Care
        // Records reason, never the Companion setback itself, so the record
        // vocabulary does not move when the flow's states do.
        records.append(
            .medicineAssessmentDidNotSucceed(
                MedicineAssessmentSetback.notWiredUpYet.careRecordReason
            )
        )
    }

    // MARK: - Simulated read

    /// Drops whatever simulated read is still in flight.
    ///
    /// Every abandonment of a read goes through here, so there is one place to
    /// look for why a stale result was ignored. Call it only after the matching
    /// transition succeeded: moving the generation for a refused or repeated
    /// event would silently cancel a read that is still legitimately running.
    private func invalidatePendingRead() {
        readGeneration += 1
    }

    private func recordReadStartedAndRun() {
        guard case let .scanningMedicine(attempt) = state else { return }

        // Starting a read supersedes any earlier one. Invalidate first, then
        // capture the generation this read owns.
        invalidatePendingRead()
        let generation = readGeneration
        let attemptNumber = attempt.attemptNumber

        records.append(.medicineReadStarted(attemptNumber: attemptNumber))

        pendingReadTask = Task { [weak self] in
            do {
                try await self?.readDelay.wait()
            } catch {
                return
            }
            guard let self, self.readGeneration == generation else { return }
            self.finishRead(forAttemptNumber: attemptNumber)
        }
    }

    private func finishRead(forAttemptNumber attemptNumber: Int) {
        guard let outcome = simulator.outcome(forAttemptNumber: attemptNumber) else {
            return
        }
        switch outcome {
        case let .doesNotSucceed(setback):
            guard send(.medicineReadDidNotSucceed(setback)) else { return }
            records.append(.medicineReadDidNotSucceed(setback))
        case let .findsCandidates(candidates):
            guard send(.medicineCandidatesReady(candidates)) else { return }
            records.append(
                .medicineReadFoundCandidates(candidateCount: candidates.count)
            )
        }
    }

    // MARK: - Transition

    /// Applies an event, returning whether it changed the state.
    ///
    /// Deliberately not `@discardableResult`: a refused event must never be
    /// followed by the side effects of a successful one, so every caller is
    /// made to answer whether the transition happened.
    private func send(_ event: CompanionFlowEvent) -> Bool {
        guard let next = CompanionFlowReducer.nextState(from: state, on: event) else {
            return false
        }
        state = next
        return true
    }
}

/// A recovery choice offered after a read that did not succeed.
enum CompanionRecoveryOption: Identifiable, Equatable, Hashable, CaseIterable {
    case retryPhoto
    case chooseFromList
    case contactSomeone

    var id: Self { self }

    var title: String {
        switch self {
        case .retryPhoto: CompanionCopy.retryPhotoTitle
        case .chooseFromList: CompanionCopy.chooseFromListTitle
        case .contactSomeone: CompanionCopy.contactSomeoneTitle
        }
    }
}

/// Translates a Companion setback into the Care Records vocabulary.
///
/// The one place the two vocabularies meet, and it sits on the Companion side on
/// purpose: the flow knows about the timeline it writes to, while Care Records
/// knows nothing about the flow's internal states. `CareRecordEvent.swift`
/// therefore names reasons only and never mentions a Companion type.
///
/// `private` so the conversion cannot become an API other layers reach for; a
/// second caller would be a second place the boundary is decided.
///
/// The `switch` is exhaustive, so a new Companion setback cannot reach the
/// timeline until it has been given a deliberate record meaning — which is the
/// point of keeping the types separate. Mapping a new setback onto an existing
/// reason is a decision, not a default.
private extension MedicineAssessmentSetback {
    var careRecordReason: CareRecordIncompleteReason {
        switch self {
        case .notWiredUpYet:
            return .capabilityNotAvailableYet
        }
    }
}
