@preconcurrency import AVFoundation
import Combine
import Foundation
import os
import SlowWalkClientCore
import UIKit

// MARK: - Types

struct CameraCaptureResult: Sendable {
    let imageData: Data
    let orientation: OCRImageOrientation
    let capturedAt: Date
}

enum CameraCaptureFailure: Error, Equatable {
    case noCameraAvailable
    case permissionDenied
    case configurationFailed
    case captureFailed
    case notReady
    case stopped
    case cancelled
}

// MARK: - Camera Capture Servicing

protocol CameraCaptureServicing: Sendable {
    func start(sessionID: UUID) async throws
    func stop(sessionID: UUID) async
    func capturePhoto(
        requestID: UUID, orientation: OCRImageOrientation, capturedAt: Date
    ) async throws -> CameraCaptureResult
    func cancelPendingCapture(requestID: UUID) async
}

// MARK: - Camera Preview Source

@MainActor
final class CameraPreviewSource: ObservableObject {
    @Published private(set) var previewLayer: AVCaptureVideoPreviewLayer?
    private let session: AVCaptureSession
    private var previewSessionID: UUID?

    init() { self.session = AVCaptureSession() }

    func createPreviewLayer(sessionID: UUID) {
        if previewSessionID == sessionID, previewLayer != nil { return }
        previewLayer?.session = nil
        previewLayer?.removeFromSuperlayer()

        previewSessionID = sessionID
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        previewLayer = layer
    }

    func clearPreviewLayer(sessionID: UUID) {
        guard previewSessionID == sessionID else { return }
        previewLayer?.session = nil
        previewLayer?.removeFromSuperlayer()
        previewLayer = nil
        previewSessionID = nil
    }

    func makeCaptureService(
        executionProbe: @escaping @Sendable () -> Void = {},
        stopProbe: @escaping @Sendable () -> Void = {}
    ) -> CameraCaptureService {
        CameraCaptureService.make(
            session: session,
            executionProbe: executionProbe, stopProbe: stopProbe
        )
    }
}

// MARK: - Photo Capture Delegate

@MainActor
final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {

    typealias Callback = @Sendable (
        _ settingsID: Int64, _ data: Data?, _ error: Error?
    ) -> Void

    private let box = OSAllocatedUnfairLock(
        initialState: Callback?.none
    )

    func setOnPhoto(_ callback: @escaping Callback) {
        box.withLock { $0 = callback }
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let settingsID = photo.resolvedSettings.uniqueID
        let data: Data?
        if error == nil { data = photo.fileDataRepresentation() }
        else { data = nil }
        let callback = box.withLock { $0 }
        callback?(settingsID, data, error)
    }
}

// MARK: - Camera Capture Service

