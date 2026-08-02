import Foundation
import os
import SlowWalkClientCore
import Vision

/// The synchronous Apple Vision operation used by the OCR adapter.
///
/// Keeping request creation and execution behind one platform boundary lets
/// the adapter own cancellation and result mapping without moving a Vision
/// object across an actor boundary.
nonisolated protocol VisionTextRequestPerforming: Sendable {
    func makeRequest() -> VNRecognizeTextRequest
    func perform(
        _ request: VNRecognizeTextRequest,
        data: Data,
        orientation: CGImagePropertyOrientation
    ) throws
}

nonisolated struct AppleVisionTextRequestPerformer:
    VisionTextRequestPerforming
{
    func makeRequest() -> VNRecognizeTextRequest {
        VNRecognizeTextRequest()
    }

    func perform(
        _ request: VNRecognizeTextRequest,
        data: Data,
        orientation: CGImagePropertyOrientation
    ) throws {
        let handler = VNImageRequestHandler(
            data: data,
            orientation: orientation
        )
        try handler.perform([request])
    }
}

/// Serializes every synchronous Vision text-recognition operation that uses
/// the same gate. The shared production instance prevents a newly constructed
/// or copied recognizer from overlapping an earlier Vision `perform(_:)`.
///
/// The actor manages permits and suspended waiters only. The blocking Vision
/// operation runs outside the actor, so cancellation can promptly remove a
/// waiter while another request is still executing.
nonisolated final class VisionTextRecognitionSingleFlightGate: Sendable {
    static let shared = VisionTextRecognitionSingleFlightGate()

    private struct Permit: Sendable {
        let identifier: UUID
    }

    private actor State {
        private struct Waiter {
            let continuation: CheckedContinuation<Permit, any Error>
        }

        private var activePermitID: UUID?
        private var waiterOrder: [UUID] = []
        private var waiters: [UUID: Waiter] = [:]

        func acquire(waiterID: UUID) async throws -> Permit {
            try Task.checkCancellation()

            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (
                        continuation:
                            CheckedContinuation<Permit, any Error>
                    ) in
                    if activePermitID == nil {
                        activePermitID = waiterID
                        continuation.resume(
                            returning: Permit(identifier: waiterID)
                        )
                    } else {
                        waiterOrder.append(waiterID)
                        waiters[waiterID] = Waiter(
                            continuation: continuation
                        )
                    }
                }
            } onCancel: {
                Task {
                    await self.cancelWaiter(waiterID)
                }
            }
        }

        func release(_ permit: Permit) {
            guard activePermitID == permit.identifier else { return }
            activePermitID = nil

            while !waiterOrder.isEmpty {
                let nextID = waiterOrder.removeFirst()
                guard let waiter = waiters.removeValue(forKey: nextID) else {
                    continue
                }
                activePermitID = nextID
                waiter.continuation.resume(
                    returning: Permit(identifier: nextID)
                )
                return
            }
        }

        private func cancelWaiter(_ waiterID: UUID) {
            guard let waiter = waiters.removeValue(forKey: waiterID) else {
                return
            }
            waiterOrder.removeAll { $0 == waiterID }
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    private let state = State()

    /// Runs one synchronous operation while holding the gate's only permit.
    /// Every exit after acquisition releases that exact permit once.
    func withPermit<Result: Sendable>(
        _ operation: @Sendable () throws -> Result
    ) async throws -> Result {
        let permit = try await state.acquire(waiterID: UUID())
        do {
            try Task.checkCancellation()
            let result = try operation()
            await state.release(permit)
            return result
        } catch {
            await state.release(permit)
            throw error
        }
    }
}

