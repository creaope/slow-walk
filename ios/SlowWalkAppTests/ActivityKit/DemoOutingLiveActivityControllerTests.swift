import Combine
import Foundation
import Testing
@testable import SlowWalkApp

// MARK: - Test doubles

@MainActor
final class SpyDemoOutingLiveActivityManager: DemoOutingLiveActivityManaging {
    struct StartCall: Equatable {
        let sessionID: UUID
        let scenario: DemoOutingScenario
    }

    struct UpdateCall: Equatable {
        let sessionID: UUID
        let statusText: String
    }

    struct EndCall: Equatable {
        let sessionID: UUID
        let finalStatusText: String
    }

    private(set) var starts: [StartCall] = []
    private(set) var updates: [UpdateCall] = []
    private(set) var ends: [EndCall] = []

    func start(sessionID: UUID, scenario: DemoOutingScenario) async {
        starts.append(StartCall(sessionID: sessionID, scenario: scenario))
    }

    func update(sessionID: UUID, statusText: String) async {
        updates.append(UpdateCall(sessionID: sessionID, statusText: statusText))
    }

    func end(sessionID: UUID, finalStatusText: String) async {
        ends.append(EndCall(sessionID: sessionID, finalStatusText: finalStatusText))
    }
}

/// A manager that parks inside `end`, so a test can start a new session
/// while an old session's activity teardown is suspended mid-flight.
@MainActor
final class BlockingEndLiveActivityManager: DemoOutingLiveActivityManaging {
    private var parked: CheckedContinuation<Void, Never>?
    private(set) var isParked = false
    private(set) var started: [UUID] = []

    func start(sessionID: UUID, scenario: DemoOutingScenario) async {
        started.append(sessionID)
    }

    func update(sessionID: UUID, statusText: String) async {}

    func end(sessionID: UUID, finalStatusText: String) async {
        isParked = true
        await withCheckedContinuation { parked = $0 }
        isParked = false
    }

    func release() {
        parked?.resume()
        parked = nil
    }
}

// MARK: - Helpers

@MainActor
private struct LiveActivityHarness {
    let subject = PassthroughSubject<DemoOutingEvent, Never>()
    let manager = SpyDemoOutingLiveActivityManager()
    let controller: DemoOutingLiveActivityController

    init() {
        controller = DemoOutingLiveActivityController(
            events: subject.eraseToAnyPublisher(),
            manager: manager
        )
    }

    func send(_ state: DemoOutingState, sessionID: UUID) {
        subject.send(
            DemoOutingEvent(sessionID: sessionID, state: state, scenario: .canonical)
        )
    }

    /// Fixed-yield drain for negative tests, where no observable condition
    /// will ever become true.
    func drain() async {
        for _ in 0..<20 { await Task.yield() }
    }

    /// Yields until `condition` holds (or a generous attempt budget runs
    /// out), so assertions never race a half-finished update chain.
    func poll(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            await Task.yield()
        }
    }
}

private func testSessionID(_ byte: UInt8) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, byte))
}

/// Yields until `condition` holds (or the attempt budget runs out).
@MainActor
private func pollUntil(_ condition: @escaping @MainActor () -> Bool) async {
    for _ in 0..<200 where !condition() {
        await Task.yield()
    }
}

// MARK: - Tests

@MainActor
struct DemoOutingLiveActivityControllerTests {

    // MARK: Status text mapping

    @Test func statusTextCoversEveryVisibleState() {
        #expect(DemoOutingState.travelling.liveActivityStatusText == "On the way")
        #expect(DemoOutingState.approaching.liveActivityStatusText == "Approaching destination")
        #expect(DemoOutingState.attentionNeeded.liveActivityStatusText == "Attention needed")
        #expect(DemoOutingState.arrived.liveActivityStatusText == "Arrived")
        #expect(DemoOutingState.cancelled.liveActivityStatusText == "Cancelled")
        #expect(DemoOutingState.failed(reason: "x").liveActivityStatusText == "Ended")
        #expect(DemoOutingState.idle.liveActivityStatusText == nil)
    }

    // MARK: Start / update / end mapping

