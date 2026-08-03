import Foundation
import SlowWalkAPIContracts
import SlowWalkClientCore
import SlowWalkDomain

/// Owns the app's sole medicine assessment coordinator and serializes every
/// operation that can change its canonical generation.
@MainActor
final class MedicineAssessmentRunner {
    struct AssessmentInvocation {
        fileprivate let gateLease: MedicineAssessmentGateLease
        fileprivate let imageInput: OCRImageInput
        fileprivate let userProfile: UserHealthProfile
        fileprivate let recentRecords: [MedicationRecord]
    }

    struct ConfirmationInvocation {
        fileprivate let gateLease: MedicineAssessmentGateLease
        fileprivate let sourceContextID: ObjectIdentifier
        fileprivate let candidate: SlowWalkDomain.MedicineCandidate
        fileprivate let requestID: UUID
        fileprivate let expectedSourceGeneration: UInt64
        fileprivate let sourceUpdate: MedicineAssessmentStateUpdate
    }

    private final class AssessmentContext {
        let requestID: UUID
        let gateLease: MedicineAssessmentGateLease
        var expectedGeneration: UInt64?
        var confirmationSourceUpdate: MedicineAssessmentStateUpdate?

        init(
            requestID: UUID,
            gateLease: MedicineAssessmentGateLease,
            expectedGeneration: UInt64? = nil
        ) {
            self.requestID = requestID
            self.gateLease = gateLease
            self.expectedGeneration = expectedGeneration
        }
    }

    private final class StoppingBarrier {
        var task: Task<Void, Never>?
    }

    private final class StartAcceptance {
        private var result: Bool?
        private var continuation: CheckedContinuation<Bool, Never>?

        func wait() async -> Bool {
            if let result { return result }
            return await withCheckedContinuation { continuation in
                if let result {
                    continuation.resume(returning: result)
                } else {
                    self.continuation = continuation
                }
            }
        }

        func resolve(_ accepted: Bool) {
            guard result == nil else { return }
            result = accepted
            continuation?.resume(returning: accepted)
            continuation = nil
        }
    }

    private struct StartedAssessment {
        let acceptance: StartAcceptance
        let task: Task<Void, Never>
    }

    private let coordinator: MedicineAssessmentCoordinator
    private let session: CompanionSessionModel

    private var activeContext: AssessmentContext?
    private var lifecycleTail: Task<Void, Never>?
    private var stoppingBarrier: StoppingBarrier?
    private var updateConsumerTask: Task<Void, Never>?

    convenience init(
        session: CompanionSessionModel,
        recognizer: any MedicineTextRecognizing,
        mapper: MedicineRecognitionInputMapper,
        requester: any MedicineAssessmentRequesting,
        confirmer: (any MedicineCandidateConfirming)? = nil,
        clock: any SlowWalkDomain.Clock
    ) {
        self.init(
            session: session,
            coordinator: MedicineAssessmentCoordinator(
                recognizer: recognizer,
                mapper: mapper,
                requester: requester,
                confirmer: confirmer,
                clock: clock
            )
        )
    }

    init(
        session: CompanionSessionModel,
        coordinator: MedicineAssessmentCoordinator
    ) {
        self.session = session
        self.coordinator = coordinator
        installUpdateConsumer()
        session.installAssessmentGateInvalidationHandler { [weak self] lease in
            self?.requestStop(forInvalidatedGateLease: lease)
        }
    }

    deinit {
        activeContext = nil
        lifecycleTail?.cancel()
        updateConsumerTask?.cancel()
    }

    /// Starts a fresh assessment after the preceding lifecycle operation has
    /// completely exited and the coordinator has published a reset baseline.
    func makeAssessmentInvocation(
        imageInput: OCRImageInput,
        userProfile: UserHealthProfile,
        recentRecords: [MedicationRecord] = []
    ) -> AssessmentInvocation? {
        guard let gateLease = session.currentAssessmentGateLease,
              isCurrentAssessmentGate(gateLease)
        else { return nil }
        return AssessmentInvocation(
            gateLease: gateLease,
            imageInput: imageInput,
            userProfile: userProfile,
            recentRecords: recentRecords
        )
    }

    @discardableResult
    func start(_ invocation: AssessmentInvocation?) async -> Bool {
        guard let started = await beginAssessment(invocation) else {
            return false
        }
        let accepted = await started.acceptance.wait()
        await started.task.value
        return accepted
    }

