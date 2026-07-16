import AVFoundation
import Foundation
import Speech

/// On-device dictation for the fuel composer (FUEL-FLOW §1 — "speak it"): tap to talk, words
/// stream into `transcript` as they're recognized, tap to stop. Voice is input-only sugar — the
/// text lands in the same field and everything downstream is identical to typing.
///
/// Privacy + resilience: recognition runs on-device whenever the hardware supports it (meals are
/// personal), and every failure path degrades silently back to the keyboard — the composer never
/// blocks on the mic.
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
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.request = request

            let input = audioEngine.inputNode
            // The tap fires on the audio thread — it touches ONLY the captured request
            // (buffer appends are what that API is built for), never main-actor state.
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                // Arbitrary callback queue → extract Sendable values, then hop to main.
                let text = result?.bestTranscription.formattedString
                let done = error != nil || (result?.isFinal ?? false)
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.transcript = text }
                    if done { self.stop() }
                }
            }
            isRecording = true
        } catch {
            stop()
        }
    }

    /// Stop capturing. The transcript keeps whatever was recognized — review, then send.
    func stop() {
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
