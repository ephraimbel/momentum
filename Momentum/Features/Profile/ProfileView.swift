import SwiftUI
import SwiftData

/// You / Profile (PRD §4.8, §7.10): streak (shame-free), consistency heatmap, lifetime totals,
/// and PR shelves — framed as you vs your past self. Advanced analytics + goal ring land in
/// Phase 2/4; here we surface what history already supports.
struct ProfileView: View {
    @Query private var workouts: [Workout]
    private var weightUnit: WeightUnit { .default() }
    private var distanceUnit: DistanceUnit { .auto }

    private var stats: ProfileStats { ProfileStats(workouts: workouts) }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.xl) {
                streakHero(stats)
                heatmap(stats)
                totals(stats)
                if !stats.strengthPRs.isEmpty { strengthPRShelf(stats) }
                cardioPRShelf(stats)
            }
            .padding(Theme.Space.md)
        }
        .background(Theme.background)
        .navigationTitle("You")
    }

    private func streakHero(_ stats: ProfileStats) -> some View {
        HStack(spacing: Theme.Space.lg) {
            ZStack {
                IridescentView(intensity: stats.currentStreak > 0 ? 0.7 : 0.0)
                    .frame(width: 84, height: 84).clipShape(Circle())
                Image(systemName: "flame.fill").font(.system(size: 34)).foregroundStyle(Theme.ink)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(stats.currentStreak)")
                    .font(.system(size: Theme.FontSize.heroNumber, weight: .bold, design: .rounded))
                    .monospacedDigit().foregroundStyle(Theme.ink)
                Text("day streak").font(.system(size: Theme.FontSize.body)).foregroundStyle(Theme.inkSecondary)
                Text("Longest: \(stats.longestStreak)").font(.system(size: Theme.FontSize.caption)).foregroundStyle(Theme.inkTertiary)
            }
            Spacer()
        }
        .padding(Theme.Space.lg)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
    }

    private func heatmap(_ stats: ProfileStats) -> some View {
        let today = StreakCalculator.localDay(Date())
        let weeks = 16
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionTitle("Consistency")
            HStack(spacing: 3) {
                ForEach(0..<weeks, id: \.self) { col in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { row in
                            let day = today - ((weeks - 1 - col) * 7) - (6 - row)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(stats.countingDays.contains(day) ? Theme.ink : Theme.hairline)
                                .frame(width: 14, height: 14)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func totals(_ stats: ProfileStats) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionTitle("Lifetime")
            HStack(spacing: Theme.Space.xl) {
                stat("\(stats.totalWorkouts)", "Workouts")
                stat(Formatters.distance(meters: stats.totalDistanceM, unit: distanceUnit), "Distance")
                stat(Formatters.duration(s: stats.totalDurationS), "Time")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.lg)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
    }

    private func strengthPRShelf(_ stats: ProfileStats) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionTitle("Strength PRs (est. 1RM)")
            ForEach(stats.strengthPRs, id: \.name) { pr in
                HStack {
                    Text(pr.name).foregroundStyle(Theme.ink)
                    Spacer()
                    Text(Formatters.weight(kg: pr.e1RMKg, unit: weightUnit))
                        .monospacedDigit().foregroundStyle(Theme.inkSecondary)
                }
                .font(.system(size: Theme.FontSize.body))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func cardioPRShelf(_ stats: ProfileStats) -> some View {
        if stats.longestRunM > 0 {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                sectionTitle("Cardio PRs")
                HStack {
                    Text("Longest run").foregroundStyle(Theme.ink)
                    Spacer()
                    Text(Formatters.distance(meters: stats.longestRunM, unit: distanceUnit))
                        .monospacedDigit().foregroundStyle(Theme.inkSecondary)
                }
                .font(.system(size: Theme.FontSize.body))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: Theme.FontSize.headline, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.ink)
            Text(label.uppercased()).font(.system(size: Theme.FontSize.label)).tracking(1).foregroundStyle(Theme.inkTertiary)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: Theme.FontSize.label, weight: .semibold))
            .tracking(1.2).foregroundStyle(Theme.inkTertiary)
    }
}

#Preview {
    NavigationStack { ProfileView() }
        .modelContainer(PersistenceController.inMemory().container)
}
