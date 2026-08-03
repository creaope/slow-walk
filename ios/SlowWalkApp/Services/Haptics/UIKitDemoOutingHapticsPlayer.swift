#if canImport(UIKit)
import UIKit

/// Plays demo outing haptics through UIKit feedback generators.
///
/// Uses the standard notification feedback styles only, so the patterns feel
/// consistent with the rest of iOS and respect the system haptics settings.
@MainActor
final class UIKitDemoOutingHapticsPlayer: DemoOutingHapticsPlaying {
    func play(_ haptic: DemoOutingHaptic) async {
        switch haptic {
        case .attentionNeeded:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .arrived:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}
#endif
