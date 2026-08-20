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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ProgressRing(progress: ringProgress, lineWidth: 6)
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
        // Reduce Motion lands all rows in one shot (the parent writes `completed` 0→n at once) —
        // suppress the per-row scale-pop there so it reads as the sanctioned instant settle.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: completed)
    }
}
