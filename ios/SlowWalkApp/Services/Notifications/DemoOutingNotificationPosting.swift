import Foundation

/// A local notification request derived from one demo outing event.
///
/// Every notification is bound to the session that produced it, so any
/// observer can tie the system action back to exactly one outing session.
/// The payload always carries the demo-route marker: the demo must never be
/// mistaken for real navigation, even on the system notification surface.
struct DemoOutingNotification: Equatable, Sendable {
    /// The kind of moment the notification announces.
    enum Kind: String, Equatable, Sendable {
        case approachingDestination
        case attentionNeeded
    }

    /// Session the notification belongs to.
    let sessionID: UUID
    let kind: Kind
    let title: String
    let body: String

    /// Whether the notification may break through Focus modes
    /// (time-sensitive). Never promises maximum system volume.
    let isTimeSensitive: Bool
}

extension DemoOutingNotification {
    /// The approaching-destination local notification for one session.
    static func approaching(
        sessionID: UUID,
        scenario: DemoOutingScenario
    ) -> DemoOutingNotification {
        DemoOutingNotification(
            sessionID: sessionID,
            kind: .approachingDestination,
            title: "Approaching \(scenario.destinationName)",
            body: "You are near your destination. "
                + "\(DemoOutingScenario.demoRouteLabel) — not real navigation.",
            isTimeSensitive: false
        )
    }

    /// The strong attention-needed reminder for one session.
    static func attentionNeeded(
        sessionID: UUID,
        scenario: DemoOutingScenario
    ) -> DemoOutingNotification {
        DemoOutingNotification(
            sessionID: sessionID,
            kind: .attentionNeeded,
            title: "Attention needed",
            body: "Please check your current demo route status in the app. "
                + "\(DemoOutingScenario.demoRouteLabel) — not real navigation.",
            isTimeSensitive: true
        )
    }
}

/// Local-notification boundary for demo outing events.
///
/// Implementations must degrade safely: denied permission or a system error
/// drops the notification instead of failing the demo.
protocol DemoOutingNotificationPosting: Sendable {
    /// Posts a local notification immediately.
    func post(_ notification: DemoOutingNotification) async

    /// Removes every pending and delivered demo outing notification, e.g.
    /// when the session arrives or is cancelled.
    func cancelDemoNotifications() async
}
