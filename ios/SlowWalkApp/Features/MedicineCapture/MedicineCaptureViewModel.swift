import Combine
import Foundation
import SlowWalkClientCore
import UIKit

enum MedicineCaptureState: Equatable {
    case idle
    case requestingPermission
    case permissionDenied
    case ready
    case capturing
    case recognizing(generation: Int)
    case success([RecognizedTextObservation])
    case noTextFound
    case recognitionFailed(String)
    case cancelled
    case cameraUnavailable
}

enum MedicineAssessmentSubmissionStatus: Equatable {
    case none
    case submitted
    case failed(MedicineCaptureProcessingFailure)
}

@MainActor
final class MedicineCaptureViewModel: ObservableObject {
    @Published var state: MedicineCaptureState = .idle
    @Published private(set) var assessmentSubmissionStatus:
        MedicineAssessmentSubmissionStatus = .none

    let previewSource: CameraPreviewSource
    private let captureService: any CameraCaptureServicing
    private let processor: any MedicineCaptureProcessing
    private let onAssessmentSubmissionAccepted: @MainActor () -> Void

    private var activeCaptureID: UUID?
    private var activeSessionID: UUID?
    private var captureTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var processorCancellationTask: Task<Void, Never>?
    private var processorCancellationRequired = false
    private var processingGeneration: Int?
    private var acceptedHandoffGeneration: Int?
    private var acceptedHandoffWasDismissed = false
    private var currentGeneration = 0

    init(
        processor: any MedicineCaptureProcessing,
        previewSource: CameraPreviewSource = CameraPreviewSource(),
        captureService: (any CameraCaptureServicing)? = nil,
        onAssessmentSubmissionAccepted: @escaping @MainActor () -> Void = {}
    ) {
        self.processor = processor
        self.previewSource = previewSource
        self.captureService = captureService
            ?? previewSource.makeCaptureService()
        self.onAssessmentSubmissionAccepted =
            onAssessmentSubmissionAccepted
    }

    convenience init(
        recognizer: any MedicineTextRecognizing,
        previewSource: CameraPreviewSource = CameraPreviewSource(),
        captureService: (any CameraCaptureServicing)? = nil
    ) {
        self.init(
            processor: MedicineCaptureStandaloneOCRProcessor(
                recognizer: recognizer
            ),
            previewSource: previewSource,
            captureService: captureService,
            onAssessmentSubmissionAccepted: {}
        )
    }

    // MARK: - Session

    func startSession() async throws {
        let sessionID = UUID()
        activeSessionID = sessionID

        do {
            try Task.checkCancellation()
            try await captureService.start(sessionID: sessionID)
            try Task.checkCancellation()
        } catch {
            if activeSessionID == sessionID {
                activeSessionID = nil
            }
            await captureService.stop(sessionID: sessionID)
            throw error
        }

        guard activeSessionID == sessionID else {
            await captureService.stop(sessionID: sessionID)
            return
        }
        previewSource.createPreviewLayer(sessionID: sessionID)
        state = .ready
    }

    // MARK: - Camera capture

    func capturePhoto() {
        let replacedRequestID = activeCaptureID
        activeCaptureID = nil
        captureTask?.cancel()
        captureTask = nil
        _ = beginProcessingCancellation()
        currentGeneration &+= 1
        let generation = currentGeneration
        let requestID = UUID()
        activeCaptureID = requestID
        let orientation = cameraOrientation()
        let capturedAt = Date()
        state = .capturing
        assessmentSubmissionStatus = .none

        if let replacedRequestID {
            Task {
                await captureService.cancelPendingCapture(
                    requestID: replacedRequestID
                )
            }
        }

        captureTask = Task { [weak self, captureService] in
            guard let self else { return }
            do {
                let result = try await captureService.capturePhoto(
                    requestID: requestID, orientation: orientation,
                    capturedAt: capturedAt
                )
                try Task.checkCancellation()
                guard self.activeCaptureID == requestID,
                      self.currentGeneration == generation
                else { return }
                self.activeCaptureID = nil
                self.startProcessing(
                    input: OCRImageInput(data: result.imageData,
                        orientation: result.orientation,
                        capturedAt: result.capturedAt),
                    generation: generation
                )
            } catch is CancellationError { return }
            catch CameraCaptureFailure.cancelled { return }
            catch {
                guard self.activeCaptureID == requestID,
                      self.currentGeneration == generation
                else { return }
                self.activeCaptureID = nil
                self.state = .recognitionFailed("capture_failed")
            }
        }
    }

    // MARK: - PhotosPicker input

    func capture(
        imageData: Data, orientation: OCRImageOrientation, capturedAt: Date
    ) {
        let replacedRequestID = activeCaptureID
        activeCaptureID = nil
        captureTask?.cancel()
        captureTask = nil
        _ = beginProcessingCancellation()
        currentGeneration &+= 1
        let gen = currentGeneration
        if let replacedRequestID {
            Task {
                await captureService.cancelPendingCapture(
                    requestID: replacedRequestID
                )
            }
        }
        startProcessing(
            input: OCRImageInput(data: imageData, orientation: orientation,
                capturedAt: capturedAt),
            generation: gen
        )
    }

    // MARK: - Cancel / Dismiss

