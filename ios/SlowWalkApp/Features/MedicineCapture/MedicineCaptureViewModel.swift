@preconcurrency import AVFoundation
import Combine
import Foundation
import SlowWalkClientCore
import UIKit

@MainActor
protocol CameraPermissionProviding: AnyObject {
    var authorizationState: AVAuthorizationStatus { get }
    var isCameraAvailable: Bool { get }
    func requestAccess() async -> Bool
}

@MainActor
final class SystemCameraPermissionProvider: CameraPermissionProviding {
    var authorizationState: AVAuthorizationStatus {
        CameraCaptureService.authorizationStatus
    }

    var isCameraAvailable: Bool {
        AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back
        ) != nil
    }

    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }
}

enum MedicineCaptureState: Equatable {
    case idle
    case requestingPermission
    case permissionDenied
    case cameraRestricted
    case startingCamera
    case ready
    case capturing
    case loadingPhoto(generation: Int)
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
    struct BackgroundCleanup: Sendable {
        fileprivate let captureRequestID: UUID?
        fileprivate let sessionID: UUID?
    }

    @Published var state: MedicineCaptureState = .idle
    @Published private(set) var assessmentSubmissionStatus:
        MedicineAssessmentSubmissionStatus = .none
    @Published private(set) var isCameraSessionStarted = false

    let previewSource: CameraPreviewSource
    private let captureService: any CameraCaptureServicing
    private let permissionProvider: any CameraPermissionProviding
    private let processor: any MedicineCaptureProcessing
    private let onAssessmentSubmissionAccepted: @MainActor () -> Void

