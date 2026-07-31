import Foundation
import SlowWalkAPIContracts
import SlowWalkDomain

/// Structural checks applied before a response can become presentation state.
public struct MedicineAssessmentResponseValidator: Sendable {
    public init() {}

    public func validate(
        _ response: MedicineAssessmentResponseDTO,
        for request: MedicineAssessmentRequestDTO
    ) throws {
        guard response.requestID == request.requestID else {
            throw MedicineAssessmentResponseValidationError.requestIDMismatch
        }
        guard response.apiVersion == request.apiVersion else {
            throw MedicineAssessmentResponseValidationError.apiVersionMismatch
        }
        guard
            !response.sourceDataVersion
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw MedicineAssessmentResponseValidationError
                .missingSourceDataVersion
        }
        guard response.generatedAt == response.actionCard.generatedAt else {
            throw MedicineAssessmentResponseValidationError
                .generatedAtMismatch
        }
        try validateRecognitionEvidence(
            response.resolution.evidence,
            for: request.input
        )

        let candidateIDs = response.resolution.candidates.map {
            $0.medicine.id
        }
        guard Set(candidateIDs).count == candidateIDs.count else {
            throw MedicineAssessmentResponseValidationError
                .duplicateCandidateID
        }

        switch response.resolution.status {
        case .resolved:
            guard let selected = response.resolution.selectedMedicine,
                response.resolution.candidates.contains(where: {
                    $0.medicine == selected
                })
            else {
                throw MedicineAssessmentResponseValidationError
                    .invalidResolution
            }
            guard response.assessment != nil else {
                throw MedicineAssessmentResponseValidationError
                    .assessmentMismatch
            }
        case .ambiguous,
            .insufficientEvidence,
            .notFound,
            .recognitionFailed:
            guard response.resolution.selectedMedicine == nil,
                response.assessment == nil
            else {
                throw MedicineAssessmentResponseValidationError
                    .invalidResolution
            }
        }

        if let assessment = response.assessment {
            guard response.resolution.status == .resolved,
                assessment.level <= response.actionCard.riskLevel
            else {
                throw MedicineAssessmentResponseValidationError
                    .assessmentMismatch
            }
        }

        guard
            response.resolution.requiresUserConfirmation
                == response.actionCard.mustConfirmMedicine
        else {
            throw MedicineAssessmentResponseValidationError
                .confirmationMismatch
        }
    }

    /// Binds the returned evidence to the recognition input that was sent.
    ///
    /// A matching request identifier alone cannot prove that a response
    /// describes the current scan, so the recognition evidence is compared
    /// field by field before the response may become presentation state.
    private func validateRecognitionEvidence(
        _ evidence: MedicineResolutionEvidence,
        for input: MedicineRecognitionInput
    ) throws {
        guard evidence.recognizedTexts == input.recognizedTexts,
            evidence.languageCode == input.languageCode,
            Self.isSameConfidence(
                evidence.rawConfidence,
                input.rawConfidence
            )
        else {
            throw MedicineAssessmentResponseValidationError
                .recognitionEvidenceMismatch
        }
    }

    /// Conservative confidence comparison.
    ///
    /// Only two finite values within `confidenceTolerance` match. A single
    /// missing value or any non-finite value is treated as a mismatch so that
    /// `NaN` or an infinity can never be read as equal evidence.
    private static func isSameConfidence(
        _ lhs: Double?,
        _ rhs: Double?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case (let lhs?, let rhs?):
            lhs.isFinite && rhs.isFinite
                && abs(lhs - rhs) <= confidenceTolerance
        default:
            false
        }
    }

    private static let confidenceTolerance = 1e-12
}

public enum MedicineAssessmentResponseValidationError:
    Error,
    Sendable,
    Equatable
{
    case requestIDMismatch
    case apiVersionMismatch
    case missingSourceDataVersion
    case generatedAtMismatch
    case recognitionEvidenceMismatch
    case duplicateCandidateID
    case invalidResolution
    case assessmentMismatch
    case confirmationMismatch
}
