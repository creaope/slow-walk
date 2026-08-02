import Foundation
import Combine

/// Runs one deterministic demo outing session at a time.
///
/// The controller owns the scripted timeline for automatic mode and the
/// developer controls for manual mode. It guarantees the demo contract:
///
/// - at most one session is ever active;
/// - a repeated `start` while active does not create a second session;
/// - `cancel` and `arrived` are terminal — nothing is published afterwards;
/// - a stale scripted leg can never publish after its session ended.
///
/// There is no live location, no map, no transit and no server anywhere in
/// this controller. It only advances the fixed demo scenario.
///
/// DEMO ROUTE — NOT REAL NAVIGATION.
@MainActor
final class DemoOutingSessionController: ObservableObject {
    /// The current state of the (single) session, for direct UI binding.
    @Published private(set) var state: DemoOutingState = .idle

    /// The scenario this controller replays. Fixed for the demo.
    let scenario: DemoOutingScenario

    private let sleeper: any DemoOutingSleeping
    private let makeSessionID: () -> UUID

    /// Identifier of the currently active session, if any.
    private var activeSessionID: UUID?

    /// The running scripted timeline for the active session. Cancelled the
    /// moment the session ends so no stale leg can publish.
    private var scriptedTask: Task<Void, Never>?

    /// Streams every published state change to subscribers (alerts, Live
    /// Activity). Events are only ever emitted from `publish`, which is the
    /// single funnel enforcing the terminal and stale-session rules.
    private let eventSubject = PassthroughSubject<DemoOutingEvent, Never>()

    init(
        scenario: DemoOutingScenario = .canonical,
        sleeper: any DemoOutingSleeping = TaskDemoOutingSleeper(),
        makeSessionID: @escaping () -> UUID = { UUID() }
    ) {
        self.scenario = scenario
        self.sleeper = sleeper
        self.makeSessionID = makeSessionID
    }

    /// A stream of every published session event.
    var events: AnyPublisher<DemoOutingEvent, Never> {
        eventSubject.eraseToAnyPublisher()
    }

    /// Whether a session is currently running.
    var isActive: Bool { state.isActive }

    /// The identifier of the active session, if one is running.
    var currentSessionID: UUID? { activeSessionID }

    // MARK: - Starting

    /// Starts the scripted demo outing.
    ///
    /// - Returns: `true` if a new session was started, `false` if a session
    ///   was already active and the repeated start was refused.
    @discardableResult
    func start() -> Bool {
        guard !state.isActive else { return false }

        let sessionID = makeSessionID()
        activeSessionID = sessionID
        publish(.travelling, sessionID: sessionID)
        scriptedTask = Task { [weak self, sleeper, scenario] in
            guard let self else { return }
            await self.runScriptedTimeline(
                sessionID: sessionID,
                scenario: scenario,
                sleeper: sleeper
            )
        }
        return true
    }

    // MARK: - Developer controls

    /// Applies a developer control to the active session.
    ///
    /// Controls are ignored when no session is active or the session is
    /// already terminal, so a stray tap can never resurrect a finished demo.
    func apply(_ control: DemoOutingControl) {
        guard state.isActive, let sessionID = activeSessionID else { return }
        switch control {
        case .triggerApproaching:
            publish(.approaching, sessionID: sessionID)
        case .triggerAttentionNeeded:
            publish(.attentionNeeded, sessionID: sessionID)
        case .arriveNow:
            publish(.arrived, sessionID: sessionID)
            endSession()
        case .cancel:
            publish(.cancelled, sessionID: sessionID)
            endSession()
        }
    }

    // MARK: - Scripted timeline

    /// Advances the automatic timeline for one session.
    ///
    /// Every step re-checks that the session it belongs to is still the
    /// active one before publishing. If the session was cancelled, arrived
    /// early, or replaced, the continuation is dropped silently — the stale
    /// leg must never emit.
    private func runScriptedTimeline(
        sessionID: UUID,
        scenario: DemoOutingScenario,
        sleeper: any DemoOutingSleeping
    ) async {
        do {
            try await sleeper.sleep(for: scenario.travellingDuration)
            publishIfCurrent(.approaching, sessionID: sessionID)

            try await sleeper.sleep(for: scenario.approachingDuration)
            publishIfCurrent(.arrived, sessionID: sessionID)

            // Arrival ends the session; clear it without publishing again.
            finishIfCurrent(sessionID: sessionID)
        } catch {
            // The session was cancelled or replaced mid-leg. Nothing further
            // may be published for this session.
        }
    }

    // MARK: - Publication funnel

    /// Publishes a state only if the session is still the active one.
    private func publishIfCurrent(_ state: DemoOutingState, sessionID: UUID) {
        guard activeSessionID == sessionID, self.state.isActive else { return }
        publish(state, sessionID: sessionID)
    }

    /// Ends the session only if it is still the active one.
    private func finishIfCurrent(sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        endSession()
    }

    /// The single place state changes and events are emitted. Centralising
    /// this keeps the "no events after terminal" guarantee in one spot.
    private func publish(_ state: DemoOutingState, sessionID: UUID) {
        self.state = state
        eventSubject.send(
            DemoOutingEvent(sessionID: sessionID, state: state, scenario: scenario)
        )
    }

    /// Tears down the active session: cancels any in-flight scripted leg and
    /// forgets the session. The terminal state itself has already been
    /// published by the caller.
    private func endSession() {
        scriptedTask?.cancel()
        scriptedTask = nil
        activeSessionID = nil
    }

    deinit {
        scriptedTask?.cancel()
    }
}