    @Test func travellingStartsOneActivityBoundToSession() async {
        let harness = LiveActivityHarness()
        let sessionID = testSessionID(1)

        harness.send(.travelling, sessionID: sessionID)
        await harness.poll { harness.manager.updates.count == 1 }

        #expect(harness.manager.starts == [
            .init(sessionID: sessionID, scenario: .canonical)
        ])
        #expect(harness.manager.updates == [
            .init(sessionID: sessionID, statusText: "On the way")
        ])
        #expect(harness.manager.ends.isEmpty)
        #expect(harness.controller.boundSessionID == sessionID)
    }

    @Test func activeStatesUpdateWithTheirStatusText() async {
        let harness = LiveActivityHarness()
        let sessionID = testSessionID(1)

        harness.send(.travelling, sessionID: sessionID)
        harness.send(.approaching, sessionID: sessionID)
        harness.send(.attentionNeeded, sessionID: sessionID)
        await harness.poll { harness.manager.updates.count == 3 }

        #expect(harness.manager.updates.map(\.statusText) == [
            "On the way",
            "Approaching destination",
            "Attention needed",
        ])
        #expect(harness.manager.ends.isEmpty)
    }

    @Test func arrivedEndsActivityWithFinalStatusAndUnbinds() async {
        let harness = LiveActivityHarness()
        let sessionID = testSessionID(1)

        harness.send(.travelling, sessionID: sessionID)
        harness.send(.arrived, sessionID: sessionID)
        await harness.poll { harness.manager.ends.count == 1 }

        #expect(harness.manager.ends == [
            .init(sessionID: sessionID, finalStatusText: "Arrived")
        ])
        #expect(harness.controller.boundSessionID == nil)
    }

    @Test func cancelledEndsActivityWithFinalStatus() async {
        let harness = LiveActivityHarness()
        let sessionID = testSessionID(1)

        harness.send(.travelling, sessionID: sessionID)
        harness.send(.cancelled, sessionID: sessionID)
        await harness.poll { harness.manager.ends.count == 1 }

        #expect(harness.manager.ends == [
            .init(sessionID: sessionID, finalStatusText: "Cancelled")
        ])
        #expect(harness.controller.boundSessionID == nil)
    }

    @Test func failedEndsActivityLikeCancellation() async {
        let harness = LiveActivityHarness()
        let sessionID = testSessionID(1)

        harness.send(.travelling, sessionID: sessionID)
        harness.send(.failed(reason: "demo"), sessionID: sessionID)
        await harness.poll { harness.manager.ends.count == 1 }

        #expect(harness.manager.ends == [
            .init(sessionID: sessionID, finalStatusText: "Ended")
        ])
        #expect(harness.controller.boundSessionID == nil)
    }

    // MARK: Dedupe

    @Test func repeatedStateUpdatesOnlyOnce() async {
        let harness = LiveActivityHarness()
        let sessionID = testSessionID(1)

        harness.send(.travelling, sessionID: sessionID)
        harness.send(.approaching, sessionID: sessionID)
        harness.send(.approaching, sessionID: sessionID)
        harness.send(.approaching, sessionID: sessionID)
        await harness.poll { harness.manager.updates.count == 2 }

        #expect(harness.manager.updates.map(\.statusText) == [
            "On the way",
            "Approaching destination",
        ])
        #expect(harness.manager.starts.count == 1)
    }

    // MARK: Stale session guard

    @Test func unboundSessionEventsNeverTouchTheActivity() async {
        let harness = LiveActivityHarness()
        let bound = testSessionID(1)
        let stale = testSessionID(2)

        harness.send(.travelling, sessionID: bound)
        harness.send(.approaching, sessionID: stale)
        harness.send(.arrived, sessionID: stale)
        await harness.poll { harness.manager.updates.count == 1 }

        #expect(harness.manager.starts.count == 1)
        #expect(harness.manager.ends.isEmpty)
        #expect(harness.controller.boundSessionID == bound)
    }

    @Test func eventsAfterTerminalStateNeverTouchTheActivity() async {
        let harness = LiveActivityHarness()
        let sessionID = testSessionID(1)

        harness.send(.travelling, sessionID: sessionID)
        harness.send(.arrived, sessionID: sessionID)
        harness.send(.approaching, sessionID: sessionID)
        harness.send(.attentionNeeded, sessionID: sessionID)
        await harness.poll { harness.manager.ends.count == 1 }
        await harness.drain()

        #expect(harness.manager.updates.map(\.statusText) == ["On the way"])
        #expect(harness.manager.ends.count == 1)
    }

    @Test func newSessionRebindsAndStartsAgain() async {
        let harness = LiveActivityHarness()
        let first = testSessionID(1)
        let second = testSessionID(2)

        harness.send(.travelling, sessionID: first)
        harness.send(.cancelled, sessionID: first)
        harness.send(.travelling, sessionID: second)
        harness.send(.approaching, sessionID: first)  // stale first session
        harness.send(.approaching, sessionID: second)
        await harness.poll { harness.manager.updates.count == 3 }

        #expect(harness.manager.starts.map(\.sessionID) == [first, second])
        #expect(harness.manager.ends == [
            .init(sessionID: first, finalStatusText: "Cancelled")
        ])
        #expect(harness.manager.updates.last == .init(
            sessionID: second,
            statusText: "Approaching destination"
        ))
        #expect(harness.controller.boundSessionID == second)
    }

    // MARK: Mid-flight rebind race

    @Test func endSuspendedMidFlightCannotClobberNewSessionBinding() async {
        let subject = PassthroughSubject<DemoOutingEvent, Never>()
        let manager = BlockingEndLiveActivityManager()
        let controller = DemoOutingLiveActivityController(
            events: subject.eraseToAnyPublisher(),
            manager: manager
        )
        let first = testSessionID(1)
        let second = testSessionID(2)

        subject.send(DemoOutingEvent(sessionID: first, state: .travelling, scenario: .canonical))
        subject.send(DemoOutingEvent(sessionID: first, state: .arrived, scenario: .canonical))
        // The first session's activity end is now suspended mid-flight.
        await pollUntil { manager.isParked }

        // A new session starts before the old teardown resumes.
        subject.send(DemoOutingEvent(sessionID: second, state: .travelling, scenario: .canonical))
        await pollUntil { controller.boundSessionID == second }

        // The stale teardown finishes; it must not unbind the new session.
        manager.release()
        await pollUntil { !manager.isParked }
        #expect(controller.boundSessionID == second)
        #expect(manager.started == [first, second])
    }

    // MARK: Integration with the real controller

    @Test func controllerEventsDriveLiveActivityEndToEnd() async throws {
        let sleeper = ControllableDemoOutingSleeper()
        let ids = ScriptedSessionIDs()
        let controller = DemoOutingSessionController(
            scenario: .canonical,
            sleeper: sleeper,
            makeSessionID: { ids.make() }
        )
        let manager = SpyDemoOutingLiveActivityManager()
        let liveActivity = DemoOutingLiveActivityController(
            events: controller.events,
            manager: manager
        )

        #expect(controller.start())
        await sleeper.waitForInstall()
        sleeper.releaseNext()   // travelling → approaching
        await Task.yield()
        await sleeper.waitForInstall()
        sleeper.releaseNext()   // approaching → arrived
        await pollUntil { manager.ends.count == 1 }

        let sessionID = try #require(ids.issued.first)
        #expect(manager.starts == [.init(sessionID: sessionID, scenario: .canonical)])
        #expect(manager.updates.map(\.statusText) == [
            "On the way",
            "Approaching destination",
        ])
        #expect(manager.ends == [
            .init(sessionID: sessionID, finalStatusText: "Arrived")
        ])
        #expect(liveActivity.boundSessionID == nil)
    }

    @Test func cancelledControllerSessionEndsLiveActivityEndToEnd() async {
        let sleeper = ControllableDemoOutingSleeper()
        let ids = ScriptedSessionIDs()
        let controller = DemoOutingSessionController(
            scenario: .canonical,
            sleeper: sleeper,
            makeSessionID: { ids.make() }
        )
        let manager = SpyDemoOutingLiveActivityManager()
        let liveActivity = DemoOutingLiveActivityController(
            events: controller.events,
            manager: manager
        )

        #expect(controller.start())
        await sleeper.waitForInstall()
        controller.apply(.cancel)
        sleeper.cancelAll()
        await pollUntil {
            manager.ends.count == 1 && liveActivity.boundSessionID == nil
        }

        #expect(manager.starts.count == 1)
        #expect(manager.ends.map(\.finalStatusText) == ["Cancelled"])
    }
}
