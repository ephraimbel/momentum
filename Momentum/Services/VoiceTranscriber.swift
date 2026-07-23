import AVFoundation
import Foundation
import Speech

/// On-device dictation for the fuel + workout-log composers: tap to talk, words stream into
/// `transcript` as they're recognized, tap to stop. Voice is input-only sugar — the text lands in
/// the same field and everything downstream is identical to typing.
///
/// **Continuous across pauses.** The recognizer closes an "utterance" at every silence and the
/// next partial would REPLACE everything already said — the athlete listing sets ("bench pressed
/// 185… (pause) …then squatted 225") would watch their first sentence vanish. So every finalized
/// segment is BANKED and a fresh recognition segment starts immediately on the same running audio
/// engine; `transcript` is always banked + live partial, and the banked part can never shrink.
/// Dictation only ends when the athlete taps stop — or after two consecutive silent segments
/// (they walked away).
///
/// Privacy + resilience: recognition runs on-device whenever the hardware supports it, and every
/// failure path degrades silently back to the keyboard — the composer never blocks on the mic.
@MainActor
@Observable
final class VoiceTranscriber {
    /// Live recognized text for the current recording — resets on each `start()`.
    private(set) var transcript = ""
    private(set) var isRecording = false
    /// Mic or speech permission was refused — the view offers the Settings hand-off once.
    var showPermissionAlert = false

    /// false when this device/locale can't recognize speech at all → the mic button hides.
    var isSupported: Bool { recognizer != nil }

    private let recognizer = SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Finalized segments, joined — the part of `transcript` no later partial may ever replace.
    private var banked = ""
    /// Invalidates callbacks from a superseded segment (each restart bumps it).
    private var segmentToken = 0
    /// Segments that ended with no fresh words — two in a row means nobody's talking anymore;
    /// stop rather than spin the recognizer forever.
    private var quietSegments = 0

    func toggle() {
        if isRecording { stop() } else { Task { await start() } }
    }

    func start() async {
        guard !isRecording, let recognizer, recognizer.isAvailable else { return }
        // Both gates up front (speech, then mic) — the composer keyboard stays usable throughout.
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard speech == .authorized else {
            showPermissionAlert = speech == .denied || speech == .restricted
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            showPermissionAlert = true
            return
        }

        transcript = ""
        banked = ""
        quietSegments = 0
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            beginSegment()
        } catch {
            stop()
        }
    }

    /// One recognition segment on the already-running engine. Called at start and again after
    /// every finalization/failure while recording — this restart chain is what makes dictation
    /// survive the recognizer's per-utterance silence timeout.
    private func beginSegment() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request

        let input = audioEngine.inputNode
        input.removeTap(onBus: 0)
        // The tap fires on the audio thread — it touches ONLY the captured request
        // (buffer appends are what that API is built for), never main-actor state.
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }

        segmentToken += 1
        let token = segmentToken
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Arbitrary callback queue → extract Sendable values, then hop to main.
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                guard let self, token == self.segmentToken else { return }
                if let text, !text.isEmpty {
                    self.quietSegments = 0
                    self.transcript = self.banked.isEmpty ? text : self.banked + " " + text
                }
                guard isFinal || failed else { return }
                // The utterance closed (silence) or the recognizer gave up. Bank whatever stands —
                // nothing already spoken is ever lost — and keep listening.
                let spokeThisSegment = self.transcript != self.banked && !self.transcript.isEmpty
                self.banked = self.transcript
                guard self.isRecording else { return }
                if !spokeThisSegment {
                    self.quietSegments += 1
                    if self.quietSegments >= 2 {   // they walked away
                        self.stop()
                        return
                    }
                }
                self.beginSegment()
            }
        }
    }

    /// Stop capturing. The transcript keeps everything banked plus the last partial — review,
    /// then send.
    func stop() {
        segmentToken += 1   // orphan any in-flight callback before tearing down
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRecording = false
    }
}
