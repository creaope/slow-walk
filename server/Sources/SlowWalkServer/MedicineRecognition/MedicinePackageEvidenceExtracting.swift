import Foundation

/// Provider boundary for non-clinical medicine-package evidence extraction.
/// Implementations must not return a canonical identity or health judgement.
protocol MedicinePackageEvidenceExtracting: Sendable {
    func extractMedicinePackageEvidence(
        from image: VisionImagePayload
    ) async throws -> RemoteMedicinePackageEvidence
}

extension ZhipuVisionClient: MedicinePackageEvidenceExtracting {}

struct UnavailableMedicinePackageEvidenceExtractor:
    MedicinePackageEvidenceExtracting,
    Sendable
{
    func extractMedicinePackageEvidence(
        from image: VisionImagePayload
    ) async throws -> RemoteMedicinePackageEvidence {
        throw ZhipuVisionClientError.missingCredential
    }
}
