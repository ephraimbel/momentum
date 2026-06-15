import Foundation
import AVFoundation
import os

/// Spoken coaching cues during a workout (PRD §4.10 voice coach — Pro). Reads the deterministic
/// strings from `CoachingCueBuilder` aloud, ducking music/podcasts for the moment it speaks. No-ops
/// when disabled so the live loop never depends on it.
@MainActor
final class VoiceCoachService: NSObject, VoiceCoachServing {
    var isEnabled = true

    private let synthesizer = AVSpeechSynthesizer()
    private let logger = Logger(subsystem: "com.momentum.app", category: "voicecoach")

    /// Speak a cue. Activates a ducking audio session, speaks, and lets the session deactivate when
    /// speech finishes (so music returns to full volume).
    func announce(_ text: String) {
        guard isEnabled, !text.isEmpty else { return }
        logger.info("cue=\(text, privacy: .public)")
        configureSession()
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        // Mix with the user's music/podcast but duck it while we speak the cue.
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true, options: [])
    }
}

extension VoiceCoachService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        // Hand audio focus back once we're done talking.
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
