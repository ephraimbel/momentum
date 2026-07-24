import SwiftUI

/// The "building your plan…" beat (PRD §4.1 step 3) — a clean, enterprise-grade loader: a single
/// iridescent progress ring that fills as the plan comes together, over a title and a per-answer
/// checklist that **ticks to checkmarks** one at a time (each line reflects one of the user's answers).
/// Calm and premium — no theatrics. Auto-advances after a couple of seconds. Honors Reduce Motion.
struct BuildingPlanView: View {
    /// Personalized status lines (from `OnboardingViewModel.buildingLines()`), completed one at a time.
    var lines: [String] = ["Balancing your week", "Spacing your efforts",
                           "Setting your paces", "Finalizing your plan"]

    /// Fires once the ring has filled and every line has ticked off (plus a brief "done" hold). The
    /// advance is DRIVEN by the animation finishing — not a fixed timer the plan generation running
    /// alongside could outrun — so the beat always plays in full before the reveal.
    var onComplete: (() -> Void)?

    @State private var completed = 0
    @State private var ringFill = 0.0
    @State private var didComplete = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let lineTick = Timer.publish(every: Self.tickInterval, on: .main, in: .common).autoconnect()

    static let tickInterval = 0.55

    init(lines: [String]? = nil, onComplete: (() -> Void)? = nil) {
        if let lines { self.lines = lines }
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // A continuous fill (Core Animation, so it stays smooth even while the main thread is
                // briefly busy generating the plan), not stepped with the checklist.
                ProgressRing(progress: ringFill, lineWidth: 6)
                BrandMark(size: 40)
            }
            .frame(width: 92, height: 92)
            .padding(.bottom, Theme.Space.xxl)

            VStack(spacing: Theme.Space.xs) {
                Text("Building your plan")
                    .font(.display(Theme.FontSize.title, weight: .black))
                    .foregroundStyle(Theme.ink)
                Text("Shaped around your answers, not averages.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, Theme.Space.lg)
            .padding(.bottom, Theme.Space.xl)

            VStack(alignment: .leading, spacing: Theme.Space.md) {
                ForEach(lines.indices, id: \.self) { i in checklistRow(i) }
            }
            .frame(width: 300, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Theme.background.ignoresSafeArea())
        .onReceive(lineTick) { _ in
            guard !reduceMotion, completed < lines.count else { return }
            withAnimation(.easeOut(duration: 0.4)) { completed += 1 }
            if completed == lines.count { holdThenAdvance(1.0) }   // all checked → hold, then reveal
        }
        .onAppear {
            if reduceMotion {
                completed = lines.count; ringFill = 1
                holdThenAdvance(0.7)
            } else {
                // Fill the ring across the whole checklist span so it completes right as the last
                // line checks off — one continuous, premium motion.
                withAnimation(.easeInOut(duration: Double(lines.count) * Self.tickInterval + 0.35)) {
                    ringFill = 1
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Building your plan")
    }

    /// Advance once, after a calm hold on the finished state (full ring + every checkmark).
    private func holdThenAdvance(_ hold: Double) {
        guard !didComplete else { return }
        didComplete = true
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { onComplete?() }
    }

    private func checklistRow(_ i: Int) -> some View {
        let done = i < completed
        let current = i == completed
        return HStack(spacing: Theme.Space.sm) {
            ZStack {
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .transition(.opacity.combined(with: .scale(scale: 0.7)))
                } else if current && !reduceMotion {
                    ProgressView().controlSize(.small).tint(Theme.inkTertiary)
                } else {
                    Image(systemName: "circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.hairline)
                }
            }
            .frame(width: 20, height: 20)

            Text(lines[i])
                .font(.rounded(Theme.FontSize.body, weight: .semibold))
                .foregroundStyle(done ? Theme.ink : (current ? Theme.inkSecondary : Theme.inkTertiary))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.35), value: completed)
    }
}
