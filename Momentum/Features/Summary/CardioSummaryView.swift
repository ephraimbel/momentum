import SwiftUI
import MapKit
import SwiftData

/// Post-workout summary for a cardio session (PRD §4.3 finish, §4.6). Route map + distance/pace/
/// duration/elevation + per-unit splits + fastest-window PRs. AI read and true-B/W share snapshot
/// land in later phases.
struct CardioSummaryView: View {
    let workoutId: UUID
    var distanceUnit: DistanceUnit = .auto
    var onDone: () -> Void

    @Query private var workouts: [Workout]
    private var workout: Workout? { workouts.first { $0.id == workoutId } }

    private var unitMeters: Double {
        distanceUnit.resolved() == .imperial ? Formatters.metersPerMile : 1000
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let workout, let gps = workout.gps {
                    VStack(spacing: Theme.Space.xl) {
                        routeMap(gps)
                        headline(workout, gps)
                        splitsSection(gps)
                    }
                    .padding(Theme.Space.md)
                } else {
                    ContentUnavailableView("Workout not found", systemImage: "questionmark")
                }
            }
            .background(Theme.background)
            .navigationTitle(workout?.type.title ?? "Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone() }.fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private func routeMap(_ gps: GPSDetail) -> some View {
        let coords = gps.samples.filter(\.accepted).sorted { $0.t < $1.t }
            .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        if coords.count > 1 {
            Map(interactionModes: []) {
                MapPolyline(coordinates: coords)
                    .stroke(Theme.route, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
    }

    private func headline(_ workout: Workout, _ gps: GPSDetail) -> some View {
        VStack(spacing: Theme.Space.lg) {
            HeroMetric(value: Formatters.distance(meters: gps.distanceM, unit: distanceUnit).components(separatedBy: " ").first ?? "0",
                       label: distanceUnit.resolved() == .imperial ? "Miles" : "Kilometers")
            HStack(spacing: Theme.Space.xl) {
                stat(Formatters.duration(s: workout.durationS), "Time")
                stat(paceOrSpeed(gps), workout.type == .ride ? "Avg speed" : "Avg pace")
                stat("\(Int(gps.elevationGainM)) m", "Elevation")
            }
        }
        .padding(.vertical, Theme.Space.md)
    }

    private func paceOrSpeed(_ gps: GPSDetail) -> String {
        if workout?.type == .ride {
            let speed = workout!.durationS > 0 ? gps.distanceM / workout!.durationS : 0
            return Formatters.speed(ms: speed, unit: distanceUnit)
        }
        let pace = gps.distanceM > 0 ? workout!.durationS / (gps.distanceM / 1000) : 0
        return Formatters.pace(secPerKm: pace, unit: distanceUnit)
    }

    private func splitsSection(_ gps: GPSDetail) -> some View {
        let points = samplePoints(gps)
        let splits = CardioMetrics.splits(points, unitMeters: unitMeters)
        let unitLabel = distanceUnit.resolved() == .imperial ? "mi" : "km"
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if !splits.isEmpty {
                Text("Splits").font(.system(size: Theme.FontSize.label, weight: .semibold))
                    .tracking(1.2).foregroundStyle(Theme.inkTertiary)
                ForEach(splits, id: \.index) { split in
                    HStack {
                        Text("\(split.index + 1) \(unitLabel)\(split.isPartial ? " (partial)" : "")")
                            .foregroundStyle(Theme.inkSecondary)
                        Spacer()
                        Text(Formatters.duration(s: split.durationS)).monospacedDigit().foregroundStyle(Theme.ink)
                    }
                    .font(.system(size: Theme.FontSize.body))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: Theme.FontSize.headline, weight: .semibold)).monospacedDigit()
            Text(label.uppercased()).font(.system(size: Theme.FontSize.label)).tracking(1).foregroundStyle(Theme.inkTertiary)
        }
    }

    private func samplePoints(_ gps: GPSDetail) -> [CardioMetrics.SamplePoint] {
        let accepted = gps.samples.filter(\.accepted).sorted { $0.t < $1.t }
        guard let first = accepted.first else { return [] }
        var pts: [CardioMetrics.SamplePoint] = []
        var cumulative = 0.0
        var prev: LocationSample?
        for s in accepted {
            if let p = prev {
                cumulative += Geo.distance(lat1: p.lat, lon1: p.lon, lat2: s.lat, lon2: s.lon)
            }
            pts.append(.init(t: s.t.timeIntervalSince(first.t), cumulativeM: cumulative))
            prev = s
        }
        return pts
    }
}
