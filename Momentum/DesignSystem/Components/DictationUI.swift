import SwiftUI

/// The shared premium-dictation surfaces (log composer · fuel · coach chat): a voice-reactive
/// level meter and a live transcript that keeps the newest words in view. ONE implementation, so
/// every composer's dictation moment looks and moves identically.
///
/// Motion doctrine: transform/opacity only, and everything is LEVEL-driven — the bars move
/// because the athlete spoke, nothing pulses on its own. Reduce Motion collapses to the static
/// waveform glyph.

/// Five slim capsules riding the live input level. Each bar carries a fixed phase and weight so
/// the cluster undulates organically (center-weighted, never lockstep); amplitude is the spoken
/// level, so silence reads as a calm dotted line and speech reads alive under the voice.
struct VoiceLevelBars: View {
    /// 0–1 smoothed input level (`VoiceTranscriber.level`).
    let level: Double
    var tint: Color = .white
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let phases: [Double] = [0.0, 1.9, 0.8, 2.6, 1.3]
    private static let weights: [Double] = [0.55, 0.85, 1.0, 0.85, 0.55]

    var body: some View {
        if reduceMotion {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
        } else {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 2.5) {
                    ForEach(0..<5, id: \.self) { i in
                        Capsule()
                            .fill(tint)
                            .frame(width: 2.5, height: barHeight(i, t: t))
                    }
                }
                .frame(height: 18)
            }
        }
    }

    private func barHeight(_ i: Int, t: Double) -> Double {
        // Per-bar sway (phase-offset sine) scaled by the LIVE level — no voice, no dance.
        let sway = 0.5 + 0.5 * sin(t * 9 + Self.phases[i])
        return 3 + level * 13 * Self.weights[i] * (0.55 + 0.45 * sway)
    }
}

/// The words as they land — sits exactly where the composer's TextField sits and always shows
/// the TAIL of the dictation (head-truncated), so the athlete watches their newest words arrive
/// no matter how long they talk. The composer swaps back to its TextField on stop; the full text
/// is there.
struct LiveTranscriptView: View {
    let text: String
    var placeholder: String = "Listening…"

    private var display: String {
        text.isEmpty ? placeholder : text
    }

    var body: some View {
        Text(display)
            .font(.rounded(Theme.FontSize.body, weight: .medium))
            .foregroundStyle(text.isEmpty ? Theme.inkTertiary : Theme.ink)
            .lineLimit(6)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(Motion.standard, value: display)
            .accessibilityLabel(text.isEmpty ? "Listening for dictation" : "Dictated: \(text)")
    }
}
