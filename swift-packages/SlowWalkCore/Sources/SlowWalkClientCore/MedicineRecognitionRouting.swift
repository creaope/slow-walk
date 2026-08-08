import Foundation
import SlowWalkDomain

public enum MedicineRecognitionMode:
    String,
    Codable,
    Sendable,
    CaseIterable,
    Hashable
{
    case remotePreferred = "remote_preferred"
    case onDeviceOnly = "on_device_only"
}

public enum MedicineRecognitionSource:
    String,
    Codable,
    Sendable,
    CaseIterable,
    Hashable
{
    case remote
    case localFallback = "local_fallback"
}

public enum MedicineRecognitionFallbackReason:
    String,
    Codable,
    Sendable,
    CaseIterable,
    Hashable
{
    case onDeviceOnly = "on_device_only"
    case offline
    case timeout
    case rateLimited = "rate_limited"
    case serverUnavailable = "server_unavailable"
    case providerUnavailable = "provider_unavailable"
}

/// Non-medical provenance for one recognition attempt.
public struct MedicineRecognitionContext:
    Sendable,
    Equatable,
    Hashable
{
    public let source: MedicineRecognitionSource
    public let fallbackReason: MedicineRecognitionFallbackReason?

    public init(
        source: MedicineRecognitionSource,
        fallbackReason: MedicineRecognitionFallbackReason? = nil
    ) {
        self.source = source
        self.fallbackReason = fallbackReason
    }

    public static let remote = MedicineRecognitionContext(
        source: .remote,
        fallbackReason: nil
    )

    public static let onDeviceOnly = MedicineRecognitionContext(
        source: .localFallback,
        fallbackReason: .onDeviceOnly
    )
}

/// Recognition input plus provenance and optional remote identity witness.
///
/// The expected identity is only used to reject a disagreeing canonical
/// pipeline response. It is never used to select or replace a medicine.
public struct MedicineRecognitionRoutingOutcome:
    Sendable,
    Equatable,
    Hashable
{
    public let recognitionInput: MedicineRecognitionInput
    public let recognitionContext: MedicineRecognitionContext
    public let expectedCanonicalMedicineID: String?
    public let expectedCanonicalMedicineName: String?

    public var source: MedicineRecognitionSource {
        recognitionContext.source
    }

    public var fallbackReason: MedicineRecognitionFallbackReason? {
        recognitionContext.fallbackReason
    }

    public init(
        recognitionInput: MedicineRecognitionInput,
        recognitionContext: MedicineRecognitionContext,
        expectedCanonicalMedicineID: String? = nil,
        expectedCanonicalMedicineName: String? = nil
    ) {
        self.recognitionInput = recognitionInput
        self.recognitionContext = recognitionContext
        self.expectedCanonicalMedicineID = expectedCanonicalMedicineID
        self.expectedCanonicalMedicineName = expectedCanonicalMedicineName
    }

    public init(
        recognitionInput: MedicineRecognitionInput,
        source: MedicineRecognitionSource,
        fallbackReason: MedicineRecognitionFallbackReason? = nil,
        expectedCanonicalMedicineID: String? = nil,
        expectedCanonicalMedicineName: String? = nil
    ) {
        self.init(
            recognitionInput: recognitionInput,
            recognitionContext: MedicineRecognitionContext(
                source: source,
                fallbackReason: fallbackReason
            ),
            expectedCanonicalMedicineID: expectedCanonicalMedicineID,
            expectedCanonicalMedicineName: expectedCanonicalMedicineName
        )
    }
}

public protocol MedicineRecognitionRouting: Sendable {
    func recognize(
        imageInput: OCRImageInput,
        requestID: UUID,
        mode: MedicineRecognitionMode
    ) async throws -> MedicineRecognitionRoutingOutcome
}

/// Stateless remote-first recognition with an explicitly bounded local
/// fallback policy.
public struct RemoteFirstMedicineRecognitionRouter:
    MedicineRecognitionRouting,
    Sendable
{
    private let remoteRequester: any OnlineMedicineRecognitionRequesting
    private let localRecognizer: any MedicineTextRecognizing
    private let localMapper: MedicineRecognitionInputMapper

    public init(
        remoteRequester: any OnlineMedicineRecognitionRequesting,
        localRecognizer: any MedicineTextRecognizing,
        localMapper: MedicineRecognitionInputMapper
    ) {
        self.remoteRequester = remoteRequester
        self.localRecognizer = localRecognizer
        self.localMapper = localMapper
    }

    public func recognize(
        imageInput: OCRImageInput,
        requestID: UUID,
        mode: MedicineRecognitionMode
    ) async throws -> MedicineRecognitionRoutingOutcome {
        switch mode {
        case .onDeviceOnly:
            return try await recognizeLocally(
                imageInput: imageInput,
                reason: .onDeviceOnly
            )
        case .remotePreferred:
            break
        }

        do {
            try Task.checkCancellation()
            let result = try await remoteRequester.recognize(
                request: OnlineMedicineRecognitionRequest(
                    image: imageInput,
                    requestID: requestID
                )
            )
            try Task.checkCancellation()
            guard result.requestID == requestID else {
                throw OnlineMedicineRecognitionFailure.invalidResponse
            }
            return MedicineRecognitionRoutingOutcome(
                recognitionInput: result.recognitionInput,
                recognitionContext: .remote,
                expectedCanonicalMedicineID:
                    result.expectedCanonicalMedicineID,
                expectedCanonicalMedicineName:
                    result.expectedCanonicalMedicineName
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as OnlineMedicineRecognitionFailure {
            guard let reason = Self.fallbackReason(for: failure) else {
                throw failure
            }
            return try await recognizeLocally(
                imageInput: imageInput,
                reason: reason
            )
        }
    }

    private func recognizeLocally(
        imageInput: OCRImageInput,
        reason: MedicineRecognitionFallbackReason
    ) async throws -> MedicineRecognitionRoutingOutcome {
        try Task.checkCancellation()
        let observations = try await localRecognizer.recognizeText(
            in: imageInput
        )
        try Task.checkCancellation()
        return MedicineRecognitionRoutingOutcome(
            recognitionInput: localMapper.map(
                observations: observations,
                capturedAt: imageInput.capturedAt
            ),
            source: .localFallback,
            fallbackReason: reason
        )
    }

    private static func fallbackReason(
        for failure: OnlineMedicineRecognitionFailure
    ) -> MedicineRecognitionFallbackReason? {
        switch failure {
        case .offline:
            return .offline
        case .timeout:
            return .timeout
        case .rateLimited:
            return .rateLimited
        case .serverUnavailable:
            return .serverUnavailable
        case .providerUnavailable:
            return .providerUnavailable
        case .invalidImage, .imageTooLarge, .invalidResponse,
             .unreadable, .noCandidate, .ambiguous:
            return nil
        }
    }
}

struct OnDeviceMedicineRecognitionRouter:
    MedicineRecognitionRouting,
    Sendable
{
    let recognizer: any MedicineTextRecognizing
    let mapper: MedicineRecognitionInputMapper

    func recognize(
        imageInput: OCRImageInput,
        requestID: UUID,
        mode: MedicineRecognitionMode
    ) async throws -> MedicineRecognitionRoutingOutcome {
        try Task.checkCancellation()
        let observations = try await recognizer.recognizeText(in: imageInput)
        try Task.checkCancellation()
        return MedicineRecognitionRoutingOutcome(
            recognitionInput: mapper.map(
                observations: observations,
                capturedAt: imageInput.capturedAt
            ),
            source: .localFallback,
            fallbackReason: .onDeviceOnly
        )
    }
}
