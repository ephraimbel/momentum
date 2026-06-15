import SwiftUI
import SwiftData

/// Post-workout apply-on-confirm (PRD §9.4 — the consent-required half of the adaptive loop). When
/// the deterministic coach computes that you've earned more load (ACWR under-loaded), it offers a
/// one-tap, bounded plan bump. `autoAdapt` already eases/rests on its own; raising load is the one
/// direction that should never happen without a tap — so the athlete confirms it here. The numbers
/// are the engine's (`PlanCoaching.apply`); the AI only narrates elsewhere.
struct PlanProposalCard: View {
    @Environment(\.modelContext) private var context
    @Environment(Services.self) private var services
    @Query private var profiles: [UserProfile]
    @Query private var workouts: [Workout]

    /// `nil` = undecided, `>= 0` = applied (n sessions), `-1` = dismissed. Latches so the card
    /// resolves to one state and never re-offers within the summary.
    @State private var outcome: Int?

    private var plan: TrainingPlan? { profiles.first?.plan }
    private var proposal: PlanCoaching.Proposal? {
        outcome == nil ? PlanCoaching.proposeAdjustment(plan, workouts: workouts) : nil
    }

    var body: some View {
        if let applied = outcome, applied >= 0 {
            confirmation(applied)
        } else if let p = proposal {
            offer(p)
        }
    }

    private func offer(_ p: PlanCoaching.Proposal) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            header
            Text(p.headline)
                .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(p.detail)
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.sm) {
                Button { apply(p) } label: {
                    chip("Apply", icon: "wand.and.stars", filled: true)
                }
                .buttonStyle(.plain)
                Button { withAnimation(Motion.standard) { outcome = -1 } } label: {
                    Text("Not now")
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                        .padding(.horizontal, Theme.Space.sm).padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.lg)
        .background(cardBackground)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Coach suggestion: \(p.headline). \(p.detail)")
    }

    private func confirmation(_ n: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            header
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 13, weight: .bold))
                Text("Plan updated — nudged your next \(n) session\(n == 1 ? "" : "s") up about 10%.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
            }
            .foregroundStyle(Theme.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.lg)
        .background(cardBackground)
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "sparkles")
            Text("COACH").tracking(1.5)
        }
        .font(.rounded(Theme.FontSize.label, weight: .semibold))
        .foregroundStyle(Theme.inkTertiary)
    }

    /// Iridescent pill — mirrors the Progress tab's adaptation chip so "apply a plan change" reads the
    /// same everywhere.
    private func chip(_ text: String, icon: String, filled: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold))
            Text(text).font(.rounded(Theme.FontSize.caption, weight: .bold))
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, Theme.Space.md).padding(.vertical, 8)
        .background {
            Capsule().fill(IridescentMaterial()).opacity(filled ? 0.45 : 0.3)
            Capsule().stroke(Theme.hairline)
        }
    }

    @ViewBuilder private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
        RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
    }

    private func apply(_ p: PlanCoaching.Proposal) {
        let changed = PlanCoaching.apply(p.rec, to: plan, in: context)
        if changed > 0 { services.analytics.log(.planSessionAdapted) }
        Haptics.success()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { outcome = max(0, changed) }
    }
}
