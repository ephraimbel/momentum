import SwiftUI

/// The post-workout AI read (PRD §4.6, §7.6): a short, human, plan-aware note that makes you feel
/// seen. Fades in after a brief shimmer; Pro-gated. The narrative is always present (template
/// fallback) so the moment never breaks.
struct AIReadCard: View {
    let workout: Workout
    var weightUnit: WeightUnit = .default()
    var distanceUnit: DistanceUnit = .auto

    @Environment(Services.self) private var services
    @Environment(PaywallController.self) private var paywall
    @State private var read: WorkoutRead?
    @State private var appeared = false

    var body: some View {
        Group {
            if paywall.isEntitled(to: .aiRead) {
                card
            } else {
                lockedTeaser
            }
        }
        .task {
            guard paywall.isEntitled(to: .aiRead) else { return }   // don't spend an AI call when locked
            let started = Date()
            read = await services.ai.workoutRead(
                for: workout, planned: workout.plannedSession != nil,
                weightUnit: weightUnit, distanceUnit: distanceUnit)
            // AI latency + fallback rate (PRD §13.5) + the north-star "viewed the AI read" milestone.
            services.analytics.log(.aiReadViewed(
                latencyMs: Int(Date().timeIntervalSince(started) * 1000),
                fallback: !AIService.isServerConfigured))
            withAnimation(Motion.standard) { appeared = true }
        }
    }

    /// The free-tier glimpse: shows the coach exists, taps through to the paywall (PRD §10 — gate the
    /// AI block, never the workout). Fires the `ai_read` placement context.
    private var lockedTeaser: some View {
        Button { paywall.present(for: .aiRead) } label: {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: "sparkles").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.ink)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Coach read").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("A short, personal note on this workout — with Pro.")
                        .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "lock.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.inkTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.lg)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(IridescentMaterial(), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Unlock the AI coach read with Pro")
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
