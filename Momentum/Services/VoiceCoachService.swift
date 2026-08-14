import Foundation
import AVFoundation
import os

/// Spoken coaching cues during a workout (PRD §4.10 voice coach — Pro). Reads the deterministic
/// strings from `CoachingCueBuilder` aloud, ducking music/podcasts for the moment it speaks. No-ops
/// when disabled so the live loop never depends on it.
@MainActor
final class VoiceCoachService: NSObject, VoiceCoachServing {
    /// The Settings mute writes the same key (`@AppStorage`), so reading defaults here means a flip
    /// mid-run silences the very next cue. Defaults to on.
    static let storageKey = "voiceCoachEnabled"
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.storageKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.storageKey) }
    }

    /// Lazily created: `AVSpeechSynthesizer()` spins up the speech/audio stack, which is real cost
    /// on the cold-start path (this service is built inside `Services.live()` in `MomentumApp.init`)
    /// for something only ever needed mid-run. First `announce` pays it instead.
    private let logger = Logger(subsystem: "com.ephraimbel.momentum.app", category: "voicecoach")

    private var _synthesizer: AVSpeechSynthesizer?
    private var synthesizer: AVSpeechSynthesizer {
        if let existing = _synthesizer { return existing }
        let fresh = AVSpeechSynthesizer()
        // Without the delegate, `didFinish` never fires and the ducking session is only released at
        // finish() — leaving the athlete's music quiet for the entire run after the first cue.
        fresh.delegate = self
        _synthesizer = fresh
        return fresh
    }

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
        // Only touch the synthesizer if it was ever created — `stop()` runs at every workout
        // finish, and spinning up the audio stack just to stop nothing defeats the lazy init.
        _synthesizer?.stopSpeaking(at: .immediate)
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
        // Hand audio focus back once we're done talking — but not between queued cues, or the
        // deactivate would race the next utterance's playback.
        guard !synthesizer.isSpeaking else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
