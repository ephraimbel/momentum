import SwiftUI
import SwiftData

/// History — a clean, Strava-style feed (PRD §4.8, §7.10). Each workout is a rich card with its
/// route snapshot (cardio) or glyph banner (strength), grouped by week. Tap → workout detail.
struct HistoryView: View {
    @Query private var allWorkouts: [Workout]
    @Environment(PaywallController.self) private var paywall

    /// Free tier keeps the most recent weeks; older entries are Pro (PRD §10/§13.10).
    private static let freeWeeks = 2

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
                        HeatmapHistoryCard(workouts: allWorkouts, distanceUnit: distanceUnit)
                        let entitled = paywall.isEntitled(to: .fullHistory)
                        let shown = entitled ? weeks : Array(weeks.prefix(Self.freeWeeks))
                        ForEach(shown, id: \.start) { week in
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
                        let hidden = entitled ? 0 : weeks.dropFirst(Self.freeWeeks).reduce(0) { $0 + $1.items.count }
                        if hidden > 0 { lockedFooter(hidden) }
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

    /// The Pro cap under the free window — taps through to the paywall (PRD §10).
    private func lockedFooter(_ count: Int) -> some View {
        Button { paywall.present(for: .fullHistory) } label: {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: "lock.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(count) earlier workout\(count == 1 ? "" : "s")")
                        .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("Unlock your full history with Pro")
                        .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.inkTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.lg)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(IridescentMaterial(), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func weekLabel(_ start: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(start, equalTo: Date(), toGranularity: .weekOfYear) { return "THIS WEEK" }
        if let lastWeek = cal.date(byAdding: .weekOfYear, value: -1, to: Date()),
           cal.isDate(start, equalTo: lastWeek, toGranularity: .weekOfYear) { return "LAST WEEK" }
        return start.formatted(.dateTime.month().day()).uppercased()
    }
}