    func cancel() {
        guard acceptedHandoffGeneration == nil,
              !acceptedHandoffWasDismissed
        else { return }
        let requestID = activeCaptureID
        activeCaptureID = nil
        currentGeneration &+= 1
        captureTask?.cancel()
        captureTask = nil
        _ = beginProcessingCancellation(forceInitialStop: true)
        state = .cancelled
        assessmentSubmissionStatus = .none
        if let requestID {
            Task {
                await captureService.cancelPendingCapture(
                    requestID: requestID
                )
            }
        }
    }

    func dismiss() async {
        let requestID = activeCaptureID
        let sessionID = activeSessionID
        activeCaptureID = nil
        activeSessionID = nil
        currentGeneration &+= 1
        captureTask?.cancel()
        captureTask = nil
        let preservesAcceptedAssessment = acceptedHandoffWasDismissed
            || (assessmentSubmissionStatus == .submitted
                && acceptedHandoffGeneration == processingGeneration)
        let processorCancellation: Task<Void, Never>?
        if preservesAcceptedAssessment {
            acceptedHandoffWasDismissed = true
            processingTask = nil
            processingGeneration = nil
            processorCancellationRequired = false
            processorCancellation = nil
        } else {
            processorCancellation = beginProcessingCancellation(
                forceInitialStop: true
            )
        }
        if let requestID {
            await captureService.cancelPendingCapture(
                requestID: requestID
            )
        }
        await processorCancellation?.value
        if let sessionID {
            await captureService.stop(sessionID: sessionID)
            previewSource.clearPreviewLayer(sessionID: sessionID)
        }
        state = .idle
        assessmentSubmissionStatus = .none
        acceptedHandoffGeneration = nil
    }

    func reset() {
        if acceptedHandoffWasDismissed {
            state = .idle
            assessmentSubmissionStatus = .none
            return
        }
        activeCaptureID = nil
        captureTask?.cancel()
        captureTask = nil
        _ = beginProcessingCancellation(forceInitialStop: true)
        currentGeneration &+= 1
        state = .idle
        assessmentSubmissionStatus = .none
    }

    // MARK: - Permission

    func requestPermission() { state = .requestingPermission }
    func setPermissionAuthorized(_ authorized: Bool) {
        state = authorized ? .ready : .permissionDenied
    }
    func setCameraUnavailable() { state = .cameraUnavailable }
    func setPhotoLoadingFailed() {
        state = .recognitionFailed("photo_loading_failed")
    }

    // MARK: - Processing

    private func startProcessing(
        input: OCRImageInput, generation: Int
    ) {
        state = .recognizing(generation: generation)
        assessmentSubmissionStatus = .none
        acceptedHandoffGeneration = nil
        acceptedHandoffWasDismissed = false
        processingGeneration = generation
        processorCancellationRequired = true
        let cancellationBarrier = processorCancellationTask
        processingTask = Task { @MainActor [processor, weak self] in
            await cancellationBarrier?.value
            guard !Task.isCancelled, let self else { return }
            do {
                let result = try await processor.process(input)
                try Task.checkCancellation()
                self.handleProcessingResult(
                    result, generation: generation
                )
            } catch is CancellationError {
                self.handleCancellation(generation: generation)
            } catch {
                self.handleProcessingFailure(
                    error: error, generation: generation
                )
            }
        }
    }

    private func handleProcessingResult(
        _ result: MedicineCaptureProcessingResult,
        generation: Int
    ) {
        guard generation == currentGeneration else { return }
        switch result {
        case .recognized(let observations):
            state = observations.isEmpty
                ? .noTextFound
                : .success(observations)
        case .submittedForAssessment:
            acceptedHandoffGeneration = generation
            assessmentSubmissionStatus = .submitted
            onAssessmentSubmissionAccepted()
        }
    }

    private func handleCancellation(generation: Int) {
        guard generation == currentGeneration else { return }
        if case .recognizing = state { state = .idle }
    }

    private func handleProcessingFailure(
        error: Error, generation: Int
    ) {
        guard generation == currentGeneration else { return }
        if let failure = error as? MedicineCaptureProcessingFailure {
            switch failure {
            case .cancelled:
                handleCancellation(generation: generation)
            case .assessmentGateUnavailable,
                 .assessmentSubmissionRejected:
                assessmentSubmissionStatus = .failed(failure)
            case .processingFailed:
                state = .recognitionFailed(failure.rawValue)
            }
            return
        }
        let reason: String
        if let f = error as? AppleVisionMedicineTextRecognizer.Failure {
            switch f {
            case .emptyImageData:   reason = "empty_image_data"
            case .recognitionFailed: reason = "vision_text_recognition_failed"
            }
        } else { reason = "vision_text_recognition_failed" }
        state = .recognitionFailed(reason)
    }

    // MARK: - Helpers

    @discardableResult
    private func beginProcessingCancellation(
        forceInitialStop: Bool = false
    ) -> Task<Void, Never>? {
        processingTask?.cancel()
        processingTask = nil
        if forceInitialStop, processorCancellationTask == nil {
            processorCancellationRequired = true
        }
        guard processingGeneration != nil || processorCancellationRequired else {
            return processorCancellationTask
        }
        processingGeneration = nil
        processorCancellationRequired = false
        let predecessor = processorCancellationTask
        let processor = processor
        let task = Task { @MainActor in
            await predecessor?.value
            await processor.cancel()
        }
        processorCancellationTask = task
        return task
    }

    private func cameraOrientation() -> OCRImageOrientation {
        switch UIDevice.current.orientation {
        case .portrait:            return .right
        case .portraitUpsideDown:  return .left
        case .landscapeLeft:       return .up
        case .landscapeRight:      return .down
        default:                   return .right
        }
    }
}
