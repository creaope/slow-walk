import AVFAudio
import Foundation

/// Speaks demo outing messages through `AVSpeechSynthesizer`.
///
/// Uses the system speech rate and volume as-is — no attempt is made to
/// override the user's volume or accessibility settings.
@MainActor
final class AVSpeechDemoOutingSpeaker: DemoOutingSpeaking {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ speech: DemoOutingSpeech) async {
        let utterance = AVSpeechUtterance(string: speech.message)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stopSpeaking() async {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
