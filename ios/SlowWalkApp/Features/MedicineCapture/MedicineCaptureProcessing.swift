import SlowWalkClientCore

enum MedicineCaptureProcessingResult: Equatable, Sendable {
    case recognized([RecognizedTextObservation])
    case submittedForAssessment
}

enum MedicineCaptureProcessingFailure: String, Error, Equatable, Sendable {
    case processingFailed = "processing_failed"
    case assessmentGateUnavailable = "assessment_gate_unavailable"
    case assessmentSubmissionRejected = "assessment_submission_rejected"
    case cancelled
}

@MainActor
protocol MedicineCaptureProcessing: AnyObject {
    func process(
        _ input: OCRImageInput
    ) async throws -> MedicineCaptureProcessingResult

    func cancel() async
}

@MainActor
final class MedicineCaptureStandaloneOCRProcessor: MedicineCaptureProcessing {
    private let recognizer: any MedicineTextRecognizing

    init(recognizer: any MedicineTextRecognizing) {
        self.recognizer = recognizer
    }

    func process(
        _ input: OCRImageInput
    ) async throws -> MedicineCaptureProcessingResult {
        do {
            let observations = try await recognizer.recognizeText(in: input)
            try Task.checkCancellation()
            return .recognized(observations)
        } catch is CancellationError {
            throw MedicineCaptureProcessingFailure.cancelled
        } catch let failure as AppleVisionMedicineTextRecognizer.Failure {
            throw failure
        } catch {
            throw MedicineCaptureProcessingFailure.processingFailed
        }
    }

    func cancel() async {
        // Recognition runs in the caller's task, which is cancelled first.
    }
}
