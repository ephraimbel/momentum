import SwiftUI

/// The "you did it" beat shown the instant a workout is saved (PRD §4.6, §6.2) — an iridescent
/// goal ring sweeps to full around a checkmark (the earned accent), a celebration haptic fires,
/// then it fades to reveal the summary. Plays once; honors Reduce Motion (snaps + brief hold).
struct CompletionCelebration: View {
    let title: String
    /// Where the ring starts and where it sweeps to, or nil when there is nothing true to draw.
    ///
    /// nil renders the bare track. It must NOT fall back to 0→1: a full sweep is a claim that the
    /// week is complete, and defaulting to it turned every case the reading deliberately declined to
    /// make — a treadmill run with no GPS lock, an athlete with no weekly target — into the loudest
    /// possible one. That spinner-wearing-an-achievement's-clothes is the whole thing this replaced.
    var ring: (from: Double, to: Double)?
    /// The legend the ring needs to mean anything ("14 of 20 mi this week"). A ring with no reading
    /// beside it is decoration no matter what it's wired to.
    var caption: String?
    var onDone: () -> Void

    init(title: String, ring: (from: Double, to: Double)? = nil, caption: String? = nil,
         onDone: @escaping () -> Void) {
        self.title = title
        self.ring = ring
        self.caption = caption
        self.onDone = onDone
        // Seeded so the first painted frame already shows the week as it stood — starting at zero
        // and jumping would read as the week resetting before it filled.
        _swept = State(initialValue: ring?.from ?? 0)
    }

    /// Wall time from appear to `onDone` — the sum of the beats in `run()` below. Callers schedule
    /// work to land *after* the beat rather than stalling the screen before it.
    static let duration: Double = 0.86

    /// When the fade-out starts. Content underneath should begin its own reveal here, so the two
    /// cross-dissolve into one motion instead of playing back to back with a dead gap between.
    static let handoff: Double = 0.60

    /// The animated sweep position.
    @State private var swept = 0.0
    @State private var check = 0.0      // checkmark + title scale/opacity
    @State private var bloom = 0.0
    @State private var fade = 1.0
    /// Guards `onDone` against firing twice when a tap and the timed run race each other.
    @State private var handedOff = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: Theme.Space.lg) {
                ZStack {
                    Circle().fill(IridescentMaterial())
                        .frame(width: 180, height: 180)
                        .opacity(0.25 * bloom)
                        .blur(radius: 24)
                    // Seeded at the week as it stood and swept to where it stands now — the arc it
                    // travels IS this session, expressed as growth rather than as a second colour.
                    // With no reading, the bare track: a frame for the checkmark that claims nothing.
                    if ring != nil {
                        ProgressRing(progress: swept).frame(width: 132, height: 132)
                    } else {
                        Circle().stroke(Theme.hairline, lineWidth: 12).frame(width: 132, height: 132)
                    }
                    Image(systemName: "checkmark")
                        .font(.system(size: 46, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .scaleEffect(0.5 + 0.5 * check)
                        .opacity(check)
                }
                VStack(spacing: Theme.Space.xs) {
                    Text(title)
                        .font(.display(28, weight: .black))
                        .foregroundStyle(Theme.ink)
                    if let caption {
                        Text(caption)
                            .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
                .opacity(check)
            }
        }
        .opacity(fade)
        .contentShape(Rectangle())
        // Skippable. An athlete finishing five sessions a week sees this every time, and a beat you
        // can't get past stops being a reward and becomes a toll. Tapping cuts to the summary.
        .onTapGesture { finish(fadeDuration: 0.12) }
        .task { await run() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption.map { "\(title). \($0)" } ?? title)
        .accessibilityHint("Tap to skip")
        .accessibilityAddTraits(.isButton)
    }

    /// Fade out and hand back exactly once, whichever gets here first — the timed run or a tap.
    private func finish(fadeDuration: Double) {
        guard !handedOff else { return }
        handedOff = true
        withAnimation(.easeIn(duration: fadeDuration)) { fade = 0 }
        Task {
            try? await Task.sleep(for: .seconds(fadeDuration))
            onDone()
        }
    }

    private func run() async {
        Haptics.celebration()
        if reduceMotion {
            swept = ring?.to ?? 0; check = 1; bloom = 1
            try? await Task.sleep(for: .seconds(0.5))
        } else {
            withAnimation(.easeOut(duration: 0.5)) { swept = ring?.to ?? 0; bloom = 1 }
            try? await Task.sleep(for: .seconds(0.18))
            withAnimation(.spring(response: 0.36, dampingFraction: 0.6)) { check = 1 }
            try? await Task.sleep(for: .seconds(0.42))
        }
        // Routed through the same single exit as a tap, so a skip mid-beat can't be followed by a
        // second hand-off when the timeline catches up.
        finish(fadeDuration: 0.26)
    }
}
