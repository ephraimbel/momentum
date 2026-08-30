import Foundation
import AVFoundation
import os

/// Spoken coaching cues during a workout (PRD §4.10 voice coach — Pro). Reads the deterministic
/// strings from `CoachingCueBuilder` aloud, ducking music/podcasts for the moment it speaks. No-ops
/// when disabled so the live loop never depends on it.
///
/// The whole point of this service is the run you do NOT look at: phone pocketed, screen locked,
/// AirPods in. Everything below exists because that run is hostile to speech.
///
/// - iOS refuses an audio session to a backgrounded app that has not declared the `audio`
///   background mode. `location` keeps the app *running*; only `audio` lets it *speak*
///   (`project.yml` → `UIBackgroundModes`). Nothing here plays on silence: the session is activated
///   for a cue and released once the talking stops, so the mode is used for what it says.
/// - Ducking is a ramp, not a switch. Speaking the instant the session goes active eats the first
///   syllable ("ile three"), so the first line of a burst carries a short `preUtteranceDelay`.
/// - Almost every runner is on Bluetooth, and Bluetooth drops its audio link the moment nothing is
///   playing. Cues are 12 s apart at the closest, so every one of them arrives into a torn-down
///   link and the lead-in has to cover bringing it back up. The category stays `.playback`, which
///   is output only, so the route never falls to the call-quality HFP path.
/// - The media server can be reset out from under a long run. That permanently deafens an
///   `AVSpeechSynthesizer`, so we throw it away and build a fresh one.
/// - The cue text is authored in English. The voice therefore has to be an English one, matched to
///   the athlete's *region* rather than their device language: a French voice reading "Mile 3" is
///   not a coach, it is noise.
@MainActor
final class VoiceCoachService: NSObject, VoiceCoachServing {
    /// The Settings mute writes the same key (`@AppStorage`), so reading defaults here means a flip
    /// mid-run silences the very next cue. Defaults to on.
    static let storageKey = "voiceCoachEnabled"
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.storageKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.storageKey) }
    }

    /// How long the ducking ramp is given before the first word of a burst, wired or on the
    /// phone's own speaker.
    private static let duckRampS: TimeInterval = 0.2
    /// The same lead-in over a wireless route. Bluetooth tears its audio link down when nothing is
    /// playing and needs noticeably longer to bring it back up, and a cue arrives into silence
    /// every time (12 s apart at the closest). This is the "AirPods ate the first word" complaint,
    /// and it is the route almost every runner is actually on.
    private static let wirelessDuckRampS: TimeInterval = 0.45
    /// Silence after the last word before audio focus goes back to the music. Long enough that two
    /// cues in quick succession (a step call chased by its target) don't un-duck between them.
    private static let releaseIdleS: TimeInterval = 1.5
    /// Nobody wants a backlog read at them. Beyond this many lines waiting, the oldest are dropped:
    /// a cue that arrives late is worse than one that never came.
    private static let maxQueued = 2

    private let logger = Logger(subsystem: "com.ephraimbel.momentum.app", category: "voicecoach")

    /// Lazily created: `AVSpeechSynthesizer()` spins up the speech/audio stack, which is real cost
    /// on the cold-start path (this service is built inside `Services.live()` in `MomentumApp.init`)
    /// for something only ever needed mid-run. `prepare()` (at workout start) or the first
    /// `announce` pays it instead.
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

    /// Resolved once (`speechVoices()` walks every installed voice) and re-resolved after a media
    /// reset, since a downloaded voice can appear or vanish while the app is alive.
    private var cachedVoice: AVSpeechSynthesisVoice?

    private var sessionActive = false
    private var releaseTask: Task<Void, Never>?
    /// Speech we've handed to the synthesizer and not yet heard finish. Counted rather than held so
    /// a cancel can't leave a phantom in the queue.
    private var inFlight = 0
    /// True while the system owns our audio (a phone call). Cues raised in that window are dropped,
    /// not queued: by the time the call ends, "Mile 3" is a lie.
    private var interrupted = false

    override init() {
        super.init()
        observeAudioSession()
    }

    // MARK: Speaking

    /// Warm the speech stack ahead of the first cue (called as a workout arms). Building the
    /// synthesizer and resolving the voice takes tens of milliseconds the first time; paying it
    /// here means the opening line lands on the beat instead of a moment after it.
    func prepare() {
        guard isEnabled else { return }
        _ = synthesizer
        _ = voice()
    }

    /// Speak a cue. Activates a ducking audio session, speaks, and lets the session deactivate a
    /// beat after speech finishes (so music returns to full volume, but two cues in a row don't
    /// duck twice).
    func announce(_ text: String) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled, !line.isEmpty else { return }
        guard !interrupted else {
            logger.info("dropped (interrupted) cue=\(line, privacy: .public)")
            return
        }
        // A backlog means the coach is behind the run. Say the newest thing, not the oldest.
        // The count is NOT zeroed here: `stopSpeaking` cancels asynchronously, so the `didCancel`
        // callbacks land after the new utterance is already queued. Zeroing meant those late
        // decrements drove the count to nothing under a live utterance, and the idle release then
        // deactivated the session mid-word. `finished()` resyncs against `isSpeaking` instead.
        if inFlight >= Self.maxQueued {
            logger.info("backlog \(self.inFlight) — flushing before cue=\(line, privacy: .public)")
            _synthesizer?.stopSpeaking(at: .word)
        }

        releaseTask?.cancel()
        releaseTask = nil
        let wasActive = sessionActive
        activateSession()

        let utterance = AVSpeechUtterance(string: line)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = voice()
        // Only the line that opens a burst waits out the duck ramp; a follow-on cue is already
        // speaking into a ducked mix and a pause there would just sound like hesitation. Read the
        // route per cue rather than caching it: AirPods get connected and disconnected mid-run.
        utterance.preUtteranceDelay = wasActive ? 0
            : (Self.isWirelessRoute(AVAudioSession.sharedInstance()) ? Self.wirelessDuckRampS : Self.duckRampS)
        inFlight += 1
        logger.info("cue=\(line, privacy: .public)")
        synthesizer.speak(utterance)
    }

    func stop() {
        // Only touch the synthesizer if it was ever created — `stop()` runs at every workout
        // finish, and spinning up the audio stack just to stop nothing defeats the lazy init.
        _synthesizer?.stopSpeaking(at: .immediate)
        inFlight = 0
        releaseTask?.cancel()
        releaseTask = nil
        deactivateSession()
    }

    // MARK: Audio session

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // Mix with the user's music/podcast but duck it while we speak the cue.
            //
            // `.voicePrompt` is the mode Apple added for exactly this: a short spoken prompt over
            // someone else's audio, the same shape as a turn instruction. Do NOT "upgrade" it to
            // `.spokenAudio` — that mode is for CONTINUOUS spoken content (podcasts, audiobooks)
            // and its whole meaning is "pause me rather than duck me when another app plays a
            // prompt". We are the prompt.
            //
            // The tinny, call-quality Bluetooth path is worth naming because it is the thing people
            // reach for this mode to avoid: it comes from the RECORDING categories (`.playAndRecord`)
            // and the chat modes, which force the bidirectional HFP link. `.playback` is output
            // only, so the route stays on A2DP whichever of these modes is set.
            try session.setCategory(.playback, mode: .voicePrompt,
                                    options: [.duckOthers, .mixWithOthers])
            try session.setActive(true, options: [])
            sessionActive = true
        } catch {
            // Swallowing this is what made the coach look "broken": a backgrounded app without the
            // `audio` capability fails here every single time, and every cue vanished with it.
            sessionActive = false
            logger.error("audio session activate failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deactivateSession() {
        guard sessionActive else { return }
        sessionActive = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            logger.error("audio session deactivate failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Hand audio focus back once the talking has actually stopped — after a short silence, so a
    /// step call and the line chasing it don't un-duck the athlete's music between them.
    ///
    /// `isSpeaking` is the authority here, never the counter. Releasing the session under a live
    /// utterance cuts the cue off mid-word, and that is precisely the failure the athlete reports
    /// as "it only says half of it".
    private func scheduleRelease() {
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.releaseIdleS))
            guard !Task.isCancelled, let self, self._synthesizer?.isSpeaking != true else { return }
            self.deactivateSession()
        }
    }

    /// True when audio is currently leaving the phone over a wireless link.
    nonisolated static func isWirelessRoute(_ session: AVAudioSession) -> Bool {
        session.currentRoute.outputs.contains { output in
            switch output.portType {
            case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .airPlay: true
            default: false
            }
        }
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        // A phone call takes the session away. Without this the coach keeps "speaking" into a dead
        // session for the rest of the run: the utterances complete, nobody hears a word.
        center.addObserver(forName: AVAudioSession.interruptionNotification,
                           object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init)
            MainActor.assumeIsolated { self?.handleInterruption(type) }
        }
        // The media server can be reset mid-run. Every audio object made before it, the synthesizer
        // included, is dead afterwards and silently no-ops; the only cure is to rebuild.
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMediaReset() }
        }
        // Route changes need no handling — speech follows the new route on its own and the lead-in
        // is read per cue — but they are logged, because "it works at home and not with my AirPods"
        // is otherwise an unreproducible support email, which is exactly how this feature's last
        // bug arrived.
        center.addObserver(forName: AVAudioSession.routeChangeNotification,
                           object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated { self?.logRouteChange(reason) }
        }
    }

    private func logRouteChange(_ reason: AVAudioSession.RouteChangeReason?) {
        let session = AVAudioSession.sharedInstance()
        let ports = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
        logger.info("route=\(ports, privacy: .public) wireless=\(Self.isWirelessRoute(session)) reason=\(reason?.rawValue ?? 0)")
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?) {
        switch type {
        case .began:
            interrupted = true
            sessionActive = false
            inFlight = 0
            _synthesizer?.stopSpeaking(at: .immediate)
            logger.info("interrupted")
        case .ended:
            // The next cue re-activates from scratch; there is nothing worth resuming, because a
            // coaching line is only true at the moment it was raised.
            interrupted = false
            logger.info("interruption ended")
        default:
            break
        }
    }

    private func handleMediaReset() {
        logger.error("media services reset — rebuilding the synthesizer")
        _synthesizer?.delegate = nil
        _synthesizer = nil
        cachedVoice = nil
        sessionActive = false
        inFlight = 0
        interrupted = false
    }

    // MARK: Voice selection

    /// The voice that reads the cues. English, because the cues are written in English; the
    /// athlete's region picks the accent, so a UK runner hears "kilometre" the way they say it.
    /// Upgrades to the Enhanced/Premium download of that same voice when they have one.
    private func voice() -> AVSpeechSynthesisVoice? {
        if let cachedVoice { return cachedVoice }
        let resolved = Self.resolveVoice()
        cachedVoice = resolved
        logger.info("voice=\(resolved?.identifier ?? "system default", privacy: .public)")
        return resolved
    }

    nonisolated static func resolveVoice() -> AVSpeechSynthesisVoice? {
        // `AVSpeechSynthesisVoice(language:)` returns the SYSTEM's default voice for a language,
        // which is the only reliable way to avoid the novelty voices ("Bells", "Trinoids") that
        // also ship under en-US and would otherwise win a naive "best quality" scan.
        let region = Locale.current.region?.identifier ?? "US"
        let base = AVSpeechSynthesisVoice(language: "en-\(region)")
            ?? AVSpeechSynthesisVoice(language: "en-US")
        guard let base else { return nil }
        // If the athlete has downloaded the Enhanced or Premium build of that same voice, use it:
        // same character, markedly better outdoors.
        let upgrade = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == base.language && $0.name == base.name
                      && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .max { $0.quality.rawValue < $1.quality.rawValue }
        if let upgrade, upgrade.quality.rawValue > base.quality.rawValue { return upgrade }
        return base
    }
}

extension VoiceCoachService: AVSpeechSynthesizerDelegate {
    // These two hop to the main actor rather than asserting they are already on it. AVFoundation
    // does not document the delivery queue for synthesizer callbacks, and `MainActor.assumeIsolated`
    // is a precondition: one callback off the main thread would not misbehave, it would crash the
    // app mid-run. Nothing here is ordering-sensitive enough to be worth that.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finished() }
    }

    /// `stopSpeaking` cancels rather than finishes, so without this the in-flight count would never
    /// come back down and every later cue would look like a backlog.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finished() }
    }

    private func finished() {
        inFlight = max(0, inFlight - 1)
        // Not between queued cues, or the deactivate would race the next utterance's playback.
        guard _synthesizer?.isSpeaking != true else { return }
        // Speech has actually stopped, so resync the count against the truth. A cancelled utterance
        // that never reported back would otherwise leave the coach looking permanently backlogged,
        // flushing every cue it was asked to say from then on.
        inFlight = 0
        scheduleRelease()
    }
}
