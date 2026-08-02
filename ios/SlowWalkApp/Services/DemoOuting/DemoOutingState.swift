import Foundation

/// The state of one deterministic demo outing session.
///
/// This models the scripted demo walkthrough only. It deliberately carries no
/// live location, route or transit data — the demo route is fixed and every
/// transition is driven by the scripted timeline or a developer control.
enum DemoOutingState: Equatable, Hashable, Sendable {
    /// No session is running.
    case idle
    /// The demo outing has started; the scripted journey is underway.
    case travelling
    /// The scripted destination is close.
    case approaching
    /// The demo needs the person's attention right now.
    case attentionNeeded
    /// The scripted destination was reached. Terminal.
    case arrived
    /// The session was cancelled before arriving. Terminal.
    case cancelled
    /// The session could not continue. Terminal.
    case failed(reason: String)

    /// Whether the session is still running and can accept events.
    var isActive: Bool {
        switch self {
        case .travelling, .approaching, .attentionNeeded:
            true
        case .idle, .arrived, .cancelled, .failed:
            false
        }
    }

    /// Whether no further events may be published after this state.
    var isTerminal: Bool { !isActive && self != .idle }
}

/// A single published change in a demo outing session.
///
/// `sessionID` lets any downstream consumer (alerts, Live Activity) ignore
/// events that arrive after the session they belong to has been replaced —
/// the stale-session guard is part of the contract, not an afterthought.
struct DemoOutingEvent: Equatable, Hashable, Sendable {
    let sessionID: UUID
    let state: DemoOutingState
    let scenario: DemoOutingScenario
}

/// Inputs that drive a demo outing session from the outside.
enum DemoOutingControl: Equatable, Hashable, Sendable {
    /// Developer control: jump straight to the approaching leg.
    case triggerApproaching
    /// Developer control: raise the attention-needed moment.
    case triggerAttentionNeeded
    /// Developer control: arrive immediately.
    case arriveNow
    /// End the session before arrival.
    case cancel
}
