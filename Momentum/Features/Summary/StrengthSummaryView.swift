import SwiftUI
import SwiftData

/// Reusable strength summary body (PRD §4.4): headline volume/sets/duration, PR badges,
/// working-sets-by-muscle, per-exercise breakdown. No navigation chrome of its own.
struct StrengthSummaryContent: View {
    let workout: Workout
    var weightUnit: WeightUnit = .default()
    var celebratePRs: Bool = false
    /// Show the user's title/description header (off in the save editor, which has editable fields).
    var showsHeader: Bool = true
    var canEditPhoto: Bool = false
    /// Added to every reveal below, so the cascade waits for the celebration beat playing over it.
    /// See `CardioSummaryContent.revealDelay`. History passes 0 and reveals immediately.
    var revealDelay: Double = 0

    @Environment(\.modelContext) private var context
    @State private var prs: [StrengthPRs.Hit] = []

    var body: some View {
        if let session = workout.strength {
            // Reveal-first: lead with the mastery payoff (hero + competence line), promote PRs ABOVE
            // the AI read, then the supporting detail. Naming lives at the bottom of the save flow.
            VStack(spacing: Theme.Space.lg) {
                if showsHeader, !workout.title.isEmpty || !workout.note.isEmpty { titleHeader }
                headline(workout, session).reveal(revealDelay)
                if !prs.isEmpty { prSection.reveal(revealDelay + 0.12) }
                // Always offered — see CardioSummaryView. The title stays honest: a session with no
                // record on it is worth sharing, but it isn't a PR and must not claim to be.
                EarnedShareButton(workout: workout, weightUnit: weightUnit,
                                  title: prs.isEmpty ? "Share this session" : "Share your PR").reveal(revealDelay + 0.18)
                WorkoutPhotoSection(workout: workout, canEdit: canEditPhoto).reveal(revealDelay + 0.22)
                AIReadCard(workout: workout, weightUnit: weightUnit).reveal(revealDelay + 0.24)
                PlanProposalCard().reveal(revealDelay + 0.28)
                muscleSection(session).reveal(revealDelay + 0.32)
                exercisesSection(session).reveal(revealDelay + 0.40)
            }
            .task {
                prs = StrengthPRs.detect(for: workout, weightUnit: weightUnit, in: context)
            }
        } else {
            Text("No strength data").foregroundStyle(Theme.inkTertiary)
        }
    }

    /// One self-relative line that frames the session as progress — drawn from this workout's PRs.
    private var competenceText: String? {
        guard !prs.isEmpty else { return nil }
        if prs.count == 1 { return "\(prs[0].exerciseName) \(prs[0].label) · \(prs[0].detail)" }
        return "\(prs.count) personal records today"
    }

    private func headline(_ workout: Workout, _ session: StrengthSession) -> some View {
        let volume = weightUnit == .lb ? session.totalVolumeKg * Formatters.lbPerKg : session.totalVolumeKg
        return VStack(spacing: Theme.Space.lg) {
            CountUpHero(target: volume,
                        format: { "\(Int($0.rounded()))" },
                        label: "Volume (\(weightUnit == .lb ? "lb" : "kg"))",
                        delay: revealDelay)
            if let competenceText { EarnedLine(text: competenceText) }
            HStack(spacing: Theme.Space.lg) {
                stat("\(session.totalSets)", "Sets")
                stat(Formatters.duration(s: workout.durationS), "Duration")
                stat("\(session.exercises.count)", "Exercises")
                if let kcal = workout.calories, kcal > 0 { stat("\(Int(kcal))", "Calories") }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.lg)
    }

    private var titleHeader: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if !workout.title.isEmpty {
                Text(workout.title).font(.display(26, weight: .black)).foregroundStyle(Theme.ink)
            }
            if !workout.note.isEmpty {
                Text(workout.note).font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.display(20, weight: .heavy)).monospacedDigit().foregroundStyle(Theme.ink)
            Text(label.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1).foregroundStyle(Theme.inkTertiary)
        }
    }

    private var prSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionTitle("Personal records")
            ForEach(prs) { hit in
                PRBadge(text: "\(hit.exerciseName) · \(hit.label) \(hit.detail)", celebrate: celebratePRs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func muscleSection(_ session: StrengthSession) -> some View {
        let entries = session.exercises.map { row in
            (primary: (row.exercise?.primaryMuscles ?? []).compactMap(MuscleGroup.init(rawValue:)),
             secondary: (row.exercise?.secondaryMuscles ?? []).compactMap(MuscleGroup.init(rawValue:)),
             sets: row.sets.filter { $0.isComplete && $0.type == .working }.count)
        }
        let activation = StrengthMath.weeklySetsByMuscle(entries)
        let byMuscle = activation
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
        return VStack(alignment: .leading, spacing: Theme.Space.md) {
            sectionTitle("Muscles worked")
            MuscleMapView(activation: activation)
                .frame(height: 240)
                .frame(maxWidth: .infinity)
            ForEach(byMuscle, id: \.key) { muscle, sets in
                HStack {
                    Text(muscle.rawValue.capitalized).foregroundStyle(Theme.ink)
                    Spacer()
                    Text(sets == sets.rounded() ? "\(Int(sets))" : String(format: "%.1f", sets))
                        .monospacedDigit().foregroundStyle(Theme.inkSecondary)
                }
                .font(.rounded(Theme.FontSize.body, weight: .medium))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func exercisesSection(_ session: StrengthSession) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            sectionTitle("Exercises")
            ForEach(session.exercises.sorted { $0.order < $1.order }, id: \.persistentModelID) { row in
                let working = row.sets.filter { $0.isComplete && $0.type == .working }.sorted { $0.index < $1.index }
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.exercise?.name ?? "Exercise")
                        .font(.rounded(Theme.FontSize.body, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    Text(summary(working))
                        .font(.rounded(Theme.FontSize.caption, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.md)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
            }
        }
    }

    private func summary(_ sets: [SetEntry]) -> String {
        guard !sets.isEmpty else { return "No working sets" }
        return sets.map { s in
            let w = s.weightKg.map { Formatters.weight(kg: $0, unit: weightUnit) } ?? "—"
            return "\(w) × \(s.reps ?? 0)"
        }.joined(separator: "  ·  ")
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.rounded(Theme.FontSize.label, weight: .bold))
            .tracking(1.4)
            .foregroundStyle(Theme.inkTertiary)
    }
}
