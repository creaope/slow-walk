import Combine
import Foundation

/// Consumes the demo outing event stream and drives the real system
/// capabilities: local notifications, speech and haptics.
///
/// This coordinator is a pure event consumer. It never feeds anything back
/// into the outing state machine, and it mirrors the machine's guarantees
/// on the alert side:
///
/// - every system action is bound to the session that triggered it;
/// - events from a stale session produce no alerts;
/// - the same state arriving twice for one session alerts only once;
/// - after `arrived` / `cancelled` / `failed` the session is unbound and no
///   further alerts can fire for it;
/// - a repeated `start` can never stack a second set of alerts, because a
///   new `travelling` event re-binds the coordinator to the new session.
///
/// DEMO ROUTE — every payload produced here carries the demo-route marker.
@MainActor
final class DemoOutingAlertCoordinator {
    private let notifier: any DemoOutingNotificationPosting
    private let speaker: any DemoOutingSpeaking
    private let hapticsPlayer: any DemoOutingHapticsPlaying

    private var cancellable: AnyCancellable?

    /// The session alerts are currently bound to, if any.
    private(set) var boundSessionID: UUID?

    /// Session/state pairs already handled — the dedupe guard.
    private var handled: Set<DemoOutingEventKey> = []

    init(
        events: AnyPublisher<DemoOutingEvent, Never>,
        notifier: any DemoOutingNotificationPosting,
        speaker: any DemoOutingSpeaking,
        hapticsPlayer: any DemoOutingHapticsPlaying
    ) {
        self.notifier = notifier
        self.speaker = speaker
        self.hapticsPlayer = hapticsPlayer
        cancellable = events.sink { [weak self] event in
            Task { @MainActor [weak self] in
                await self?.handle(event)
            }
        }
    }

    /// Handles one published event. The guard chain (bind → stale → dedupe)
    /// runs before any side effect so repeated or stale events can never
    /// reach the system.
    private func handle(_ event: DemoOutingEvent) async {
        if event.state == .travelling {
            // A new session always re-binds; earlier sessions become stale.
            boundSessionID = event.sessionID
            handled = []
        }
        guard event.sessionID == boundSessionID else { return }

        let key = DemoOutingEventKey(sessionID: event.sessionID, state: event.state)
        guard handled.insert(key).inserted else { return }

        switch event.state {
        case .idle, .travelling:
            break
        case .approaching:
            await notifier.post(
                .approaching(sessionID: event.sessionID, scenario: event.scenario)
            )
        case .attentionNeeded:
            await notifier.post(
                .attentionNeeded(sessionID: event.sessionID, scenario: event.scenario)
            )
            await playHapticIfAny(for: event.state)
        case .arrived:
            // Arrival: confirm with speech and haptic, clear pending
            // reminders, then unbind so nothing else can fire.
            await notifier.cancelDemoNotifications()
            await speaker.speak(
                .arrived(sessionID: event.sessionID, scenario: event.scenario)
            )
            await playHapticIfAny(for: event.state)
            unbindIfStillBound(to: event.sessionID)
        case .cancelled, .failed:
            // Termination: pull pending reminders, cut off speech, unbind.
            await notifier.cancelDemoNotifications()
            await speaker.stopSpeaking()
            unbindIfStillBound(to: event.sessionID)
        }
    }

    /// Releases the session binding — but only if no newer session was
    /// bound while this event's alert chain was suspended mid-flight.
    /// Otherwise the stale chain would silently disable the new session's
    /// alerts.
    private func unbindIfStillBound(to sessionID: UUID) {
        if boundSessionID == sessionID {
            boundSessionID = nil
        }
    }

    private func playHapticIfAny(for state: DemoOutingState) async {
        if let haptic = DemoOutingHaptic(state: state) {
            await hapticsPlayer.play(haptic)
        }
    }
}

/// Identity of one handled state change, for dedupe.
private struct DemoOutingEventKey: Hashable {
    let sessionID: UUID
    let state: DemoOutingState
}
