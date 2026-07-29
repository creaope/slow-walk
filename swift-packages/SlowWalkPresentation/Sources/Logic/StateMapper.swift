import SlowWalkDomain
import SlowWalkAPIContracts

/// Maps MedicineAssessDTO to MedicineDisplayState using a strict
/// priority-based ordering. When multiple conditions are simultaneously
/// true, the highest-priority state wins.
public struct StateMapper {

    /// Ordered list of state checks, from highest to lowest priority.
    /// The first matching condition determines the display state.
    public static func map(_ input: MedicineAssessDTO) -> MedicineDisplayState {
        if input.isTimeout {
            return .timeout
        }
        if input.isLoading {
            return .loading
        }
        if input.currentRisk == .highRed {
            return .redRisk
        }
        if input.hasHealthAlert {
            return .healthWarning
        }
        if input.hasSourceWarning {
            return .knowledgeWarning
        }
        if input.isAmbiguousResult {
            return .ambiguous
        }
        return .normalSuccess
    }

    /// Convenience: maps an API response directly.
    public static func map(response: MedicineAssessmentResponseDTO) -> MedicineDisplayState {
        map(MedicineAssessDTO(response: response))
    }
}