/// Owns the only reference shared between the recognition operation and its
/// task cancellation handler.
///
/// `VNRequest` is a non-Sendable Objective-C object. This controller is
/// `@unchecked Sendable` because every access to that reference and all state
/// transitions are serialized by `OSAllocatedUnfairLock`. The sole operation
/// performed outside the lock is the framework's thread-safe cancellation
/// entry point, while a strong local reference keeps the request alive.
nonisolated final class VisionRequestCancellationController:
    @unchecked Sendable
{
    enum RegistrationResult: Sendable, Equatable {
        case registered
        case cancelImmediately
        case rejectedAlreadyRegistered
    }

    private final class RequestReference: @unchecked Sendable {
        let request: VNRequest
        let identifier: ObjectIdentifier

        init(_ request: VNRequest) {
            self.request = request
            self.identifier = ObjectIdentifier(request)
        }
    }

    private enum State {
        case idle
        case registered(RequestReference)
        case cancelled
    }

    private let state = OSAllocatedUnfairLock(initialState: State.idle)

    @discardableResult
    func register(_ request: VNRequest) -> RegistrationResult {
        let request = RequestReference(request)
        let result = state.withLock { state -> RegistrationResult in
            switch state {
            case .idle:
                state = .registered(request)
                return .registered
            case .registered(let current):
                guard current.identifier != request.identifier else {
                    return .registered
                }
                return .rejectedAlreadyRegistered
            case .cancelled:
                return .cancelImmediately
            }
        }
        if result == .cancelImmediately {
            request.request.cancel()
        }
        return result
    }

    func cancel() {
        let request = state.withLock { state -> RequestReference? in
            switch state {
            case .idle:
                state = .cancelled
                return nil
            case .registered(let request):
                state = .cancelled
                return request
            case .cancelled:
                return nil
            }
        }
        request?.request.cancel()
    }

    func clear(_ request: VNRequest) {
        let identifier = ObjectIdentifier(request)
        state.withLock { state in
            guard case .registered(let current) = state,
                  current.identifier == identifier
            else { return }
            state = .idle
        }
    }

    /// Atomically chooses the winner between successful Vision completion and
    /// task cancellation, and unregisters the request when completion wins.
    func complete(
        _ request: VNRequest,
        taskIsCancelled: @Sendable () -> Bool
    ) -> Bool {
        let identifier = ObjectIdentifier(request)
        return state.withLock { state in
            guard case .registered(let current) = state,
                  current.identifier == identifier
            else {
                return false
            }
            guard !taskIsCancelled() else { return false }
            state = .idle
            return true
        }
    }

    var isCancelled: Bool {
        state.withLock { state in
            if case .cancelled = state { return true }
            return false
        }
    }
}

/// Apple Vision adapter that performs text recognition only.
///
/// It never resolves medicines, evaluates health risk, or persists the
/// original image bytes.
struct AppleVisionMedicineTextRecognizer: MedicineTextRecognizing {
    struct Configuration: Sendable, Equatable {
        enum LanguageCorrection: Sendable, Equatable {
            case automatic
            case disabled
        }

        var recognitionLevel: VNRequestTextRecognitionLevel = .accurate
        var languageCorrection: LanguageCorrection = .automatic
        var recognitionLanguages: [String] = []
        var minimumTextHeight: Float?

        static let `default` = Configuration()
    }

    enum Failure: Error, Equatable {
        case emptyImageData
        case recognitionFailed(String)
    }

    let configuration: Configuration
    private let performer: any VisionTextRequestPerforming
    private let singleFlightGate: VisionTextRecognitionSingleFlightGate

    init(
        configuration: Configuration = .default,
        performer: any VisionTextRequestPerforming =
            AppleVisionTextRequestPerformer(),
        singleFlightGate: VisionTextRecognitionSingleFlightGate = .shared
    ) {
        self.configuration = configuration
        self.performer = performer
        self.singleFlightGate = singleFlightGate
    }

    // Isolation boundaries (the app target compiles with default MainActor
    // isolation and complete strict concurrency):
    // - Entry (this function): caller isolation. Only cheap, non-blocking
    //   validation and cancellation-handler registration happen here.
    // - Vision work (`performRecognition`): `@concurrent`, so the blocking
    //   `VNImageRequestHandler.perform(_:)` runs on the cooperative thread
    //   pool instead of the caller's executor. Vision objects are created and
    //   used there. Only the lock-protected cancellation controller exposes
    //   the current request to the synchronous cancellation handler.
    // - Result: `[RecognizedTextObservation]` is Sendable and is the only
    //   value that crosses back to the caller.
    func recognizeText(
        in input: OCRImageInput
    ) async throws -> [SlowWalkClientCore.RecognizedTextObservation] {
        try Task.checkCancellation()
        guard !input.data.isEmpty else {
            throw Failure.emptyImageData
        }

        let cancellationController =
            VisionRequestCancellationController()
        return try await withTaskCancellationHandler {
            try await Self.performRecognition(
                data: input.data,
                orientation: input.orientation,
                configuration: configuration,
                observedAt: input.capturedAt,
                performer: performer,
                cancellationController: cancellationController,
                singleFlightGate: singleFlightGate
            )
        } onCancel: {
            cancellationController.cancel()
        }
    }

