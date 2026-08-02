import Foundation
import os
import SlowWalkClientCore
import Testing
import Vision
@preconcurrency import XCTest

@testable import SlowWalkApp

private let eventTimeout: TimeInterval = 2

nonisolated private final class TestEvent: @unchecked Sendable {
    private let expectation: XCTestExpectation

    init(_ description: String) {
        expectation = XCTestExpectation(description: description)
    }

    func signal() { expectation.fulfill() }

    func wait() async -> Bool {
        await XCTWaiter.fulfillment(
            of: [expectation], timeout: eventTimeout
        ) == .completed
    }
}

nonisolated private func visionError(
    _ code: VNErrorCode, localizedDescription: String? = nil
) -> NSError {
    NSError(
        domain: VNErrorDomain,
        code: code.rawValue,
        userInfo: localizedDescription.map { [NSLocalizedDescriptionKey: $0] } ?? [:]
    )
}

private enum TestPerformerError: Error, Equatable {
    case foreignRequest
}

nonisolated private final class ObservableTextRequest:
    VNRecognizeTextRequest,
    @unchecked Sendable
{
    private weak var observer: SequencedVisionTextRequestPerformer?
    private let cancellations = OSAllocatedUnfairLock(initialState: 0)

    init(observer: SequencedVisionTextRequestPerformer? = nil) {
        self.observer = observer
        super.init(completionHandler: nil)
    }

    override func cancel() {
        super.cancel()
        cancellations.withLock { $0 += 1 }
        observer?.requestDidCancel(self)
    }

    var cancelCount: Int { cancellations.withLock { $0 } }
}

