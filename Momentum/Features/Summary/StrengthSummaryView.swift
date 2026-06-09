import SwiftUI
import SwiftData

/// Post-workout summary for a strength session (PRD §4.4 finish, §4.6). Headline volume/sets/
/// duration, PR badges (iridescent sweep), per-muscle working sets, per-exercise breakdown.
/// AI read is added in Phase 2; muscle *map* diagram in the analytics pass.
struct StrengthSummaryView: View {
    let workoutId: UUID
    var weightUnit: WeightUnit = .default()
    var onDone: () -> Void

    @Environment(\.modelContext) private var context
    @Query private var workouts: [Workout]

    @State private var prs: [StrengthPRs.Hit] = []

    private var workout: Workout? { workouts.first { $0.id == workoutId } }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let workout, let session = workout.strength {
                    VStack(spacing: Theme.Space.xl) {
                        headline(workout, session)
                        if !prs.isEmpty { prSection }
                        muscleSection(session)
                        exercisesSection(session)
                    }
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
            }
            .task {
                if let workout { prs = StrengthPRs.detect(for: workout, weightUnit: weightUnit, in: context) }
            }
        }
    }

    private func headline(_ workout: Workout, _ session: StrengthSession) -> some View {
        let volume = weightUnit == .lb ? session.totalVolumeKg * Formatters.lbPerKg : session.totalVolumeKg
        return VStack(spacing: Theme.Space.lg) {
            HeroMetric(value: "\(Int(volume))", label: "Volume (\(weightUnit == .lb ? "lb" : "kg"))")
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
            Text(value).font(.system(size: Theme.FontSize.headline, weight: .semibold)).monospacedDigit()
            Text(label.uppercased()).font(.system(size: Theme.FontSize.label)).tracking(1).foregroundStyle(Theme.inkTertiary)
        }
    }

    private var prSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionTitle("Personal records")
            ForEach(prs) { hit in
                PRBadge(text: "\(hit.exerciseName) · \(hit.label) \(hit.detail)", celebrate: true)
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
                .font(.system(size: Theme.FontSize.body))
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
                        .font(.system(size: Theme.FontSize.body, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(summary(working))
                        .font(.system(size: Theme.FontSize.caption))
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
        let parts = sets.map { s -> String in
            let w = s.weightKg.map { Formatters.weight(kg: $0, unit: weightUnit) } ?? "—"
            return "\(w) × \(s.reps ?? 0)"
        }
        return parts.joined(separator: "  ·  ")
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: Theme.FontSize.label, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(Theme.inkTertiary)
    }
}