    @concurrent
    private static func performRecognition(
        data: Data,
        orientation: OCRImageOrientation,
        configuration: Configuration,
        observedAt: Date,
        performer: any VisionTextRequestPerforming,
        cancellationController: VisionRequestCancellationController,
        singleFlightGate: VisionTextRecognitionSingleFlightGate
    ) async throws -> [SlowWalkClientCore.RecognizedTextObservation] {
        try Task.checkCancellation()

        return try await singleFlightGate.withPermit {
            try Self.performRecognitionWhileHoldingPermit(
                data: data,
                orientation: orientation,
                configuration: configuration,
                observedAt: observedAt,
                performer: performer,
                cancellationController: cancellationController
            )
        }
    }

    nonisolated private static func performRecognitionWhileHoldingPermit(
        data: Data,
        orientation: OCRImageOrientation,
        configuration: Configuration,
        observedAt: Date,
        performer: any VisionTextRequestPerforming,
        cancellationController: VisionRequestCancellationController
    ) throws -> [SlowWalkClientCore.RecognizedTextObservation] {
        try Task.checkCancellation()
        let request = performer.makeRequest()
        request.recognitionLevel = configuration.recognitionLevel
        request.usesLanguageCorrection =
            configuration.languageCorrection == .automatic
        if !configuration.recognitionLanguages.isEmpty {
            request.recognitionLanguages = configuration.recognitionLanguages
        }
        if let minimumTextHeight = configuration.minimumTextHeight {
            request.minimumTextHeight = minimumTextHeight
        }

        switch cancellationController.register(request) {
        case .registered:
            break
        case .cancelImmediately:
            throw CancellationError()
        case .rejectedAlreadyRegistered:
            throw Failure.recognitionFailed(
                "vision_text_recognition_failed"
            )
        }
        defer { cancellationController.clear(request) }
        try Task.checkCancellation()

        do {
            try performer.perform(
                request,
                data: data,
                orientation: orientation.cgImageOrientation
            )
        } catch {
            if error is CancellationError {
                throw CancellationError()
            }
            if Task.isCancelled {
                throw CancellationError()
            }
            if isVisionRequestCancellation(error) {
                throw CancellationError()
            }
            if cancellationController.isCancelled {
                throw CancellationError()
            }

            // The failure reason must not carry `localizedDescription`:
            // Vision errors can embed image-derived or privacy-sensitive
            // details. A stable, content-free reason is sufficient.
            throw Failure.recognitionFailed(
                "vision_text_recognition_failed"
            )
        }

        // This is the success publication point. The lock makes cancellation
        // and completion a single-winner race, and the task state check keeps
        // a cancelled operation from reading or publishing Vision results.
        guard cancellationController.complete(
            request,
            taskIsCancelled: { Task.isCancelled }
        ) else {
            throw CancellationError()
        }

        return (request.results ?? []).map {
            // Vision does not expose a per-observation language, so
            // the platform-neutral contract field stays nil here.
            let candidate = $0.topCandidates(1).first
            return SlowWalkClientCore.RecognizedTextObservation(
                text: candidate?.string ?? "",
                confidence: Double(candidate?.confidence ?? 0),
                boundingRegion: OCRBoundingRegion(
                    x: Double($0.boundingBox.origin.x),
                    y: Double(1 - $0.boundingBox.origin.y
                        - $0.boundingBox.size.height),
                    width: Double($0.boundingBox.size.width),
                    height: Double($0.boundingBox.size.height)
                ),
                languageCode: nil,
                observedAt: observedAt
            )
        }
    }

    nonisolated private static func isVisionRequestCancellation(
        _ error: any Error
    ) -> Bool {
        let error = error as NSError
        return error.domain == VNErrorDomain
            && error.code == VNErrorCode.requestCancelled.rawValue
    }
}

extension OCRImageOrientation {
    nonisolated fileprivate var cgImageOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        }
    }
}
