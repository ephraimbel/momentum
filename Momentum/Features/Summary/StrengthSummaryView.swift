import SwiftUI
import SwiftData

/// Post-workout summary screen for strength (PRD §4.4 finish, §4.6): a presented cover with Done.
/// Renders `StrengthSummaryContent`, which is also reused by `WorkoutDetailView`.
struct StrengthSummaryView: View {
    let workoutId: UUID
    var weightUnit: WeightUnit = .default()
    var onDone: () -> Void

    @Query private var workouts: [Workout]
    @State private var celebrating = true
    private var workout: Workout? { workouts.first { $0.id == workoutId } }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let workout {
                    StrengthSummaryContent(workout: workout, weightUnit: weightUnit, celebratePRs: true)
                        .padding(Theme.Space.md)
                } else {
                    ContentUnavailableView("Workout not found", systemImage: "questionmark")
                }
            }
            .background(Theme.background)
            .navigationTitle("Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone() }.fontWeight(.semibold)
                }
                if let workout {
                    ToolbarItem(placement: .topBarLeading) {
                        ShareButton(workout: workout, weightUnit: weightUnit)
                    }
                }
            }
        }
        .overlay {
            if celebrating {
                CompletionCelebration(title: "Workout complete") { celebrating = false }
            }
        }
    }
}

/// Reusable strength summary body (PRD §4.4): headline volume/sets/duration, PR badges,
/// working-sets-by-muscle, per-exercise breakdown. No navigation chrome of its own.
struct StrengthSummaryContent: View {
    let workout: Workout
    var weightUnit: WeightUnit = .default()
    var celebratePRs: Bool = false

    @Environment(\.modelContext) private var context
    @State private var prs: [StrengthPRs.Hit] = []

    var body: some View {
        if let session = workout.strength {
            VStack(spacing: Theme.Space.xl) {
                headline(workout, session).reveal(0)
                AIReadCard(workout: workout, weightUnit: weightUnit).reveal(0.12)
                if !prs.isEmpty { prSection.reveal(0.22) }
                muscleSection(session).reveal(0.30)
                exercisesSection(session).reveal(0.38)
            }
            .task {
                prs = StrengthPRs.detect(for: workout, weightUnit: weightUnit, in: context)
            }
        } else {
            Text("No strength data").foregroundStyle(Theme.inkTertiary)
        }
    }

    private func headline(_ workout: Workout, _ session: StrengthSession) -> some View {
        let volume = weightUnit == .lb ? session.totalVolumeKg * Formatters.lbPerKg : session.totalVolumeKg
        return VStack(spacing: Theme.Space.lg) {
            CountUpHero(target: volume,
                        format: { "\(Int($0.rounded()))" },
                        label: "Volume (\(weightUnit == .lb ? "lb" : "kg"))")
            HStack(spacing: Theme.Space.xl) {
                stat("\(session.totalSets)", "Sets")
                stat(Formatters.duration(s: workout.durationS), "Duration")
                stat("\(session.exercises.count)", "Exercises")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.lg)
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
        let byMuscle = StrengthMath.weeklySetsByMuscle(entries)
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionTitle("Working sets by muscle")
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
                let working = row.sets.filter { $0.isComplete && $0.type == .working }
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
