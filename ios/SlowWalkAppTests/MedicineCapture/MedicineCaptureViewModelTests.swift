import AVFoundation
import Combine
import Foundation
import os
import SlowWalkClientCore
import Testing

@testable import SlowWalkApp

// MARK: - Fake Camera

private actor FakeCameraCaptureService: CameraCaptureServicing {
    struct Pending {
        let requestID: UUID
        let continuation: CheckedContinuation<CameraCaptureResult, Error>
    }
    private var pending: [UUID: Pending] = [:]
    private var captureStartedWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var pendingRequestIDWaiters: [CheckedContinuation<UUID, Never>] = []
    private var startWaiters: [(
        count: Int, continuation: CheckedContinuation<Void, Never>
    )] = []
    private var activeSessionID: UUID?
    private(set) var startIDs: [UUID] = []
    private(set) var stopIDs: [UUID] = []
    private(set) var cancelledIDs: [UUID] = []
    private(set) var captureIDs: [UUID] = []

    func start(sessionID: UUID) async throws {
        activeSessionID = sessionID
        startIDs.append(sessionID)
        let waiters = startWaiters.filter { $0.count <= startIDs.count }
        startWaiters.removeAll { $0.count <= startIDs.count }
        for waiter in waiters { waiter.continuation.resume() }
    }

    func stop(sessionID: UUID) async {
        guard activeSessionID == sessionID else { return }
        activeSessionID = nil
        stopIDs.append(sessionID)
    }

    func currentSessionID() -> UUID? { activeSessionID }

    func waitUntilStarted() async { await waitUntilStartCount(1) }

    func waitUntilStartCount(_ count: Int) async {
        if startIDs.count >= count { return }
        await withCheckedContinuation {
            startWaiters.append((count: count, continuation: $0))
        }
    }

    func capturePhoto(
        requestID: UUID, orientation: OCRImageOrientation, capturedAt: Date
    ) async throws -> CameraCaptureResult {
        return try await withCheckedThrowingContinuation { continuation in
            captureIDs.append(requestID)
            pending[requestID] = Pending(
                requestID: requestID, continuation: continuation
            )
            let requestIDWaiters = pendingRequestIDWaiters
            pendingRequestIDWaiters.removeAll()
            for waiter in requestIDWaiters {
                waiter.resume(returning: requestID)
            }
            if let waiters = captureStartedWaiters.removeValue(
                forKey: requestID
            ) {
                for w in waiters { w.resume() }
            }
        }
    }

    func cancelPendingCapture(requestID: UUID) async {
        cancelledIDs.append(requestID)
        guard let req = pending.removeValue(forKey: requestID) else { return }
        req.continuation.resume(throwing: CameraCaptureFailure.cancelled)
    }

    func waitUntilCaptureStarted(requestID: UUID) async {
        if pending[requestID] != nil { return }
        await withCheckedContinuation { cont in
            captureStartedWaiters[requestID, default: []].append(cont)
        }
    }

    func hasPendingCapture(requestID: UUID) -> Bool {
        pending[requestID] != nil
    }

    func nextPendingRequestID() async -> UUID {
        if let requestID = pending.keys.first { return requestID }
        return await withCheckedContinuation {
            pendingRequestIDWaiters.append($0)
        }
    }

    func complete(requestID: UUID, data: Data) {
        guard let req = pending.removeValue(forKey: requestID) else { return }
        req.continuation.resume(
            returning: CameraCaptureResult(
                imageData: data, orientation: .up,
                capturedAt: Date(timeIntervalSince1970: 100)
            )
        )
    }
}

