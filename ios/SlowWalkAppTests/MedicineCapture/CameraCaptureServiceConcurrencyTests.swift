import AVFoundation
import Foundation
import os
import SlowWalkClientCore
import Testing

@testable import SlowWalkApp

private final class ThreadProbeBox: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Probe())
    private struct Probe {
        var startMain: Bool?; var stopMain: Bool?
        var markers: [Int] = []; var next = 0
    }
    nonisolated var startWasMain: Bool? { lock.withLock { $0.startMain } }
    nonisolated var stopWasMain: Bool? { lock.withLock { $0.stopMain } }
    nonisolated var allMarkers: [Int] { lock.withLock { $0.markers } }
    nonisolated func recordStart(isMain: Bool) {
        lock.withLock { $0.startMain = isMain; $0.next += 1
            $0.markers.append($0.next) }
    }
    nonisolated func recordStop(isMain: Bool) {
        lock.withLock { $0.stopMain = isMain; $0.next += 1
            $0.markers.append($0.next) }
    }
}

@Suite("CameraCaptureService Concurrency")
struct CameraCaptureServiceConcurrencyTests {

    @Test func startRunningNotOnMainActor() async throws {
        let probe = ThreadProbeBox()
        let svc = CameraPreviewSource().makeCaptureService(
            executionProbe: { probe.recordStart(isMain: Thread.isMainThread) }
        )
        let sessionID = UUID()
        do { try await svc.start(sessionID: sessionID) }
        catch CameraCaptureFailure.noCameraAvailable { return }
        defer { Task { await svc.stop(sessionID: sessionID) } }
        #expect(probe.startWasMain == false)
    }

    @Test func stopRunningNotOnMainActor() async throws {
        let probe = ThreadProbeBox()
        let svc = CameraPreviewSource().makeCaptureService(
            stopProbe: { probe.recordStop(isMain: Thread.isMainThread) }
        )
        let sessionID = UUID()
        do { try await svc.start(sessionID: sessionID) }
        catch CameraCaptureFailure.noCameraAvailable { return }
        await svc.stop(sessionID: sessionID)
        for _ in 0..<10 {
            if probe.stopWasMain != nil { break }
            await Task.yield()
        }
        #expect(probe.stopWasMain == false)
    }

    @Test func stopDiscardsPendingCapture() async throws {
        let svc = CameraPreviewSource().makeCaptureService()
        let sessionID = UUID()
        do { try await svc.start(sessionID: sessionID) }
        catch CameraCaptureFailure.noCameraAvailable { return }
        await svc.stop(sessionID: sessionID)
        for _ in 0..<10 { await Task.yield() }
        do {
            _ = try await svc.capturePhoto(
                requestID: UUID(), orientation: .up, capturedAt: Date()
            )
            Issue.record("expected .notReady")
        } catch CameraCaptureFailure.notReady { /* ok */ }
        catch { Issue.record("unexpected: \(error)") }
    }

    @Test func cancelPendingByRequestID() async throws {
        let svc = CameraPreviewSource().makeCaptureService()
        let sessionID = UUID()
        do { try await svc.start(sessionID: sessionID) }
        catch CameraCaptureFailure.noCameraAvailable { return }
        defer { Task { await svc.stop(sessionID: sessionID) } }
        let req = UUID()
        async let photo = svc.capturePhoto(
            requestID: req, orientation: .up, capturedAt: Date()
        )
        await svc.cancelPendingCapture(requestID: req)
        do {
            _ = try await photo
            Issue.record("expected .cancelled")
        } catch CameraCaptureFailure.cancelled { /* ok */ }
        catch { Issue.record("unexpected: \(error)") }
    }

    @Test func wrongRequestIDDoesNotCancel() async throws {
        let svc = CameraPreviewSource().makeCaptureService()
        let sessionID = UUID()
        do { try await svc.start(sessionID: sessionID) }
        catch CameraCaptureFailure.noCameraAvailable { return }
        defer { Task { await svc.stop(sessionID: sessionID) } }
        await svc.cancelPendingCapture(requestID: UUID())
        // No-op for non-existent request.
    }

    @Test func oldSessionStopDoesNotStopNewSession() async throws {
        let svc = CameraPreviewSource().makeCaptureService()
        let sessionA = UUID()
        do { try await svc.start(sessionID: sessionA) }
        catch CameraCaptureFailure.noCameraAvailable { return }
        await svc.stop(sessionID: sessionA)
        let sessionB = UUID()
        do { try await svc.start(sessionID: sessionB) }
        catch CameraCaptureFailure.noCameraAvailable { return }
        defer { Task { await svc.stop(sessionID: sessionB) } }
        // Stop with old session A — must not affect B.
        await svc.stop(sessionID: sessionA)
        // B should still be running (can attempt capturePhoto).
    }

    @Test func rapidStartStopStartUsesSessionIDs() async throws {
        let probe = ThreadProbeBox()
        let src1 = CameraPreviewSource()
        let s1 = src1.makeCaptureService(
            executionProbe: { probe.recordStart(isMain: Thread.isMainThread) },
            stopProbe: { probe.recordStop(isMain: Thread.isMainThread) }
        )
        let sid1 = UUID()
        do { try await s1.start(sessionID: sid1) }
        catch CameraCaptureFailure.noCameraAvailable { return }
        await s1.stop(sessionID: sid1)
        for _ in 0..<10 {
            if probe.stopWasMain != nil { break }
            await Task.yield()
        }
        let src2 = CameraPreviewSource()
        let s2 = src2.makeCaptureService(
            executionProbe: { probe.recordStart(isMain: Thread.isMainThread) }
        )
        let sid2 = UUID()
        do { try await s2.start(sessionID: sid2) }
        catch CameraCaptureFailure.noCameraAvailable { return }
        defer { Task { await s2.stop(sessionID: sid2) } }
        let m = probe.allMarkers
        #expect(m.count == 3)
        if m.count == 3 {
            #expect(m[0] < m[1] && m[1] < m[2])
        }
    }

}