actor CameraCaptureService {

    private let queue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    private struct PendingCapture {
        let requestID: UUID
        let settingsID: Int64
        let orientation: OCRImageOrientation
        let capturedAt: Date
        let continuation: CheckedContinuation<CameraCaptureResult, Error>
    }

    private let session: AVCaptureSession
    private let photoOutput: AVCapturePhotoOutput
    private let delegate: PhotoCaptureDelegate

    private var pendingCapture: PendingCapture?

    private var activeSessionID: UUID?
    private var isConfigured = false
    private var isStopped = false

    private let executionProbe: @Sendable () -> Void
    private let stopProbe: @Sendable () -> Void

    private init(
        session: AVCaptureSession, delegate: PhotoCaptureDelegate,
        executionProbe: @escaping @Sendable () -> Void,
        stopProbe: @escaping @Sendable () -> Void
    ) {
        self.session = session
        self.photoOutput = AVCapturePhotoOutput()
        self.delegate = delegate
        self.executionProbe = executionProbe
        self.stopProbe = stopProbe
        self.queue = DispatchSerialQueue(label: "slowwalk.camera.capture")
    }

    @MainActor
    fileprivate static func make(
        session: AVCaptureSession,
        executionProbe: @escaping @Sendable () -> Void,
        stopProbe: @escaping @Sendable () -> Void
    ) -> CameraCaptureService {
        let delegate = PhotoCaptureDelegate()
        let service = CameraCaptureService(
            session: session, delegate: delegate,
            executionProbe: executionProbe, stopProbe: stopProbe
        )
        delegate.setOnPhoto { [weak service] settingsID, data, error in
            guard let service else { return }
            Task { await service.didReceivePhoto(
                settingsID: settingsID, data: data, error: error
            ) }
        }
        return service
    }

    // MARK: - Permission

    static nonisolated var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    // MARK: - Session

    func start(sessionID: UUID) throws {
        activeSessionID = sessionID
        isStopped = false
        if session.isRunning { return }
        if !isConfigured { try configure(); isConfigured = true }
        executionProbe()
        session.startRunning()
    }

    func stop(sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        activeSessionID = nil
        isStopped = true
        if let pending = pendingCapture {
            pendingCapture = nil
            pending.continuation.resume(
                throwing: CameraCaptureFailure.stopped
            )
        }
        guard session.isRunning else { return }
        stopProbe()
        session.stopRunning()
    }

    // MARK: - Capture

    func capturePhoto(
        requestID: UUID, orientation: OCRImageOrientation, capturedAt: Date
    ) async throws -> CameraCaptureResult {
        try Task.checkCancellation()
        guard isConfigured, session.isRunning, !isStopped else {
            throw CameraCaptureFailure.notReady
        }
        if let old = pendingCapture {
            pendingCapture = nil
            old.continuation.resume(
                throwing: CameraCaptureFailure.cancelled
            )
        }
        let settings = AVCapturePhotoSettings()
        let settingsID = settings.uniqueID

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingCapture = PendingCapture(
                    requestID: requestID, settingsID: settingsID,
                    orientation: orientation, capturedAt: capturedAt,
                    continuation: continuation
                )
                guard !Task.isCancelled else {
                    pendingCapture = nil
                    continuation.resume(
                        throwing: CancellationError()
                    )
                    return
                }
                photoOutput.capturePhoto(
                    with: settings, delegate: delegate
                )
            }
        } onCancel: {
            Task {
                await self.cancelPendingCapture(requestID: requestID)
            }
        }
    }

    func cancelPendingCapture(requestID: UUID) {
        guard let pending = pendingCapture,
              pending.requestID == requestID
        else { return }
        pendingCapture = nil
        pending.continuation.resume(
            throwing: CameraCaptureFailure.cancelled
        )
    }

    // MARK: - Private

    private func configure() throws {
        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back
        ) else { throw CameraCaptureFailure.noCameraAvailable }
        session.beginConfiguration()
        guard let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input)
        else {
            session.commitConfiguration()
            throw CameraCaptureFailure.configurationFailed
        }
        session.addInput(input)
        guard session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            throw CameraCaptureFailure.configurationFailed
        }
        session.sessionPreset = .photo
        session.addOutput(photoOutput)
        session.commitConfiguration()
    }

    private func didReceivePhoto(
        settingsID: Int64, data: Data?, error: Error?
    ) {
        guard let pending = pendingCapture else { return }
        guard pending.settingsID == settingsID else { return }
        pendingCapture = nil

        if isStopped {
            pending.continuation.resume(
                throwing: CameraCaptureFailure.stopped
            )
            return
        }
        if let error {
            pending.continuation.resume(throwing: error)
            return
        }
        guard let data else {
            pending.continuation.resume(
                throwing: CameraCaptureFailure.captureFailed
            )
            return
        }
        pending.continuation.resume(
            returning: CameraCaptureResult(
                imageData: data, orientation: pending.orientation,
                capturedAt: pending.capturedAt
            )
        )
    }
}

extension CameraCaptureService: CameraCaptureServicing {}