/// A deterministic single- and multi-call implementation of the production
/// execution boundary. Blocking calls exit only after explicit resolution.
private final class SequencedVisionTextRequestPerformer:
    @unchecked Sendable,
    VisionTextRequestPerforming
{
    enum Behavior {
        case waitForResolution
        case succeed
        case fail(NSError)
        case failCancellationError
        case cancelCurrentTaskThenSucceed
    }

    enum Resolution {
        case success
        case failure(NSError)
        case cancellationError
        case requestCancelled
    }

    struct Metrics: Sendable {
        var makeRequestCount = 0
        var performCount = 0
        var activePerformCount = 0
        var maxConcurrentPerformCount = 0
        var entryOrder: [Int] = []
        var exitOrder: [Int] = []
        var cancellationCounts: [Int: Int] = [:]
        var performedOnMainThread: Bool?
        var requestIndices: [ObjectIdentifier: Int] = [:]
        var registeredRequests: [ObjectIdentifier: ObservableTextRequest] = [:]

        func cancellationCount(for index: Int) -> Int { cancellationCounts[index, default: 0] }
        var totalCancellationCount: Int { cancellationCounts.values.reduce(0, +) }
    }

    private let expectedRequestCount: Int
    private let behavior: Behavior
    private let cancellationResolution: Resolution?
    private let condition = NSCondition()
    private var resolutions: [Int: Resolution] = [:]
    private let snapshot = OSAllocatedUnfairLock(initialState: Metrics())
    private let performEntered: [TestEvent]
    private let performExited: [TestEvent]
    private let requestCancelObserved: [TestEvent]

    init(
        expectedRequestCount: Int = 1,
        behavior: Behavior = .waitForResolution,
        cancellationResolution: Resolution? = nil
    ) {
        precondition(expectedRequestCount > 0)
        self.expectedRequestCount = expectedRequestCount
        self.behavior = behavior
        self.cancellationResolution = cancellationResolution
        performEntered = (0..<expectedRequestCount).map {
            TestEvent("perform \($0) entered")
        }
        performExited = (0..<expectedRequestCount).map {
            TestEvent("perform \($0) exited")
        }
        requestCancelObserved = (0..<expectedRequestCount).map {
            TestEvent("request \($0) cancelled")
        }
    }

    func makeRequest() -> VNRecognizeTextRequest {
        let request = ObservableTextRequest(observer: self)
        let identifier = ObjectIdentifier(request)
        snapshot.withLock { snapshot in
            precondition(
                snapshot.makeRequestCount < expectedRequestCount,
                "unexpected extra Vision request"
            )
            snapshot.requestIndices[identifier] = snapshot.makeRequestCount
            snapshot.registeredRequests[identifier] = request
            snapshot.makeRequestCount += 1
        }
        return request
    }

    func perform(
        _ request: VNRecognizeTextRequest,
        data: Data,
        orientation: CGImagePropertyOrientation
    ) throws {
        guard let request = request as? ObservableTextRequest else {
            throw TestPerformerError.foreignRequest
        }
        let identifier = ObjectIdentifier(request)
        let index = try snapshot.withLock { snapshot -> Int in
            guard let index = snapshot.requestIndices[identifier],
                  snapshot.registeredRequests[identifier] === request
            else {
                throw TestPerformerError.foreignRequest
            }
            snapshot.performCount += 1
            snapshot.activePerformCount += 1
            snapshot.maxConcurrentPerformCount = max(
                snapshot.maxConcurrentPerformCount,
                snapshot.activePerformCount
            )
            snapshot.entryOrder.append(index)
            snapshot.performedOnMainThread = Thread.isMainThread
            return index
        }
        performEntered[index].signal()

        defer {
            snapshot.withLock { snapshot in
                snapshot.activePerformCount -= 1
                snapshot.exitOrder.append(index)
            }
            performExited[index].signal()
        }

        switch behavior {
        case .succeed:
            return
        case .fail(let error):
            throw error
        case .failCancellationError:
            throw CancellationError()
        case .cancelCurrentTaskThenSucceed:
            withUnsafeCurrentTask { $0?.cancel() }
            return
        case .waitForResolution:
            try waitForResolution(at: index)
        }
    }

    func requestDidCancel(_ request: VNRequest) {
        guard let request = request as? ObservableTextRequest else { return }
        let identifier = ObjectIdentifier(request)
        let index = snapshot.withLock { snapshot -> Int? in
            guard let index = snapshot.requestIndices[identifier],
                  snapshot.registeredRequests[identifier] === request
            else {
                return nil
            }
            snapshot.cancellationCounts[index, default: 0] += 1
            return index
        }
        guard let index else { return }
        requestCancelObserved[index].signal()
        if let cancellationResolution {
            finish(index, with: cancellationResolution)
        }
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
        for index in 0..<expectedRequestCount
        where resolutions[index] == nil {
            resolutions[index] = .failure(visionError(.operationFailed))
        }
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilPerformEntered(_ index: Int) async -> Bool { await performEntered[index].wait() }
    func waitUntilPerformExited(_ index: Int) async -> Bool { await performExited[index].wait() }
    func waitUntilRequestCancelObserved(_ index: Int) async -> Bool { await requestCancelObserved[index].wait() }

    var metrics: Metrics { snapshot.withLock { $0 } }

    private func waitForResolution(at index: Int) throws {
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
            throw visionError(.requestCancelled)
        case nil:
            preconditionFailure("resolution must be present")
        }
    }
}

