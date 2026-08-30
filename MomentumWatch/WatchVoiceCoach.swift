import Foundation
import AVFoundation
import os

/// The voice coach on the wrist (PRD §4.10 — Pro).
///
/// The phone's `VoiceCoachService` and this speak the SAME words: every line comes from the shared
/// `CoachingCueBuilder`, and the decision of what to say and when comes from the shared
/// `LiveRunCoach`. Only the plumbing differs, and it differs because watchOS is not iOS:
///
/// - There is no `UIBackgroundModes: audio` on the watch. The workout session's
///   `workout-processing` mode is what keeps us alive with the wrist down, and speech is allowed
///   from there — but only through an audio session we activate ourselves.
/// - watchOS wants `activate(options:completionHandler:)` rather than iOS's synchronous
///   `setActive(true)`. The synchronous call is what silently fails on the wrist.
/// - A Watch with no headphones connected routes to its own speaker, which is quiet and easy to
///   miss outdoors. That's the athlete's call, not ours: we speak either way and never pretend.
/// - The Digital Crown volume and Silent Mode are honoured by the system; we don't fight them.
@MainActor
final class WatchVoiceCoach {
    static let shared = WatchVoiceCoach()

    /// Silence after the last word before audio focus goes back to the music, long enough that a
    /// step call and the line chasing it don't un-duck between them (matches the phone).
    private static let releaseIdleS: TimeInterval = 1.5
    /// Beyond this many lines waiting, the backlog is flushed: a cue that arrives late is worse
    /// than one that never came.
    private static let maxQueued = 2

    private let logger = Logger(subsystem: "com.ephraimbel.momentum.app.watchkitapp", category: "voicecoach")

    /// Built lazily — the speech stack is real cost on a watch and a plain recorded run may never
    /// need it. `prepare()` at workout start pays it off the first cue's critical path.
    private var _synthesizer: AVSpeechSynthesizer?
    private var synthesizer: AVSpeechSynthesizer {
        if let existing = _synthesizer { return existing }
        let fresh = AVSpeechSynthesizer()
        fresh.delegate = delegateBox
        _synthesizer = fresh
        return fresh
    }
    private lazy var delegateBox = SpeechDelegate(owner: self)

    private var cachedVoice: AVSpeechSynthesisVoice?
    private var sessionActive = false
    private var activating = false
    private var releaseTask: Task<Void, Never>?
    private var inFlight = 0

    /// Whether the athlete gets spoken coaching at all: Pro entitlement AND the Settings switch,
    /// both decided on the phone and pushed across (`WatchSyncStore.voiceCoachOn`). A watch that
    /// has never heard from its phone stays silent rather than guessing an entitlement.
    var isEnabled: Bool { WatchSyncStore.shared.voiceCoachOn }

    #if DEBUG
    /// Every line actually handed to the synthesizer, in order. The watch simulator cannot play
    /// speech, so this is how the wrist's cue sequence is verified at all.
    private(set) var spokenLog: [String] = []
    #endif

    private init() {}

    /// Warm the speech stack ahead of the first cue (called as a workout starts).
    func prepare() {
        guard isEnabled else { return }
        _ = synthesizer
        _ = voice()
    }

    func announce(_ text: String) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled, !line.isEmpty else { return }
        if inFlight >= Self.maxQueued {
            _synthesizer?.stopSpeaking(at: .word)
            inFlight = 0
        }
        releaseTask?.cancel()
        releaseTask = nil
        activateSession()

