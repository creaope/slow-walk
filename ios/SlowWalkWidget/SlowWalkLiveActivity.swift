import ActivityKit
import SwiftUI
import WidgetKit

/// Live Activity entry point for an ongoing walk session.
///
/// Renders `SlowWalkActivityAttributes` on the Lock Screen and in the
/// Dynamic Island. Starting and updating the activity happens in the app
/// target; this widget only describes how the activity looks.
///
/// The demo-route badge stays visible in every presentation so the activity
/// can never be mistaken for real navigation.
struct SlowWalkLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SlowWalkActivityAttributes.self) { context in
            VStack(spacing: 8) {
                DemoRouteBadge()
                Text(context.attributes.sessionTitle)
                    .font(.headline)
                Text(context.state.statusText)
                    .font(.body)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .activityBackgroundTint(.black.opacity(0.6))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 4) {
                        DemoRouteBadge()
                        Text(context.state.statusText)
                    }
                }
            } compactLeading: {
                Text("慢走")
            } compactTrailing: {
                EmptyView()
            } minimal: {
                Text("慢")
            }
        }
    }
}

/// The always-visible marker that this route is a scripted demo.
private struct DemoRouteBadge: View {
    var body: some View {
        Text(DemoOutingScenarioMarker.text)
            .font(.caption2)
            .fontWeight(.bold)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(.yellow.opacity(0.25))
            .clipShape(Capsule())
    }
}

/// Keeps the widget free of app-module imports for one constant.
enum DemoOutingScenarioMarker {
    static let text = "DEMO ROUTE"
}
