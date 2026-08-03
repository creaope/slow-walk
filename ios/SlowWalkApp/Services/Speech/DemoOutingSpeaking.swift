import Foundation

/// One spoken message for the demo outing, bound to its session.
struct DemoOutingSpeech: Equatable, Sendable {
    /// Session the message belongs to.
    let sessionID: UUID
    let message: String
}

extension DemoOutingSpeech {
    /// The arrival announcement for one session. Explicitly names the demo
    /// nature of the route — the demo must never sound like real navigation.
    static func arrived(
        sessionID: UUID,
        scenario: DemoOutingScenario
    ) -> DemoOutingSpeech {
        DemoOutingSpeech(
            sessionID: sessionID,
            message: "You have arrived at \(scenario.destinationName). "
                + "This was a demo route, not real navigation."
        )
    }
}

/// Voice output boundary for demo outing events.
///
/// Mirrors `RiskResultSpeaking`: implementations may speak immediately and
/// must support cutting speech off when a session ends.
protocol DemoOutingSpeaking: Sendable {
    func speak(_ speech: DemoOutingSpeech) async
    func stopSpeaking() async
}
