import SwiftUI

/// The post-workout AI read (PRD §4.6, §7.6): a short, human, plan-aware note that makes you feel
/// seen. Fades in after a brief shimmer; Pro-gated. The narrative is always present (template
/// fallback) so the moment never breaks.
struct AIReadCard: View {
    let workout: Workout
    var weightUnit: WeightUnit = .default()
    var distanceUnit: DistanceUnit = .auto

    @Environment(Services.self) private var services
    @State private var read: WorkoutRead?
    @State private var appeared = false

    var body: some View {
        Group {
            if services.paywall.isEntitled(to: .aiRead) {
                card
            }
        }
        .task {
            read = await services.ai.workoutRead(
                for: workout, planned: workout.plannedSession != nil,
                weightUnit: weightUnit, distanceUnit: distanceUnit)
            withAnimation(Motion.standard) { appeared = true }
        }
    }

    @ViewBuilder
    private var card: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "sparkles")
                Text("COACH").tracking(1.5)
            }
            .font(.rounded(Theme.FontSize.label, weight: .semibold))
            .foregroundStyle(Theme.inkTertiary)

            if let read {
                Text(read.narrative)
                    .font(.rounded(Theme.FontSize.body, weight: .regular))
                    .foregroundStyle(Theme.ink)
                    .opacity(appeared ? 1 : 0)
                // The "why": the read's effect on the plan, when the coach adjusted it. Shows the
                // reasoning rather than just the verdict — the trust driver (research).
                if let why = read.planAdjustment, !why.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "arrow.turn.down.right").font(.system(size: 11, weight: .bold))
                        Text(why).font(.rounded(Theme.FontSize.caption, weight: .medium))
                    }
                    .foregroundStyle(Theme.inkSecondary)
                    .opacity(appeared ? 1 : 0)
                }
                CoachDisclaimer().opacity(appeared ? 1 : 0)
            } else {
                // Brief skeleton shimmer while the read resolves.
                RoundedRectangle(cornerRadius: 6).fill(Theme.hairline).frame(height: 16)
                RoundedRectangle(cornerRadius: 6).fill(Theme.hairline).frame(height: 16).frame(maxWidth: 220)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.lg)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Coach read")
        .accessibilityValue(read?.narrative ?? "")
    }
}
