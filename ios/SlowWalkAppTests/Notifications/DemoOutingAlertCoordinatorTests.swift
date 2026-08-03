import Combine
import Foundation
import Testing
@testable import SlowWalkApp

// MARK: - Test doubles

@MainActor
final class SpyDemoOutingNotifier: DemoOutingNotificationPosting {
    private(set) var posted: [DemoOutingNotification] = []
    private(set) var cancelCount = 0

    func post(_ notification: DemoOutingNotification) async {
        posted.append(notification)
    }

    func cancelDemoNotifications() async {
        cancelCount += 1
    }
}

@MainActor
final class SpyDemoOutingSpeaker: DemoOutingSpeaking {
    private(set) var spoken: [DemoOutingSpeech] = []
    private(set) var stopCount = 0

    func speak(_ speech: DemoOutingSpeech) async {
        spoken.append(speech)
    }

    func stopSpeaking() async {
        stopCount += 1
    }
}

@MainActor
final class SpyDemoOutingHapticsPlayer: DemoOutingHapticsPlaying {
    private(set) var played: [DemoOutingHaptic] = []

    func play(_ haptic: DemoOutingHaptic) async {
        played.append(haptic)
    }
}

/// A speaker that parks mid-utterance on a continuation, so a test can
/// start a new session while an old session's alert chain is suspended.
@MainActor
final class BlockingDemoOutingSpeaker: DemoOutingSpeaking {
    private var parked: CheckedContinuation<Void, Never>?
    private(set) var isParked = false

    func speak(_ speech: DemoOutingSpeech) async {
        isParked = true
        await withCheckedContinuation { parked = $0 }
        isParked = false
    }

    func stopSpeaking() async {}

    func release() {
        parked?.resume()
        parked = nil
    }
}

/// A notifier that parks inside `cancelDemoNotifications`, so a test can
/// start a new session while an old session's teardown is suspended.
@MainActor
final class BlockingDemoOutingNotifier: DemoOutingNotificationPosting {
    private var parked: CheckedContinuation<Void, Never>?
    private(set) var isParked = false

    func post(_ notification: DemoOutingNotification) async {}

    func cancelDemoNotifications() async {
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
private struct AlertHarness {
    let subject = PassthroughSubject<DemoOutingEvent, Never>()
    let notifier = SpyDemoOutingNotifier()
    let speaker = SpyDemoOutingSpeaker()
    let haptics = SpyDemoOutingHapticsPlayer()
    let coordinator: DemoOutingAlertCoordinator

    init() {
        coordinator = DemoOutingAlertCoordinator(
            events: subject.eraseToAnyPublisher(),
            notifier: notifier,
            speaker: speaker,
            hapticsPlayer: haptics
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
    /// out), so assertions never race a half-finished alert chain.
    func poll(_ condition: @escaping @MainActor () -> Bool) async {
        await pollUntil(condition)
    }
}

/// Yields until `condition` holds (or the attempt budget runs out).
@MainActor
private func pollUntil(_ condition: @escaping @MainActor () -> Bool) async {
    for _ in 0..<200 where !condition() {
        await Task.yield()
    }
}

private func testSessionID(_ byte: UInt8) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, byte))
}

// MARK: - Tests

@MainActor
struct DemoOutingAlertCoordinatorTests {

    // MARK: Alert content factories

    @Test func approachingNotificationCarriesDemoRouteMarker() {
        let sessionID = testSessionID(1)
        let notification = DemoOutingNotification.approaching(
            sessionID: sessionID, scenario: .canonical
        )
        #expect(notification.sessionID == sessionID)
        #expect(notification.kind == .approachingDestination)
        #expect(notification.title.contains("Community Health Centre"))
        #expect(notification.body.contains(DemoOutingScenario.demoRouteLabel))
        #expect(notification.isTimeSensitive == false)
    }

    @Test func attentionNeededNotificationIsTimeSensitive() {
        let notification = DemoOutingNotification.attentionNeeded(
            sessionID: testSessionID(1), scenario: .canonical
        )
        #expect(notification.kind == .attentionNeeded)
        #expect(notification.isTimeSensitive)
        #expect(notification.body.contains(DemoOutingScenario.demoRouteLabel))
    }

