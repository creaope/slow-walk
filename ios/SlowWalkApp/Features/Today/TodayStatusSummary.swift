import Foundation

/// A one-line summary of where the current companion session stands.
///
/// Today uses this so the app can pick up where the person left off instead of
/// starting over.
struct TodayStatusSummary: Equatable, Hashable {
    let stepLabel: String
    let situation: String
    let nextStep: String
    let isSessionUnderway: Bool
    let hasFinishedSession: Bool

    /// - Parameters:
    ///   - state: The companion session's current step.
    ///   - capabilities: The table the session is running against, so Today's
    ///     summary describes the same build as the Companion screen. Required
    ///     rather than defaulted: a default here would be a second capability
    ///     source, and Today would keep describing the shipping build while the
    ///     session ran against something else.
    init(state: CompanionFlowState, capabilities: CapabilityCatalog) {
        stepLabel = CompanionCopy.stepLabel(for: state)
        situation = CompanionCopy.situation(for: state, capabilities: capabilities)
        nextStep = CompanionCopy.nextStep(for: state)
        isSessionUnderway = state.isActive
        if case .completed = state {
            hasFinishedSession = true
        } else {
            hasFinishedSession = false
        }
    }

    /// Title for Today's primary action, which continues an existing session
    /// rather than silently restarting it.
    var primaryActionTitle: String {
        isSessionUnderway
            ? CompanionCopy.continueCompanionTitle
            : CompanionCopy.startCompanionTitle
    }

    var accessibilityLabel: String {
        "当前陪伴状态：\(stepLabel)。\(situation)\(nextStep)"
    }
}