@MainActor
private final class ControllableCameraPermissionProvider:
    CameraPermissionProviding
{
    var authorizationState: AVAuthorizationStatus
    var isCameraAvailable: Bool
    private(set) var requestCount = 0
    private var result = false
    private let requestGate = CaptureGate()

    init(
        state: AVAuthorizationStatus,
        isCameraAvailable: Bool = true
    ) {
        authorizationState = state
        self.isCameraAvailable = isCameraAvailable
    }

    func requestAccess() async -> Bool {
        requestCount += 1
        await requestGate.wait()
        return result
    }

    func waitUntilRequested() async {
        await requestGate.waitUntilEntered()
    }

    func resolve(
        _ granted: Bool,
        state: AVAuthorizationStatus
    ) {
        authorizationState = state
        result = granted
        requestGate.open()
    }
}

// MARK: - Spy Recognizer

private final class SpyRecognizer: MedicineTextRecognizing, Sendable {
    private let _result:
        @Sendable (OCRImageInput) async throws -> [RecognizedTextObservation]
    private let callCountBox = OSAllocatedUnfairLock(initialState: 0)
    init(
        result: @escaping @Sendable (OCRImageInput) async throws ->
            [RecognizedTextObservation]
    ) { self._result = result }
    func recognizeText(in input: OCRImageInput) async throws ->
        [RecognizedTextObservation] {
        callCountBox.withLock { $0 += 1 }
        return try await _result(input)
    }
    var callCount: Int { callCountBox.withLock { $0 } }
}

@MainActor
private final class SpyCaptureProcessor: MedicineCaptureProcessing {
    private let processResult: @MainActor (OCRImageInput) async throws ->
        MedicineCaptureProcessingResult
    private let cancellation: @MainActor () async -> Void
    private(set) var inputs: [OCRImageInput] = []
    private(set) var cancelCallCount = 0

    init(
        processResult: @escaping @MainActor (OCRImageInput) async throws ->
            MedicineCaptureProcessingResult,
        cancellation: @escaping @MainActor () async -> Void = {}
    ) {
        self.processResult = processResult
        self.cancellation = cancellation
    }

    func process(
        _ input: OCRImageInput
    ) async throws -> MedicineCaptureProcessingResult {
        inputs.append(input)
        return try await processResult(input)
    }

    func cancel() async {
        cancelCallCount += 1
        await cancellation()
    }
}

// MARK: - Gate

private final class CaptureGate: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private struct State {
        var open = false; var entered = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var enterWaiters: [CheckedContinuation<Void, Never>] = []
    }
    func wait() async {
        lock.withLock { $0.entered = true }
        let cs = lock.withLock { s in
            let c = s.enterWaiters; s.enterWaiters = []; return c
        }
        for c in cs { c.resume() }
        if lock.withLock({ $0.open }) { return }
        await withCheckedContinuation { c in
            lock.withLock { s in
                if s.open { c.resume() } else { s.waiters.append(c) }
            }
        }
    }
    func waitUntilEntered() async {
        if lock.withLock({ $0.entered }) { return }
        await withCheckedContinuation { c in
            lock.withLock { s in
                if s.entered { c.resume() }
                else { s.enterWaiters.append(c) }
            }
        }
    }
    func open() {
        let cs = lock.withLock { s in
            s.open = true; let r = s.waiters; s.waiters = []; return r
        }
        for c in cs { c.resume() }
    }
}

// MARK: - Helpers

private nonisolated func makeObs(
    _ text: String = "aspirin"
) -> RecognizedTextObservation {
    RecognizedTextObservation(text: text, confidence: 1.0,
        boundingRegion: nil, languageCode: nil,
        observedAt: Date(timeIntervalSince1970: 100))
}

private func img(_ id: String = "img") -> Data { Data(id.utf8) }

@MainActor
private func waitForSubmission(
    _ viewModel: MedicineCaptureViewModel
) async -> Bool {
    for await status in viewModel.$assessmentSubmissionStatus.values {
        if status == .submitted { return true }
        if case .failed = status { return false }
    }
    return false
}

@MainActor
private func waitForRecognitionResult(
    _ viewModel: MedicineCaptureViewModel
) async -> MedicineCaptureState {
    for await state in viewModel.$state.values {
        switch state {
        case .success, .noTextFound, .recognitionFailed, .cancelled:
            return state
        default:
            continue
        }
    }
    return viewModel.state
}

