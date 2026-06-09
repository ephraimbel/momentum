import SwiftUI
import SwiftData
import CoreLocation

/// History — one mixed monochrome timeline grouped by week (PRD §4.8, §7.10), with the right
/// thumbnail per type (route silhouette vs strength glyph). Tap → `WorkoutDetailView`.
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
                VStack(spacing: Theme.Space.lg) {
                    MomentumMark(iridescent: false).frame(width: 56, height: 56).opacity(0.45)
                    Text("No workouts yet")
                        .font(.system(size: Theme.FontSize.headline, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text("Your runs, rides, walks, and lifts will live here.")
                        .font(.system(size: Theme.FontSize.body))
                        .foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(weeks, id: \.start) { week in
                        Section(weekLabel(week.start)) {
                            ForEach(week.items, id: \.persistentModelID) { workout in
                                NavigationLink {
                                    WorkoutDetailView(workout: workout,
                                                      weightUnit: weightUnit, distanceUnit: distanceUnit)
                                } label: {
                                    HistoryRow(workout: workout, weightUnit: weightUnit, distanceUnit: distanceUnit)
                                }
                                .listRowBackground(Theme.surface)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.background)
        .navigationTitle("History")
    }

    private func weekLabel(_ start: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(start, equalTo: Date(), toGranularity: .weekOfYear) { return "This week" }
        if let lastWeek = cal.date(byAdding: .weekOfYear, value: -1, to: Date()),
           cal.isDate(start, equalTo: lastWeek, toGranularity: .weekOfYear) { return "Last week" }
        return start.formatted(.dateTime.month().day())
    }
}

private struct HistoryRow: View {
    let workout: Workout
    let weightUnit: WeightUnit
    let distanceUnit: DistanceUnit

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            thumbnail
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(Theme.background))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.type.title)
                    .font(.system(size: Theme.FontSize.body, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(stats)
                    .font(.system(size: Theme.FontSize.caption))
                    .foregroundStyle(Theme.inkTertiary)
            }
            Spacer()
            Text(workout.startedAt.formatted(.dateTime.weekday(.abbreviated)))
                .font(.system(size: Theme.FontSize.caption))
                .foregroundStyle(Theme.inkTertiary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(workout.type.title), \(workout.startedAt.formatted(.dateTime.weekday(.wide)))")
        .accessibilityValue(stats)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if workout.type == .strength {
            Image(systemName: "dumbbell.fill")
                .font(.system(size: 20))
                .foregroundStyle(Theme.inkSecondary)
        } else {
            let coords = (workout.gps?.samples ?? []).filter(\.accepted).sorted { $0.t < $1.t }
                .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            if coords.count > 1 {
                RouteSilhouette(coords: coords)
                    .stroke(Theme.route, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .padding(8)
            } else {
                Image(systemName: workout.type.systemImage)
                    .font(.system(size: 20)).foregroundStyle(Theme.inkSecondary)
            }
        }
    }

    private var stats: String {
        if workout.type == .strength, let s = workout.strength {
            let vol = weightUnit == .lb ? s.totalVolumeKg * Formatters.lbPerKg : s.totalVolumeKg
            return "\(Int(vol)) \(weightUnit == .lb ? "lb" : "kg") · \(s.totalSets) sets · \(Formatters.duration(s: workout.durationS))"
        } else if let gps = workout.gps {
            return "\(Formatters.distance(meters: gps.distanceM, unit: distanceUnit)) · \(Formatters.duration(s: workout.durationS))"
        }
        return Formatters.duration(s: workout.durationS)
    }
}
