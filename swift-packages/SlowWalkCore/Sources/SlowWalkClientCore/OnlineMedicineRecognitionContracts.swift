import Foundation
import SlowWalkDomain

/// Image-only input for remote medicine package recognition.
///
/// Health profiles and medication history are intentionally absent from this
/// boundary. They remain inputs to the existing assessment pipeline only.
public struct OnlineMedicineRecognitionRequest:
    Sendable,
    Equatable,
    Hashable
{
    public let image: OCRImageInput
    public let requestID: UUID

    public init(image: OCRImageInput, requestID: UUID) {
        self.image = image
        self.requestID = requestID
    }
}

/// A verified remote identity expressed through the existing recognition
/// boundary. The expected identity lets the composition layer reject a local
/// canonical result that disagrees with the server's canonical resolver.
public struct OnlineMedicineRecognitionResult:
    Sendable,
    Equatable,
    Hashable
{
    public let requestID: UUID
    public let recognitionInput: MedicineRecognitionInput
    public let expectedCanonicalMedicineID: String
    public let expectedCanonicalMedicineName: String

    public init(
        requestID: UUID,
        recognitionInput: MedicineRecognitionInput,
        expectedCanonicalMedicineID: String,
        expectedCanonicalMedicineName: String
    ) {
        self.requestID = requestID
        self.recognitionInput = recognitionInput
        self.expectedCanonicalMedicineID = expectedCanonicalMedicineID
        self.expectedCanonicalMedicineName = expectedCanonicalMedicineName
    }
}

/// Performs package recognition only. Implementations must not read or send
/// user health data, assess risk, or construct presentation models.
public protocol OnlineMedicineRecognitionRequesting: Sendable {
    func recognize(
        request: OnlineMedicineRecognitionRequest
    ) async throws -> OnlineMedicineRecognitionResult
}

/// Stable failures understood by the remote-first composition layer.
///
/// Cancellation deliberately remains Swift's `CancellationError` and must not
/// be wrapped in this enum.
public enum OnlineMedicineRecognitionFailure:
    Error,
    Sendable,
    Equatable
{
    case offline
    case timeout
    case rateLimited
    case serverUnavailable
    case providerUnavailable
    case invalidImage
    case imageTooLarge
    case invalidResponse
    case unreadable
    case noCandidate
    case ambiguous
}