// MARK: - Tests

@Suite("MedicineCaptureViewModel")
struct MedicineCaptureViewModelTests {

    @Test func standaloneProcessorCallsRecognizerExactlyOnce() async throws {
        let recognizer = SpyRecognizer { _ in [makeObs()] }
        let processor = MedicineCaptureStandaloneOCRProcessor(
            recognizer: recognizer
        )

        let result = try await processor.process(
            OCRImageInput(
                data: img(), orientation: .left,
                capturedAt: Date(timeIntervalSince1970: 100)
            )
        )

        #expect(result == .recognized([makeObs()]))
        #expect(recognizer.callCount == 1)
    }

    @Test func initialStateIsIdle() {
        let vm = MedicineCaptureViewModel(
            recognizer: SpyRecognizer { _ in [] }
        )
        #expect(vm.state == .idle)
    }

    @Test func photosPickerSuccess() async {
        let spy = SpyRecognizer { _ in [makeObs("阿司匹林")] }
        let vm = MedicineCaptureViewModel(recognizer: spy)
        vm.capture(imageData: img(), orientation: .up,
                   capturedAt: Date(timeIntervalSince1970: 100))
        while case .recognizing = vm.state { await Task.yield() }
        guard case .success(let obs) = vm.state else {
            Issue.record("expected .success"); return
        }
        #expect(obs.first?.text == "阿司匹林")
        #expect(spy.callCount == 1)
    }

    @Test func emptyObservationsGivesNoTextFound() async {
        let spy = SpyRecognizer { _ in [] }
        let vm = MedicineCaptureViewModel(recognizer: spy)
        vm.capture(imageData: img(), orientation: .up,
                   capturedAt: Date(timeIntervalSince1970: 100))
        while case .recognizing = vm.state { await Task.yield() }
        #expect(vm.state == .noTextFound)
        #expect(spy.callCount == 1)
    }

    @Test func photosPickerInputUsesProcessingContractWithoutCaptureSuccess()
        async
    {
        let processor = SpyCaptureProcessor { _ in
            .submittedForAssessment
        }
        let vm = MedicineCaptureViewModel(processor: processor)
        let input = OCRImageInput(
            data: img("photo"), orientation: .downMirrored,
            capturedAt: Date(timeIntervalSince1970: 321)
        )

        vm.capture(
            imageData: input.data,
            orientation: input.orientation,
            capturedAt: input.capturedAt
        )
        #expect(await waitForSubmission(vm))

        #expect(processor.inputs == [input])
        #expect(vm.assessmentSubmissionStatus == .submitted)
        guard case .recognizing = vm.state else {
            Issue.record("assessment handoff must remain recognizing")
            return
        }
    }

