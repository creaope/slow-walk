// ActivityKit predates Sendable annotations: `Activity` is safe to drive
// from any isolation domain but carries no conformance. The preconcurrency
// import keeps those SDK gaps from failing strict-concurrency builds; all
// activity access still flows through this one manager.
@preconcurrency import ActivityKit
import Foundation

/// Runs the demo outing Live Activity through ActivityKit.
///
/// Single-instance rule: starting while an activity is running ends the old
/// one first, so a repeated start can never stack a second system session.
///
/// Degradation: when Live Activities are disabled or a request fails, the
/// call is dropped and the demo continues without a Live Activity.
final class ActivityKitDemoOutingLiveActivityManager: DemoOutingLiveActivityManaging,
    @unchecked Sendable
{
    /// The one running activity and the session it belongs to.
    private var current: (activity: SendableActivity, sessionID: UUID)?

    func start(sessionID: UUID, scenario: DemoOutingScenario) async {
        if let current, current.sessionID == sessionID {
            // Repeated start for the same session: nothing to do.
            return
        }
        if let current {
            await current.activity.end(finalStatusText: nil)
            self.current = nil
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // The fixed title carries the demo-route marker: the Lock Screen
        // and Dynamic Island can never be mistaken for real navigation.
        let attributes = SlowWalkActivityAttributes(
            sessionTitle: "\(scenario.destinationName) — "
                + DemoOutingScenario.demoRouteLabel
        )
        let content = ActivityContent(
            state: SlowWalkActivityAttributes.ContentState(
                statusText: DemoOutingState.travelling.liveActivityStatusText ?? ""
            ),
            staleDate: nil
        )
        guard let activity = try? Activity.request(
            attributes: attributes,
            content: content,
            pushType: nil
        ) else { return }
        current = (SendableActivity(activity), sessionID)
    }

    func update(sessionID: UUID, statusText: String) async {
        guard let current, current.sessionID == sessionID else { return }
        await current.activity.update(statusText: statusText)
    }

    func end(sessionID: UUID, finalStatusText: String) async {
        guard let current, current.sessionID == sessionID else { return }
        await current.activity.end(finalStatusText: finalStatusText)
        self.current = nil
    }
}

/// `Activity` predates `Sendable` conformance but is designed to be driven
/// from any isolation domain; this wrapper states that explicitly and keeps
/// every `ActivityContent` construction inside the Sendable boundary.
private struct SendableActivity: @unchecked Sendable {
    private let activity: Activity<SlowWalkActivityAttributes>

    init(_ activity: Activity<SlowWalkActivityAttributes>) {
        self.activity = activity
    }

    func update(statusText: String) async {
        await activity.update(
            ActivityContent(
                state: SlowWalkActivityAttributes.ContentState(statusText: statusText),
                staleDate: nil
            )
        )
    }

    /// Ends the activity immediately, optionally leaving a final status.
    func end(finalStatusText: String?) async {
        if let finalStatusText {
            let content = ActivityContent(
                state: SlowWalkActivityAttributes.ContentState(
                    statusText: finalStatusText
                ),
                staleDate: nil
            )
            await activity.end(content, dismissalPolicy: .immediate)
        } else {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