    /// Returns as soon as the invocation owns the canonical generation. The
    /// assessment continues on `lifecycleTail` and remains owned by this runner.
    @discardableResult
    func submit(_ invocation: AssessmentInvocation?) async -> Bool {
        guard let started = await beginAssessment(invocation) else {
            return false
        }
        return await started.acceptance.wait()
    }

    private func beginAssessment(
        _ invocation: AssessmentInvocation?
    ) async -> StartedAssessment? {
        guard let invocation,
              isCurrentAssessmentGate(invocation.gateLease)
        else { return nil }
        await waitForStoppingBarrier()

        guard isCurrentAssessmentGate(invocation.gateLease) else {
            return nil
        }
        let context = AssessmentContext(
            requestID: UUID(),
            gateLease: invocation.gateLease
        )
        activeContext = context
        let predecessor = lifecycleTail
        predecessor?.cancel()
        let coordinator = coordinator
        let acceptance = StartAcceptance()

        let task = Task { @MainActor [weak self, coordinator] in
            defer { acceptance.resolve(false) }
            await predecessor?.value
            guard !Task.isCancelled,
                  self?.isActive(context, for: invocation.gateLease) == true
            else {
                return
            }

            await coordinator.reset()
            guard !Task.isCancelled,
                  self?.isActive(context, for: invocation.gateLease) == true
            else {
                return
            }

            let baseline = await coordinator.currentStateUpdate.sequenceNumber
            let (expectedGeneration, overflow) =
                baseline.addingReportingOverflow(1)
            guard !overflow,
                  !Task.isCancelled,
                  self?.isActive(context, for: invocation.gateLease) == true
            else {
                return
            }
            context.expectedGeneration = expectedGeneration
            guard self?.isActive(context, for: invocation.gateLease) == true else {
                return
            }

            acceptance.resolve(true)
            _ = await coordinator.assess(
                imageInput: invocation.imageInput,
                userProfile: invocation.userProfile,
                recentRecords: invocation.recentRecords,
                requestID: context.requestID
            )
        }
        lifecycleTail = task
        return StartedAssessment(acceptance: acceptance, task: task)
    }

    /// Confirms an exact candidate from the current canonical response.
    /// Confirmation preserves the coordinator's pending context and lets the
    /// coordinator itself open the next generation.
    func makeConfirmationInvocation(
        _ candidate: SlowWalkDomain.MedicineCandidate
    ) -> ConfirmationInvocation? {
        guard let sourceContext = activeContext,
              let expectedGeneration = sourceContext.expectedGeneration,
              let sourceUpdate = sourceContext.confirmationSourceUpdate,
              isActive(sourceContext, for: sourceContext.gateLease)
        else { return nil }
        return ConfirmationInvocation(
            gateLease: sourceContext.gateLease,
            sourceContextID: ObjectIdentifier(sourceContext),
            candidate: candidate,
            requestID: sourceContext.requestID,
            expectedSourceGeneration: expectedGeneration,
            sourceUpdate: sourceUpdate
        )
    }

    @discardableResult
    func confirmMedicine(
        _ invocation: ConfirmationInvocation?
    ) async -> Bool {
        guard let invocation else { return false }
        await waitForStoppingBarrier()

        guard isCurrent(invocation) else { return false }
        let predecessor = lifecycleTail
        await predecessor?.value
        guard isCurrent(invocation) else { return false }

        let baselineUpdate = await coordinator.currentStateUpdate
        guard isCurrent(invocation),
              baselineUpdate == invocation.sourceUpdate,
              baselineUpdate.sequenceNumber
                == invocation.expectedSourceGeneration,
              case .requiresMedicineConfirmation(let requirement) =
                baselineUpdate.state,
              Self.supportsCandidateConfirmation(requirement.reason),
              let response = requirement.response,
              response.requestID == invocation.requestID,
              response.resolution.candidates.contains(invocation.candidate)
        else {
            return false
        }

        let (confirmationGeneration, overflow) =
            baselineUpdate.sequenceNumber.addingReportingOverflow(1)
        guard !overflow else { return false }

        let confirmationContext = AssessmentContext(
            requestID: invocation.requestID,
            gateLease: invocation.gateLease,
            expectedGeneration: confirmationGeneration
        )
        guard isCurrent(invocation) else { return false }
        activeContext = confirmationContext
        let coordinator = coordinator
        let task = Task { @MainActor [weak self, coordinator] in
            await predecessor?.value
            guard !Task.isCancelled,
                  self?.isActive(
                    confirmationContext,
                    for: invocation.gateLease
                  ) == true
            else {
                return
            }
            _ = await coordinator.confirmMedicine(
                candidateID: invocation.candidate.medicine.id
            )
        }
        lifecycleTail = task
        await task.value
        return true
    }