    @Test func cameraInputUsesSameProcessingContractAndCaptureMetadata()
        async throws
    {
        let camera = FakeCameraCaptureService()
        let processor = SpyCaptureProcessor { _ in
            .submittedForAssessment
        }
        let vm = MedicineCaptureViewModel(
            processor: processor, captureService: camera
        )

        try await vm.startSession()
        vm.capturePhoto()
        let requestID = await camera.nextPendingRequestID()
        await camera.complete(requestID: requestID, data: img("camera"))
        #expect(await waitForSubmission(vm))

        #expect(processor.inputs == [
            OCRImageInput(
                data: img("camera"), orientation: .up,
                capturedAt: Date(timeIntervalSince1970: 100)
            ),
        ])
        #expect(vm.assessmentSubmissionStatus == .submitted)
        guard case .recognizing = vm.state else {
            Issue.record("assessment handoff must not publish OCR success")
            return
        }
    }

    @Test func repeatedCancelStopsProcessorOnceAndRejectsLateSubmission()
        async
    {
        let gate = CaptureGate()
        let cancellationGate = CaptureGate()
        let completionGate = CaptureGate()
        let processor = SpyCaptureProcessor(
            processResult: { _ in
                await gate.wait()
                completionGate.open()
                return .submittedForAssessment
            },
            cancellation: { await cancellationGate.wait() }
        )
        let vm = MedicineCaptureViewModel(processor: processor)
        vm.capture(
            imageData: img(), orientation: .up,
            capturedAt: Date(timeIntervalSince1970: 100)
        )
        await gate.waitUntilEntered()

        vm.cancel()
        vm.cancel()
        await cancellationGate.waitUntilEntered()
        cancellationGate.open()
        gate.open()
        await completionGate.wait()

        #expect(processor.cancelCallCount == 1)
        #expect(vm.state == .cancelled)
        #expect(vm.assessmentSubmissionStatus == .none)
    }

    @Test func dismissWaitsForProcessorCancellationAndIsRepeatable() async {
        let processGate = CaptureGate()
        let completionGate = CaptureGate()
        let cancellationGate = CaptureGate()
        let processor = SpyCaptureProcessor(
            processResult: { _ in
                await processGate.wait()
                completionGate.open()
                return .submittedForAssessment
            },
            cancellation: { await cancellationGate.wait() }
        )
        let vm = MedicineCaptureViewModel(processor: processor)
        vm.capture(
            imageData: img(), orientation: .up,
            capturedAt: Date(timeIntervalSince1970: 100)
        )
        await processGate.waitUntilEntered()

        let dismiss = Task { await vm.dismiss() }
        await cancellationGate.waitUntilEntered()
        guard case .recognizing = vm.state else {
            Issue.record("dismiss returned before processor cancellation")
            return
        }
        cancellationGate.open()
        await dismiss.value
        await vm.dismiss()
        processGate.open()
        await completionGate.wait()

        #expect(processor.cancelCallCount == 1)
        #expect(vm.state == .idle)
    }

    @Test func recognitionFailure() async {
        let vm = MedicineCaptureViewModel(recognizer: SpyRecognizer { _ in
            throw AppleVisionMedicineTextRecognizer.Failure
                .recognitionFailed("x")
        })
        vm.capture(imageData: img("bad"), orientation: .up,
                   capturedAt: Date(timeIntervalSince1970: 100))
        while case .recognizing = vm.state { await Task.yield() }
        #expect(vm.state == .recognitionFailed(
            "vision_text_recognition_failed"
        ))
    }

    @Test func explicitCancelTransitionsToCancelled() async {
        let gate = CaptureGate()
        let spy = SpyRecognizer { _ in
            await gate.wait()
            try Task.checkCancellation()
            return [makeObs()]
        }
        let vm = MedicineCaptureViewModel(recognizer: spy)
        vm.capture(imageData: img(), orientation: .up,
                   capturedAt: Date(timeIntervalSince1970: 100))
        await gate.waitUntilEntered()
        vm.cancel()
        #expect(vm.state == .cancelled)
        await gate.open()
        await Task.yield(); await Task.yield()
        #expect(vm.state == .cancelled)
        #expect(spy.callCount == 1)
    }

    @Test func supersededGenerationSilentlyDiscarded() async {
        let gate = CaptureGate()
        let firstImg = img("first")
        let spy = SpyRecognizer { input in
            if input.data == firstImg {
                await gate.wait()
                try Task.checkCancellation()
                return [makeObs("old")]
            }
            return [makeObs("new")]
        }
        let vm = MedicineCaptureViewModel(recognizer: spy)
        vm.capture(imageData: firstImg, orientation: .up,
                   capturedAt: Date(timeIntervalSince1970: 100))
        await gate.waitUntilEntered()
        vm.capture(imageData: img("second"), orientation: .up,
                   capturedAt: Date(timeIntervalSince1970: 200))
        while case .recognizing = vm.state { await Task.yield() }
        guard case .success(let obs) = vm.state else {
            Issue.record("expected .success"); return
        }
        #expect(obs.first?.text == "new")
        #expect(spy.callCount == 2)
        await gate.open()
        await Task.yield(); await Task.yield()
        guard case .success(let finalObs) = vm.state else {
            Issue.record("state was overwritten by stale generation"); return
        }
        #expect(finalObs.first?.text == "new")
    }

    @Test func oldErrorDoesNotOverwriteNewSuccess() async {
        let gate = CaptureGate()
        let firstImg = img("first")
        let spy = SpyRecognizer { input in
            if input.data == firstImg {
                await gate.wait()
                try Task.checkCancellation()
                throw AppleVisionMedicineTextRecognizer.Failure
                    .recognitionFailed("x")
            }
            return [makeObs("new-ok")]
        }
        let vm = MedicineCaptureViewModel(recognizer: spy)
        vm.capture(imageData: firstImg, orientation: .up,
                   capturedAt: Date(timeIntervalSince1970: 100))
        await gate.waitUntilEntered()
        vm.capture(imageData: img("second"), orientation: .up,
                   capturedAt: Date(timeIntervalSince1970: 200))
        while case .recognizing = vm.state { await Task.yield() }
        guard case .success = vm.state else {
            Issue.record("expected .success"); return
        }
        await gate.open(); await Task.yield(); await Task.yield()
        guard case .success(let obs) = vm.state else {
            Issue.record("stale error overwrote success"); return
        }
        #expect(obs.first?.text == "new-ok")
        #expect(spy.callCount == 2)
    }

    @Test func oldCancellationErrorDoesNotOverwriteNewState() async {
        let gate = CaptureGate()
        let firstImg = img("first")
        let spy = SpyRecognizer { input in
            if input.data == firstImg {
                await gate.wait()
                try Task.checkCancellation()
                return [makeObs("should-not-appear")]
            }
            return [makeObs("new-ok")]
        }
        let vm = MedicineCaptureViewModel(recognizer: spy)
        vm.capture(imageData: firstImg, orientation: .up,
                   capturedAt: Date(timeIntervalSince1970: 100))
        await gate.waitUntilEntered()
        vm.capture(imageData: img("second"), orientation: .up,
                   capturedAt: Date(timeIntervalSince1970: 200))
        while case .recognizing = vm.state { await Task.yield() }
        guard case .success = vm.state else {
            Issue.record("expected .success"); return
        }
        #expect(spy.callCount == 2)
        await gate.open(); await Task.yield(); await Task.yield()
        guard case .success(let obs) = vm.state else {
            Issue.record("stale cancellation overwrote success"); return
        }
        #expect(obs.first?.text == "new-ok")
    }

    @Test func resetToIdle() async {
        let vm = MedicineCaptureViewModel(
            recognizer: SpyRecognizer { _ in [makeObs()] }
        )
        vm.capture(imageData: img(), orientation: .up,
                   capturedAt: Date(timeIntervalSince1970: 100))
        while case .recognizing = vm.state { await Task.yield() }
        guard case .success = vm.state else { return }
        vm.reset()
        #expect(vm.state == .idle)
    }

    @Test func cancelFromIdle() {
        let vm = MedicineCaptureViewModel(
            recognizer: SpyRecognizer { _ in [] }
        )
        vm.cancel()
        #expect(vm.state == .cancelled)
    }

    // MARK: - Camera cancel prevents late photo from starting OCR

    @Test func fakeCancelledCaptureDoesNotDeliverResult() async {
        let fake = FakeCameraCaptureService()
        let spy = SpyRecognizer { _ in [makeObs("ocr")] }
        let vm = MedicineCaptureViewModel(
            recognizer: spy, captureService: fake
        )
        let reqA = UUID()
        let taskA = Task {
            try await fake.capturePhoto(
                requestID: reqA, orientation: .up, capturedAt: Date()
            )
        }
        await fake.waitUntilCaptureStarted(requestID: reqA)
        await fake.cancelPendingCapture(requestID: reqA)
        _ = await taskA.result
        // Late photo must not start OCR.
        await fake.complete(requestID: reqA, data: img("late-photo"))
        await Task.yield(); await Task.yield()
        #expect(spy.callCount == 0)
    }

    // MARK: - Cancel A, start B

    @Test func cancelAStartBLateAResultDoesNotCompleteB() async {
        let fake = FakeCameraCaptureService()
        let gate = CaptureGate()
        let spy = SpyRecognizer { _ in
            await gate.wait()
            try Task.checkCancellation()
            return [makeObs("ocr-result")]
        }
        let vm = MedicineCaptureViewModel(
            recognizer: spy, captureService: fake
        )
        vm.capture(imageData: img("from-A"), orientation: .up,
                   capturedAt: Date(timeIntervalSince1970: 100))
        await gate.waitUntilEntered()
        vm.cancel()
        #expect(vm.state == .cancelled)
        vm.capture(imageData: img("from-B"), orientation: .up,
                   capturedAt: Date(timeIntervalSince1970: 200))
        await gate.open()
        await Task.yield(); await Task.yield()
        while case .recognizing = vm.state { await Task.yield() }
        guard case .success = vm.state else {
            Issue.record("expected .success for B, got \(vm.state)"); return
        }
        #expect(spy.callCount == 2)
    }

    // MARK: - Old cancel request does not cancel new capture

    @Test func oldCancelRequestDoesNotCancelNewCapture() async {
        let fake = FakeCameraCaptureService()
        let requestA = UUID()
        let requestB = UUID()
        let taskA = Task {
            try await fake.capturePhoto(
                requestID: requestA, orientation: .up, capturedAt: Date()
            )
        }
        await fake.waitUntilCaptureStarted(requestID: requestA)
        await fake.cancelPendingCapture(requestID: requestA)
        _ = await taskA.result
        let taskB = Task {
            try await fake.capturePhoto(
                requestID: requestB, orientation: .up, capturedAt: Date()
            )
        }
        await fake.waitUntilCaptureStarted(requestID: requestB)
        // Late cancel of old request ID.
        await fake.cancelPendingCapture(requestID: requestA)
        #expect(await fake.hasPendingCapture(requestID: requestB))
        await fake.complete(requestID: requestB, data: Data("B".utf8))
        switch await taskB.result {
        case .success(let result):
            #expect(result.imageData == Data("B".utf8))
        case .failure(let error):
            Issue.record("B must not be cancelled: \(error)")
        }
    }

    // MARK: - Dismiss prevents late photo from starting OCR

    @Test func dismissDropsInFlightOCRResult() async {
        let gate = CaptureGate()
        let spy = SpyRecognizer { _ in
            await gate.wait()
            try Task.checkCancellation()
            return [makeObs("late")]
        }
        let vm = MedicineCaptureViewModel(recognizer: spy)
        vm.capture(imageData: img(), orientation: .up,
                   capturedAt: Date(timeIntervalSince1970: 100))
        await gate.waitUntilEntered()
        await vm.dismiss()
        #expect(vm.state == .idle)
        await gate.open()
        await Task.yield(); await Task.yield()
        #expect(vm.state == .idle)
        #expect(spy.callCount == 1)
    }

    // MARK: - Old session stop does not stop new session

    @Test func oldSessionStopDoesNotStopNewSession() async throws {
        let fake = FakeCameraCaptureService()
        let sessionA = UUID()
        let sessionB = UUID()
        try await fake.start(sessionID: sessionA)
        try await fake.start(sessionID: sessionB)
        await fake.stop(sessionID: sessionA)
        #expect(await fake.currentSessionID() == sessionB)
        #expect(await fake.stopIDs.isEmpty)
    }

    // MARK: - Superseded image input drops old OCR result

    @Test func supersededImageInputBeforeProcessingOnlyRunsLatestOCR() async {
        let spy = SpyRecognizer { _ in [makeObs("latest")] }
        let vm = MedicineCaptureViewModel(recognizer: spy)
        vm.capture(imageData: img("first"), orientation: .up,
                   capturedAt: Date(timeIntervalSince1970: 100))
        vm.capture(imageData: img("second"), orientation: .up,
                   capturedAt: Date(timeIntervalSince1970: 200))
        while case .recognizing = vm.state { await Task.yield() }
        guard case .success = vm.state else { return }
        #expect(spy.callCount == 1)
    }

    // MARK: - Dismiss drops in-flight OCR result

    @Test func fakeCancellationDiscardsPendingCaptureResult() async {
        let fake = FakeCameraCaptureService()
        let spy = SpyRecognizer { _ in [makeObs("ocr")] }
        let vm = MedicineCaptureViewModel(
            recognizer: spy, captureService: fake
        )
        let req = UUID()
        let task = Task {
            try await fake.capturePhoto(
                requestID: req, orientation: .up, capturedAt: Date()
            )
        }
        await fake.waitUntilCaptureStarted(requestID: req)
        await fake.cancelPendingCapture(requestID: req)
        _ = await task.result
        await Task.yield(); await Task.yield()
        #expect(spy.callCount == 0)
    }

    // MARK: - Device demo hardening

    @Test func notDeterminedRapidTapRequestsOnceAndStartsOnce() async {
        let permission = ControllableCameraPermissionProvider(
            state: .notDetermined
        )
        let camera = FakeCameraCaptureService()
        let vm = MedicineCaptureViewModel(
            recognizer: SpyRecognizer { _ in [] },
            captureService: camera,
            permissionProvider: permission
        )
        #expect(vm.beginCameraPresentation())
        #expect(vm.beginCameraPresentation() == false)
        await permission.waitUntilRequested()
        #expect(permission.requestCount == 1)
        #expect(vm.state == .requestingPermission)
        permission.resolve(true, state: .authorized)
        await camera.waitUntilStarted()
        #expect(await camera.startIDs.count == 1)
        #expect(vm.state == .ready)
    }

    @Test func authorizedCameraDoesNotReopenAndRapidShutterSubmitsOnce()
        async throws
    {
        let permission = ControllableCameraPermissionProvider(
            state: .authorized
        )
        let camera = FakeCameraCaptureService()
        let recognizer = SpyRecognizer { _ in [makeObs()] }
        let vm = MedicineCaptureViewModel(
            recognizer: recognizer,
            captureService: camera,
            permissionProvider: permission
        )
        #expect(vm.beginCameraPresentation())
        #expect(vm.beginCameraPresentation() == false)
        await camera.waitUntilStarted()
        #expect(permission.requestCount == 0)
        #expect(await camera.startIDs.count == 1)
        #expect(vm.state == .ready)
        await vm.appDidEnterBackground()
        #expect(await camera.stopIDs.count == 1)
        vm.appDidBecomeActive()
        #expect(await camera.startIDs.count == 1)
        #expect(vm.beginCameraPresentation())
        await camera.waitUntilStartCount(2)
        vm.capturePhoto()
        vm.capturePhoto()
        let requestID = await camera.nextPendingRequestID()
        #expect(await camera.captureIDs == [requestID])
        await camera.complete(requestID: requestID, data: img("camera"))
        _ = await waitForRecognitionResult(vm)
        #expect(recognizer.callCount == 1)
    }

    @Test func blockedCameraStatesNeverRequestOrStartAndKeepPhotos() async {
        let scenarios: [(
            authorization: AVAuthorizationStatus,
            available: Bool,
            expected: MedicineCaptureState
        )] = [
            (.denied, true, .permissionDenied),
            (.restricted, true, .cameraRestricted),
            (.authorized, false, .cameraUnavailable),
        ]
        for scenario in scenarios {
            let permission = ControllableCameraPermissionProvider(
                state: scenario.authorization,
                isCameraAvailable: scenario.available
            )
            let camera = FakeCameraCaptureService()
            let vm = MedicineCaptureViewModel(
                recognizer: SpyRecognizer { _ in [] },
                captureService: camera,
                permissionProvider: permission
            )
            #expect(vm.beginCameraPresentation())
            #expect(vm.state == scenario.expected)
            #expect(vm.beginCameraPresentation() == false)
            #expect(permission.requestCount == 0)
            #expect(await camera.startIDs.isEmpty)
            #expect(vm.beginPhotosPickerPresentation())
            #expect(vm.beginPhotosPickerPresentation() == false)
            vm.endPhotosPickerPresentation()
            if scenario.authorization == .denied {
                permission.authorizationState = .authorized
                vm.appDidBecomeActive()
                #expect(vm.state == .idle)
            }
        }
    }

    @Test func photoInputLockAndRetryUseDistinctLifecycles() async throws {
        let processGate = CaptureGate()
        let firstData = img("first")
        let processor = SpyCaptureProcessor { input in
            if input.data == firstData {
                await processGate.wait()
                throw MedicineCaptureProcessingFailure.processingFailed
            }
            return .recognized([makeObs()])
        }
        let vm = MedicineCaptureViewModel(processor: processor)
        let oldLoadID = try #require(vm.beginPhotoLoading())
        #expect(vm.submitLoadedPhoto(
            loadID: oldLoadID,
            imageData: firstData,
            orientation: .up,
            capturedAt: Date(timeIntervalSince1970: 100)
        ))
        #expect(vm.submitLoadedPhoto(
            loadID: oldLoadID,
            imageData: firstData,
            orientation: .up,
            capturedAt: Date(timeIntervalSince1970: 100)
        ) == false)
        await processGate.waitUntilEntered()
        #expect(vm.beginPhotosPickerPresentation() == false)
        #expect(vm.beginCameraPresentation() == false)
        vm.capturePhoto()
        #expect(processor.inputs.count == 1)
        processGate.open()
        #expect(await waitForRecognitionResult(vm)
            == .recognitionFailed("processing_failed"))
        vm.reset()
        let currentLoadID = try #require(vm.beginPhotoLoading())
        #expect(currentLoadID != oldLoadID)
        #expect(vm.submitLoadedPhoto(
            loadID: oldLoadID,
            imageData: img("stale"),
            orientation: .up,
            capturedAt: Date(timeIntervalSince1970: 100)
        ) == false)
        #expect(vm.submitLoadedPhoto(
            loadID: currentLoadID,
            imageData: img("current"),
            orientation: .up,
            capturedAt: Date(timeIntervalSince1970: 200)
        ))
        _ = await waitForRecognitionResult(vm)
        #expect(processor.inputs.map(\.data) == [firstData, img("current")])
    }

    @Test func backgroundKeepsOneProcessingAndAcceptedHandoffIsNotStopped()
        async throws
    {
        let processGate = CaptureGate()
        let processor = SpyCaptureProcessor { _ in
            await processGate.wait()
            return .submittedForAssessment
        }
        var acceptedCount = 0
        let vm = MedicineCaptureViewModel(
            processor: processor,
            onAssessmentSubmissionAccepted: { acceptedCount += 1 }
        )
        let loadID = try #require(vm.beginPhotoLoading())
        #expect(vm.submitLoadedPhoto(
            loadID: loadID,
            imageData: img("background"),
            orientation: .up,
            capturedAt: Date(timeIntervalSince1970: 100)
        ))
        await processGate.waitUntilEntered()
        await vm.appDidEnterBackground()
        guard case .recognizing = vm.state else {
            Issue.record("background must preserve processing")
            return
        }
        vm.appDidBecomeActive()
        #expect(vm.beginPhotosPickerPresentation() == false)
        #expect(processor.inputs.count == 1)
        #expect(processor.cancelCallCount == 0)
        processGate.open()
        #expect(await waitForSubmission(vm))
        await vm.dismiss()
        #expect(processor.inputs.count == 1)
        #expect(processor.cancelCallCount == 0)
        #expect(acceptedCount == 1)
    }
}
