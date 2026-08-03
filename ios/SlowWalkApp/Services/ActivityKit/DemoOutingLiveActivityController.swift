import Combine
import Foundation

/// Consumes the demo outing event stream and mirrors it onto the Live
/// Activity.
///
/// Like the alert coordinator, this controller is a pure event consumer and
/// mirrors the state machine's guarantees on the Live Activity side:
///
/// - every start / update / end is bound to the session that triggered it;
/// - events from a stale session never touch the activity;
/// - the same state arriving twice updates the activity only once;
/// - `arrived` / `cancelled` / `failed` end the activity and unbind the
///   session, so nothing updates it afterwards.
///
/// The widget only ever displays the current demo outing state — no risk
/// rules, no medicine content, no health data.
@MainActor
final class DemoOutingLiveActivityController {
    private let manager: any DemoOutingLiveActivityManaging

    private var cancellable: AnyCancellable?

    /// The session the Live Activity is currently bound to, if any.
    private(set) var boundSessionID: UUID?

    /// Session/state pairs already handled — the dedupe guard.
    private var handled: Set<DemoOutingLiveActivityEventKey> = []

    init(
        events: AnyPublisher<DemoOutingEvent, Never>,
        manager: any DemoOutingLiveActivityManaging
    ) {
        self.manager = manager
        cancellable = events.sink { [weak self] event in
            Task { @MainActor [weak self] in
                await self?.handle(event)
            }
        }
    }

    /// Handles one published event. The guard chain (bind → stale → dedupe)
    /// runs before any side effect so repeated or stale events can never
    /// reach the Live Activity.
    private func handle(_ event: DemoOutingEvent) async {
        if event.state == .travelling {
            // A new session always re-binds; the manager ends any activity
            // left over from an earlier session before starting the new one.
            boundSessionID = event.sessionID
            handled = []
            await manager.start(sessionID: event.sessionID, scenario: event.scenario)
        }
        guard event.sessionID == boundSessionID else { return }

        let key = DemoOutingLiveActivityEventKey(
            sessionID: event.sessionID,
            state: event.state
        )
        guard handled.insert(key).inserted else { return }

        switch event.state {
        case .idle:
            break
        case .travelling, .approaching, .attentionNeeded:
            if let statusText = event.state.liveActivityStatusText {
                await manager.update(sessionID: event.sessionID, statusText: statusText)
            }
        case .arrived, .cancelled, .failed:
            // Terminal: end the activity with the final status, then unbind
            // so nothing can update it again.
            await manager.end(
                sessionID: event.sessionID,
                finalStatusText: event.state.liveActivityStatusText ?? "Ended"
            )
            unbindIfStillBound(to: event.sessionID)
        }
    }

    /// Releases the session binding — but only if no newer session was
    /// bound while this event's end call was suspended mid-flight.
    /// Otherwise the stale chain would silently freeze the new session's
    /// Live Activity.
    private func unbindIfStillBound(to sessionID: UUID) {
        if boundSessionID == sessionID {
            boundSessionID = nil
        }
    }
}

/// Identity of one handled state change, for dedupe.
private struct DemoOutingLiveActivityEventKey: Hashable {
    let sessionID: UUID
    let state: DemoOutingState
}
