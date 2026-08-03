import Foundation
import SlowWalkClientCore
import SlowWalkDomain

typealias UserHealthProfileProvider = @MainActor () -> UserHealthProfile
typealias MedicationRecordsProvider = @MainActor () -> [MedicationRecord]

@MainActor
final class MedicineAssessmentCaptureSubmitter: MedicineCaptureProcessing {
    private let runner: MedicineAssessmentRunner
    private let userHealthProfileProvider: UserHealthProfileProvider
    private let medicationRecordsProvider: MedicationRecordsProvider
    private var activeOperationID: UUID?

    init(
        runner: MedicineAssessmentRunner,
        userHealthProfileProvider: @escaping UserHealthProfileProvider,
        medicationRecordsProvider: @escaping MedicationRecordsProvider
    ) {
        self.runner = runner
        self.userHealthProfileProvider = userHealthProfileProvider
        self.medicationRecordsProvider = medicationRecordsProvider
    }

    func process(
        _ input: OCRImageInput
    ) async throws -> MedicineCaptureProcessingResult {
        guard !Task.isCancelled else {
            throw MedicineCaptureProcessingFailure.cancelled
        }
        let operationID = UUID()
        activeOperationID = operationID
        defer {
            if activeOperationID == operationID {
                activeOperationID = nil
            }
        }

        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let invocation = runner.makeAssessmentInvocation(
                    imageInput: input,
                    userProfile: userHealthProfileProvider(),
                    recentRecords: medicationRecordsProvider()
                )
                guard let invocation else {
                    throw MedicineCaptureProcessingFailure
                        .assessmentGateUnavailable
                }

                let accepted = await runner.start(invocation)
                try Task.checkCancellation()
                guard accepted else {
                    throw MedicineCaptureProcessingFailure
                        .assessmentSubmissionRejected
                }
                return .submittedForAssessment
            } catch is CancellationError {
                await stopIfCurrent(operationID)
                throw MedicineCaptureProcessingFailure.cancelled
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                await self?.stopIfCurrent(operationID)
            }
        }
    }

    func cancel() async {
        let operationID = activeOperationID
        await runner.stop()
        if activeOperationID == operationID {
            activeOperationID = nil
        }
    }

    private func stopIfCurrent(_ operationID: UUID) async {
        guard activeOperationID == operationID else { return }
        await runner.stop()
        if activeOperationID == operationID {
            activeOperationID = nil
        }
    }
}