    @Test func arrivedSpeechNamesDestinationAndDemoNature() {
        let sessionID = testSessionID(1)
        let speech = DemoOutingSpeech.arrived(sessionID: sessionID, scenario: .canonical)
        #expect(speech.sessionID == sessionID)
        #expect(speech.message.contains("Community Health Centre"))
        #expect(speech.message.contains("demo route"))
    }

    // MARK: State → system action mapping

    @Test func approachingPostsOneSessionBoundNotification() async {
        let harness = AlertHarness()
        let sessionID = testSessionID(1)

        harness.send(.travelling, sessionID: sessionID)
        harness.send(.approaching, sessionID: sessionID)
        await harness.poll { harness.notifier.posted.count == 1 }

        #expect(harness.notifier.posted == [
            .approaching(sessionID: sessionID, scenario: .canonical)
        ])
        #expect(harness.speaker.spoken.isEmpty)
        #expect(harness.haptics.played.isEmpty)
        #expect(harness.coordinator.boundSessionID == sessionID)
    }

    @Test func attentionNeededPostsStrongReminderAndWarningHaptic() async {
        let harness = AlertHarness()
        let sessionID = testSessionID(1)

        harness.send(.travelling, sessionID: sessionID)
        harness.send(.attentionNeeded, sessionID: sessionID)
        await harness.poll {
            harness.notifier.posted.count == 1 && harness.haptics.played.count == 1
        }

        #expect(harness.notifier.posted == [
            .attentionNeeded(sessionID: sessionID, scenario: .canonical)
        ])
        #expect(harness.haptics.played == [.attentionNeeded])
        #expect(harness.speaker.spoken.isEmpty)
    }

    @Test func arrivedSpeaksPlaysHapticCancelsAndUnbinds() async {
        let harness = AlertHarness()
        let sessionID = testSessionID(1)

        harness.send(.travelling, sessionID: sessionID)
        harness.send(.arrived, sessionID: sessionID)
        await harness.poll {
            harness.speaker.spoken.count == 1
                && harness.haptics.played.count == 1
                && harness.coordinator.boundSessionID == nil
        }

        #expect(harness.notifier.cancelCount == 1)
        #expect(harness.speaker.spoken == [
            .arrived(sessionID: sessionID, scenario: .canonical)
        ])
        #expect(harness.haptics.played == [.arrived])
        #expect(harness.coordinator.boundSessionID == nil)
    }

    @Test func cancelledCancelsNotificationsStopsSpeechAndUnbinds() async {
        let harness = AlertHarness()
        let sessionID = testSessionID(1)

        harness.send(.travelling, sessionID: sessionID)
        harness.send(.approaching, sessionID: sessionID)
        harness.send(.cancelled, sessionID: sessionID)
        await harness.poll {
            harness.notifier.cancelCount == 1 && harness.speaker.stopCount == 1
        }

        #expect(harness.notifier.posted.count == 1)
        #expect(harness.notifier.cancelCount == 1)
        #expect(harness.speaker.stopCount == 1)
        #expect(harness.speaker.spoken.isEmpty)
        #expect(harness.haptics.played.isEmpty)
        #expect(harness.coordinator.boundSessionID == nil)
    }

    @Test func failedStopsAlertsLikeCancellation() async {
        let harness = AlertHarness()
        let sessionID = testSessionID(1)

        harness.send(.travelling, sessionID: sessionID)
        harness.send(.failed(reason: "demo"), sessionID: sessionID)
        await harness.poll {
            harness.notifier.cancelCount == 1 && harness.speaker.stopCount == 1
        }

        #expect(harness.notifier.cancelCount == 1)
        #expect(harness.speaker.stopCount == 1)
        #expect(harness.notifier.posted.isEmpty)
        #expect(harness.coordinator.boundSessionID == nil)
    }

    // MARK: Dedupe

    @Test func repeatedStateDoesNotAlertTwice() async {
        let harness = AlertHarness()
        let sessionID = testSessionID(1)

        harness.send(.travelling, sessionID: sessionID)
        harness.send(.approaching, sessionID: sessionID)
        harness.send(.approaching, sessionID: sessionID)
        harness.send(.attentionNeeded, sessionID: sessionID)
        harness.send(.attentionNeeded, sessionID: sessionID)
        await harness.poll {
            harness.notifier.posted.count == 2 && harness.haptics.played.count == 1
        }

        #expect(harness.notifier.posted == [
            .approaching(sessionID: sessionID, scenario: .canonical),
            .attentionNeeded(sessionID: sessionID, scenario: .canonical),
        ])
        #expect(harness.haptics.played == [.attentionNeeded])
    }

    // MARK: Stale session guard

    @Test func unboundSessionEventsProduceNoAlerts() async {
        let harness = AlertHarness()
        let bound = testSessionID(1)
        let stale = testSessionID(2)

        harness.send(.travelling, sessionID: bound)
        harness.send(.approaching, sessionID: stale)
        harness.send(.attentionNeeded, sessionID: stale)
        harness.send(.arrived, sessionID: stale)
        await harness.drain()

        #expect(harness.notifier.posted.isEmpty)
        #expect(harness.haptics.played.isEmpty)
        #expect(harness.speaker.spoken.isEmpty)
        #expect(harness.coordinator.boundSessionID == bound)
    }

    @Test func eventsAfterTerminalStateProduceNoAlerts() async {
        let harness = AlertHarness()
        let sessionID = testSessionID(1)

        harness.send(.travelling, sessionID: sessionID)
        harness.send(.cancelled, sessionID: sessionID)
        // A stale leg from the ended session must not alert.
        harness.send(.approaching, sessionID: sessionID)
        harness.send(.attentionNeeded, sessionID: sessionID)
        harness.send(.arrived, sessionID: sessionID)
        await harness.poll { harness.notifier.cancelCount == 1 }

        #expect(harness.notifier.posted.isEmpty)
        #expect(harness.haptics.played.isEmpty)
        #expect(harness.speaker.spoken.isEmpty)
        #expect(harness.notifier.cancelCount == 1)
    }

    @Test func newSessionRebindsAndAlertsOnlyForIt() async {
        let harness = AlertHarness()
        let first = testSessionID(1)
        let second = testSessionID(2)

        harness.send(.travelling, sessionID: first)
        harness.send(.cancelled, sessionID: first)
        harness.send(.travelling, sessionID: second)
        harness.send(.approaching, sessionID: first)  // stale first session
        harness.send(.approaching, sessionID: second)
        await harness.poll { harness.notifier.posted.count == 1 }

        #expect(harness.notifier.posted == [
            .approaching(sessionID: second, scenario: .canonical)
        ])
        #expect(harness.coordinator.boundSessionID == second)
    }

    // MARK: Mid-flight rebind race

    @Test func arrivalChainSuspendedMidFlightCannotClobberNewSessionBinding() async {
        let subject = PassthroughSubject<DemoOutingEvent, Never>()
        let notifier = SpyDemoOutingNotifier()
        let speaker = BlockingDemoOutingSpeaker()
        let haptics = SpyDemoOutingHapticsPlayer()
        let coordinator = DemoOutingAlertCoordinator(
            events: subject.eraseToAnyPublisher(),
            notifier: notifier,
            speaker: speaker,
            hapticsPlayer: haptics
        )
        let first = testSessionID(1)
        let second = testSessionID(2)

        subject.send(DemoOutingEvent(sessionID: first, state: .travelling, scenario: .canonical))
        subject.send(DemoOutingEvent(sessionID: first, state: .arrived, scenario: .canonical))
        // The first session's arrival chain is now suspended inside speak.
        await pollUntil { speaker.isParked }

        // A new session starts before the old chain resumes.
        subject.send(DemoOutingEvent(sessionID: second, state: .travelling, scenario: .canonical))
        await pollUntil { coordinator.boundSessionID == second }

        // The stale chain finishes; it must not unbind the new session.
        speaker.release()
        await pollUntil { haptics.played.count == 1 }
        #expect(coordinator.boundSessionID == second)

        // The new session still alerts normally.
        subject.send(DemoOutingEvent(sessionID: second, state: .approaching, scenario: .canonical))
        await pollUntil { notifier.posted.count == 1 }
        #expect(notifier.posted.first?.sessionID == second)
    }

    @Test func cancelChainSuspendedMidFlightCannotClobberNewSessionBinding() async {
        let subject = PassthroughSubject<DemoOutingEvent, Never>()
        let notifier = BlockingDemoOutingNotifier()
        let speaker = SpyDemoOutingSpeaker()
        let haptics = SpyDemoOutingHapticsPlayer()
        let coordinator = DemoOutingAlertCoordinator(
            events: subject.eraseToAnyPublisher(),
            notifier: notifier,
            speaker: speaker,
            hapticsPlayer: haptics
        )
        let first = testSessionID(1)
        let second = testSessionID(2)

        subject.send(DemoOutingEvent(sessionID: first, state: .travelling, scenario: .canonical))
        subject.send(DemoOutingEvent(sessionID: first, state: .cancelled, scenario: .canonical))
        // The first session's teardown is now suspended inside cancel.
        await pollUntil { notifier.isParked }

        subject.send(DemoOutingEvent(sessionID: second, state: .travelling, scenario: .canonical))
        await pollUntil { coordinator.boundSessionID == second }

        notifier.release()
        await pollUntil { speaker.stopCount == 1 }
        #expect(coordinator.boundSessionID == second)
    }

    // MARK: Integration with the real controller

    @Test func controllerEventsDriveAlertsEndToEnd() async throws {
        let sleeper = ControllableDemoOutingSleeper()
        let ids = ScriptedSessionIDs()
        let controller = DemoOutingSessionController(
            scenario: .canonical,
            sleeper: sleeper,
            makeSessionID: { ids.make() }
        )
        let notifier = SpyDemoOutingNotifier()
        let speaker = SpyDemoOutingSpeaker()
        let haptics = SpyDemoOutingHapticsPlayer()
        let coordinator = DemoOutingAlertCoordinator(
            events: controller.events,
            notifier: notifier,
            speaker: speaker,
            hapticsPlayer: haptics
        )

        #expect(controller.start())
        await sleeper.waitForInstall()
        sleeper.releaseNext()   // travelling → approaching
        await Task.yield()
        await sleeper.waitForInstall()
        sleeper.releaseNext()   // approaching → arrived
        await pollUntil {
            speaker.spoken.count == 1
                && haptics.played.count == 1
                && coordinator.boundSessionID == nil
        }

        let sessionID = try #require(ids.issued.first)
        #expect(notifier.posted == [
            .approaching(sessionID: sessionID, scenario: .canonical)
        ])
        #expect(notifier.cancelCount == 1)
        #expect(speaker.spoken == [
            .arrived(sessionID: sessionID, scenario: .canonical)
        ])
        #expect(haptics.played == [.arrived])
        #expect(coordinator.boundSessionID == nil)
    }

    @Test func cancelledControllerSessionStopsAlertsEndToEnd() async {
        let sleeper = ControllableDemoOutingSleeper()
        let ids = ScriptedSessionIDs()
        let controller = DemoOutingSessionController(
            scenario: .canonical,
            sleeper: sleeper,
            makeSessionID: { ids.make() }
        )
        let notifier = SpyDemoOutingNotifier()
        let speaker = SpyDemoOutingSpeaker()
        let haptics = SpyDemoOutingHapticsPlayer()
        let coordinator = DemoOutingAlertCoordinator(
            events: controller.events,
            notifier: notifier,
            speaker: speaker,
            hapticsPlayer: haptics
        )

        #expect(controller.start())
        await sleeper.waitForInstall()
        controller.apply(.triggerAttentionNeeded)
        controller.apply(.cancel)
        sleeper.cancelAll()
        await pollUntil {
            notifier.cancelCount == 1
                && speaker.stopCount == 1
                && coordinator.boundSessionID == nil
        }

        #expect(notifier.posted.map(\.kind) == [.attentionNeeded])
        #expect(notifier.cancelCount == 1)
        #expect(speaker.stopCount == 1)
        #expect(haptics.played == [.attentionNeeded])
        #expect(coordinator.boundSessionID == nil)
    }
}
