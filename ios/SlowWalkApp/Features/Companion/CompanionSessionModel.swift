import Foundation
import SlowWalkAPIContracts
import SlowWalkClientCore
import SlowWalkDomain

struct MedicineAssessmentGateLease: Equatable, Sendable {
    private let identifier: UUID

    fileprivate init() {
        identifier = UUID()
    }
}

/// Owns the live companion session: current state, side effects, and records.
///
/// All transition decisions come from `CompanionFlowReducer`. This type adds
/// only what a pure function cannot do — write care records and run the
/// simulated read — so the two concerns stay separable.
@Observable
@MainActor
final class CompanionSessionModel {
    private enum GateLeaseChange {
        case preserve, replace, invalidate
    }

    private(set) var state: CompanionFlowState = .notStarted
    private(set) var currentAssessmentGateLease: MedicineAssessmentGateLease?

    private let records: any CareRecordStoring
    private let careActionShownRecorder: CareActionShownRecorder
    private let simulator: any MedicineScanSimulating
    private let readDelay: any MedicineReadDelaying
    private let plan: TodayPlan
    private var assessmentGateInvalidationHandler:
        (@MainActor (MedicineAssessmentGateLease) -> Void)?
    private var recordedCanonicalMedicineRequestIDs: Set<UUID> = []

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
        careActionShownRecorder: CareActionShownRecorder,
        simulator: any MedicineScanSimulating = MockMedicineScanSimulator.demo,
        plan: TodayPlan,
        readDelay: any MedicineReadDelaying = ContinuousMedicineReadDelay(),
        capabilities: CapabilityCatalog
    ) {
        self.records = records
        self.careActionShownRecorder = careActionShownRecorder
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
    /// True only when the current canonical `.result` was actually displayed
    /// and an outing is planned. This is qualification, not an automatic
    /// transition.
    var canDepart: Bool {
        guard let gate = assessmentGate,
              gate.hasDisplayedCurrentResult,
              plan.outing != nil
        else { return false }
        return true
    }

    /// Whether a medicine-only session has earned its completion qualification.
    ///
    /// True only when the current canonical `.result` was actually displayed
    /// and no outing is planned. The session stays at the gate until explicit
    /// completion.
    var canCompleteMedicineCheck: Bool {
        guard let gate = assessmentGate,
              gate.hasDisplayedCurrentResult,
              plan.outing == nil
        else { return false }
        return true
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
        guard send(.startCompanion, gateLeaseChange: .invalidate) else {
            return false
        }
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

    /// Establishes the canonical gate before Capture has produced an identity.
    @discardableResult
    func beginMedicineCaptureAssessment() -> Bool {
        send(.beginMedicineCaptureAssessment, gateLeaseChange: .replace)
    }

    func retryMedicineRead() {
        guard send(.retryMedicineRead) else { return }
        recordReadStartedAndRun()
    }

    func chooseFromFrequentList() {
        let candidates = MedicineCandidate.demoFrequentlyUsed
        let leaseChange: GateLeaseChange = assessmentGate == nil
            ? .preserve
            : .invalidate
        guard send(
            .chooseFromFrequentList(candidates),
            gateLeaseChange: leaseChange
        ) else { return }
        // The read is being abandoned in favour of the list, so its result
        // must not arrive later and overwrite this choice.
        invalidatePendingRead()
    }

    /// Goes back to reading when none of the offered candidates match.
    func retakeMedicinePhoto() {
        guard send(.retakeMedicinePhoto, gateLeaseChange: .invalidate) else {
            return
        }
        recordReadStartedAndRun()
    }

    func confirmMedicine(_ candidate: MedicineCandidate) {
        guard case .awaitingMedicineConfirmation = state,
              send(.confirmMedicine(candidate), gateLeaseChange: .replace)
        else {
            return
        }
        // Candidate selection carries no canonical medicine identity and writes
        // no care record. A later validated canonical result owns both the name
        // and the request ID used for `medicineConfirmed`.
        // Any pending read is abandoned: a confirmation is a decision, and a
        // result that was in flight when it was made must not land afterwards
        // and reopen a step the person has already left.
        invalidatePendingRead()
    }

    /// Goes back to the candidate list to choose a different medicine.
    func reconsiderMedicineChoice() {
        guard send(
            .reconsiderMedicineChoice,
            gateLeaseChange: .invalidate
        ) else { return }
    }

    func approachStop() {
        guard send(.approachStop) else { return }
    }

    func arriveSafely() {
        guard send(.arriveSafely, gateLeaseChange: .invalidate) else { return }
        records.append(.companionFinished(.arrivedSafely))
    }

    func endEarly() {
        guard send(.endEarly, gateLeaseChange: .invalidate) else { return }
        // The session is over; nothing from the abandoned read may land after
        // it and reopen a step the person has already left.
        invalidatePendingRead()
        records.append(.companionFinished(.endedEarly))
    }

    // MARK: - Medicine assessment

    /// Applies a lease-bound canonical update from the environment-owned runner.
    /// A valid result records canonical identity here; display remains separate.
    func applyAssessmentStateUpdate(_ update: MedicineAssessmentStateUpdate) {
        guard let lease = currentAssessmentGateLease else { return }
        applyAssessmentStateUpdate(update, forGateLease: lease)
    }

    func applyAssessmentStateUpdate(
        _ update: MedicineAssessmentStateUpdate,
        forGateLease lease: MedicineAssessmentGateLease
    ) {
        guard let gate = assessmentGate,
              currentAssessmentGateLease == lease
        else { return }
        guard send(.medicineAssessmentStateDidUpdate(update)) else { return }
        recordCanonicalMedicineConfirmation(
            from: update,
            origin: gate.preAssessmentSelection?.confirmed.origin
                ?? .readFromPhoto
        )
    }

    /// Acknowledges that the current canonical result was actually displayed.
    ///
    /// The caller supplies the identity of the result it actually displayed.
    /// The live gate must still hold that exact canonical request, with a valid
    /// lease and canonical medicine identity, before either the record or flow
    /// qualification changes.
    @discardableResult
    func medicineAssessmentResultDidDisplay(requestID: UUID) -> Bool {
        guard currentAssessmentGateLease != nil,
              let gate = assessmentGate,
              case let .result(presentation) = gate.assessmentState,
              presentation.response.requestID == requestID,
              let medicineName = canonicalMedicineName(from: presentation)
        else { return false }

        guard send(.medicineAssessmentResultDidDisplay(requestID)) else {
            return false
        }
        _ = careActionShownRecorder.recordDisplayed(
            requestID: requestID,
            medicineName: medicineName
        )
        return true
    }

    /// Explicitly leaves the assessment gate for a planned outing.
    @discardableResult
    func continueToOuting() -> Bool {
        guard canDepart else { return false }
        return send(.continueToOuting, gateLeaseChange: .invalidate)
    }

    /// Explicitly finishes a session whose plan contains medicine only.
    @discardableResult
    func completeMedicineCheck() -> Bool {
        guard canCompleteMedicineCheck,
              send(.completeMedicineCheck, gateLeaseChange: .invalidate)
        else { return false }
        records.append(.companionFinished(.completedMedicineCheck))
        return true
    }

    func installAssessmentGateInvalidationHandler(
        _ handler: @escaping @MainActor (MedicineAssessmentGateLease) -> Void
    ) {
        precondition(assessmentGateInvalidationHandler == nil)
        assessmentGateInvalidationHandler = handler
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
    private func send(
        _ event: CompanionFlowEvent,
        gateLeaseChange: GateLeaseChange = .preserve
    ) -> Bool {
        guard let next = CompanionFlowReducer.nextState(from: state, on: event) else {
            return false
        }
        switch gateLeaseChange {
        case .preserve:
            break
        case .replace:
            invalidateAssessmentGateLease()
            currentAssessmentGateLease = MedicineAssessmentGateLease()
        case .invalidate:
            invalidateAssessmentGateLease()
        }
        state = next
        return true
    }

    private func invalidateAssessmentGateLease() {
        guard let lease = currentAssessmentGateLease else { return }
        currentAssessmentGateLease = nil
        assessmentGateInvalidationHandler?(lease)
    }

    private func recordCanonicalMedicineConfirmation(
        from update: MedicineAssessmentStateUpdate,
        origin: MedicineChoiceOrigin
    ) {
        guard case let .result(presentation) = update.state,
              let medicineName = canonicalMedicineName(from: presentation),
              recordedCanonicalMedicineRequestIDs.insert(
                presentation.response.requestID
              ).inserted
        else { return }

        records.append(
            .medicineConfirmed(
                medicineName: medicineName,
                origin: origin
            )
        )
    }

    private func canonicalMedicineName(
        from presentation: MedicineAssessmentPresentation
    ) -> String? {
        guard presentation.response.resolution.status == .resolved,
              let medicine = presentation.response.resolution.selectedMedicine,
              !medicine.canonicalName.trimmingCharacters(
            in: .whitespacesAndNewlines
              ).isEmpty
        else { return nil }
        return medicine.canonicalName
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