    private var activeCaptureID: UUID?
    private var activeSessionID: UUID?
    private var activePhotoLoadID: UUID?
    private var isPhotosPickerPresented = false
    private var cameraPreparationTask: Task<Void, Never>?
    private var cameraPreparationGeneration = 0
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
        permissionProvider: (any CameraPermissionProviding)? = nil,
        onAssessmentSubmissionAccepted: @escaping @MainActor () -> Void = {}
    ) {
        self.processor = processor
        self.previewSource = previewSource
        self.captureService = captureService
            ?? previewSource.makeCaptureService()
        self.permissionProvider = permissionProvider
            ?? SystemCameraPermissionProvider()
        self.onAssessmentSubmissionAccepted =
            onAssessmentSubmissionAccepted
    }

    convenience init(
        recognizer: any MedicineTextRecognizing,
        previewSource: CameraPreviewSource = CameraPreviewSource(),
        captureService: (any CameraCaptureServicing)? = nil,
        permissionProvider: (any CameraPermissionProviding)? = nil
    ) {
        self.init(
            processor: MedicineCaptureStandaloneOCRProcessor(
                recognizer: recognizer
            ),
            previewSource: previewSource,
            captureService: captureService,
            permissionProvider: permissionProvider,
            onAssessmentSubmissionAccepted: {}
        )
    }

    // MARK: - Session

    func startSession(preparationGeneration: Int? = nil) async throws {
        guard activeSessionID == nil else { return }
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

        guard activeSessionID == sessionID,
              preparationGeneration.map(ownsCameraPreparation) ?? true
        else {
            await captureService.stop(sessionID: sessionID)
            return
        }
        previewSource.createPreviewLayer(sessionID: sessionID)
        isCameraSessionStarted = true
        state = .ready
    }

    @discardableResult
    func beginCameraPresentation() -> Bool {
        guard state == .idle,
              activeSessionID == nil,
              cameraPreparationTask == nil
        else { return false }

        guard permissionProvider.isCameraAvailable else {
            state = .cameraUnavailable
            return true
        }

        switch permissionProvider.authorizationState {
        case .notDetermined:
            beginPermissionRequest()
        case .authorized:
            beginAuthorizedCameraStart()
        case .denied:
            state = .permissionDenied
        case .restricted:
            state = .cameraRestricted
        @unknown default:
            state = .cameraUnavailable
        }
        return true
    }

    // MARK: - Camera capture

    func capturePhoto() {
        guard state == .ready,
              activeCaptureID == nil,
              activePhotoLoadID == nil,
              processingGeneration == nil
        else { return }

        currentGeneration &+= 1
        let generation = currentGeneration
        let requestID = UUID()
        activeCaptureID = requestID
        let orientation = cameraOrientation()
        let capturedAt = Date()
        state = .capturing
        assessmentSubmissionStatus = .none

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

    var canChoosePhoto: Bool {
        switch state {
        case .idle, .permissionDenied, .cameraRestricted,
             .cameraUnavailable, .ready:
            true
        case .requestingPermission, .startingCamera, .capturing,
             .loadingPhoto, .recognizing, .success, .noTextFound,
             .recognitionFailed, .cancelled:
            false
        }
    }

    @discardableResult
    func beginPhotosPickerPresentation() -> Bool {
        guard canChoosePhoto,
              !isPhotosPickerPresented,
              activePhotoLoadID == nil
        else { return false }
        isPhotosPickerPresented = true
        return true
    }

    func endPhotosPickerPresentation() { isPhotosPickerPresented = false }

    func beginPhotoLoading() -> UUID? {
        guard canChoosePhoto, activePhotoLoadID == nil else { return nil }
        isPhotosPickerPresented = false
        currentGeneration &+= 1
        let generation = currentGeneration
        let loadID = UUID()
        activePhotoLoadID = loadID
        state = .loadingPhoto(generation: generation)
        assessmentSubmissionStatus = .none
        return loadID
    }

    @discardableResult
    func submitLoadedPhoto(
        loadID: UUID,
        imageData: Data,
        orientation: OCRImageOrientation,
        capturedAt: Date
    ) -> Bool {
        guard activePhotoLoadID == loadID,
              case .loadingPhoto(let generation) = state,
              generation == currentGeneration
        else { return false }
        activePhotoLoadID = nil
        startProcessing(
            input: OCRImageInput(
                data: imageData,
                orientation: orientation,
                capturedAt: capturedAt
            ),
            generation: generation
        )
        return true
    }

    func photoLoadingFailed(loadID: UUID) {
        guard activePhotoLoadID == loadID,
              case .loadingPhoto(let generation) = state,
              generation == currentGeneration
        else { return }
        activePhotoLoadID = nil
        state = .recognitionFailed("photo_loading_failed")
    }

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
        invalidateCameraPreparation()
        isPhotosPickerPresented = false
        activePhotoLoadID = nil
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
        invalidateCameraPreparation()
        isPhotosPickerPresented = false
        activePhotoLoadID = nil
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
        isCameraSessionStarted = false
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
        invalidateCameraPreparation()
        isPhotosPickerPresented = false
        activePhotoLoadID = nil
        activeCaptureID = nil
        captureTask?.cancel()
        captureTask = nil
        _ = beginProcessingCancellation(forceInitialStop: true)
        currentGeneration &+= 1
        state = isCameraSessionStarted ? .ready : .idle
        assessmentSubmissionStatus = .none
    }

    // MARK: - Permission

    func appDidBecomeActive() {
        guard cameraPreparationTask == nil,
              activeSessionID == nil
        else { return }

        switch state {
        case .permissionDenied, .cameraRestricted, .cameraUnavailable:
            applyCurrentCameraAvailability()
        default:
            break
        }
    }

    func prepareForBackground() -> BackgroundCleanup {
        invalidateCameraPreparation()
        isPhotosPickerPresented = false

        let abandonsInput = activeCaptureID != nil
            || activePhotoLoadID != nil
        let requestID = activeCaptureID
        let sessionID = activeSessionID
        activeCaptureID = nil
        activePhotoLoadID = nil
        activeSessionID = nil
        captureTask?.cancel()
        captureTask = nil
        if abandonsInput {
            currentGeneration &+= 1
        }

        isCameraSessionStarted = false
        if let sessionID {
            previewSource.clearPreviewLayer(sessionID: sessionID)
        }

        switch state {
        case .requestingPermission, .startingCamera, .ready,
             .capturing, .loadingPhoto:
            state = .idle
        default:
            break
        }

        return BackgroundCleanup(
            captureRequestID: requestID,
            sessionID: sessionID
        )
    }

    func finishBackgroundCleanup(_ cleanup: BackgroundCleanup) async {
        if let requestID = cleanup.captureRequestID {
            await captureService.cancelPendingCapture(requestID: requestID)
        }
        if let sessionID = cleanup.sessionID {
            await captureService.stop(sessionID: sessionID)
        }
    }

    private func beginPermissionRequest() {
        let permissionProvider = permissionProvider
        cameraPreparationGeneration &+= 1
        let generation = cameraPreparationGeneration
        state = .requestingPermission
        cameraPreparationTask = Task { @MainActor [weak self] in
            let granted = await permissionProvider.requestAccess()
            guard let self,
                  self.ownsCameraPreparation(generation)
            else { return }

            guard granted else {
                self.applyCurrentCameraAvailability()
                self.finishCameraPreparation(generation)
                return
            }
            guard permissionProvider.isCameraAvailable else {
                self.state = .cameraUnavailable
                self.finishCameraPreparation(generation)
                return
            }
            self.state = .startingCamera
            await self.startAuthorizedCamera(generation: generation)
        }
    }

    private func beginAuthorizedCameraStart() {
        cameraPreparationGeneration &+= 1
        let generation = cameraPreparationGeneration
        state = .startingCamera
        cameraPreparationTask = Task { @MainActor [weak self] in
            await self?.startAuthorizedCamera(generation: generation)
        }
    }

    private func startAuthorizedCamera(generation: Int) async {
        guard ownsCameraPreparation(generation) else { return }
        do {
            try await startSession(preparationGeneration: generation)
            guard ownsCameraPreparation(generation) else { return }
        } catch is CancellationError {
            return
        } catch CameraCaptureFailure.permissionDenied {
            guard ownsCameraPreparation(generation) else { return }
            state = .permissionDenied
        } catch {
            guard ownsCameraPreparation(generation) else { return }
            state = .cameraUnavailable
        }
        finishCameraPreparation(generation)
    }

    private func ownsCameraPreparation(_ generation: Int) -> Bool {
        !Task.isCancelled
            && cameraPreparationGeneration == generation
            && cameraPreparationTask != nil
    }

    private func finishCameraPreparation(_ generation: Int) {
        guard ownsCameraPreparation(generation) else { return }
        cameraPreparationTask = nil
    }

    private func invalidateCameraPreparation() {
        cameraPreparationGeneration &+= 1
        cameraPreparationTask?.cancel()
        cameraPreparationTask = nil
    }

    private func applyCurrentCameraAvailability() {
        guard permissionProvider.isCameraAvailable else {
            state = .cameraUnavailable
            return
        }
        switch permissionProvider.authorizationState {
        case .notDetermined, .authorized:
            state = .idle
        case .denied:
            state = .permissionDenied
        case .restricted:
            state = .cameraRestricted
        @unknown default:
            state = .cameraUnavailable
        }
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
