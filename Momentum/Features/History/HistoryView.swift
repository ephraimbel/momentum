import SwiftUI
import SwiftData

/// History — a clean, Strava-style feed (PRD §4.8, §7.10). Each workout is a rich card with its
/// route snapshot (cardio) or glyph banner (strength), grouped by week. Tap → workout detail.
struct HistoryView: View {
    @Query private var allWorkouts: [Workout]

    private var weightUnit: WeightUnit { .default() }
    private var distanceUnit: DistanceUnit { .auto }

    private var weeks: [(start: Date, items: [Workout])] {
        let cal = Calendar.current
        let sorted = allWorkouts.sorted { $0.startedAt > $1.startedAt }
        let groups = Dictionary(grouping: sorted) { w in
            cal.dateInterval(of: .weekOfYear, for: w.startedAt)?.start ?? cal.startOfDay(for: w.startedAt)
        }
        return groups.map { ($0.key, $0.value) }.sorted { $0.start > $1.start }
    }

    var body: some View {
        Group {
            if allWorkouts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.xl) {
                        Text("History")
                            .font(.display(32, weight: .black))
                            .foregroundStyle(Theme.ink)
                            .padding(.top, Theme.Space.sm)
                        ForEach(weeks, id: \.start) { week in
                            VStack(alignment: .leading, spacing: Theme.Space.md) {
                                Text(weekLabel(week.start))
                                    .font(.rounded(Theme.FontSize.label, weight: .bold))
                                    .tracking(1.4).foregroundStyle(Theme.inkTertiary)
                                ForEach(week.items, id: \.persistentModelID) { workout in
                                    NavigationLink {
                                        WorkoutDetailView(workout: workout,
                                                          weightUnit: weightUnit, distanceUnit: distanceUnit)
                                    } label: {
                                        CompletedWorkoutCard(workout: workout,
                                                             weightUnit: weightUnit, distanceUnit: distanceUnit)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(Theme.Space.lg)
                    .padding(.bottom, Theme.Space.xxl)
                }
            }
        }
        .background(Theme.background)
        .navigationBarHidden(true)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.lg) {
            IridescentOrb(size: 72)
            Text("No workouts yet")
                .font(.display(Theme.FontSize.headline, weight: .heavy))
                .foregroundStyle(Theme.ink)
            Text("Your runs, rides, walks, and lifts will live here.")
                .font(.rounded(Theme.FontSize.body, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func weekLabel(_ start: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(start, equalTo: Date(), toGranularity: .weekOfYear) { return "THIS WEEK" }
        if let lastWeek = cal.date(byAdding: .weekOfYear, value: -1, to: Date()),
           cal.isDate(start, equalTo: lastWeek, toGranularity: .weekOfYear) { return "LAST WEEK" }
        return start.formatted(.dateTime.month().day()).uppercased()
    }
}
