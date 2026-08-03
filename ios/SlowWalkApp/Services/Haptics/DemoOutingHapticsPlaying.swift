import Foundation

/// Haptic patterns used by the demo outing.
enum DemoOutingHaptic: Equatable, Sendable {
    /// Strong warning pulse for the attention-needed moment.
    case attentionNeeded
    /// Success confirmation on arrival.
    case arrived
}

extension DemoOutingHaptic {
    /// The haptic a demo outing state triggers, if any.
    ///
    /// Only the two alert moments produce haptics; travelling, approaching
    /// and every terminal-or-idle remainder stay silent.
    init?(state: DemoOutingState) {
        switch state {
        case .attentionNeeded:
            self = .attentionNeeded
        case .arrived:
            self = .arrived
        case .idle, .travelling, .approaching, .cancelled, .failed:
            return nil
        }
    }
}

/// Haptic playback boundary for demo outing events.
protocol DemoOutingHapticsPlaying: Sendable {
    func play(_ haptic: DemoOutingHaptic) async
}
