import Foundation
import SlowWalkAPIContracts
import SlowWalkDomain

/// Pure Swift orchestration from OCR input to canonical medicine view state.
///
/// It owns cancellation, response validation, candidate-confirmation context,
/// and observable state updates. It never retains image bytes in view state.
public actor MedicineAssessmentCoordinator {
    private struct OperationOutcome: Sendable {
        let state: MedicineAssessmentViewState
        let pendingConfirmation: PendingConfirmation?
    }

    private struct PendingConfirmation: Sendable {
        let request: MedicineAssessmentRequestDTO
        let candidateIDs: Set<String>
        let recognitionContext: MedicineRecognitionContext
        let expectedCanonicalMedicineID: String?
        let expectedCanonicalMedicineName: String?
    }

    public private(set) var state: MedicineAssessmentViewState = .idle

    private let recognitionRouter: any MedicineRecognitionRouting
    private let requestBuilder: any MedicineAssessmentRequestBuilding
    private let requester: any MedicineAssessmentRequesting
    private let confirmer: (any MedicineCandidateConfirming)?
    private let responseValidator: MedicineAssessmentResponseValidator
    private let clock: any Clock
    private let apiVersion: String

    private var activeTask: Task<OperationOutcome, Never>?
    private var generation: UInt64 = 0
    private var activeGeneration: UInt64?
    private var pendingConfirmation: PendingConfirmation?
    private var stateContinuations:
        [UUID: AsyncStream<MedicineAssessmentStateUpdate>.Continuation] = [:]

    public init(
        recognitionRouter: any MedicineRecognitionRouting,
        requestBuilder: any MedicineAssessmentRequestBuilding =
            MedicineAssessmentRequestBuilder(),
        requester: any MedicineAssessmentRequesting,
        confirmer: (any MedicineCandidateConfirming)? = nil,
        responseValidator: MedicineAssessmentResponseValidator = .init(),
        clock: any Clock,
        apiVersion: String = SlowWalkAPI.version
    ) {
        self.recognitionRouter = recognitionRouter
        self.requestBuilder = requestBuilder
        self.requester = requester
        self.confirmer = confirmer
        self.responseValidator = responseValidator
        self.clock = clock
        self.apiVersion = apiVersion
    }

    /// Compatibility initializer for existing on-device-only compositions.
    public init(
        recognizer: any MedicineTextRecognizing,
        mapper: MedicineRecognitionInputMapper,
        requestBuilder: any MedicineAssessmentRequestBuilding =
            MedicineAssessmentRequestBuilder(),
        requester: any MedicineAssessmentRequesting,
        confirmer: (any MedicineCandidateConfirming)? = nil,
        responseValidator: MedicineAssessmentResponseValidator = .init(),
        clock: any Clock,
        apiVersion: String = SlowWalkAPI.version
    ) {
        recognitionRouter = OnDeviceMedicineRecognitionRouter(
            recognizer: recognizer,
            mapper: mapper
        )
        self.requestBuilder = requestBuilder
        self.requester = requester
        self.confirmer = confirmer
        self.responseValidator = responseValidator
        self.clock = clock
        self.apiVersion = apiVersion
    }

    /// Starts an assessment from domain models used by an on-device client.
    ///
    /// DTO conversion stays inside ClientCore so an app composition root does
    /// not need to treat the local pipeline as an HTTP service.
    @discardableResult
    public func assess(
        imageInput: OCRImageInput,
        userProfile: UserHealthProfile,
        recentRecords: [MedicationRecord],
        requestID: UUID,
        mode: MedicineRecognitionMode = .remotePreferred
    ) async -> MedicineAssessmentViewState {
        await assess(
            imageInput: imageInput,
            userProfile: UserHealthProfileDTO(userProfile),
            recentRecords: recentRecords.map(MedicationRecordDTO.init),
            requestID: requestID,
            mode: mode
        )
    }

    /// State stream for a MainActor facade or another presentation consumer.
    /// The current value is yielded immediately; later updates are buffered so
    /// short recognizing/assessing transitions are not lost.
    public func stateUpdates()
        -> AsyncStream<MedicineAssessmentStateUpdate>
    {
        let id = UUID()
        let pair = AsyncStream<MedicineAssessmentStateUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        stateContinuations[id] = pair.continuation
        pair.continuation.yield(currentStateUpdate)
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStateContinuation(id) }
        }
        return pair.stream
    }

    public var currentStateUpdate: MedicineAssessmentStateUpdate {
        MedicineAssessmentStateUpdate(
            sequenceNumber: generation,
            state: state
        )
    }

    @discardableResult
    public func assess(
        imageInput: OCRImageInput,
        userProfile: UserHealthProfileDTO,
        recentRecords: [MedicationRecordDTO],
        requestID: UUID,
        mode: MedicineRecognitionMode = .remotePreferred
    ) async -> MedicineAssessmentViewState {
        beginOperation(with: .recognizing(startedAt: clock.now()))
        pendingConfirmation = nil
        let operationGeneration = generation

        let recognitionRouter = self.recognitionRouter
        let requestBuilder = self.requestBuilder
        let requester = self.requester
        let responseValidator = self.responseValidator
        let clock = self.clock
        let apiVersion = self.apiVersion

        let task = Task<OperationOutcome, Never> {
            do {
                try Task.checkCancellation()
                let routingOutcome = try await recognitionRouter.recognize(
                    imageInput: imageInput,
                    requestID: requestID,
                    mode: mode
                )
                try Task.checkCancellation()
                let recognitionInput = routingOutcome.recognitionInput

                guard !recognitionInput.recognizedTexts.isEmpty else {
                    return OperationOutcome(
                        state: .requiresMedicineConfirmation(
                            MedicineConfirmationRequirement(
                                reason: .noRecognizedText,
                                recognitionInput: recognitionInput,
                                response: nil,
                                recognitionContext:
                                    routingOutcome.recognitionContext
                            )
                        ),
                        pendingConfirmation: nil
                    )
                }

                let request = requestBuilder.makeRequest(
                    input: recognitionInput,
                    userProfile: userProfile,
                    recentRecords: recentRecords,
                    requestID: requestID,
                    apiVersion: apiVersion
                )
                try Task.checkCancellation()
                self.transition(
                    to: .assessing(startedAt: clock.now()),
                    generation: operationGeneration
                )
                let response = try await requester.assess(request: request)
                try Task.checkCancellation()
                try responseValidator.validate(response, for: request)

                guard Self.response(
                    response,
                    matchesExpectedIdentityFrom: routingOutcome
                ) else {
                    return OperationOutcome(
                        state: Self.unresolvedIdentityState(
                            recognitionInput: recognitionInput,
                            recognitionContext:
                                routingOutcome.recognitionContext
                        ),
                        pendingConfirmation: nil
                    )
                }

                let nextState = Self.viewState(
                    response: response,
                    recognitionInput: recognitionInput,
                    recognitionContext:
                        routingOutcome.recognitionContext
                )
                return OperationOutcome(
                    state: nextState,
                    pendingConfirmation: Self.pendingConfirmation(
                        for: nextState,
                        request: request,
                        recognitionContext:
                            routingOutcome.recognitionContext,
                        expectedCanonicalMedicineID:
                            routingOutcome.expectedCanonicalMedicineID,
                        expectedCanonicalMedicineName:
                            routingOutcome.expectedCanonicalMedicineName
                    )
                )
            } catch is CancellationError {
                return OperationOutcome(
                    state: .cancelled,
                    pendingConfirmation: nil
                )
            } catch let failure as OnlineMedicineRecognitionFailure {
                return OperationOutcome(
                    state: Self.viewState(
                        for: failure,
                        capturedAt: imageInput.capturedAt
                    ),
                    pendingConfirmation: nil
                )
            } catch {
                return OperationOutcome(
                    state: .failed(ClientFailureMapper.map(error)),
                    pendingConfirmation: nil
                )
            }
        }
        activeTask = task
        return await finish(task, generation: operationGeneration)
    }

    /// Confirms one candidate from the current confirmation requirement.
    @discardableResult
    public func confirmMedicine(
        candidateID: String
    ) async -> MedicineAssessmentViewState {
        guard let pendingConfirmation,
            pendingConfirmation.candidateIDs.contains(candidateID),
            let confirmer
        else {
            return state
        }

        beginOperation(with: .assessing(startedAt: clock.now()))
        let operationGeneration = generation
        let request = pendingConfirmation.request
        let responseValidator = self.responseValidator

        let task = Task<OperationOutcome, Never> {
            do {
                try Task.checkCancellation()
                let response = try await confirmer.confirmMedicine(
                    command: MedicineCandidateConfirmationCommand(
                        originalRequestID: request.requestID,
                        candidateID: candidateID
                    )
                )
                try Task.checkCancellation()
                try responseValidator.validate(response, for: request)
                guard response.resolution.selectedMedicine?.id == candidateID
                else {
                    throw MedicineAssessmentResponseValidationError
                        .invalidResolution
                }

                let routingOutcome = MedicineRecognitionRoutingOutcome(
                    recognitionInput: request.input,
                    recognitionContext:
                        pendingConfirmation.recognitionContext,
                    expectedCanonicalMedicineID:
                        pendingConfirmation.expectedCanonicalMedicineID,
                    expectedCanonicalMedicineName:
                        pendingConfirmation.expectedCanonicalMedicineName
                )
                guard Self.response(
                    response,
                    matchesExpectedIdentityFrom: routingOutcome
                ) else {
                    return OperationOutcome(
                        state: Self.unresolvedIdentityState(
                            recognitionInput: request.input,
                            recognitionContext:
                                pendingConfirmation.recognitionContext
                        ),
                        pendingConfirmation: nil
                    )
                }
                let nextState = Self.viewState(
                    response: response,
                    recognitionInput: request.input,
                    recognitionContext:
                        pendingConfirmation.recognitionContext
                )
                return OperationOutcome(
                    state: nextState,
                    pendingConfirmation: Self.pendingConfirmation(
                        for: nextState,
                        request: request,
                        recognitionContext:
                            pendingConfirmation.recognitionContext,
                        expectedCanonicalMedicineID:
                            pendingConfirmation.expectedCanonicalMedicineID,
                        expectedCanonicalMedicineName:
                            pendingConfirmation.expectedCanonicalMedicineName
                    )
                )
            } catch is CancellationError {
                return OperationOutcome(
                    state: .cancelled,
                    pendingConfirmation: nil
                )
            } catch {
                return OperationOutcome(
                    state: .failed(ClientFailureMapper.map(error)),
                    pendingConfirmation: nil
                )
            }
        }
        activeTask = task
        return await finish(task, generation: operationGeneration)
    }

    public func cancelCurrentAssessment() {
        activeTask?.cancel()
        activeTask = nil
        activeGeneration = nil
        pendingConfirmation = nil
        publish(.cancelled)
    }

    public func reset() {
        activeTask?.cancel()
        activeTask = nil
        activeGeneration = nil
        pendingConfirmation = nil
        generation += 1
        publish(.idle)
    }

    private func beginOperation(with initialState: MedicineAssessmentViewState) {
        activeTask?.cancel()
        generation += 1
        activeGeneration = generation
        publish(initialState)
    }

    private func finish(
        _ task: Task<OperationOutcome, Never>,
        generation operationGeneration: UInt64
    ) async -> MedicineAssessmentViewState {
        let outcome = await withTaskCancellationHandler(
            operation: { await task.value },
            onCancel: { task.cancel() }
        )
        if activeGeneration == operationGeneration {
            pendingConfirmation = outcome.pendingConfirmation
            publish(outcome.state)
            activeTask = nil
            activeGeneration = nil
        }
        return outcome.state
    }

    private func transition(
        to newState: MedicineAssessmentViewState,
        generation operationGeneration: UInt64
    ) {
        guard activeGeneration == operationGeneration else { return }
        publish(newState)
    }

    private func publish(_ newState: MedicineAssessmentViewState) {
        state = newState
        let update = currentStateUpdate
        for continuation in stateContinuations.values {
            continuation.yield(update)
        }
    }

    private func removeStateContinuation(_ id: UUID) {
        stateContinuations[id] = nil
    }

    private static func needsCandidateConfirmation(
        _ state: MedicineAssessmentViewState
    ) -> Bool {
        guard case .requiresMedicineConfirmation(let requirement) = state,
            let response = requirement.response
        else {
            return false
        }
        switch requirement.reason {
        case .ambiguousMedicine, .unresolvedMedicine:
            return !response.resolution.candidates.isEmpty
        case .noRecognizedText, .serverRequiresConfirmation:
            return false
        }
    }

    private static func pendingConfirmation(
        for state: MedicineAssessmentViewState,
        request: MedicineAssessmentRequestDTO,
        recognitionContext: MedicineRecognitionContext,
        expectedCanonicalMedicineID: String?,
        expectedCanonicalMedicineName: String?
    ) -> PendingConfirmation? {
        guard needsCandidateConfirmation(state),
              case .requiresMedicineConfirmation(let requirement) = state,
              let response = requirement.response
        else {
            return nil
        }
        return PendingConfirmation(
            request: request,
            candidateIDs: Set(
                response.resolution.candidates.map { $0.medicine.id }
            ),
            recognitionContext: recognitionContext,
            expectedCanonicalMedicineID: expectedCanonicalMedicineID,
            expectedCanonicalMedicineName: expectedCanonicalMedicineName
        )
    }

    private static func response(
        _ response: MedicineAssessmentResponseDTO,
        matchesExpectedIdentityFrom outcome:
            MedicineRecognitionRoutingOutcome
    ) -> Bool {
        let expectedID = outcome.expectedCanonicalMedicineID
        let expectedName = outcome.expectedCanonicalMedicineName
        guard outcome.source == .remote,
              expectedID != nil || expectedName != nil
        else {
            return true
        }
        guard let selectedMedicine =
            response.resolution.selectedMedicine
        else {
            return false
        }
        if let expectedID, selectedMedicine.id != expectedID {
            return false
        }
        if let expectedName,
           selectedMedicine.canonicalName != expectedName
        {
            return false
        }
        return true
    }

    private static func unresolvedIdentityState(
        recognitionInput: MedicineRecognitionInput,
        recognitionContext: MedicineRecognitionContext
    ) -> MedicineAssessmentViewState {
        .requiresMedicineConfirmation(
            MedicineConfirmationRequirement(
                reason: .unresolvedMedicine,
                recognitionInput: recognitionInput,
                response: nil,
                recognitionContext: recognitionContext
            )
        )
    }

    private static func viewState(
        for failure: OnlineMedicineRecognitionFailure,
        capturedAt: Date
    ) -> MedicineAssessmentViewState {
        let recognitionInput = MedicineRecognitionInput(
            recognizedTexts: [],
            capturedAt: capturedAt,
            languageCode: nil,
            rawConfidence: nil
        )
        switch failure {
        case .ambiguous:
            return .requiresMedicineConfirmation(
                MedicineConfirmationRequirement(
                    reason: .ambiguousMedicine,
                    recognitionInput: recognitionInput,
                    response: nil,
                    recognitionContext: .remote
                )
            )
        case .noCandidate:
            return .requiresMedicineConfirmation(
                MedicineConfirmationRequirement(
                    reason: .unresolvedMedicine,
                    recognitionInput: recognitionInput,
                    response: nil,
                    recognitionContext: .remote
                )
            )
        case .unreadable:
            return .requiresMedicineConfirmation(
                MedicineConfirmationRequirement(
                    reason: .noRecognizedText,
                    recognitionInput: recognitionInput,
                    response: nil,
                    recognitionContext: .remote
                )
            )
        case .offline, .timeout, .rateLimited, .serverUnavailable,
             .providerUnavailable, .invalidImage, .imageTooLarge,
             .invalidResponse:
            return .failed(ClientFailureMapper.map(failure))
        }
    }

    private static func viewState(
        response: MedicineAssessmentResponseDTO,
        recognitionInput: MedicineRecognitionInput,
        recognitionContext: MedicineRecognitionContext
    ) -> MedicineAssessmentViewState {
        if response.resolution.status == .ambiguous {
            return .requiresMedicineConfirmation(
                MedicineConfirmationRequirement(
                    reason: .ambiguousMedicine,
                    recognitionInput: recognitionInput,
                    response: response,
                    recognitionContext: recognitionContext
                )
            )
        }
        if response.resolution.status != .resolved {
            return .requiresMedicineConfirmation(
                MedicineConfirmationRequirement(
                    reason: .unresolvedMedicine,
                    recognitionInput: recognitionInput,
                    response: response,
                    recognitionContext: recognitionContext
                )
            )
        }
        if response.resolution.requiresUserConfirmation {
            return .requiresMedicineConfirmation(
                MedicineConfirmationRequirement(
                    reason: .serverRequiresConfirmation,
                    recognitionInput: recognitionInput,
                    response: response,
                    recognitionContext: recognitionContext
                )
            )
        }
        return .result(
            MedicineAssessmentPresentation(
                response: response,
                recognitionContext: recognitionContext
            )
        )
    }
}
