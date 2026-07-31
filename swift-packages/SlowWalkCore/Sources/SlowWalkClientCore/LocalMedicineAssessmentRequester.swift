import Foundation
import SlowWalkAPIContracts
import SlowWalkDomain
import SlowWalkMedicinePipeline

/// Device-local adapter from the existing client contract to MedicinePipeline.
///
/// It performs no HTTP request and retains at most one pending confirmation
/// context. Starting another assessment invalidates the previous context.
public actor LocalMedicineAssessmentRequester:
    MedicineAssessmentRequesting,
    MedicineCandidateConfirming
{
    private struct PendingConfirmation: Sendable {
        let request: MedicineAssessmentRequestDTO
        let context: MedicineConfirmationContext
    }

    private let pipeline: MedicinePipeline
    private let confirmationBarrier: (any LocalConfirmationBarrier)?
    private var pendingConfirmation: PendingConfirmation?
    private var assessmentGeneration: UInt64 = 0

    public init(pipeline: MedicinePipeline) {
        self.pipeline = pipeline
        confirmationBarrier = nil
    }

    /// Test-only composition that can suspend a confirmation mid-flight.
    ///
    /// `assessConfirmedCandidate` has no injectable suspension point, so the
    /// stale-confirmation guard would otherwise only be observable by guessing
    /// the scheduler. The barrier is internal and unavailable to clients.
    init(
        pipeline: MedicinePipeline,
        confirmationBarrier: any LocalConfirmationBarrier
    ) {
        self.pipeline = pipeline
        self.confirmationBarrier = confirmationBarrier
    }

    /// Explicit demo composition using the bundled non-clinical catalog.
    public static func demo() -> LocalMedicineAssessmentRequester {
        LocalMedicineAssessmentRequester(
            pipeline: MedicinePipeline()
        )
    }

    /// Explicit deterministic demo composition for previews and tests.
    public static func demo(
        clock: any Clock
    ) -> LocalMedicineAssessmentRequester {
        LocalMedicineAssessmentRequester(
            pipeline: MedicinePipeline(dateProvider: clock)
        )
    }

    public func assess(
        request: MedicineAssessmentRequestDTO
    ) async throws -> MedicineAssessmentResponseDTO {
        try Task.checkCancellation()
        assessmentGeneration &+= 1
        let operationGeneration = assessmentGeneration
        pendingConfirmation = nil
        try validateVersion(request)

        let result: MedicinePipelineAssessmentResult
        do {
            let records = try request.recentRecords.map {
                try $0.domainModel()
            }
            result = try await pipeline.assess(
                input: request.input,
                userProfile: request.userProfile.domainModel,
                recentRecords: records
            )
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw canonicalClientError(
                for: error,
                requestID: request.requestID
            )
        }

        if operationGeneration == assessmentGeneration,
            let context = result.confirmationContext
        {
            pendingConfirmation = PendingConfirmation(
                request: request,
                context: context
            )
        }
        return makeResponse(from: result, request: request)
    }

    public func confirmMedicine(
        command: MedicineCandidateConfirmationCommand
    ) async throws -> MedicineAssessmentResponseDTO {
        try Task.checkCancellation()
        guard let pendingConfirmation,
            pendingConfirmation.request.requestID
                == command.originalRequestID
        else {
            throw LocalMedicineConfirmationError.noPendingAssessment
        }
        guard
            pendingConfirmation.context.candidates.contains(
                where: { $0.medicine.id == command.candidateID }
            )
        else {
            throw LocalMedicineConfirmationError.candidateNotOffered
        }

        let request = pendingConfirmation.request
        let operationGeneration = assessmentGeneration
        let result: MedicinePipelineAssessmentResult
        do {
            let records = try request.recentRecords.map {
                try $0.domainModel()
            }
            await confirmationBarrier?.waitBeforeConfirmation()
            result = try await pipeline.assessConfirmedCandidate(
                candidateID: command.candidateID,
                context: pendingConfirmation.context,
                userProfile: request.userProfile.domainModel,
                recentRecords: records
            )
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw canonicalClientError(
                for: error,
                requestID: request.requestID
            )
        }

        // A newer assessment started while this confirmation was suspended,
        // so its result describes evidence the caller has already replaced and
        // must never become a consumable response.
        guard operationGeneration == assessmentGeneration,
            self.pendingConfirmation?.request.requestID == request.requestID
        else {
            throw CancellationError()
        }
        self.pendingConfirmation = nil
        return makeResponse(from: result, request: request)
    }

    private func validateVersion(
        _ request: MedicineAssessmentRequestDTO
    ) throws {
        guard
            SlowWalkAPI.supports(
                bodyVersion: request.apiVersion,
                for: .medicineAssess
            )
        else {
            throw ClientAPIError(
                error: APIErrorDTO(
                    code: .unsupportedAPIVersion,
                    message: "The requested API version is not supported.",
                    requestID: request.requestID,
                    details: nil
                )
            )
        }
    }

    private func makeResponse(
        from result: MedicinePipelineAssessmentResult,
        request: MedicineAssessmentRequestDTO
    ) -> MedicineAssessmentResponseDTO {
        MedicineAssessmentResponseDTO(
            requestID: request.requestID,
            resolution: result.resolution,
            assessment: result.assessment,
            actionCard: result.actionCard,
            cacheHit: result.cacheHit,
            resolutionCacheStatus: result.cacheStatus,
            knowledgeCacheStatus: result.knowledgeResult?.cacheStatus,
            sourceDataVersion: result.sourceDataVersion,
            generatedAt: result.generatedAt,
            apiVersion: request.apiVersion,
            healthContextValidation: HealthContextValidationDTO(
                result.healthContextValidation
            ),
            medicineKnowledge: result.knowledgeResult
        )
    }

    private func canonicalClientError(
        for error: any Error,
        requestID: UUID
    ) -> any Error {
        if let clientError = error as? ClientAPIError {
            return clientError
        }
        if error is HealthContextDTOError {
            return apiError(
                code: .invalidMedicationRecord,
                message:
                    "Medication history contains an unsupported event or source value.",
                requestID: requestID
            )
        }

        guard let kind = MedicinePipelineFailureClassifier.classify(error) else {
            return apiError(
                code: .internalError,
                message: "The medicine assessment could not be completed.",
                requestID: requestID
            )
        }
        let mapping = Self.apiMapping(for: kind)
        return apiError(
            code: mapping.code,
            message: mapping.message,
            requestID: requestID
        )
    }

    private func apiError(
        code: APIErrorCode,
        message: String,
        requestID: UUID
    ) -> ClientAPIError {
        ClientAPIError(
            error: APIErrorDTO(
                code: code,
                message: message,
                requestID: requestID,
                details: nil
            )
        )
    }

    private static func apiMapping(
        for kind: MedicinePipelineFailureKind
    ) -> (code: APIErrorCode, message: String) {
        switch kind {
        case .invalidUserProfile:
            (.invalidUserProfile, "The user health profile is invalid.")
        case .unsupportedProfileSchema:
            (.unsupportedProfileSchema, "The user health profile schema is not supported.")
        case .invalidMedicationRecord:
            (.invalidMedicationRecord, "Medication history contains an invalid record.")
        case .futureMedicationRecord:
            (.futureMedicationRecord, "Medication history contains a future record.")
        case .invalidBodyMetrics:
            (.invalidBodyMetrics, "Body metrics failed data-quality validation.")
        case .knowledgeSourceUnavailable:
            (.knowledgeSourceUnavailable, "The medicine knowledge source is unavailable.")
        case .knowledgeSourceTimeout:
            (.knowledgeSourceTimeout, "The medicine knowledge request timed out.")
        case .invalidSourceResponse:
            (.invalidSourceResponse, "A medicine knowledge source returned an invalid response.")
        case .sourceVersionUnsupported:
            (.sourceVersionUnsupported, "A medicine knowledge source version is unsupported.")
        case .medicineNotFound:
            (.medicineNotFound, "No trusted medicine source matched the query.")
        case .sourceConflict:
            (.sourceConflict, "Trusted medicine sources returned a conflict.")
        case .offlineCacheUnavailable:
            (.offlineCacheUnavailable, "No usable offline medicine knowledge cache is available.")
        case .malformedRequest:
            (.malformedRequest, "The medicine knowledge request is malformed.")
        case .internalInvariant:
            (.internalError, "The medicine assessment could not be completed.")
        }
    }
}

public enum LocalMedicineConfirmationError:
    Error,
    Sendable,
    Equatable
{
    case noPendingAssessment
    case candidateNotOffered
}

/// Internal seam that lets a test hold a confirmation at a known point.
protocol LocalConfirmationBarrier: Sendable {
    func waitBeforeConfirmation() async
}
