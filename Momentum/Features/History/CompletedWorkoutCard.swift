import SwiftUI
import CoreLocation

/// A completed-workout card (PRD §4.6, §7.10) — Strava-style. Cardio shows the route snapshot
/// (or a drawn silhouette until the snapshot exists); strength shows a glyph banner. Stats sit on
/// a clean light row beneath. Used on Today's "done today" and the History feed.
struct CompletedWorkoutCard: View {
    let workout: Workout
    var weightUnit: WeightUnit = .default()
    var distanceUnit: DistanceUnit = .auto

    var body: some View {
        VStack(spacing: 0) {
            banner.frame(height: 150).frame(maxWidth: .infinity).clipped()
            statsRow
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(workout.type.title)")
        .accessibilityValue(statsText)
    }

    // MARK: Banner

    @ViewBuilder
    private var banner: some View {
        if workout.type == .strength {
            ZStack {
                LinearGradient(colors: Theme.iridescent.map { $0.opacity(0.25) },
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "dumbbell.fill")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(Theme.ink.opacity(0.85))
            }
        } else if let data = workout.gps?.mapSnapshotData, let ui = UIImage(data: data) {
            Image(uiImage: ui).resizable().scaledToFill()
        } else {
            ZStack {
                Theme.background
                routeSilhouette
            }
        }
    }

    @ViewBuilder
    private var routeSilhouette: some View {
        let coords = (workout.gps?.samples ?? []).filter(\.accepted).sorted { $0.t < $1.t }
            .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        if coords.count > 1 {
            RouteSilhouette(coords: coords)
                .stroke(Theme.route, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .padding(Theme.Space.lg)
        } else {
            Image(systemName: workout.type.systemImage)
                .font(.system(size: 40)).foregroundStyle(Theme.inkTertiary)
        }
    }

    // MARK: Stats

    private var statsRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.title.isEmpty ? workout.type.title : workout.title)
                    .font(.rounded(Theme.FontSize.headline, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(workout.startedAt.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
            }
            Spacer()
            Text(statsText)
                .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.inkSecondary)
        }
        .padding(Theme.Space.md)
    }

    private var statsText: String {
        if workout.type == .strength, let s = workout.strength {
            let vol = weightUnit == .lb ? s.totalVolumeKg * Formatters.lbPerKg : s.totalVolumeKg
            return "\(Int(vol)) \(weightUnit == .lb ? "lb" : "kg") · \(s.totalSets) sets · \(Formatters.duration(s: workout.durationS))"
        } else if let gps = workout.gps {
            return "\(Formatters.distance(meters: gps.distanceM, unit: distanceUnit)) · \(Formatters.duration(s: workout.durationS))"
        }
        return Formatters.duration(s: workout.durationS)
    }
}
