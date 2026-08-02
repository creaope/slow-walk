import Foundation

/// The one fixed, deterministic route used for the competition demo.
///
/// This is not a real route. It is a scripted walkthrough destination so the
/// outing state machine, notifications, speech, haptics and Live Activity can
/// be demonstrated deterministically on stage. No live location, map or
/// transit data is involved, and nothing is uploaded anywhere.
///
/// DEMO ROUTE — NOT REAL NAVIGATION.
struct DemoOutingScenario: Equatable, Hashable, Sendable {
    /// The displayed destination for the demo route.
    let destinationName: String

    /// A short human-readable description of the scripted route.
    let routeDescription: String

    /// Durations for each scripted leg of the automatic mode.
    let travellingDuration: Duration
    let approachingDuration: Duration

    /// A label that must stay visible wherever this route is shown, so the
    /// demo can never be mistaken for real navigation.
    static let demoRouteLabel = "DEMO ROUTE"

    /// Whether this scenario is the scripted demo route. Always true for the
    /// demo scenario; kept as a property so a view can bind to the fact
    /// rather than hard-coding the string comparison.
    var isDemoRoute: Bool { true }

    /// The canonical scenario used on stage: start → travelling (8 s) →
    /// approaching (8 s) → arrived.
    static let canonical = DemoOutingScenario(
        destinationName: "Community Health Centre",
        routeDescription: "Scripted demo route — fixed destination, no live location or transit data.",
        travellingDuration: .seconds(8),
        approachingDuration: .seconds(8)
    )
}
