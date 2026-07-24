import SwiftUI

/// The "you did it" beat (PRD §4.6, §6.2) — played when the athlete taps Done on a save screen
/// (user call 2026-07-23, reversing the earlier play-on-arrival order: the finished, named post is
/// the moment worth crowning, and arrival now goes straight to the summary with nothing standing
/// in front of it). The ring sweeps — or the bare track draws itself — while the checkmark strokes
/// itself through the middle, a celebration haptic fires, then the beat fades and hands back
/// (dismissing the save screen). Plays once; honors Reduce Motion (snaps + brief hold).
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
    static let duration: Double = 0.99

    /// When the fade-out starts. Content underneath should begin its own reveal here, so the two
    /// cross-dissolve into one motion instead of playing back to back with a dead gap between.
    static let handoff: Double = 0.73

    /// The animated ring-sweep position (meaningful reading) …
    @State private var swept = 0.0
    /// … or the bare track drawing itself when there's no reading (trim 0→1 from 12 o'clock).
    @State private var track = 0.0
    /// Stroke-draw progress of the checkmark — the check DRAWS (trim), it doesn't pop.
    @State private var check = 0.0
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
                    // With no reading, the track draws itself: a frame for the checkmark that
                    // claims nothing (never a fake full sweep — see `ring`).
                    if ring != nil {
                        ProgressRing(progress: swept).frame(width: 132, height: 132)
                    } else {
                        Circle()
                            .trim(from: 0, to: track)
                            .stroke(Theme.hairline, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 132, height: 132)
                    }
                    // Drawn tip-to-tail with the same round stroke language as the ring, so circle
                    // and check read as one gesture rather than a shape with a symbol stamped on it.
                    CheckmarkShape()
                        .trim(from: 0, to: check)
                        .stroke(Theme.ink, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                        .frame(width: 52, height: 40)
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
                // Rises in with the check's draw — one motion, not two queued ones.
                .opacity(check)
                .offset(y: 8 * (1 - check))
            }
        }
        .opacity(fade)
        .contentShape(Rectangle())
        // Skippable. An athlete finishing five sessions a week sees this every time, and a beat you
        // can't get past stops being a reward and becomes a toll. Tapping cuts straight through.
        .onTapGesture { finish(fadeDuration: 0.12) }
        .task { await run() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption.map { "\(title). \($0)" } ?? title)
        .accessibilityHint("Tap to skip")
        // Modal to VoiceOver, so the swipe rotor can't wander onto the summary and toolbar sitting
        // behind the opaque overlay during the ~0.86s beat. Fixes all three save screens at once.
        .accessibilityAddTraits([.isButton, .isModal])
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
            swept = ring?.to ?? 0; track = 1; check = 1; bloom = 1
            try? await Task.sleep(for: .seconds(0.5))
        } else {
            // Circle first, check through it while the circle is still finishing — the overlap is
            // what makes it read as one continuous gesture. The check completes its draw at
            // ~0.52s, then the finished mark HOLDS for a fifth of a second before the fade — the
            // hold is what makes it read as done rather than yanked away mid-stroke.
            withAnimation(.easeOut(duration: 0.45)) { swept = ring?.to ?? 0; track = 1; bloom = 1 }
            try? await Task.sleep(for: .seconds(0.18))
            withAnimation(.easeOut(duration: 0.34)) { check = 1 }
            try? await Task.sleep(for: .seconds(0.55))
        }
        // Routed through the same single exit as a tap, so a skip mid-beat can't be followed by a
        // second hand-off when the timeline catches up.
        finish(fadeDuration: 0.26)
    }
}

/// The checkmark as a strokeable path (short arm down, long arm up — one continuous line), so it
/// can draw itself via `.trim`. Proportions sit the glyph optically centered in the ring.
private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + 0.04 * rect.width, y: rect.minY + 0.52 * rect.height))
        p.addLine(to: CGPoint(x: rect.minX + 0.36 * rect.width, y: rect.minY + 0.88 * rect.height))
        p.addLine(to: CGPoint(x: rect.minX + 0.96 * rect.width, y: rect.minY + 0.10 * rect.height))
        return p
    }
}
