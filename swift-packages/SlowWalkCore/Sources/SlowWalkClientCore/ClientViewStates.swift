import Foundation
import SlowWalkAPIContracts
import SlowWalkDomain

/// Non-color-only risk semantics for future accessible UI.
public enum RiskAttentionSemantics:
    String,
    Codable,
    Sendable,
    CaseIterable,
    Hashable
{
    case routine
    case reviewRequired = "review_required"
    case urgentAttention = "urgent_attention"
    case immediateAttention = "immediate_attention"
}
public struct RiskPresentation:
    Sendable,
    Equatable,
    Hashable
{
    public let level: RiskLevel
    public let attention:
        RiskAttentionSemantics
    public let requiresImmediateAttention: Bool

    public init(level: RiskLevel) {
        self.level = level
        switch level {
        case .green:
            attention = .routine
            requiresImmediateAttention = false
        case .yellow:
            attention = .reviewRequired
            requiresImmediateAttention = false
        case .orange:
            attention = .urgentAttention
            requiresImmediateAttention = false
        case .red:
            attention = .immediateAttention
            requiresImmediateAttention = true
        }
    }
}

public struct MedicineAssessmentPresentation:
    Sendable,
    Equatable,
    Hashable
{
    public let response:
        MedicineAssessmentResponseDTO
    public let risk: RiskPresentation
    public let recognitionContext: MedicineRecognitionContext

    public init(
        response: MedicineAssessmentResponseDTO,
        recognitionContext: MedicineRecognitionContext = .onDeviceOnly
    ) {
        self.response = response
        self.recognitionContext = recognitionContext
        risk = RiskPresentation(
            level: response.actionCard.riskLevel
        )
    }
}

public enum MedicineConfirmationReason:
    String,
    Codable,
    Sendable,
    CaseIterable,
    Hashable
{
    case noRecognizedText = "no_recognized_text"
    case ambiguousMedicine = "ambiguous_medicine"
    case unresolvedMedicine = "unresolved_medicine"
    case serverRequiresConfirmation =
        "server_requires_confirmation"
}

public struct MedicineConfirmationRequirement:
    Sendable,
    Equatable,
    Hashable
{
    public let reason: MedicineConfirmationReason
    public let recognitionInput:
        MedicineRecognitionInput
    public let response:
        MedicineAssessmentResponseDTO?
    public let recognitionContext: MedicineRecognitionContext

    public init(
        reason: MedicineConfirmationReason,
        recognitionInput:
            MedicineRecognitionInput,
        response:
            MedicineAssessmentResponseDTO?,
        recognitionContext: MedicineRecognitionContext = .onDeviceOnly
    ) {
        self.reason = reason
        self.recognitionInput = recognitionInput
        self.response = response
        self.recognitionContext = recognitionContext
    }
}

public enum MedicineAssessmentViewState:
    Sendable,
    Equatable
{
    case idle
    case recognizing(startedAt: Date)
    case requiresMedicineConfirmation(
        MedicineConfirmationRequirement
    )
    case assessing(startedAt: Date)
    case result(MedicineAssessmentPresentation)
    case failed(ClientFailure)
    case cancelled
}

/// Monotonic coordinator state update used to reject late progress events.
public struct MedicineAssessmentStateUpdate: Sendable, Equatable {
    public let sequenceNumber: UInt64
    public let state: MedicineAssessmentViewState

    public init(
        sequenceNumber: UInt64,
        state: MedicineAssessmentViewState
    ) {
        self.sequenceNumber = sequenceNumber
        self.state = state
    }
}

public struct LocationAssessmentPresentation:
    Sendable,
    Equatable,
    Hashable
{
    public let response:
        LocationAssessmentResponseDTO
    public let risk: RiskPresentation

    public init(
        response: LocationAssessmentResponseDTO
    ) {
        self.response = response
        risk = RiskPresentation(
            level: response.assessment.level
        )
    }
}

public struct InsufficientLocationSamples:
    Sendable,
    Equatable,
    Hashable
{
    public let availableSampleCount: Int
    public let requiredSampleCount: Int

    public init(
        availableSampleCount: Int,
        requiredSampleCount: Int
    ) {
        self.availableSampleCount =
            availableSampleCount
        self.requiredSampleCount =
            requiredSampleCount
    }
}

public enum LocationAssessmentViewState:
    Sendable,
    Equatable
{
    case idle
    case collecting(startedAt: Date)
    case insufficientSamples(
        InsufficientLocationSamples
    )
    case assessing(startedAt: Date)
    case result(LocationAssessmentPresentation)
    case failed(ClientFailure)
    case cancelled
}
