import SwiftUI
import SwiftData

/// The coach's post-session pace review (running-excellence R4) — shown on the summary/history
/// detail of a guided run. Renders the deterministic `PaceInsights` verdict (On point / Ahead /
/// Review / Variable), the per-rep achieved-vs-target table, and — only for "Review" — the
/// consent-gated "ease future paces" action (`PlanCoaching.easeQualityPaces`). Hitting the
/// prescription is progress, so the On-point verdict chip earns iridescence; every other state is
/// monochrome. No-shame: there is no red, and "Review" reads as tuning, not failure.
struct PaceInsightsCard: View {
    let workout: Workout
    var distanceUnit: DistanceUnit = .auto

    @Environment(\.modelContext) private var context
    @Environment(Services.self) private var services
    @Query private var profiles: [UserProfile]

    /// nil = undecided, `>= 0` = eased (n sessions), `-1` = declined. Latches like PlanProposalCard
    /// so the offer resolves once and never re-asks within this render of the summary.
    @State private var easedOutcome: Int?

    private var plan: TrainingPlan? { profiles.first?.plan }

    private var analysis: PaceInsights.Analysis? {
        guard let data = workout.gps?.stepResultsData,
              let results = try? JSONDecoder().decode([StepResult].self, from: data) else { return nil }
        return PaceInsights.analyze(results, unit: distanceUnit)
    }

    var body: some View {
        if let a = analysis {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack {
                    HStack(spacing: Theme.Space.xs) {
                        Image(systemName: "gauge.with.needle")
                        Text("PACE INSIGHTS").tracking(1.5)
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
                repTable(a.reps)
                if a.suggestsEasing { easeOffer }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.md)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Pace insights: \(a.verdict.rawValue). \(a.headline). \(a.detail)")
        }
    }

    /// The verdict pill. On point = you ran the prescription = earned iridescence; the rest stay ink.
    private func verdictChip(_ v: PaceInsights.Verdict) -> some View {
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

    // MARK: Rep table

    private func repTable(_ reps: [PaceInsights.RepLine]) -> some View {
        VStack(spacing: 6) {
            ForEach(reps) { rep in
                HStack {
                    Text(rep.label)
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(width: 72, alignment: .leading)
                    Text(pace(rep.targetSPerKm))
                        .font(.rounded(Theme.FontSize.caption, weight: .medium)).monospacedDigit()
                        .foregroundStyle(Theme.inkTertiary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                    Text(pace(rep.achievedSPerKm))
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Text(delta(rep.deltaSPerKm))
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Theme.inkSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(rep.label): target \(pace(rep.targetSPerKm)), ran \(pace(rep.achievedSPerKm))")
            }
        }
        .padding(.top, 2)
    }

    // MARK: Ease-paces offer (consent-gated — the one direction that never auto-applies)

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

    // MARK: Formatting

    private func pace(_ sPerKm: Double) -> String {
        Formatters.pace(secPerKm: sPerKm, unit: distanceUnit)
    }

    /// Signed delta in seconds per display unit: "−4s" (faster) / "+7s" (slower) / "±0s".
    private func delta(_ dSPerKm: Double) -> String {
        let perUnit = distanceUnit.resolved() == .imperial ? Formatters.metersPerMile / 1000 : 1
        let s = Int((dSPerKm * perUnit).rounded())
        if s == 0 { return "±0s" }
        return s < 0 ? "−\(abs(s))s" : "+\(s)s"
    }
}
