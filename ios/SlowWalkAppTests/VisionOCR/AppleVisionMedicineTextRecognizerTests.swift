import Foundation
import os
import SlowWalkClientCore
import Testing
import UIKit
import Vision
@preconcurrency import XCTest

@testable import SlowWalkApp

private let eventTimeout: TimeInterval = 2

nonisolated private protocol TestVisionWorkReleasing: Sendable {
    func releaseOutstandingWork()
}

nonisolated private final class ObservableTextRequest:
    VNRecognizeTextRequest,
    @unchecked Sendable
{
    private weak var observer: ControlledVisionTextRequestPerformer?

    init(observer: ControlledVisionTextRequestPerformer) {
        self.observer = observer
        super.init(completionHandler: nil)
    }

    override func cancel() {
        super.cancel()
        observer?.requestDidCancel(self)
    }
}

/// A deterministic implementation of the platform execution boundary.
/// Its blocking mode exits only when the request is cancelled or the test
/// explicitly resolves it, so no image-size or scheduler timing is involved.
private final class ControlledVisionTextRequestPerformer:
    @unchecked Sendable,
    VisionTextRequestPerforming,
    TestVisionWorkReleasing
{
    enum Behavior {
        case waitForResolution
        case succeed
        case fail(NSError)
        case failCancellationError
        case cancelCurrentTaskThenSucceed
    }

    private enum Resolution {
        case success
        case failure(NSError)
        case cancelled
    }

    private struct Snapshot {
        var makeRequestCount = 0
        var performCount = 0
        var performedOnMainThread: Bool?
        var cancellationCounts: [ObjectIdentifier: Int] = [:]
    }

    private let behavior: Behavior
    private let condition = NSCondition()
    private var resolution: Resolution?
    private let snapshot = OSAllocatedUnfairLock(
        initialState: Snapshot()
    )
    private let performStarted = XCTestExpectation(
        description: "Vision perform started"
    )

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func makeRequest() -> VNRecognizeTextRequest {
        snapshot.withLock { $0.makeRequestCount += 1 }
        return ObservableTextRequest(observer: self)
    }

    func perform(
        _ request: VNRecognizeTextRequest,
        data: Data,
        orientation: CGImagePropertyOrientation
    ) throws {
        snapshot.withLock { snapshot in
            snapshot.performCount += 1
            snapshot.performedOnMainThread = Thread.isMainThread
        }
        performStarted.fulfill()

        switch behavior {
        case .succeed:
            return
        case .fail(let error):
            throw error
        case .failCancellationError:
            throw CancellationError()
        case .cancelCurrentTaskThenSucceed:
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return
        case .waitForResolution:
            condition.lock()
            while resolution == nil {
                condition.wait()
            }
            let resolution = resolution
            condition.unlock()

            switch resolution {
            case .success:
                return
            case .failure(let error):
                throw error
            case .cancelled:
                throw NSError(
                    domain: VNErrorDomain,
                    code: VNErrorCode.requestCancelled.rawValue
                )
            case nil:
                preconditionFailure("resolution must be present")
            }
        }
    }

    func requestDidCancel(_ request: VNRequest) {
        let identifier = ObjectIdentifier(request)
        snapshot.withLock { snapshot in
            snapshot.cancellationCounts[identifier, default: 0] += 1
        }

        condition.lock()
        if resolution == nil {
            resolution = .cancelled
        }
        condition.broadcast()
        condition.unlock()
    }

    func finishSuccessfully() {
        resolve(.success)
    }

    func releaseOutstandingWork() {
        resolve(
            .failure(
                NSError(
                    domain: VNErrorDomain,
                    code: VNErrorCode.operationFailed.rawValue
                )
            )
        )
    }

    func waitUntilPerformStarted() async -> Bool {
        let result = await XCTWaiter.fulfillment(
            of: [performStarted],
            timeout: eventTimeout
        )
        return result == .completed
    }

    func cancellationCount(for request: VNRequest) -> Int {
        let identifier = ObjectIdentifier(request)
        return snapshot.withLock {
            $0.cancellationCounts[identifier, default: 0]
        }
    }

    var totalCancellationCount: Int {
        snapshot.withLock {
            $0.cancellationCounts.values.reduce(0, +)
        }
    }

    var makeRequestCount: Int {
        snapshot.withLock { $0.makeRequestCount }
    }

    var performCount: Int {
        snapshot.withLock { $0.performCount }
    }

    var performedOnMainThread: Bool? {
        snapshot.withLock { $0.performedOnMainThread }
    }

    private func resolve(_ newResolution: Resolution) {
        condition.lock()
        if resolution == nil {
            resolution = newResolution
        }
        condition.broadcast()
        condition.unlock()
    }
}

nonisolated private final class SequencedObservableTextRequest:
    VNRecognizeTextRequest,
    @unchecked Sendable
{
    private weak var observer: SequencedVisionTextRequestPerformer?

    init(observer: SequencedVisionTextRequestPerformer) {
        self.observer = observer
        super.init(completionHandler: nil)
    }

    override func cancel() {
        super.cancel()
        observer?.requestDidCancel(self)
    }
}

