import ActivityKit
import Foundation

/// Shared ActivityKit contract between the app and the widget extension.
///
/// This is the project entry point for Live Activities: the app starts and
/// updates a walk session activity with these attributes, and the widget
/// extension renders it on the Lock Screen and in the Dynamic Island. The
/// same source file is compiled into both targets so the contract can never
/// drift apart.
struct SlowWalkActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Short status line shown while the session is running.
        var statusText: String
    }

    /// Fixed title for the walk session, shown at the top of the activity.
    var sessionTitle: String
}
