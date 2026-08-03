import Foundation
import UserNotifications

/// Posts demo outing notifications through `UNUserNotificationCenter`.
///
/// Permission handling is lazy and safe:
///
/// - authorization is requested on the first post when undetermined;
/// - a denied permission drops the notification silently — the demo keeps
///   running without system banners;
/// - a failing `add` call is swallowed for the same reason.
///
/// Only identifiers with the demo prefix are ever cancelled, so unrelated
/// app notifications are left untouched.
final class UserNotificationCenterDemoOutingNotifier: DemoOutingNotificationPosting,
    @unchecked Sendable
{
    /// Identifier prefix for every notification this poster creates.
    private static let identifierPrefix = "slowwalk.demo-outing."

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func post(_ notification: DemoOutingNotification) async {
        guard await ensureAuthorization() else { return }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        if notification.isTimeSensitive {
            content.interruptionLevel = .timeSensitive
        }

        let identifier = Self.identifierPrefix
            + notification.sessionID.uuidString
            + "." + notification.kind.rawValue
        // Immediate delivery: the outing state machine already decides when
        // the moment happens, so no trigger is attached.
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    func cancelDemoNotifications() async {
        let prefix = Self.identifierPrefix
        let pending = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(prefix) }
        let delivered = await center.deliveredNotifications()
            .map(\.request.identifier)
            .filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        center.removeDeliveredNotifications(withIdentifiers: delivered)
    }

    /// Whether notifications may be posted. Requests authorization once when
    /// the status is undetermined; any denial degrades to `false`.
    private func ensureAuthorization() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound]))
                ?? false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }
}
