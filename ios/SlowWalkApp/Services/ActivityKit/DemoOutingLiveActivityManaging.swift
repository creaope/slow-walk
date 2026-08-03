import Foundation

/// Live Activity boundary for the demo outing.
///
/// The app-side controller drives one Live Activity per outing session
/// through this boundary. Implementations must guarantee:
///
/// - at most one Live Activity exists at any time;
/// - ActivityKit being unavailable (or Live Activities disabled) degrades
///   silently — the demo keeps running without a Lock Screen presence.
protocol DemoOutingLiveActivityManaging: Sendable {
    /// Starts the Live Activity for a new session. If one is already
    /// running for another session it is ended first — there is never a
    /// second system session.
    func start(sessionID: UUID, scenario: DemoOutingScenario) async

    /// Pushes the current state to the running activity.
    func update(sessionID: UUID, statusText: String) async

    /// Ends the running activity with a final status line.
    func end(sessionID: UUID, finalStatusText: String) async
}

extension DemoOutingState {
    /// The Live Activity status line for a state, if the state is shown.
    ///
    /// The demo-route marker lives in the activity title and the widget
    /// badge, so the status line itself stays short and readable.
    var liveActivityStatusText: String? {
        switch self {
        case .travelling:
            "On the way"
        case .approaching:
            "Approaching destination"
        case .attentionNeeded:
            "Attention needed"
        case .arrived:
            "Arrived"
        case .cancelled:
            "Cancelled"
        case .failed:
            "Ended"
        case .idle:
            nil
        }
    }
}
