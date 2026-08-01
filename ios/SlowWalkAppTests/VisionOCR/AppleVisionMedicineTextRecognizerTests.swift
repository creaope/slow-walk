import Foundation
import os
import SlowWalkClientCore
import Testing
import UIKit

@testable import SlowWalkApp

@Suite("Apple Vision text recognizer")
struct AppleVisionMedicineTextRecognizerTests {
    /// Deterministic one-bit gate used to deliver cancellation while a
    /// recognition is deterministically paused before `perform(_:)`.
    private actor CancellationGate {
        private var isOpen = false
        private var enterCount = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var enterWaiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            enterCount += 1
            let entered = enterWaiters
            enterWaiters.removeAll()
            entered.forEach { $0.resume() }
            if isOpen { return }
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Void, Never>) in
                if isOpen {
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                }
            }
        }

        func waitUntilEntered() async {
            if enterCount > 0 { return }
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Void, Never>) in
                if enterCount > 0 {
                    continuation.resume()
                } else {
                    enterWaiters.append(continuation)
                }
            }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    /// Lock-protected box so the `@Sendable` execution probe can record the
    /// thread it observed without introducing actor hops (and races) into
    /// the probed code path.
    private final class ThreadProbeBox: Sendable {
        private let storage = OSAllocatedUnfairLock<Bool?>(
            initialState: nil
        )

        nonisolated func record(_ isMainThread: Bool) {
            storage.withLock { $0 = isMainThread }
        }

        nonisolated var observed: Bool? {
            storage.withLock { $0 }
        }
    }

    private func makeBlankPNGData() -> Data {
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 32, height: 32)
        )
        return renderer.pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
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
            Issue.record("unexpected error: \(error)")
        }
    }

    /// The blocking Vision call must not run on the caller's executor.
    /// Regression criterion: if `@concurrent` is removed from
    /// `performRecognition`, the work inherits this MainActor test's
    /// executor and the probe observes the main thread, failing the test.
    @MainActor
    @Test func recognitionDoesNotRunOnMainActor() async throws {
        let probe = ThreadProbeBox()
        let recognizer = AppleVisionMedicineTextRecognizer(
            executionProbe: { probe.record(Thread.isMainThread) }
        )
        let input = OCRImageInput(
            data: makeBlankPNGData(),
            orientation: .up,
            capturedAt: Date(timeIntervalSince1970: 100)
        )

        _ = try await recognizer.recognizeText(in: input)

        #expect(probe.observed == false)
    }

    /// A task cancelled mid-recognition must surface `CancellationError`
    /// and must never publish the stale success result.
    @Test func cancelledRecognitionDoesNotPublishResults() async {
        let gate = CancellationGate()
        let recognizer = AppleVisionMedicineTextRecognizer(
            recognitionGate: { await gate.wait() }
        )
        let input = OCRImageInput(
            data: makeBlankPNGData(),
            orientation: .up,
            capturedAt: Date(timeIntervalSince1970: 100)
        )

        let task = Task {
            try await recognizer.recognizeText(in: input)
        }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.open()

        do {
            _ = try await task.value
            Issue.record("cancelled recognition must not return results")
        } catch is CancellationError {
            // Expected: cancellation wins over the in-flight success.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    /// Vision failures surface as a stable, content-free reason; no
    /// `localizedDescription` (which can embed image-derived details)
    /// crosses the adapter boundary.
    @Test func recognitionFailureIsContentFree() async {
        let recognizer = AppleVisionMedicineTextRecognizer()
        let input = OCRImageInput(
            data: Data("not an image".utf8),
            orientation: .up,
            capturedAt: Date(timeIntervalSince1970: 100)
        )

        do {
            _ = try await recognizer.recognizeText(in: input)
            Issue.record("non-image data must fail recognition")
        } catch let error as AppleVisionMedicineTextRecognizer.Failure {
            #expect(
                error == .recognitionFailed(
                    "vision_text_recognition_failed"
                )
            )
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
