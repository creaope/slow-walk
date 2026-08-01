import ActivityKit
import SwiftUI
import WidgetKit

/// Live Activity entry point for an ongoing walk session.
///
/// Renders `SlowWalkActivityAttributes` on the Lock Screen and in the
/// Dynamic Island. Starting and updating the activity happens in the app
/// target; this widget only describes how the activity looks.
struct SlowWalkLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SlowWalkActivityAttributes.self) { context in
            VStack(spacing: 8) {
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
                    Text(context.state.statusText)
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
