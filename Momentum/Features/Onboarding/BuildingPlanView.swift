import SwiftUI

/// The "building your plan…" beat (PRD §4.1 step 3) — a clean, enterprise-grade loader: a single
/// iridescent progress ring that fills as the plan comes together, over a title and a per-answer
/// checklist that **ticks to checkmarks** one at a time (each line reflects one of the user's answers).
///
/// Purely presentational: `completed` and `ringProgress` are DRIVEN by the parent
/// (`OnboardingFlow.buildPlan`), which paces the beat with `await`s and slots the real plan
/// generation in behind the final "Finalizing" line — where the main thread's brief busy moment is
/// hidden by a spinner that's *supposed* to be spinning. That's why the beat always plays in full and
/// never freezes mid-tick (the old self-timed version stalled while `finish()` starved its timer).
/// Calm and premium — no theatrics. Honors Reduce Motion.
struct BuildingPlanView: View {
    /// Personalized status lines (from `OnboardingViewModel.buildingLines()`), completed one at a time.
    var lines: [String] = ["Balancing your week", "Spacing your efforts",
                           "Setting your paces", "Finalizing your plan"]

    /// How many lines are checked off — 0…lines.count, parent-driven.
    var completed: Int = 0

    /// Ring fill, 0…1 — parent-driven. A continuous Core Animation fill (stays smooth even while the
    /// main thread is briefly busy generating the plan), not stepped with the checklist.
    var ringProgress: Double = 0

    @ReducedMotionPreference private var reduceMotion
    @State private var breathe = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ProgressRing(progress: ringProgress, lineWidth: 7, isStatic: reduceMotion)
                BrandMark(size: 46)
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            }
            .frame(width: 100, height: 100)
            // The ring on its own pool of light, BEHIND it (a background never sizes the ring —
            // as a ZStack sibling the 240pt pool blew the ring up to match). The pool breathes
            // slowly while the plan builds; Reduce Motion holds it still.
            .background {
                RadialGradient(colors: [Theme.iridescent[0].opacity(0.42), Theme.iridescent[1].opacity(0.12), .clear],
                               center: .center, startRadius: 8, endRadius: 110)
                    .frame(width: 220, height: 220)
                    .scaleEffect(reduceMotion ? 1 : (breathe ? 1.08 : 0.94))
                    .opacity(reduceMotion || breathe ? 1 : 0.8)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                               value: breathe)
            }
            .padding(.bottom, Theme.Space.xl)
            .onAppear { breathe = true }

            VStack(spacing: Theme.Space.xs) {
                Text("Building your plan")
                    .font(.display(30, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("Shaped around your answers, not averages.")
                    .font(.rounded(17, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, Theme.Space.lg)
            .padding(.bottom, Theme.Space.xl)

            VStack(alignment: .leading, spacing: Theme.Space.md) {
                ForEach(lines.indices, id: \.self) { i in checklistRow(i) }
            }
            .padding(.horizontal, 22).padding(.vertical, 20)
            .frame(maxWidth: 320, alignment: .leading)
            .raised(RoundedRectangle(cornerRadius: OnboardingStyle.cardRadius, style: .continuous))
            .padding(.horizontal, Theme.Space.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(OnboardingCanvas())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Building your plan")
    }

    private func checklistRow(_ i: Int) -> some View {
        let done = i < completed
        let current = i == completed
        return HStack(spacing: Theme.Space.sm) {
            ZStack {
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white, Theme.purple)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.4)))
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
        // Reduce Motion lands all rows in one shot (the parent writes `completed` 0→n at once) —
        // suppress the per-row scale-pop there so it reads as the sanctioned instant settle.
        // A spring, not an ease: each check lands with a small overshoot — the beat feels alive.
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.62), value: completed)
    }
}
