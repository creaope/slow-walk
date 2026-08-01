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

@MainActor
final class MedicineCaptureViewModel: ObservableObject {
    @Published var state: MedicineCaptureState = .idle

    let previewSource: CameraPreviewSource
    private let captureService: any CameraCaptureServicing
    private let recognizer: any MedicineTextRecognizing

    private var activeCaptureID: UUID?
    private var activeSessionID: UUID?
    private var captureTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    private var currentGeneration = 0

    init(
        recognizer: any MedicineTextRecognizing,
        previewSource: CameraPreviewSource = CameraPreviewSource(),
        captureService: (any CameraCaptureServicing)? = nil
    ) {
        self.recognizer = recognizer
        self.previewSource = previewSource
        self.captureService = captureService
            ?? previewSource.makeCaptureService()
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
        captureTask?.cancel()
        recognitionTask?.cancel()
        currentGeneration &+= 1
        let generation = currentGeneration
        let requestID = UUID()
        activeCaptureID = requestID
        let orientation = cameraOrientation()
        let capturedAt = Date()
        state = .capturing

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
                self.startRecognition(
                    with: OCRImageInput(data: result.imageData,
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
        activeCaptureID = nil
        cancelPendingTasks()
        currentGeneration &+= 1
        let gen = currentGeneration
        startRecognition(
            with: OCRImageInput(data: imageData, orientation: orientation,
                capturedAt: capturedAt),
            generation: gen
        )
    }

    // MARK: - Cancel / Dismiss

    func cancel() {
        let requestID = activeCaptureID
        activeCaptureID = nil
        currentGeneration &+= 1
        captureTask?.cancel()
        captureTask = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        state = .cancelled
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
        recognitionTask?.cancel()
        recognitionTask = nil
        if let requestID {
            await captureService.cancelPendingCapture(
                requestID: requestID
            )
        }
        if let sessionID {
            await captureService.stop(sessionID: sessionID)
            previewSource.clearPreviewLayer(sessionID: sessionID)
        }
        state = .idle
    }

    func reset() {
        activeCaptureID = nil
        cancelPendingTasks()
        currentGeneration &+= 1
        state = .idle
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

    // MARK: - Recognition

    private func startRecognition(
        with input: OCRImageInput, generation: Int
    ) {
        state = .recognizing(generation: generation)
        recognitionTask = Task { [recognizer, weak self] in
            do {
                let obs = try await recognizer.recognizeText(in: input)
                try Task.checkCancellation()
                self?.handleRecognitionResult(
                    observations: obs, generation: generation
                )
            } catch is CancellationError {
                self?.handleCancellation(generation: generation)
            } catch {
                self?.handleRecognitionFailure(
                    error: error, generation: generation
                )
            }
        }
    }

    private func handleRecognitionResult(
        observations: [RecognizedTextObservation], generation: Int
    ) {
        guard generation == currentGeneration else { return }
        state = observations.isEmpty ? .noTextFound : .success(observations)
    }

    private func handleCancellation(generation: Int) {
        guard generation == currentGeneration else { return }
        if case .recognizing = state { state = .idle }
    }

    private func handleRecognitionFailure(
        error: Error, generation: Int
    ) {
        guard generation == currentGeneration else { return }
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

    private func cancelPendingTasks() {
        captureTask?.cancel()
        captureTask = nil
        recognitionTask?.cancel()
        recognitionTask = nil
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
