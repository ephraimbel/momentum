import SwiftUI
import SwiftData

/// The coach's verdict on a guided run's pacing (running-excellence R4), shown right under the
/// per-rep breakdown: On point / Ahead / Review / Variable from `SessionPaceReview`, plus — only for
/// "Review" — the consent-gated "ease future paces" action (`PlanCoaching.easeQualityPaces`).
/// Hitting the prescription is progress, so the On-point chip earns iridescence; every other state
/// stays monochrome. No-shame: there is no red, and "Review" reads as tuning, not failure.
struct SessionPaceReviewCard: View {
    let workout: Workout
    var distanceUnit: DistanceUnit = .auto

    @Environment(\.modelContext) private var context
    @Environment(Services.self) private var services
    @Query private var profiles: [UserProfile]

    /// nil = undecided, `>= 0` = eased (n sessions), `-1` = declined. Latches like PlanProposalCard
    /// so the offer resolves once and never re-asks within this render of the summary.
    @State private var easedOutcome: Int?

    private var plan: TrainingPlan? { profiles.first?.plan }

    private var analysis: SessionPaceReview.Analysis? {
        guard let reps = workout.gps?.structuredReps, !reps.isEmpty else { return nil }
        return SessionPaceReview.analyze(reps, unit: distanceUnit)
    }

    var body: some View {
        if let a = analysis {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack {
                    HStack(spacing: Theme.Space.xs) {
                        Image(systemName: "gauge.with.needle")
                        Text("PACE REVIEW").tracking(1.5)
                    }
                    .font(.rounded(Theme.FontSize.label, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
                    Spacer()
                    verdictChip(a.verdict)
                }
                Text(a.headline)
                    .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(a.detail)
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if a.suggestsEasing { easeOffer }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.md)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Pace review: \(a.verdict.rawValue). \(a.headline). \(a.detail)")
        }
    }

    /// The verdict pill. On point = you ran the prescription = earned iridescence; the rest stay ink.
    private func verdictChip(_ v: SessionPaceReview.Verdict) -> some View {
        Text(v.rawValue.uppercased())
            .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, Theme.Space.sm).padding(.vertical, 4)
            .background {
                if v == .onPoint {
                    Capsule().fill(IridescentMaterial()).opacity(0.45)
                }
                Capsule().stroke(Theme.hairline)
            }
    }

    // MARK: Ease-paces offer (consent-gated — slowing targets never happens without a tap)

    @ViewBuilder private var easeOffer: some View {
        if let n = easedOutcome, n >= 0 {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 13, weight: .bold))
                Text("Done — eased the paces on your next \(n) session\(n == 1 ? "" : "s").")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
            }
            .foregroundStyle(Theme.inkSecondary)
            .padding(.top, 2)
        } else if easedOutcome == nil, plan != nil {
            HStack(spacing: Theme.Space.sm) {
                Button { ease() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars").font(.system(size: 11, weight: .bold))
                        Text("Ease future paces").font(.rounded(Theme.FontSize.caption, weight: .bold))
                    }
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, Theme.Space.md).padding(.vertical, 8)
                    .background {
                        Capsule().fill(IridescentMaterial()).opacity(0.45)
                        Capsule().stroke(Theme.hairline)
                    }
                }
                .buttonStyle(.plain)
                Button { withAnimation(Motion.standard) { easedOutcome = -1 } } label: {
                    Text("Keep them")
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                        .padding(.horizontal, Theme.Space.sm).padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
    }

    private func ease() {
        let changed = PlanCoaching.easeQualityPaces(plan, in: context)
        if changed > 0 { services.analytics.log(.planSessionAdapted) }
        Haptics.success()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { easedOutcome = changed }
    }
}