/// Multi-call deterministic performer used to prove cross-call serialization.
/// Request cancellation is only observed; each test separately decides when
/// the synchronous perform actually returns.
private final class SequencedVisionTextRequestPerformer:
    @unchecked Sendable,
    VisionTextRequestPerforming,
    TestVisionWorkReleasing
{
    enum Resolution {
        case success
        case failure(NSError)
        case cancellationError
        case requestCancelled
    }

    private struct Snapshot {
        var nextRequestIndex = 0
        var requestIndices: [ObjectIdentifier: Int] = [:]
        var activePerformCount = 0
        var maxConcurrentPerformCount = 0
        var entryOrder: [Int] = []
        var exitOrder: [Int] = []
        var cancellationCounts: [Int: Int] = [:]
    }

    private let expectedPerformCount: Int
    private let condition = NSCondition()
    private var resolutions: [Int: Resolution] = [:]
    private let snapshot = OSAllocatedUnfairLock(
        initialState: Snapshot()
    )
    private let performEntered: [XCTestExpectation]
    private let performExited: [XCTestExpectation]
    private let requestCancelObserved: [XCTestExpectation]

    init(expectedPerformCount: Int) {
        precondition(expectedPerformCount > 0)
        self.expectedPerformCount = expectedPerformCount
        self.performEntered = (0..<expectedPerformCount).map {
            XCTestExpectation(description: "perform \($0) entered")
        }
        self.performExited = (0..<expectedPerformCount).map {
            XCTestExpectation(description: "perform \($0) exited")
        }
        self.requestCancelObserved = (0..<expectedPerformCount).map {
            XCTestExpectation(description: "request \($0) cancelled")
        }
    }

    func makeRequest() -> VNRecognizeTextRequest {
        let request = SequencedObservableTextRequest(observer: self)
        let identifier = ObjectIdentifier(request)
        snapshot.withLock { snapshot in
            precondition(
                snapshot.nextRequestIndex < expectedPerformCount,
                "unexpected extra Vision request"
            )
            snapshot.requestIndices[identifier] = snapshot.nextRequestIndex
            snapshot.nextRequestIndex += 1
        }
        return request
    }

    func perform(
        _ request: VNRecognizeTextRequest,
        data: Data,
        orientation: CGImagePropertyOrientation
    ) throws {
        let identifier = ObjectIdentifier(request)
        let index = snapshot.withLock { snapshot -> Int in
            guard let index = snapshot.requestIndices[identifier] else {
                preconditionFailure("performed an unknown request")
            }
            snapshot.activePerformCount += 1
            snapshot.maxConcurrentPerformCount = max(
                snapshot.maxConcurrentPerformCount,
                snapshot.activePerformCount
            )
            snapshot.entryOrder.append(index)
            return index
        }
        performEntered[index].fulfill()

        defer {
            snapshot.withLock { snapshot in
                snapshot.activePerformCount -= 1
                snapshot.exitOrder.append(index)
            }
            performExited[index].fulfill()
        }

        condition.lock()
        while resolutions[index] == nil {
            condition.wait()
        }
        let resolution = resolutions[index]
        condition.unlock()

        switch resolution {
        case .success:
            return
        case .failure(let error):
            throw error
        case .cancellationError:
            throw CancellationError()
        case .requestCancelled:
            throw NSError(
                domain: VNErrorDomain,
                code: VNErrorCode.requestCancelled.rawValue
            )
        case nil:
            preconditionFailure("resolution must be present")
        }
    }

    func requestDidCancel(_ request: VNRequest) {
        let identifier = ObjectIdentifier(request)
        let index = snapshot.withLock { snapshot -> Int in
            guard let index = snapshot.requestIndices[identifier] else {
                preconditionFailure("cancelled an unknown request")
            }
            snapshot.cancellationCounts[index, default: 0] += 1
            return index
        }
        requestCancelObserved[index].fulfill()
    }

    func finish(_ index: Int, with resolution: Resolution) {
        condition.lock()
        if resolutions[index] == nil {
            resolutions[index] = resolution
        }
        condition.broadcast()
        condition.unlock()
    }

    func releaseOutstandingWork() {
        condition.lock()
        for index in 0..<expectedPerformCount where resolutions[index] == nil {
            resolutions[index] = .failure(
                NSError(
                    domain: VNErrorDomain,
                    code: VNErrorCode.operationFailed.rawValue
                )
            )
        }
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilPerformEntered(_ index: Int) async -> Bool {
        await wait(for: performEntered[index])
    }

    func waitUntilPerformExited(_ index: Int) async -> Bool {
        await wait(for: performExited[index])
    }

    func waitUntilRequestCancelObserved(_ index: Int) async -> Bool {
        await wait(for: requestCancelObserved[index])
    }

    func cancellationCount(for index: Int) -> Int {
        snapshot.withLock { $0.cancellationCounts[index, default: 0] }
    }

    var makeRequestCount: Int {
        snapshot.withLock { $0.nextRequestIndex }
    }

    var activePerformCount: Int {
        snapshot.withLock { $0.activePerformCount }
    }

    var maxConcurrentPerformCount: Int {
        snapshot.withLock { $0.maxConcurrentPerformCount }
    }

    var entryOrder: [Int] {
        snapshot.withLock { $0.entryOrder }
    }

    var exitOrder: [Int] {
        snapshot.withLock { $0.exitOrder }
    }

    private func wait(for expectation: XCTestExpectation) async -> Bool {
        let result = await XCTWaiter.fulfillment(
            of: [expectation],
            timeout: eventTimeout
        )
        return result == .completed
    }
}

nonisolated private final class StartGate: @unchecked Sendable {
    private let entered = XCTestExpectation(
        description: "recognition task reached pre-perform gate"
    )
    private let semaphore = DispatchSemaphore(value: 0)
    private let didOpen = OSAllocatedUnfairLock(initialState: false)

    func wait() {
        entered.fulfill()
        semaphore.wait()
    }

    func open() {
        let shouldSignal = didOpen.withLock { didOpen in
            guard !didOpen else { return false }
            didOpen = true
            return true
        }
        if shouldSignal {
            semaphore.signal()
        }
    }

    func waitUntilEntered() async -> Bool {
        let result = await XCTWaiter.fulfillment(
            of: [entered],
            timeout: eventTimeout
        )
        return result == .completed
    }
}

nonisolated private final class CallStartSignal: @unchecked Sendable {
    private let started = XCTestExpectation(
        description: "recognition call started"
    )

    func markStarted() {
        started.fulfill()
    }

    func waitUntilStarted() async -> Bool {
        let result = await XCTWaiter.fulfillment(
            of: [started],
            timeout: eventTimeout
        )
        return result == .completed
    }
}

@concurrent
private func waitAtStartGate(_ gate: StartGate) async {
    gate.wait()
}

private enum RecognitionOutcome: @unchecked Sendable {
    case success([SlowWalkClientCore.RecognizedTextObservation])
    case failure(any Error)
}

private enum SingleFlightTestError: Error {
    case registrationRejected
}

private final class RecognitionCompletion: @unchecked Sendable {
    private struct State {
        var outcome: RecognitionOutcome?
        var publicationCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let completed = XCTestExpectation(
        description: "recognition task completed"
    )
    private let cleanupCompleted = XCTestExpectation(
        description: "recognition task cleanup completed"
    )

    func resolve(_ outcome: RecognitionOutcome) {
        let shouldFulfill = state.withLock { state in
            guard state.outcome == nil else { return false }
            state.outcome = outcome
            state.publicationCount += 1
            return true
        }
        guard shouldFulfill else { return }
        completed.fulfill()
        cleanupCompleted.fulfill()
    }

    func waitForCompletion() async -> Bool {
        let result = await XCTWaiter.fulfillment(
            of: [completed],
            timeout: eventTimeout
        )
        return result == .completed
    }

    func waitForCleanup() async -> Bool {
        let result = await XCTWaiter.fulfillment(
            of: [cleanupCompleted],
            timeout: eventTimeout
        )
        return result == .completed
    }

    var outcome: RecognitionOutcome? {
        state.withLock { $0.outcome }
    }

    var publicationCount: Int {
        state.withLock { $0.publicationCount }
    }
}

private struct RunningRecognition: Sendable {
    let task: Task<Void, Never>
    let completion: RecognitionCompletion
}

@Suite(
    "Apple Vision text recognizer",
    .timeLimit(.minutes(1))
)
struct AppleVisionMedicineTextRecognizerTests {
    private func makeBlankPNGData() -> Data {
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 32, height: 32)
        )
        return renderer.pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
    }

    private func makeInput() -> OCRImageInput {
        OCRImageInput(
            data: makeBlankPNGData(),
            orientation: .up,
            capturedAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func startRecognition(
        _ recognizer: AppleVisionMedicineTextRecognizer,
        input: OCRImageInput,
        startSignal: CallStartSignal? = nil
    ) -> RunningRecognition {
        let completion = RecognitionCompletion()
        let task = Task {
            startSignal?.markStarted()
            do {
                let observations = try await recognizer.recognizeText(
                    in: input
                )
                completion.resolve(.success(observations))
            } catch {
                completion.resolve(.failure(error))
            }
        }
        return RunningRecognition(task: task, completion: completion)
    }

    private func waitForOutcome(
        _ running: RunningRecognition,
        releasing performer: (any TestVisionWorkReleasing)? = nil
    ) async -> RecognitionOutcome? {
        guard await running.completion.waitForCompletion() else {
            Issue.record("recognition exceeded its event deadline")
            running.task.cancel()
            performer?.releaseOutstandingWork()
            let cleanedUp = await running.completion.waitForCleanup()
            #expect(cleanedUp)
            if cleanedUp {
                await running.task.value
            }
            return nil
        }
        await running.task.value
        return running.completion.outcome
    }

    private func expectCancellation(_ outcome: RecognitionOutcome?) {
        switch outcome {
        case .failure(let error):
            #expect(error is CancellationError)
        case .success:
            Issue.record("cancelled recognition returned a result")
        case nil:
            break
        }
    }

    private func expectSuccess(_ outcome: RecognitionOutcome?) {
        switch outcome {
        case .success:
            break
        case .failure:
            Issue.record("recognition unexpectedly failed")
        case nil:
            break
        }
    }

    @Test func recognizerRejectsEmptyImage() async {
        let recognizer = AppleVisionMedicineTextRecognizer()
        let input = OCRImageInput(
            data: Data(),
            orientation: .up,
            capturedAt: Date(timeIntervalSince1970: 100)
        )

        do {
            _ = try await recognizer.recognizeText(in: input)
            Issue.record("empty image data must be rejected")
        } catch let error as AppleVisionMedicineTextRecognizer.Failure {
            #expect(error == .emptyImageData)
        } catch {
            Issue.record("unexpected empty-image error")
        }
    }

    @Test func preCancelledTaskWinsOverEmptyImage() async {
        let performer = ControlledVisionTextRequestPerformer(
            behavior: .succeed
        )
        let recognizer = AppleVisionMedicineTextRecognizer(
            performer: performer,
            singleFlightGate: VisionTextRecognitionSingleFlightGate()
        )
        let completion = RecognitionCompletion()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                let observations = try await recognizer.recognizeText(
                    in: OCRImageInput(
                        data: Data(),
                        orientation: .up,
                        capturedAt: Date(timeIntervalSince1970: 100)
                    )
                )
                completion.resolve(.success(observations))
            } catch {
                completion.resolve(.failure(error))
            }
        }
        let running = RunningRecognition(task: task, completion: completion)

        let outcome = await waitForOutcome(running, releasing: performer)

        expectCancellation(outcome)
        #expect(performer.makeRequestCount == 0)
        #expect(performer.performCount == 0)
    }

    @MainActor
    @Test func recognitionDoesNotRunOnMainActor() async {
        let performer = ControlledVisionTextRequestPerformer(
            behavior: .succeed
        )
        let recognizer = AppleVisionMedicineTextRecognizer(
            performer: performer,
            singleFlightGate: VisionTextRecognitionSingleFlightGate()
        )

        let running = startRecognition(recognizer, input: makeInput())
        let outcome = await waitForOutcome(
            running,
            releasing: performer
        )

        if case .failure = outcome {
            Issue.record("controlled recognition unexpectedly failed")
        }
        #expect(performer.performedOnMainThread == false)
    }

    @Test func cancellationBeforePerformThrowsCancellationError() async {
        let gate = StartGate()
        let performer = ControlledVisionTextRequestPerformer(
            behavior: .succeed
        )
        let recognizer = AppleVisionMedicineTextRecognizer(
            performer: performer,
            singleFlightGate: VisionTextRecognitionSingleFlightGate()
        )
        let completion = RecognitionCompletion()
        let input = makeInput()
        let task = Task {
            await waitAtStartGate(gate)
            do {
                let observations = try await recognizer.recognizeText(
                    in: input
                )
                completion.resolve(.success(observations))
            } catch {
                completion.resolve(.failure(error))
            }
        }
        let running = RunningRecognition(
            task: task,
            completion: completion
        )

        let entered = await gate.waitUntilEntered()
        #expect(entered)
        task.cancel()
        gate.open()

        let outcome = await waitForOutcome(
            running,
            releasing: performer
        )
        expectCancellation(outcome)
        #expect(performer.makeRequestCount == 0)
        #expect(performer.performCount == 0)
    }

    @Test func cancellationDuringPerformCancelsCurrentRequest() async {
        let performer = ControlledVisionTextRequestPerformer(
            behavior: .waitForResolution
        )
        let recognizer = AppleVisionMedicineTextRecognizer(
            performer: performer,
            singleFlightGate: VisionTextRecognitionSingleFlightGate()
        )
        let running = startRecognition(recognizer, input: makeInput())

        let started = await performer.waitUntilPerformStarted()
        #expect(started)
        guard started else {
            running.task.cancel()
            performer.releaseOutstandingWork()
            _ = await waitForOutcome(running, releasing: performer)
            return
        }

        running.task.cancel()
        let outcome = await waitForOutcome(
            running,
            releasing: performer
        )

        expectCancellation(outcome)
        #expect(performer.totalCancellationCount == 1)
        #expect(performer.performCount == 1)
        #expect(running.completion.publicationCount == 1)
    }

    @Test func visionRequestCancelledMapsToCancellationError() async {
        let performer = ControlledVisionTextRequestPerformer(
            behavior: .fail(
                NSError(
                    domain: VNErrorDomain,
                    code: VNErrorCode.requestCancelled.rawValue
                )
            )
        )
        let recognizer = AppleVisionMedicineTextRecognizer(
            performer: performer,
            singleFlightGate: VisionTextRecognitionSingleFlightGate()
        )
        let running = startRecognition(recognizer, input: makeInput())

        let outcome = await waitForOutcome(
            running,
            releasing: performer
        )

        expectCancellation(outcome)
    }

    @Test func performerCancellationErrorPassesThrough() async {
        let performer = ControlledVisionTextRequestPerformer(
            behavior: .failCancellationError
        )
        let recognizer = AppleVisionMedicineTextRecognizer(
            performer: performer,
            singleFlightGate: VisionTextRecognitionSingleFlightGate()
        )
        let running = startRecognition(recognizer, input: makeInput())

        let outcome = await waitForOutcome(
            running,
            releasing: performer
        )

        expectCancellation(outcome)
        #expect(performer.performCount == 1)
    }

    @Test func cancellationAfterPerformPreventsSuccessPublication() async {
        let performer = ControlledVisionTextRequestPerformer(
            behavior: .cancelCurrentTaskThenSucceed
        )
        let recognizer = AppleVisionMedicineTextRecognizer(
            performer: performer,
            singleFlightGate: VisionTextRecognitionSingleFlightGate()
        )
        let running = startRecognition(recognizer, input: makeInput())

        let outcome = await waitForOutcome(
            running,
            releasing: performer
        )

        expectCancellation(outcome)
        #expect(performer.totalCancellationCount == 1)
    }

    @Test func normalCompletionWinsAndPublishesOnce() async {
        let performer = ControlledVisionTextRequestPerformer(
            behavior: .waitForResolution
        )
        let recognizer = AppleVisionMedicineTextRecognizer(
            performer: performer,
            singleFlightGate: VisionTextRecognitionSingleFlightGate()
        )
        let running = startRecognition(recognizer, input: makeInput())

        let started = await performer.waitUntilPerformStarted()
        #expect(started)
        guard started else {
            running.task.cancel()
            performer.releaseOutstandingWork()
            _ = await waitForOutcome(running, releasing: performer)
            return
        }

        performer.finishSuccessfully()
        let outcome = await waitForOutcome(
            running,
            releasing: performer
        )

        switch outcome {
        case .success(let observations):
            #expect(observations.isEmpty)
        case .failure:
            Issue.record("normal completion lost to a nonexistent cancel")
        case nil:
            break
        }
        #expect(running.completion.publicationCount == 1)
        #expect(performer.performCount == 1)

        running.task.cancel()
        #expect(performer.totalCancellationCount == 0)
    }

    @Test func nonCancellationVisionFailureIsContentFree() async {
        let performer = ControlledVisionTextRequestPerformer(
            behavior: .fail(
                NSError(
                    domain: VNErrorDomain,
                    code: VNErrorCode.invalidImage.rawValue,
                    userInfo: [
                        NSLocalizedDescriptionKey: "private image detail"
                    ]
                )
            )
        )
        let recognizer = AppleVisionMedicineTextRecognizer(
            performer: performer,
            singleFlightGate: VisionTextRecognitionSingleFlightGate()
        )
        let running = startRecognition(recognizer, input: makeInput())

        let outcome = await waitForOutcome(
            running,
            releasing: performer
        )

        switch outcome {
        case .failure(
            let error as AppleVisionMedicineTextRecognizer.Failure
        ):
            #expect(
                error == .recognitionFailed(
                    "vision_text_recognition_failed"
                )
            )
        case .failure:
            Issue.record("Vision failure used an unexpected error type")
        case .success:
            Issue.record("Vision failure returned a result")
        case nil:
            break
        }
    }

    @Test func cancelledFirstPerformMustExitBeforeSecondStarts() async {
        let performer = SequencedVisionTextRequestPerformer(
            expectedPerformCount: 2
        )
        let gate = VisionTextRecognitionSingleFlightGate()
        let recognizer = AppleVisionMedicineTextRecognizer(
            performer: performer,
            singleFlightGate: gate
        )
        let first = startRecognition(recognizer, input: makeInput())

        let firstEntered = await performer.waitUntilPerformEntered(0)
        #expect(firstEntered)
        guard firstEntered else {
            first.task.cancel()
            performer.releaseOutstandingWork()
            _ = await waitForOutcome(first, releasing: performer)
            return
        }

        let secondStarted = CallStartSignal()
        let second = startRecognition(
            recognizer,
            input: makeInput(),
            startSignal: secondStarted
        )
        #expect(await secondStarted.waitUntilStarted())

        first.task.cancel()
        let cancelObserved = await performer.waitUntilRequestCancelObserved(0)
        #expect(cancelObserved)
        #expect(performer.makeRequestCount == 1)
        #expect(performer.activePerformCount == 1)
        #expect(performer.entryOrder == [0])

        performer.finish(0, with: .requestCancelled)
        #expect(await performer.waitUntilPerformExited(0))
        let secondEntered = await performer.waitUntilPerformEntered(1)
        #expect(secondEntered)
        guard secondEntered else {
            second.task.cancel()
            performer.releaseOutstandingWork()
            _ = await waitForOutcome(first, releasing: performer)
            _ = await waitForOutcome(second, releasing: performer)
            return
        }
        performer.finish(1, with: .success)

        expectCancellation(
            await waitForOutcome(first, releasing: performer)
        )
        expectSuccess(
            await waitForOutcome(second, releasing: performer)
        )
        #expect(performer.maxConcurrentPerformCount == 1)
        #expect(performer.entryOrder == [0, 1])
        #expect(performer.exitOrder == [0, 1])
    }

    @Test func threeCallsRemainSingleFlight() async {
        let performer = SequencedVisionTextRequestPerformer(
            expectedPerformCount: 3
        )
        let recognizer = AppleVisionMedicineTextRecognizer(
            performer: performer,
            singleFlightGate: VisionTextRecognitionSingleFlightGate()
        )
        let first = startRecognition(recognizer, input: makeInput())

        let firstEntered = await performer.waitUntilPerformEntered(0)
        #expect(firstEntered)
        guard firstEntered else {
            first.task.cancel()
            performer.releaseOutstandingWork()
            _ = await waitForOutcome(first, releasing: performer)
            return
        }

        let secondStarted = CallStartSignal()
        let thirdStarted = CallStartSignal()
        let second = startRecognition(
            recognizer,
            input: makeInput(),
            startSignal: secondStarted
        )
        let third = startRecognition(
            recognizer,
            input: makeInput(),
            startSignal: thirdStarted
        )
        #expect(await secondStarted.waitUntilStarted())
        #expect(await thirdStarted.waitUntilStarted())
        #expect(performer.makeRequestCount == 1)

        performer.finish(0, with: .success)
        let secondEntered = await performer.waitUntilPerformEntered(1)
        #expect(secondEntered)
        guard secondEntered else {
            second.task.cancel()
            third.task.cancel()
            performer.releaseOutstandingWork()
            _ = await waitForOutcome(first, releasing: performer)
            _ = await waitForOutcome(second, releasing: performer)
            _ = await waitForOutcome(third, releasing: performer)
            return
        }
        #expect(performer.activePerformCount == 1)
        performer.finish(1, with: .success)

        let thirdEntered = await performer.waitUntilPerformEntered(2)
        #expect(thirdEntered)
        guard thirdEntered else {
            third.task.cancel()
            performer.releaseOutstandingWork()
            _ = await waitForOutcome(first, releasing: performer)
            _ = await waitForOutcome(second, releasing: performer)
            _ = await waitForOutcome(third, releasing: performer)
            return
        }
        performer.finish(2, with: .success)

        expectSuccess(await waitForOutcome(first, releasing: performer))
        expectSuccess(await waitForOutcome(second, releasing: performer))
        expectSuccess(await waitForOutcome(third, releasing: performer))
        #expect(performer.maxConcurrentPerformCount == 1)
        #expect(performer.entryOrder == [0, 1, 2])
        #expect(performer.exitOrder == [0, 1, 2])
        #expect(performer.activePerformCount == 0)
    }

    @Test func cancelledWaiterDoesNotConsumePermit() async {
        let performer = SequencedVisionTextRequestPerformer(
            expectedPerformCount: 3
        )
        let recognizer = AppleVisionMedicineTextRecognizer(
            performer: performer,
            singleFlightGate: VisionTextRecognitionSingleFlightGate()
        )
        let first = startRecognition(recognizer, input: makeInput())

        let firstEntered = await performer.waitUntilPerformEntered(0)
        #expect(firstEntered)
        guard firstEntered else {
            first.task.cancel()
            performer.releaseOutstandingWork()
            _ = await waitForOutcome(first, releasing: performer)
            return
        }

        let waiterStarted = CallStartSignal()
        let waiter = startRecognition(
            recognizer,
            input: makeInput(),
            startSignal: waiterStarted
        )
        #expect(await waiterStarted.waitUntilStarted())
        waiter.task.cancel()

        let waiterOutcome = await waitForOutcome(waiter)
        expectCancellation(waiterOutcome)
        if performer.makeRequestCount > 1 {
            performer.finish(1, with: .requestCancelled)
            _ = await waitForOutcome(waiter, releasing: performer)
        }
        #expect(performer.makeRequestCount == 1)
        #expect(performer.entryOrder == [0])

        performer.finish(0, with: .success)
        expectSuccess(await waitForOutcome(first, releasing: performer))

        let thirdRequestIndex = performer.makeRequestCount
        let third = startRecognition(recognizer, input: makeInput())
        let thirdEntered = await performer.waitUntilPerformEntered(
            thirdRequestIndex
        )
        #expect(thirdEntered)
        guard thirdEntered else {
            third.task.cancel()
            performer.releaseOutstandingWork()
            _ = await waitForOutcome(third, releasing: performer)
            return
        }
        performer.finish(thirdRequestIndex, with: .success)
        expectSuccess(await waitForOutcome(third, releasing: performer))

        #expect(performer.maxConcurrentPerformCount == 1)
        #expect(performer.entryOrder == [0, 1])
        #expect(performer.exitOrder == [0, 1])
    }

    @Test func copiedRecognizerSharesSingleFlightBoundary() async {
        let performer = SequencedVisionTextRequestPerformer(
            expectedPerformCount: 2
        )
        let original = AppleVisionMedicineTextRecognizer(
            performer: performer,
            singleFlightGate: VisionTextRecognitionSingleFlightGate()
        )
        let copy = original
        let first = startRecognition(original, input: makeInput())

        let firstEntered = await performer.waitUntilPerformEntered(0)
        #expect(firstEntered)
        guard firstEntered else {
            first.task.cancel()
            performer.releaseOutstandingWork()
            _ = await waitForOutcome(first, releasing: performer)
            return
        }

        let secondStarted = CallStartSignal()
        let second = startRecognition(
            copy,
            input: makeInput(),
            startSignal: secondStarted
        )
        #expect(await secondStarted.waitUntilStarted())
        #expect(performer.makeRequestCount == 1)

        performer.finish(0, with: .success)
        let secondEntered = await performer.waitUntilPerformEntered(1)
        #expect(secondEntered)
        guard secondEntered else {
            second.task.cancel()
            performer.releaseOutstandingWork()
            _ = await waitForOutcome(first, releasing: performer)
            _ = await waitForOutcome(second, releasing: performer)
            return
        }
        performer.finish(1, with: .success)

        expectSuccess(await waitForOutcome(first, releasing: performer))
        expectSuccess(await waitForOutcome(second, releasing: performer))
        #expect(performer.maxConcurrentPerformCount == 1)
    }

    @Test func independentlyConstructedRecognizersShareDefaultGate() async {
        let performer = SequencedVisionTextRequestPerformer(
            expectedPerformCount: 2
        )
        let firstRecognizer = AppleVisionMedicineTextRecognizer(
            performer: performer
        )
        let secondRecognizer = AppleVisionMedicineTextRecognizer(
            performer: performer
        )
        let first = startRecognition(firstRecognizer, input: makeInput())

        let firstEntered = await performer.waitUntilPerformEntered(0)
        #expect(firstEntered)
        guard firstEntered else {
            first.task.cancel()
            performer.releaseOutstandingWork()
            _ = await waitForOutcome(first, releasing: performer)
            return
        }

        let secondStarted = CallStartSignal()
        let second = startRecognition(
            secondRecognizer,
            input: makeInput(),
            startSignal: secondStarted
        )
        #expect(await secondStarted.waitUntilStarted())
        #expect(performer.makeRequestCount == 1)

        performer.finish(0, with: .success)
        let secondEntered = await performer.waitUntilPerformEntered(1)
        #expect(secondEntered)
        guard secondEntered else {
            second.task.cancel()
            performer.releaseOutstandingWork()
            _ = await waitForOutcome(first, releasing: performer)
            _ = await waitForOutcome(second, releasing: performer)
            return
        }
        performer.finish(1, with: .success)

        expectSuccess(await waitForOutcome(first, releasing: performer))
        expectSuccess(await waitForOutcome(second, releasing: performer))
        #expect(performer.maxConcurrentPerformCount == 1)
    }

    @Test func permitIsReleasedOnEveryExitPath() async {
        let gate = VisionTextRecognitionSingleFlightGate()

        let successPerformer = ControlledVisionTextRequestPerformer(
            behavior: .succeed
        )
        let successRecognizer = AppleVisionMedicineTextRecognizer(
            performer: successPerformer,
            singleFlightGate: gate
        )
        expectSuccess(
            await waitForOutcome(
                startRecognition(successRecognizer, input: makeInput()),
                releasing: successPerformer
            )
        )

        let failurePerformer = ControlledVisionTextRequestPerformer(
            behavior: .fail(
                NSError(
                    domain: VNErrorDomain,
                    code: VNErrorCode.operationFailed.rawValue
                )
            )
        )
        let failureRecognizer = AppleVisionMedicineTextRecognizer(
            performer: failurePerformer,
            singleFlightGate: gate
        )
        let failureOutcome = await waitForOutcome(
            startRecognition(failureRecognizer, input: makeInput()),
            releasing: failurePerformer
        )
        if case .failure(
            let error as AppleVisionMedicineTextRecognizer.Failure
        ) = failureOutcome {
            #expect(
                error == .recognitionFailed(
                    "vision_text_recognition_failed"
                )
            )
        } else {
            Issue.record("ordinary error did not use stable mapping")
        }

        let cancellationPerformer = ControlledVisionTextRequestPerformer(
            behavior: .failCancellationError
        )
        let cancellationRecognizer = AppleVisionMedicineTextRecognizer(
            performer: cancellationPerformer,
            singleFlightGate: gate
        )
        expectCancellation(
            await waitForOutcome(
                startRecognition(cancellationRecognizer, input: makeInput()),
                releasing: cancellationPerformer
            )
        )

        let requestCancelledPerformer = ControlledVisionTextRequestPerformer(
            behavior: .fail(
                NSError(
                    domain: VNErrorDomain,
                    code: VNErrorCode.requestCancelled.rawValue
                )
            )
        )
        let requestCancelledRecognizer = AppleVisionMedicineTextRecognizer(
            performer: requestCancelledPerformer,
            singleFlightGate: gate
        )
        expectCancellation(
            await waitForOutcome(
                startRecognition(
                    requestCancelledRecognizer,
                    input: makeInput()
                ),
                releasing: requestCancelledPerformer
            )
        )

        let registrationPerformer = ControlledVisionTextRequestPerformer(
            behavior: .succeed
        )
        do {
            _ = try await gate.withPermit {
                let controller = VisionRequestCancellationController()
                let firstRequest = registrationPerformer.makeRequest()
                let rejectedRequest = registrationPerformer.makeRequest()
                guard controller.register(firstRequest) == .registered,
                      controller.register(rejectedRequest)
                        == .rejectedAlreadyRegistered
                else {
                    Issue.record("registration setup failed")
                    return false
                }
                controller.clear(firstRequest)
                throw SingleFlightTestError.registrationRejected
            }
            Issue.record("registration rejection must throw")
        } catch SingleFlightTestError.registrationRejected {
            // Expected.
        } catch {
            Issue.record("unexpected registration rejection error")
        }

        do {
            let acquiredAfterEveryExit = try await gate.withPermit { true }
            #expect(acquiredAfterEveryExit)
        } catch {
            Issue.record("single-flight permit leaked after an exit path")
        }
    }

    @Test func cancelBeforeRegisterImmediatelyCancelsRequest() {
        let performer = ControlledVisionTextRequestPerformer(
            behavior: .waitForResolution
        )
        let controller = VisionRequestCancellationController()
        let request = performer.makeRequest()

        controller.cancel()
        let result = controller.register(request)

        #expect(result == .cancelImmediately)
        #expect(performer.cancellationCount(for: request) == 1)
    }

    @Test func differentRequestCannotOverwriteRegisteredRequest() {
        let performer = ControlledVisionTextRequestPerformer(
            behavior: .waitForResolution
        )
        let controller = VisionRequestCancellationController()
        let oldRequest = performer.makeRequest()
        let rejectedRequest = performer.makeRequest()

        #expect(controller.register(oldRequest) == .registered)
        #expect(
            controller.register(rejectedRequest)
                == .rejectedAlreadyRegistered
        )
        controller.cancel()

        #expect(performer.cancellationCount(for: oldRequest) == 1)
        #expect(performer.cancellationCount(for: rejectedRequest) == 0)
    }

    @Test func clearDoesNotRemoveANewerRequest() {
        let performer = ControlledVisionTextRequestPerformer(
            behavior: .waitForResolution
        )
        let controller = VisionRequestCancellationController()
        let oldRequest = performer.makeRequest()
        let newRequest = performer.makeRequest()

        #expect(controller.register(oldRequest) == .registered)
        controller.clear(oldRequest)
        #expect(controller.register(newRequest) == .registered)
        controller.clear(oldRequest)
        controller.cancel()

        #expect(performer.cancellationCount(for: oldRequest) == 0)
        #expect(performer.cancellationCount(for: newRequest) == 1)
    }

    @Test func completionFirstPreventsLateCancellationOfRequest() {
        let performer = ControlledVisionTextRequestPerformer(
            behavior: .waitForResolution
        )
        let controller = VisionRequestCancellationController()
        let request = performer.makeRequest()

        #expect(controller.register(request) == .registered)
        let completionWon = controller.complete(
            request,
            taskIsCancelled: { false }
        )
        #expect(completionWon)
        controller.cancel()

        #expect(performer.cancellationCount(for: request) == 0)
        let duplicateCompletionWon = controller.complete(
            request,
            taskIsCancelled: { false }
        )
        #expect(!duplicateCompletionWon)
    }

    @Test func cancellationFirstPreventsCompletionAndCancelsOnce() {
        let performer = ControlledVisionTextRequestPerformer(
            behavior: .waitForResolution
        )
        let controller = VisionRequestCancellationController()
        let request = performer.makeRequest()

        #expect(controller.register(request) == .registered)
        controller.cancel()
        let completionWon = controller.complete(
            request,
            taskIsCancelled: { false }
        )
        #expect(!completionWon)
        controller.cancel()

        #expect(performer.cancellationCount(for: request) == 1)
    }

    @Test func repeatedCancelIsIdempotent() {
        let performer = ControlledVisionTextRequestPerformer(
            behavior: .waitForResolution
        )
        let controller = VisionRequestCancellationController()
        let request = performer.makeRequest()

        controller.register(request)
        controller.cancel()
        controller.cancel()
        controller.cancel()

        #expect(performer.cancellationCount(for: request) == 1)
    }
}