nonisolated private final class StartGate: @unchecked Sendable {
    private let entered = TestEvent("recognition reached start gate")
    private let condition = NSCondition()
    private var isOpen = false

    func wait() {
        entered.signal()
        condition.lock()
        while !isOpen {
            condition.wait()
        }
        condition.unlock()
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilEntered() async -> Bool { await entered.wait() }
}

@concurrent
private func waitAtStartGate(_ gate: StartGate) async { gate.wait() }

private enum RecognitionOutcome: @unchecked Sendable {
    case success([SlowWalkClientCore.RecognizedTextObservation])
    case failure(any Error)
}

private final class RecognitionCompletion: @unchecked Sendable {
    private struct State {
        var outcome: RecognitionOutcome?
        var publicationCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let completed = TestEvent("recognition published an outcome")
    private let taskExited = TestEvent("recognition task exited")

    func resolve(_ outcome: RecognitionOutcome) {
        let firstPublication = state.withLock { state in
            guard state.outcome == nil else { return false }
            state.outcome = outcome
            state.publicationCount += 1
            return true
        }
        if firstPublication {
            completed.signal()
        }
    }

    func markTaskExited() { taskExited.signal() }
    func waitForCompletion() async -> Bool { await completed.wait() }
    func waitForTaskExit() async -> Bool { await taskExited.wait() }
    var outcome: RecognitionOutcome? { state.withLock { $0.outcome } }
    var publicationCount: Int { state.withLock { $0.publicationCount } }
}

private struct RunningRecognition: Sendable {
    let task: Task<Void, Never>
    let completion: RecognitionCompletion
}

private struct ControllerFixture: Sendable {
    let controller = VisionRequestCancellationController()
    let requests: [ObservableTextRequest]

    init(requestCount: Int) { requests = (0..<requestCount).map { _ in ObservableTextRequest() } }
}

enum PermitExitPath: CaseIterable, Equatable, Error, Sendable {
    case success
    case ordinaryFailure
    case cancellationError
    case requestCancelled
    case registrationRejected
}

@Suite(
    "Apple Vision text recognizer",
    .serialized,
    .timeLimit(.minutes(1))
)
struct AppleVisionMedicineTextRecognizerTests {
    private func makeInput(data: Data = Data([1])) -> OCRImageInput {
        OCRImageInput(
            data: data,
            orientation: .up,
            capturedAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func makeRecognizer(
        performer: SequencedVisionTextRequestPerformer,
        gate: VisionTextRecognitionSingleFlightGate =
            VisionTextRecognitionSingleFlightGate()
    ) -> AppleVisionMedicineTextRecognizer {
        AppleVisionMedicineTextRecognizer(
            performer: performer,
            singleFlightGate: gate
        )
    }

    private func startRecognition(
        _ recognizer: AppleVisionMedicineTextRecognizer,
        input: OCRImageInput? = nil,
        startSignal: TestEvent? = nil,
        startGate: StartGate? = nil,
        preCancelled: Bool = false
    ) -> RunningRecognition {
        let completion = RecognitionCompletion()
        let input = input ?? makeInput()
        let task = Task {
            defer { completion.markTaskExited() }
            startSignal?.signal()
            if let startGate {
                await waitAtStartGate(startGate)
            }
            if preCancelled {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            do {
                completion.resolve(
                    .success(try await recognizer.recognizeText(in: input))
                )
            } catch {
                completion.resolve(.failure(error))
            }
        }
        return RunningRecognition(task: task, completion: completion)
    }

    private func startScenario(
        behavior: SequencedVisionTextRequestPerformer.Behavior,
        input: OCRImageInput? = nil,
        gate: VisionTextRecognitionSingleFlightGate =
            VisionTextRecognitionSingleFlightGate(),
        cancellationResolution: SequencedVisionTextRequestPerformer.Resolution?
            = nil,
        startGate: StartGate? = nil,
        preCancelled: Bool = false
    ) -> (
        performer: SequencedVisionTextRequestPerformer,
        running: RunningRecognition
    ) {
        let performer = SequencedVisionTextRequestPerformer(
            behavior: behavior,
            cancellationResolution: cancellationResolution
        )
        let running = startRecognition(
            makeRecognizer(performer: performer, gate: gate),
            input: input,
            startGate: startGate,
            preCancelled: preCancelled
        )
        return (performer, running)
    }

    private func waitForOutcome(
        _ running: RunningRecognition,
        releasing performer: SequencedVisionTextRequestPerformer? = nil
    ) async -> RecognitionOutcome? {
        let completed = await running.completion.waitForCompletion()
        if !completed {
            Issue.record("recognition exceeded its event deadline")
            running.task.cancel()
            performer?.releaseOutstandingWork()
        }
        let exited = await running.completion.waitForTaskExit()
        #expect(exited)
        guard exited else { return nil }
        await running.task.value
        return running.completion.outcome
    }

    private func drain(
        _ recognitions: [RunningRecognition],
        releasing performer: SequencedVisionTextRequestPerformer
    ) async {
        recognitions.forEach { $0.task.cancel() }
        performer.releaseOutstandingWork()
        for recognition in recognitions {
            _ = await waitForOutcome(recognition, releasing: performer)
        }
    }

    private func requirePerformEntered(
        _ index: Int,
        _ performer: SequencedVisionTextRequestPerformer,
        cleaning recognitions: [RunningRecognition]
    ) async -> Bool {
        let entered = await performer.waitUntilPerformEntered(index)
        #expect(entered)
        guard entered else {
            await drain(recognitions, releasing: performer)
            return false
        }
        return true
    }

    private func resolveAndRequireExit(
        _ index: Int,
        _ resolution: SequencedVisionTextRequestPerformer.Resolution,
        _ performer: SequencedVisionTextRequestPerformer,
        cleaning recognitions: [RunningRecognition]
    ) async -> Bool {
        performer.finish(index, with: resolution)
        let exited = await performer.waitUntilPerformExited(index)
        #expect(exited)
        guard exited else {
            await drain(recognitions, releasing: performer)
            return false
        }
        return true
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

    private func expectStableFailure(_ outcome: RecognitionOutcome?) {
        guard case .failure(
            let error as AppleVisionMedicineTextRecognizer.Failure
        ) = outcome else {
            Issue.record("Vision failure used an unexpected error type")
            return
        }
        #expect(
            error == .recognitionFailed("vision_text_recognition_failed")
        )
    }

    @Test func recognizerRejectsEmptyImage() async {
        do {
            _ = try await AppleVisionMedicineTextRecognizer().recognizeText(
                in: makeInput(data: Data())
            )
            Issue.record("empty image data must be rejected")
        } catch let error as AppleVisionMedicineTextRecognizer.Failure {
            #expect(error == .emptyImageData)
        } catch {
            Issue.record("unexpected empty-image error")
        }
    }

    @Test func preCancelledTaskWinsOverEmptyImage() async {
        let (performer, running) = startScenario(
            behavior: .succeed,
            input: makeInput(data: Data()),
            preCancelled: true
        )

        expectCancellation(
            await waitForOutcome(running, releasing: performer)
        )
        #expect(performer.metrics.makeRequestCount == 0)
        #expect(performer.metrics.performCount == 0)
    }

    @MainActor
    @Test func recognitionDoesNotRunOnMainActor() async {
        let (performer, running) = startScenario(behavior: .succeed)

        expectSuccess(await waitForOutcome(running, releasing: performer))
        #expect(performer.metrics.performedOnMainThread == false)
    }

    @Test func cancellationBeforePerformThrowsCancellationError() async {
        let startGate = StartGate()
        let (performer, running) = startScenario(
            behavior: .succeed,
            startGate: startGate
        )

        let entered = await startGate.waitUntilEntered()
        #expect(entered)
        guard entered else {
            startGate.open()
            await drain([running], releasing: performer)
            return
        }
        running.task.cancel()
        startGate.open()

        expectCancellation(
            await waitForOutcome(running, releasing: performer)
        )
        #expect(performer.metrics.makeRequestCount == 0)
        #expect(performer.metrics.performCount == 0)
    }

    @Test func cancellationDuringPerformCancelsCurrentRequest() async {
        let (performer, running) = startScenario(
            behavior: .waitForResolution,
            cancellationResolution: .requestCancelled
        )
        guard await requirePerformEntered(
            0, performer, cleaning: [running]
        ) else { return }

        running.task.cancel()
        let cancelObserved = await performer.waitUntilRequestCancelObserved(0)
        #expect(cancelObserved)
        let outcome = await waitForOutcome(running, releasing: performer)

        expectCancellation(outcome)
        #expect(performer.metrics.cancellationCount(for: 0) == 1)
        #expect(performer.metrics.performCount == 1)
        #expect(running.completion.publicationCount == 1)
    }

    @Test func visionRequestCancelledMapsToCancellationError() async {
        let (performer, running) = startScenario(
            behavior: .fail(visionError(.requestCancelled))
        )

        expectCancellation(
            await waitForOutcome(running, releasing: performer)
        )
    }

    @Test func performerCancellationErrorPassesThrough() async {
        let (performer, running) = startScenario(
            behavior: .failCancellationError
        )

        expectCancellation(
            await waitForOutcome(running, releasing: performer)
        )
        #expect(performer.metrics.performCount == 1)
    }

    @Test func cancellationAfterPerformPreventsSuccessPublication() async {
        let (performer, running) = startScenario(
            behavior: .cancelCurrentTaskThenSucceed
        )

        expectCancellation(
            await waitForOutcome(running, releasing: performer)
        )
        #expect(performer.metrics.totalCancellationCount == 1)
        #expect(running.completion.publicationCount == 1)
    }

    @Test func normalCompletionWinsAndPublishesOnce() async {
        let (performer, running) = startScenario(
            behavior: .waitForResolution
        )
        guard await requirePerformEntered(
            0, performer, cleaning: [running]
        ) else { return }
        guard await resolveAndRequireExit(
            0, .success, performer, cleaning: [running]
        ) else { return }

        let outcome = await waitForOutcome(running, releasing: performer)
        if case .success(let observations) = outcome {
            #expect(observations.isEmpty)
        } else {
            Issue.record("normal completion did not publish success")
        }
        #expect(running.completion.publicationCount == 1)
        #expect(performer.metrics.performCount == 1)

        running.task.cancel()
        #expect(performer.metrics.totalCancellationCount == 0)
    }

    @Test func nonCancellationVisionFailureIsContentFree() async {
        let (performer, running) = startScenario(
            behavior: .fail(
                visionError(
                    .invalidImage,
                    localizedDescription: "private image detail"
                )
            )
        )

        expectStableFailure(
            await waitForOutcome(running, releasing: performer)
        )
    }

    @Test func cancelledFirstPerformMustExitBeforeSecondStarts() async {
        let performer = SequencedVisionTextRequestPerformer(
            expectedRequestCount: 2
        )
        let recognizer = makeRecognizer(performer: performer)
        let first = startRecognition(recognizer)
        guard await requirePerformEntered(
            0, performer, cleaning: [first]
        ) else { return }

        let secondStarted = TestEvent("second recognition started")
        let second = startRecognition(
            recognizer,
            startSignal: secondStarted
        )
        #expect(await secondStarted.wait())
        first.task.cancel()
        #expect(await performer.waitUntilRequestCancelObserved(0))

        // Cancellation is only a signal: A still owns the permit here.
        #expect(performer.metrics.makeRequestCount == 1)
        #expect(performer.metrics.activePerformCount == 1)
        #expect(performer.metrics.entryOrder == [0])

        guard await resolveAndRequireExit(
            0, .requestCancelled, performer, cleaning: [first, second]
        ) else { return }
        guard await requirePerformEntered(
            1, performer, cleaning: [first, second]
        ) else { return }
        guard await resolveAndRequireExit(
            1, .success, performer, cleaning: [first, second]
        ) else { return }

        expectCancellation(await waitForOutcome(first, releasing: performer))
        expectSuccess(await waitForOutcome(second, releasing: performer))
        #expect(performer.metrics.maxConcurrentPerformCount == 1)
        #expect(performer.metrics.entryOrder == [0, 1])
        #expect(performer.metrics.exitOrder == [0, 1])
    }

    @Test func threeCallsRemainSingleFlight() async {
        let performer = SequencedVisionTextRequestPerformer(
            expectedRequestCount: 3
        )
        let recognizer = makeRecognizer(performer: performer)
        let first = startRecognition(recognizer)
        guard await requirePerformEntered(
            0, performer, cleaning: [first]
        ) else { return }

        let secondStarted = TestEvent("second recognition started")
        let thirdStarted = TestEvent("third recognition started")
        let second = startRecognition(recognizer, startSignal: secondStarted)
        let third = startRecognition(recognizer, startSignal: thirdStarted)
        #expect(await secondStarted.wait())
        #expect(await thirdStarted.wait())
        #expect(performer.metrics.makeRequestCount == 1)

        guard await resolveAndRequireExit(
            0, .success, performer, cleaning: [first, second, third]
        ), await requirePerformEntered(
            1, performer, cleaning: [first, second, third]
        ) else { return }
        #expect(performer.metrics.activePerformCount == 1)
        guard await resolveAndRequireExit(
            1, .success, performer, cleaning: [first, second, third]
        ), await requirePerformEntered(
            2, performer, cleaning: [first, second, third]
        ), await resolveAndRequireExit(
            2, .success, performer, cleaning: [first, second, third]
        ) else { return }

        for running in [first, second, third] {
            expectSuccess(await waitForOutcome(running, releasing: performer))
        }
        #expect(performer.metrics.maxConcurrentPerformCount == 1)
        #expect(performer.metrics.entryOrder == [0, 1, 2])
        #expect(performer.metrics.exitOrder == [0, 1, 2])
        #expect(performer.metrics.activePerformCount == 0)
    }

    @Test func cancelledWaiterDoesNotConsumePermit() async {
        let performer = SequencedVisionTextRequestPerformer(
            expectedRequestCount: 3
        )
        let recognizer = makeRecognizer(performer: performer)
        let first = startRecognition(recognizer)
        guard await requirePerformEntered(
            0, performer, cleaning: [first]
        ) else { return }

        let waiterStarted = TestEvent("waiting recognition started")
        let waiter = startRecognition(recognizer, startSignal: waiterStarted)
        #expect(await waiterStarted.wait())
        waiter.task.cancel()
        expectCancellation(await waitForOutcome(waiter, releasing: performer))

        #expect(performer.metrics.makeRequestCount == 1)
        #expect(performer.metrics.performCount == 1)
        #expect(performer.metrics.entryOrder == [0])
        guard await resolveAndRequireExit(
            0, .success, performer, cleaning: [first]
        ) else { return }
        expectSuccess(await waitForOutcome(first, releasing: performer))

        let thirdIndex = performer.metrics.makeRequestCount
        let third = startRecognition(recognizer)
        guard await requirePerformEntered(
            thirdIndex, performer, cleaning: [third]
        ), await resolveAndRequireExit(
            thirdIndex, .success, performer, cleaning: [third]
        ) else { return }
        expectSuccess(await waitForOutcome(third, releasing: performer))

        #expect(performer.metrics.maxConcurrentPerformCount == 1)
        #expect(performer.metrics.entryOrder == [0, 1])
        #expect(performer.metrics.exitOrder == [0, 1])
        #expect(performer.metrics.activePerformCount == 0)
    }

    @Test func copiedRecognizerSharesSingleFlightBoundary() async {
        let performer = SequencedVisionTextRequestPerformer(
            expectedRequestCount: 2
        )
        let original = makeRecognizer(performer: performer)
        let copy = original
        guard let pair = await startPairWhileFirstPerforms(
            original,
            copy,
            performer: performer
        ) else { return }

        #expect(performer.metrics.makeRequestCount == 1)
        #expect(performer.metrics.entryOrder == [0])
        guard await finishPairInOrder(pair, performer: performer) else {
            return
        }
        #expect(performer.metrics.maxConcurrentPerformCount == 1)
    }

    @Test func independentlyConstructedRecognizersShareDefaultGate() async {
        let performer = SequencedVisionTextRequestPerformer(
            expectedRequestCount: 2
        )
        guard let pair = await startPairWhileFirstPerforms(
            AppleVisionMedicineTextRecognizer(performer: performer),
            AppleVisionMedicineTextRecognizer(performer: performer),
            performer: performer
        ) else { return }

        #expect(performer.metrics.makeRequestCount == 1)
        #expect(performer.metrics.entryOrder == [0])
        guard await finishPairInOrder(pair, performer: performer) else {
            return
        }
        #expect(performer.metrics.maxConcurrentPerformCount == 1)
    }

    private func startPairWhileFirstPerforms(
        _ firstRecognizer: AppleVisionMedicineTextRecognizer,
        _ secondRecognizer: AppleVisionMedicineTextRecognizer,
        performer: SequencedVisionTextRequestPerformer
    ) async -> (first: RunningRecognition, second: RunningRecognition)? {
        let first = startRecognition(firstRecognizer)
        guard await requirePerformEntered(
            0, performer, cleaning: [first]
        ) else { return nil }

        let secondStarted = TestEvent("second recognition started")
        let second = startRecognition(
            secondRecognizer,
            startSignal: secondStarted
        )
        let started = await secondStarted.wait()
        #expect(started)
        guard started else {
            await drain([first, second], releasing: performer)
            return nil
        }
        return (first, second)
    }

    private func finishPairInOrder(
        _ pair: (first: RunningRecognition, second: RunningRecognition),
        performer: SequencedVisionTextRequestPerformer
    ) async -> Bool {
        guard await resolveAndRequireExit(
            0, .success, performer, cleaning: [pair.first, pair.second]
        ), await requirePerformEntered(
            1, performer, cleaning: [pair.first, pair.second]
        ), await resolveAndRequireExit(
            1, .success, performer, cleaning: [pair.first, pair.second]
        ) else { return false }

        expectSuccess(await waitForOutcome(pair.first, releasing: performer))
        expectSuccess(await waitForOutcome(pair.second, releasing: performer))
        #expect(performer.metrics.entryOrder == [0, 1])
        #expect(performer.metrics.exitOrder == [0, 1])
        #expect(performer.metrics.activePerformCount == 0)
        return true
    }

    @Test(arguments: PermitExitPath.allCases)
    func permitIsReleasedOnEveryExitPath(_ path: PermitExitPath) async {
        let gate = VisionTextRecognitionSingleFlightGate()

        switch path {
        case .registrationRejected:
            let fixture = ControllerFixture(requestCount: 2)
            do {
                let _: Bool = try await gate.withPermit {
                    #expect(fixture.controller.register(fixture.requests[0])
                        == .registered)
                    #expect(fixture.controller.register(fixture.requests[1])
                        == .rejectedAlreadyRegistered)
                    fixture.controller.clear(fixture.requests[0])
                    throw PermitExitPath.registrationRejected
                }
                Issue.record("registration rejection must throw")
            } catch PermitExitPath.registrationRejected {} catch {
                Issue.record("unexpected registration rejection error")
            }
        default:
            let behavior: SequencedVisionTextRequestPerformer.Behavior =
                switch path {
                case .success: .succeed
                case .ordinaryFailure: .fail(visionError(.operationFailed))
                case .cancellationError: .failCancellationError
                case .requestCancelled: .fail(visionError(.requestCancelled))
                case .registrationRejected:
                    preconditionFailure("handled above")
                }
            let (performer, running) = startScenario(
                behavior: behavior,
                gate: gate
            )
            let outcome = await waitForOutcome(running, releasing: performer)
            if path == .success {
                expectSuccess(outcome)
            } else if path == .ordinaryFailure {
                expectStableFailure(outcome)
            } else {
                expectCancellation(outcome)
            }
            #expect(performer.metrics.performCount == 1)
            #expect(performer.metrics.activePerformCount == 0)
        }

        let (nextPerformer, nextRunning) = startScenario(
            behavior: .succeed,
            gate: gate
        )
        expectSuccess(
            await waitForOutcome(nextRunning, releasing: nextPerformer)
        )
        #expect(nextPerformer.metrics.makeRequestCount == 1)
        #expect(nextPerformer.metrics.performCount == 1)
    }

    @Test func unifiedPerformerRejectsRequestCreatedByAnotherPerformer() throws {
        let creator = SequencedVisionTextRequestPerformer()
        let receiver = SequencedVisionTextRequestPerformer()
        let foreignRequest = creator.makeRequest()

        do {
            try receiver.perform(foreignRequest, data: Data([1]), orientation: .up)
            Issue.record("foreign request must be rejected")
        } catch let error as TestPerformerError {
            #expect(error == .foreignRequest)
        } catch {
            Issue.record("foreign request used an unexpected error")
        }
        let rejectedMetrics = receiver.metrics
        #expect(rejectedMetrics.performCount == 0)
        #expect(rejectedMetrics.activePerformCount == 0)
        #expect(rejectedMetrics.entryOrder.isEmpty)
        #expect(rejectedMetrics.exitOrder.isEmpty)

        foreignRequest.cancel()
        #expect(creator.metrics.cancellationCount(for: 0) == 1)
        #expect(receiver.metrics.totalCancellationCount == 0)

        let ownRequest = receiver.makeRequest()
        receiver.finish(0, with: .success)
        try receiver.perform(ownRequest, data: Data([1]), orientation: .up)
        let acceptedMetrics = receiver.metrics
        #expect(acceptedMetrics.performCount == 1)
        #expect(acceptedMetrics.activePerformCount == 0)
        #expect(acceptedMetrics.entryOrder == [0])
        #expect(acceptedMetrics.exitOrder == [0])
    }

    @Test func cancelBeforeRegisterImmediatelyCancelsRequest() {
        let fixture = ControllerFixture(requestCount: 1)
        fixture.controller.cancel()

        #expect(fixture.controller.register(fixture.requests[0])
            == .cancelImmediately)
        #expect(fixture.requests[0].cancelCount == 1)
    }

    @Test func differentRequestCannotOverwriteRegisteredRequest() {
        let fixture = ControllerFixture(requestCount: 2)
        let oldRequest = fixture.requests[0]
        let rejectedRequest = fixture.requests[1]

        #expect(oldRequest !== rejectedRequest)
        #expect(fixture.controller.register(oldRequest) == .registered)
        #expect(fixture.controller.register(rejectedRequest)
            == .rejectedAlreadyRegistered)
        fixture.controller.cancel()

        #expect(oldRequest.cancelCount == 1)
        #expect(rejectedRequest.cancelCount == 0)
    }

    @Test func clearDoesNotRemoveANewerRequest() {
        let fixture = ControllerFixture(requestCount: 2)
        let oldRequest = fixture.requests[0]
        let newRequest = fixture.requests[1]

        #expect(oldRequest !== newRequest)
        #expect(fixture.controller.register(oldRequest) == .registered)
        fixture.controller.clear(oldRequest)
        #expect(fixture.controller.register(newRequest) == .registered)
        fixture.controller.clear(oldRequest)
        fixture.controller.cancel()

        #expect(oldRequest.cancelCount == 0)
        #expect(newRequest.cancelCount == 1)
    }

    @Test func completionFirstPreventsLateCancellationOfRequest() {
        let fixture = ControllerFixture(requestCount: 1)
        let request = fixture.requests[0]
        #expect(fixture.controller.register(request) == .registered)

        #expect(fixture.controller.complete(
            request, taskIsCancelled: { @Sendable in false }
        ))
        fixture.controller.cancel()

        #expect(request.cancelCount == 0)
        #expect(!fixture.controller.complete(
            request, taskIsCancelled: { @Sendable in false }
        ))
    }

    @Test func cancellationFirstPreventsCompletionAndCancelsOnce() {
        let fixture = ControllerFixture(requestCount: 1)
        let request = fixture.requests[0]
        #expect(fixture.controller.register(request) == .registered)

        fixture.controller.cancel()
        #expect(!fixture.controller.complete(
            request, taskIsCancelled: { @Sendable in false }
        ))
        fixture.controller.cancel()

        #expect(request.cancelCount == 1)
    }

    @Test func repeatedCancelIsIdempotent() {
        let fixture = ControllerFixture(requestCount: 1)
        let request = fixture.requests[0]
        #expect(fixture.controller.register(request) == .registered)

        fixture.controller.cancel()
        fixture.controller.cancel()
        fixture.controller.cancel()

        #expect(request.cancelCount == 1)
    }
}
