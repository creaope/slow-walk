@preconcurrency import AVFoundation
import Foundation
import SlowWalkClientCore
import Testing

@testable import SlowWalkApp

@MainActor
struct MedicineCaptureViewContractTests {
    @Test func scannerAcceptsExactlyOnePage() {
        #expect(
            MedicineDocumentScanContract.failure(forPageCount: 0)
                == .scannerReturnedNoPage
        )
        #expect(MedicineDocumentScanContract.failure(forPageCount: 1) == nil)
        #expect(
            MedicineDocumentScanContract.failure(forPageCount: 2)
                == .multiplePages
        )
    }

    @Test func scannerAvailabilityDistinguishesPermissionAndHardwareFailures() {
        #expect(
            MedicineDocumentScanContract.failure(
                for: .denied,
                isScannerSupported: true
            ) == .permissionDenied
        )
        #expect(
            MedicineDocumentScanContract.failure(
                for: .restricted,
                isScannerSupported: true
            ) == .permissionRestricted
        )
        #expect(
            MedicineDocumentScanContract.failure(
                for: .authorized,
                isScannerSupported: false
            ) == .cameraUnavailable
        )
        #expect(
            MedicineDocumentScanContract.failure(
                for: .authorized,
                isScannerSupported: true
            ) == nil
        )
    }

    @Test func invalidInputNeverReusesOrSubmitsPreviousImage() {
        var state = MedicineCaptureInputState()
        var submitted = [Data]()

        if let data = state.accept(Data([1]), failure: .imageEncodingFailed) {
            submitted.append(data)
        }
        if let data = state.accept(nil, failure: .imageEncodingFailed) {
            submitted.append(data)
        }
        if let data = state.accept(Data(), failure: .photoLoadFailed) {
            submitted.append(data)
        }

        #expect(submitted == [Data([1])])
        #expect(state.failure == .photoLoadFailed)
    }

    @Test func scannerFailureNeverCallsSuccessfulImageCallback() {
        var state = MedicineCaptureInputState()
        var callbackCount = 0

        for failure in [
            MedicineCaptureInputFailure.scannerFailed,
            .permissionDenied,
            .permissionRestricted,
            .cameraUnavailable,
            .scannerReturnedNoPage,
            .multiplePages,
            .imageEncodingFailed,
        ] {
            state.reject(failure)
            if state.accept(nil, failure: failure) != nil {
                callbackCount += 1
            }
        }

        #expect(callbackCount == 0)
        #expect(state.failure == .imageEncodingFailed)
    }

    @Test func closeGateRequestsDismissalOnlyOnce() {
        var gate = MedicineCaptureCloseGate()
        var dismissCallCount = 0

        for _ in 0..<2 where gate.requestDismissal() {
            dismissCallCount += 1
        }

        #expect(dismissCallCount == 1)
        #expect(gate.hasRequestedDismissal)
    }

    @Test func fullScreenCaptureOwnsVisibleNamedCloseChrome() throws {
        let source = try Self.captureViewSource()

        #expect(source.contains("NavigationStack {"))
        #expect(source.contains("MedicineCaptureCopy.close"))
        #expect(
            source.contains(
                ".accessibilityIdentifier(\"medicine-capture-close\")"
            )
        )
        #expect(source.contains("guard closeGate.requestDismissal() else"))
    }

    @Test func successfulRecognitionHasARealFocusTarget() {
        let observation = RecognizedTextObservation(
            text: "二甲双胍片",
            confidence: 0.99,
            boundingRegion: nil,
            languageCode: "zh-Hans",
            observedAt: Date(timeIntervalSince1970: 0)
        )

        #expect(
            MedicineCaptureAccessibilityFocusResolver.target(
                for: .success([observation]),
                submissionStatus: .none
            ) == .recognizedResult
        )
        let nonResultStates: [MedicineCaptureState] = [
            .idle,
            .requestingPermission,
            .permissionDenied,
            .cameraRestricted,
            .startingCamera,
            .ready,
            .capturing,
            .loadingPhoto(generation: 1),
            .recognizing(generation: 1),
            .noTextFound,
            .recognitionFailed("test"),
            .cancelled,
            .cameraUnavailable,
        ]
        for state in nonResultStates {
            #expect(
                MedicineCaptureAccessibilityFocusResolver.target(
                    for: state,
                    submissionStatus: .none
                ) == .status
            )
        }
        #expect(
            MedicineCaptureAccessibilityFocusResolver.target(
                for: .success([observation]),
                submissionStatus: .submitted
            ) == .status
        )
    }

    private static func captureViewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SlowWalkApp")
            .appendingPathComponent("Features")
            .appendingPathComponent("MedicineCapture")
            .appendingPathComponent("MedicineCaptureView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