        let utterance = AVSpeechUtterance(string: line)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = voice()
        utterance.preUtteranceDelay = leadIn
        inFlight += 1
        logger.info("cue=\(line, privacy: .public)")
        #if DEBUG
        spokenLog.append(line)
        #endif
        synthesizer.speak(utterance)
    }

    func stop() {
        _synthesizer?.stopSpeaking(at: .immediate)
        inFlight = 0
        releaseTask?.cancel()
        releaseTask = nil
        deactivateSession()
    }

    // MARK: Audio session
    /// Bluetooth tears its audio link down when nothing is playing, and cues are at least 12 s
    /// apart — so on a wireless route every cue arrives into a torn-down link and the first
    /// syllable goes with it ("ile three"). The watch is the MOST exposed surface for this, not the
    /// least: AirPods are the normal case for a watch-only run, and after the first cue the session
    /// is already active so nothing re-establishes the route for us.
    ///
    /// Read PER CUE rather than cached — the athlete can connect or drop AirPods mid-run.
    ///
    /// NOT verifiable on a simulator: no Bluetooth audio route exists there. This is reasoned from
    /// documented behaviour and needs a physical watch with AirPods to confirm.
    private static let wirelessLeadS: TimeInterval = 0.45
    private static let wiredLeadS: TimeInterval = 0.10
    private var leadIn: TimeInterval {
        let wireless: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .airPlay]
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.contains { wireless.contains($0.portType) } ? Self.wirelessLeadS : Self.wiredLeadS
    }


    private func activateSession() {
        guard !sessionActive, !activating else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            // `.voicePrompt`, not `.spokenAudio`: a cue is a SHORT prompt over someone else's
            // audio, the same shape as a turn instruction. `.spokenAudio` declares us to be
            // continuous spoken content (podcasts, audiobooks) whose documented wish is to be
            // PAUSED rather than ducked when another app plays a prompt — the relationship
            // backwards, and the wrong side of that negotiation on a watch paired to AirPods
            // playing a podcast. (The tinny call-quality route is not a risk here either way: HFP
            // comes from the recording categories and `.voiceChat`/`.videoChat`, and `.playback`
            // is output only, so the route stays on A2DP whichever mode is set.)
            try session.setCategory(.playback, mode: .voicePrompt,
                                    options: [.duckOthers, .mixWithOthers])
        } catch {
            logger.error("category failed: \(error.localizedDescription, privacy: .public)")
        }
        // watchOS activates asynchronously (it may have to wake a Bluetooth route). The utterance
        // is already queued by then: the synthesizer holds it until the session comes up, which is
        // exactly the behaviour we want and the reason there is no ducking ramp here.
        activating = true
        session.activate(options: []) { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                self.activating = false
                self.sessionActive = granted
                if let error {
                    self.logger.error("activate failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func deactivateSession() {
        guard sessionActive else { return }
        sessionActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func scheduleRelease() {
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.releaseIdleS))
            guard !Task.isCancelled, let self, self._synthesizer?.isSpeaking != true else { return }
            self.deactivateSession()
        }
    }

    fileprivate func finished() {
        inFlight = max(0, inFlight - 1)
        // `isSpeaking` is the authority here, never the counter. `stopSpeaking` cancels
        // ASYNCHRONOUSLY, so a `didCancel` for a flushed utterance lands after its replacement is
        // already queued — and because the flush zeroes `inFlight`, those late decrements would
        // otherwise drive it to nothing under a live utterance and deactivate the session mid-word.
        guard _synthesizer?.isSpeaking != true else { return }
        scheduleRelease()
    }

    // MARK: Voice

    /// English, matched to the athlete's REGION rather than their device language — the cues are
    /// authored in English and a French voice reading "Mile 3" is noise, not a coach.
    private func voice() -> AVSpeechSynthesisVoice? {
        if let cachedVoice { return cachedVoice }
        let region = Locale.current.region?.identifier ?? "US"
        let resolved = AVSpeechSynthesisVoice(language: "en-\(region)")
            ?? AVSpeechSynthesisVoice(language: "en-US")
        cachedVoice = resolved
        return resolved
    }
}

/// A separate box rather than conforming the coach itself: `AVSpeechSynthesizerDelegate` is
/// nonisolated and the coach is `@MainActor`, and the box keeps the hop in one place.
///
/// It HOPS (`Task { @MainActor }`) rather than asserting (`MainActor.assumeIsolated`): AVFoundation
/// does not document the delivery queue for synthesizer callbacks, and `assumeIsolated` is a
/// precondition — so a single off-main callback would crash the app mid-run rather than misbehave.
private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    private weak var owner: WatchVoiceCoach?
    init(owner: WatchVoiceCoach) { self.owner = owner }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak owner] in owner?.finished() }
    }

    /// `stopSpeaking` cancels rather than finishes; without this the in-flight count never comes
    /// back down and every later cue looks like a backlog.
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak owner] in owner?.finished() }
    }
}
