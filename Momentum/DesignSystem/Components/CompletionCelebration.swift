import SwiftUI

/// The "you did it" beat shown the instant a workout is saved (PRD §4.6, §6.2) — an iridescent
/// goal ring sweeps to full around a checkmark (the earned accent), a celebration haptic fires,
/// then it fades to reveal the summary. Plays once; honors Reduce Motion (snaps + brief hold).
struct CompletionCelebration: View {
    let title: String
    var onDone: () -> Void

    @State private var ring = 0.0
    @State private var check = 0.0      // checkmark + title scale/opacity
    @State private var bloom = 0.0
    @State private var fade = 1.0
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
                    ProgressRing(progress: ring).frame(width: 132, height: 132)
                    Image(systemName: "checkmark")
                        .font(.system(size: 46, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .scaleEffect(0.5 + 0.5 * check)
                        .opacity(check)
                }
                Text(title)
                    .font(.display(28, weight: .black))
                    .foregroundStyle(Theme.ink)
                    .opacity(check)
            }
        }
        .opacity(fade)
        .task { await run() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    private func run() async {
        Haptics.celebration()
        if reduceMotion {
            ring = 1; check = 1; bloom = 1
            try? await Task.sleep(for: .seconds(0.9))
        } else {
            withAnimation(.easeOut(duration: 0.65)) { ring = 1; bloom = 1 }
            try? await Task.sleep(for: .seconds(0.28))
            withAnimation(.spring(response: 0.42, dampingFraction: 0.6)) { check = 1 }
            try? await Task.sleep(for: .seconds(0.8))
        }
        withAnimation(.easeIn(duration: 0.32)) { fade = 0 }
        try? await Task.sleep(for: .seconds(0.32))
        onDone()
    }
}
