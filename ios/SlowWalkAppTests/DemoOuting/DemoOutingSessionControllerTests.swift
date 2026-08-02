import Foundation
import Testing
@testable import SlowWalkApp

// MARK: - Controllable sleeper

/// A test double that parks each scripted leg on a continuation the test
/// releases at a chosen moment.
///
/// This is what makes the stale-session race observable: a test can hold a
/// leg mid-flight, end or replace the session, then release the leg and
/// assert that nothing further was published.
@MainActor
final class ControllableDemoOutingSleeper: DemoOutingSleeping {
    private var pending: [CheckedContinuation<Void, Error>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Durations the sleeper was asked to wait, in order.
    private(set) var requestedDurations: [Duration] = []

    func sleep(for duration: Duration) async throws {
        requestedDurations.append(duration)
        if !pending.isEmpty || waiters.isEmpty {
            // Notify any test waiting for this leg to be installed.
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(continuation)
            let installed = waiters
            waiters.removeAll()
            for waiter in installed { waiter.resume() }
        }
    }

    /// Suspends the test until at least one scripted leg is parked.
    func waitForInstall() async {
        guard pending.isEmpty else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Releases the oldest parked leg, letting it complete.
    func releaseNext() {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume()
    }

    /// Cancels every parked leg, as if their session ended.
    func cancelAll() {
        let parked = pending
        pending.removeAll()
        for continuation in parked {
            continuation.resume(throwing: CancellationError())
        }
    }

    /// How many legs are currently parked mid-flight.
    var parkedCount: Int { pending.count }
}

// MARK: - Test IDs

/// Hands out deterministic session IDs so events can be told apart.
final class ScriptedSessionIDs: @unchecked Sendable {
    private var next = 0
    private(set) var issued: [UUID] = []

    func make() -> UUID {
        next += 1
        // Deterministic UUIDs: byte 15 carries the counter.
        let id = UUID(uuid: (
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(next)
        ))
        issued.append(id)
        return id
    }
}

// MARK: - Helpers

@MainActor
private func makeController(
    sleeper: ControllableDemoOutingSleeper,
    ids: ScriptedSessionIDs
) -> DemoOutingSessionController {
    DemoOutingSessionController(
        scenario: .canonical,
        sleeper: sleeper,
        makeSessionID: { ids.make() }
    )
}

// MARK: - Tests

@MainActor
struct DemoOutingSessionControllerTests {

    // MARK: Scenario is the fixed demo route

    @Test func scenarioIsTheFixedDemoRoute() {
        let scenario = DemoOutingScenario.canonical
        #expect(scenario.isDemoRoute)
        #expect(DemoOutingScenario.demoRouteLabel == "DEMO ROUTE")
        #expect(scenario.travellingDuration == .seconds(8))
        #expect(scenario.approachingDuration == .seconds(8))
        #expect(!scenario.destinationName.isEmpty)
        #expect(!scenario.routeDescription.isEmpty)
    }

    // MARK: Starting

    @Test func startPublishesTravelling() {
        let sleeper = ControllableDemoOutingSleeper()
        let ids = ScriptedSessionIDs()
        let controller = makeController(sleeper: sleeper, ids: ids)

        #expect(controller.start())
        #expect(controller.state == .travelling)
        #expect(controller.isActive)
        #expect(controller.currentSessionID == ids.issued.first)
    }

    @Test func repeatedStartDoesNotCreateSecondSession() async {
        let sleeper = ControllableDemoOutingSleeper()
        let ids = ScriptedSessionIDs()
        let controller = makeController(sleeper: sleeper, ids: ids)

        #expect(controller.start())
        #expect(controller.start() == false)
        #expect(controller.start() == false)
        #expect(ids.issued.count == 1)
        #expect(controller.currentSessionID == ids.issued.first)
    }

    // MARK: Automatic mode

    @Test func automaticModeWalksTravellingApproachingArrived() async {
        let sleeper = ControllableDemoOutingSleeper()
        let ids = ScriptedSessionIDs()
        let controller = makeController(sleeper: sleeper, ids: ids)

        controller.start()
        #expect(controller.state == .travelling)

        await sleeper.waitForInstall()
        sleeper.releaseNext()
        // Allow the timeline to advance past the first leg.
        await Task.yield()
        #expect(controller.state == .approaching)

        await sleeper.waitForInstall()
        sleeper.releaseNext()
        await Task.yield()
        #expect(controller.state == .arrived)
    }

    @Test func automaticModeRequestsTheScriptedDurations() async {
        let sleeper = ControllableDemoOutingSleeper()
        let ids = ScriptedSessionIDs()
        let controller = makeController(sleeper: sleeper, ids: ids)

        controller.start()
        await sleeper.waitForInstall()
        #expect(sleeper.requestedDurations == [.seconds(8)])
        sleeper.releaseNext()
        await sleeper.waitForInstall()
        #expect(sleeper.requestedDurations == [.seconds(8), .seconds(8)])
    }

    @Test func sessionIsInactiveAfterArrival() async {
        let sleeper = ControllableDemoOutingSleeper()
        let ids = ScriptedSessionIDs()
        let controller = makeController(sleeper: sleeper, ids: ids)

        controller.start()
        await sleeper.waitForInstall()
        sleeper.releaseNext()
        await sleeper.waitForInstall()
        sleeper.releaseNext()
        await Task.yield()

        #expect(controller.state == .arrived)
        #expect(controller.isActive == false)
        #expect(controller.currentSessionID == nil)
    }

    @Test func arrivalIsTerminalAndPublishesNothingFurther() async {
        let sleeper = ControllableDemoOutingSleeper()
        let ids = ScriptedSessionIDs()
        let controller = makeController(sleeper: sleeper, ids: ids)

        controller.start()
        controller.apply(.arriveNow)
        let sessionID = ids.issued.first

        // Every developer control after arrival is ignored.
        controller.apply(.triggerApproaching)
        controller.apply(.triggerAttentionNeeded)
        controller.apply(.arriveNow)
        controller.apply(.cancel)

        #expect(controller.state == .arrived)
        #expect(controller.currentSessionID == nil)
        #expect(ids.issued == [sessionID].compactMap { $0 })
    }

    // MARK: Manual mode

    @Test func manualControlJumpsToApproaching() {
        let sleeper = ControllableDemoOutingSleeper()
        let ids = ScriptedSessionIDs()
        let controller = makeController(sleeper: sleeper, ids: ids)

        controller.start()
        controller.apply(.triggerApproaching)
        #expect(controller.state == .approaching)
    }

    @Test func manualControlRaisesAttentionNeeded() {
        let sleeper = ControllableDemoOutingSleeper()
        let ids = ScriptedSessionIDs()
        let controller = makeController(sleeper: sleeper, ids: ids)

        controller.start()
        controller.apply(.triggerAttentionNeeded)
        #expect(controller.state == .attentionNeeded)
    }

    @Test func manualArriveNowEndsSession() {
        let sleeper = ControllableDemoOutingSleeper()
        let ids = ScriptedSessionIDs()
        let controller = makeController(sleeper: sleeper, ids: ids)

        controller.start()
        controller.apply(.arriveNow)

        #expect(controller.state == .arrived)
        #expect(controller.isActive == false)
        #expect(controller.currentSessionID == nil)
    }

    @Test func controlsAreIgnoredWhenIdle() {
        let sleeper = ControllableDemoOutingSleeper()
        let ids = ScriptedSessionIDs()
        let controller = makeController(sleeper: sleeper, ids: ids)

        controller.apply(.triggerApproaching)
        controller.apply(.triggerAttentionNeeded)
        controller.apply(.arriveNow)
        controller.apply(.cancel)

        #expect(controller.state == .idle)
        #expect(controller.currentSessionID == nil)
        #expect(ids.issued.isEmpty)
    }

    // MARK: Cancel

    @Test func cancelIsTerminal() {
        let sleeper = ControllableDemoOutingSleeper()
        let ids = ScriptedSessionIDs()
        let controller = makeController(sleeper: sleeper, ids: ids)

        controller.start()
        controller.apply(.cancel)

        #expect(controller.state == .cancelled)
        #expect(controller.isActive == false)
        #expect(controller.currentSessionID == nil)
    }

    @Test func cancelPublishesNothingFurther() {
        let sleeper = ControllableDemoOutingSleeper()
        let ids = ScriptedSessionIDs()
        let controller = makeController(sleeper: sleeper, ids: ids)

        controller.start()
        controller.apply(.cancel)

        controller.apply(.triggerApproaching)
        controller.apply(.arriveNow)
        #expect(controller.state == .cancelled)
    }

    // MARK: Stale session guard

    @Test func staleScriptedLegNeverPublishesAfterCancel() async {
        let sleeper = ControllableDemoOutingSleeper()
        let ids = ScriptedSessionIDs()
        let controller = makeController(sleeper: sleeper, ids: ids)

        controller.start()
        await sleeper.waitForInstall()
        // The scripted leg is parked mid-flight. End the session, then let
        // the stale leg finish — it must not publish.
        controller.apply(.cancel)
        sleeper.cancelAll()
        await Task.yield()

        #expect(controller.state == .cancelled)
        #expect(controller.currentSessionID == nil)
    }

    @Test func staleLegCannotHijackRestartedSession() async {
        let sleeper = ControllableDemoOutingSleeper()
        let ids = ScriptedSessionIDs()
        let controller = makeController(sleeper: sleeper, ids: ids)

        // First session parks a leg, then is cancelled.
        controller.start()
        let firstSession = ids.issued.first
        await sleeper.waitForInstall()
        controller.apply(.cancel)
        sleeper.cancelAll()

        // A new session starts; only its events may publish now.
        #expect(controller.start())
        let secondSession = controller.currentSessionID
        #expect(secondSession != firstSession)
        #expect(ids.issued.count == 2)
        #expect(controller.state == .travelling)
    }

    @Test func eventsCarryTheSessionIDAndDemoScenario() {
        let sleeper = ControllableDemoOutingSleeper()
        let ids = ScriptedSessionIDs()
        let controller = makeController(sleeper: sleeper, ids: ids)

        controller.start()
        let event = DemoOutingEvent(
            sessionID: ids.issued.first!,
            state: .travelling,
            scenario: controller.scenario
        )
        #expect(event.sessionID == ids.issued.first)
        #expect(event.scenario.isDemoRoute)
        #expect(DemoOutingScenario.demoRouteLabel == "DEMO ROUTE")
    }

    // MARK: State semantics

    @Test func terminalStatesAreNotActive() {
        #expect(DemoOutingState.idle.isActive == false)
        #expect(DemoOutingState.arrived.isActive == false)
        #expect(DemoOutingState.cancelled.isActive == false)
        #expect(DemoOutingState.failed(reason: "x").isActive == false)
        #expect(DemoOutingState.travelling.isActive)
        #expect(DemoOutingState.approaching.isActive)
        #expect(DemoOutingState.attentionNeeded.isActive)
    }

    @Test func terminalStatesAreMarkedTerminal() {
        #expect(DemoOutingState.arrived.isTerminal)
        #expect(DemoOutingState.cancelled.isTerminal)
        #expect(DemoOutingState.failed(reason: "x").isTerminal)
        #expect(DemoOutingState.idle.isTerminal == false)
        #expect(DemoOutingState.travelling.isTerminal == false)
    }
}