    /// Invalidates delivery immediately, then joins and resets through one
    /// barrier shared by all concurrent callers.
    func stop() async {
        let (barrier, task) = beginStopping()
        await task.value
        clearStoppingBarrier(barrier)
    }

    private func beginStopping() -> (StoppingBarrier, Task<Void, Never>) {
        if let stoppingBarrier,
           let task = stoppingBarrier.task {
            return (stoppingBarrier, task)
        }
        activeContext = nil
        let predecessor = lifecycleTail
        predecessor?.cancel()
        let coordinator = coordinator
        let barrier = StoppingBarrier()
        let task = Task { @MainActor [coordinator] in
            await predecessor?.value
            await coordinator.reset()
        }
        barrier.task = task
        stoppingBarrier = barrier
        lifecycleTail = task
        return (barrier, task)
    }

    private func clearStoppingBarrier(_ barrier: StoppingBarrier) {
        if stoppingBarrier === barrier {
            stoppingBarrier = nil
        }
    }

    private func requestStop(
        forInvalidatedGateLease lease: MedicineAssessmentGateLease
    ) {
        guard activeContext?.gateLease == lease || activeContext == nil else {
            return
        }
        let (barrier, task) = beginStopping()
        Task { @MainActor [weak self] in
            await task.value
            self?.clearStoppingBarrier(barrier)
        }
    }

    private func waitForStoppingBarrier() async {
        while let task = stoppingBarrier?.task {
            await task.value
            if task.isCancelled {
                continue
            }
            break
        }
    }

    private func installUpdateConsumer() {
        let coordinator = coordinator
        updateConsumerTask = Task { @MainActor [weak self, coordinator] in
            let updates = await coordinator.stateUpdates()
            for await update in updates {
                guard !Task.isCancelled else { return }
                self?.consume(update)
            }
        }
    }

    private func consume(_ update: MedicineAssessmentStateUpdate) {
        guard let context = activeContext,
              let expectedGeneration = context.expectedGeneration,
              update.sequenceNumber == expectedGeneration,
              Self.isAssociated(update.state, with: context.requestID)
        else {
            return
        }
        if case .requiresMedicineConfirmation = update.state {
            context.confirmationSourceUpdate = update
        } else {
            context.confirmationSourceUpdate = nil
        }
        session.applyAssessmentStateUpdate(
            update,
            forGateLease: context.gateLease
        )
    }

    private func isCurrentAssessmentGate(
        _ lease: MedicineAssessmentGateLease
    ) -> Bool {
        guard case .awaitingMedicineAssessment = session.state else {
            return false
        }
        return session.currentAssessmentGateLease == lease
    }

    private func isActive(
        _ context: AssessmentContext,
        for lease: MedicineAssessmentGateLease
    ) -> Bool {
        activeContext === context && isCurrentAssessmentGate(lease)
    }

    private func isCurrent(_ invocation: ConfirmationInvocation) -> Bool {
        guard let context = activeContext else { return false }
        return ObjectIdentifier(context) == invocation.sourceContextID
            && context.requestID == invocation.requestID
            && context.expectedGeneration
                == invocation.expectedSourceGeneration
            && context.confirmationSourceUpdate == invocation.sourceUpdate
            && context.gateLease == invocation.gateLease
            && isCurrentAssessmentGate(invocation.gateLease)
    }

    private static func supportsCandidateConfirmation(
        _ reason: MedicineConfirmationReason
    ) -> Bool {
        switch reason {
        case .ambiguousMedicine, .unresolvedMedicine:
            true
        case .noRecognizedText, .serverRequiresConfirmation:
            false
        }
    }

    private static func isAssociated(
        _ state: MedicineAssessmentViewState,
        with requestID: UUID
    ) -> Bool {
        switch state {
        case .result(let presentation):
            presentation.response.requestID == requestID
        case .requiresMedicineConfirmation(let requirement):
            requirement.response?.requestID == nil
                || requirement.response?.requestID == requestID
        case .failed(let failure):
            failure.requestID == requestID
        case .idle, .recognizing, .assessing, .cancelled:
            true
        }
    }
}
