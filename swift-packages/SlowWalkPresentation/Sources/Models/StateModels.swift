import SwiftUI
import SlowWalkDomain
import SlowWalkAPIContracts

/// UI-facing display states for the medicine assessment flow.
public enum MedicineDisplayState: Equatable {
    case loading
    case timeout
    case redRisk
    case healthWarning
    case knowledgeWarning
    case ambiguous
    case normalSuccess
}

/// Adapter that flattens the API response into simple boolean flags
/// suitable for SwiftUI view binding and state mapping.
public struct MedicineAssessDTO: Equatable {

    public let isLoading: Bool
    public let isTimeout: Bool
    public let isCancelled: Bool
    public let hasHealthAlert: Bool
    public let hasSourceWarning: Bool
    public let isAmbiguousResult: Bool
    public let currentRisk: DisplayRiskLevel
    public let primaryMessage: String
    public let actionCard: ActionCard?

    /// Creates a DTO from an API response.
    /// This is the primary initialization path for production code.
    public init(response: MedicineAssessmentResponseDTO) {
        self.isLoading = false
        self.isTimeout = false
        self.isCancelled = false
        self.hasHealthAlert = response.healthContextValidation != nil
        self.hasSourceWarning = !response.actionCard.warnings.isEmpty
        self.isAmbiguousResult = response.resolution.status == .ambiguous
            || response.resolution.status == .insufficientEvidence
        self.currentRisk = DisplayRiskLevel(domainRisk: response.actionCard.riskLevel)
        self.primaryMessage = response.actionCard.primaryInstruction
        self.actionCard = response.actionCard
    }

    /// Creates a DTO for the loading state.
    public static func loading() -> MedicineAssessDTO {
        MedicineAssessDTO(
            isLoading: true,
            isTimeout: false,
            isCancelled: false,
            hasHealthAlert: false,
            hasSourceWarning: false,
            isAmbiguousResult: false,
            currentRisk: .lowGreen,
            primaryMessage: "",
            actionCard: nil
        )
    }

    /// Creates a DTO for the timeout state.
    public static func timeout() -> MedicineAssessDTO {
        MedicineAssessDTO(
            isLoading: false,
            isTimeout: true,
            isCancelled: false,
            hasHealthAlert: false,
            hasSourceWarning: false,
            isAmbiguousResult: false,
            currentRisk: .lowGreen,
            primaryMessage: "请求超时，请重试",
            actionCard: nil
        )
    }

    /// Creates a DTO for the cancelled state.
    public static func cancelled() -> MedicineAssessDTO {
        MedicineAssessDTO(
            isLoading: false,
            isTimeout: false,
            isCancelled: true,
            hasHealthAlert: false,
            hasSourceWarning: false,
            isAmbiguousResult: false,
            currentRisk: .lowGreen,
            primaryMessage: "操作已取消",
            actionCard: nil
        )
    }

    /// Creates a DTO with custom flags, useful for previews and testing.
    public init(
        isLoading: Bool = false,
        isTimeout: Bool = false,
        isCancelled: Bool = false,
        hasHealthAlert: Bool = false,
        hasSourceWarning: Bool = false,
        isAmbiguousResult: Bool = false,
        currentRisk: DisplayRiskLevel = .lowGreen,
        primaryMessage: String = "",
        actionCard: ActionCard? = nil
    ) {
        self.isLoading = isLoading
        self.isTimeout = isTimeout
        self.isCancelled = isCancelled
        self.hasHealthAlert = hasHealthAlert
        self.hasSourceWarning = hasSourceWarning
        self.isAmbiguousResult = isAmbiguousResult
        self.currentRisk = currentRisk
        self.primaryMessage = primaryMessage
        self.actionCard = actionCard
    }
}

/// UI-oriented risk level with type-safe color and label.
public enum DisplayRiskLevel: String, Equatable, Identifiable {
    case lowGreen
    case yellow
    case orange
    case highRed

    public var id: String { rawValue }

    public var displayLabel: String {
        switch self {
        case .lowGreen:
            return String(localized: "低风险")
        case .yellow:
            return String(localized: "中等风险")
        case .orange:
            return String(localized: "较高风险")
        case .highRed:
            return String(localized: "高风险")
        }
    }

    #if canImport(UIKit)
    public var displayColor: Color {
        switch self {
        case .lowGreen:
            return Color(uiColor: .systemGreen)
        case .yellow:
            return Color(uiColor: .systemYellow)
        case .orange:
            return Color(uiColor: .systemOrange)
        case .highRed:
            return Color(uiColor: .systemRed)
        }
    }
    #else
    public var displayColor: Color {
        switch self {
        case .lowGreen:
            return Color(nsColor: .systemGreen)
        case .yellow:
            return Color(nsColor: .systemYellow)
        case .orange:
            return Color(nsColor: .systemOrange)
        case .highRed:
            return Color(nsColor: .systemRed)
        }
    }
    #endif

    public init(domainRisk: RiskLevel) {
        switch domainRisk {
        case .green:
            self = .lowGreen
        case .yellow:
            self = .yellow
        case .orange:
            self = .orange
        case .red:
            self = .highRed
        }
    }
}
