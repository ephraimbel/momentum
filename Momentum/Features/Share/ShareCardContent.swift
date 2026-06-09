import SwiftUI
import CoreLocation

/// The composed share card (PRD §4.9, §7.11, §25): pure monochrome with a single iridescent
/// accent and the foil `momentum` wordmark in the corner. Type-aware (route vs volume/PR).
/// Self-contained so `ImageRenderer` can render it off-screen.
struct ShareCardContent: View {
    let workout: Workout
    var weightUnit: WeightUnit = .default()
    var distanceUnit: DistanceUnit = .auto
    let size: CGSize

    private var pad: CGFloat { size.width * 0.08 }

    var body: some View {
        ZStack {
            Color.black
            VStack(alignment: .leading, spacing: size.height * 0.02) {
                header
                Spacer(minLength: 0)
                hero
                Spacer(minLength: 0)
                wordmark
            }
            .padding(pad)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack {
            Image(systemName: workout.type.systemImage)
            Text(workout.type.title.uppercased())
                .tracking(2)
            Spacer()
            Text(workout.startedAt.formatted(date: .abbreviated, time: .omitted).uppercased())
                .tracking(1)
        }
        .font(.rounded(size.width * 0.035, weight: .semibold))
        .foregroundStyle(.white.opacity(0.7))
    }

    @ViewBuilder
    private var hero: some View {
        if workout.type == .strength, let s = workout.strength {
            let volume = weightUnit == .lb ? s.totalVolumeKg * Formatters.lbPerKg : s.totalVolumeKg
            VStack(alignment: .leading, spacing: size.height * 0.01) {
                bigStat("\(Int(volume))", weightUnit == .lb ? "lb volume" : "kg volume")
                accentBar
                Text("\(s.totalSets) sets · \(s.exercises.count) exercises")
                    .font(.rounded(size.width * 0.045, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
        } else if let gps = workout.gps {
            VStack(alignment: .leading, spacing: size.height * 0.015) {
                routeSilhouette(gps)
                bigStat(distanceString(gps), distanceUnit.resolved() == .imperial ? "miles" : "km")
                accentBar
                Text(secondary(gps))
                    .font(.rounded(size.width * 0.045, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private func bigStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.display(size.width * 0.20, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(label.uppercased())
                .font(.rounded(size.width * 0.04, weight: .semibold))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    /// The single earned iridescent accent.
    private var accentBar: some View {
        IridescentView(intensity: 0.9, isStatic: true)
            .frame(width: size.width * 0.45, height: size.height * 0.012)
            .clipShape(Capsule())
            .padding(.vertical, size.height * 0.01)
    }

    @ViewBuilder
    private func routeSilhouette(_ gps: GPSDetail) -> some View {
        let coords = gps.samples.filter(\.accepted).sorted { $0.t < $1.t }
            .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        if coords.count > 1 {
            RouteSilhouette(coords: coords)
                .stroke(.white, style: StrokeStyle(lineWidth: size.width * 0.012, lineCap: .round, lineJoin: .round))
                .frame(height: size.height * 0.28)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var wordmark: some View {
        Text("momentum")
            .font(.display(size.width * 0.05, weight: .bold))
            .foregroundStyle(LinearGradient(colors: Theme.iridescent, startPoint: .leading, endPoint: .trailing))
            .opacity(0.85)
    }

    private func distanceString(_ gps: GPSDetail) -> String {
        Formatters.distance(meters: gps.distanceM, unit: distanceUnit)
            .components(separatedBy: " ").first ?? "0"
    }

    private func secondary(_ gps: GPSDetail) -> String {
        let time = Formatters.duration(s: workout.durationS)
        if workout.type == .ride {
            let speed = workout.durationS > 0 ? gps.distanceM / workout.durationS : 0
            return "\(time) · \(Formatters.speed(ms: speed, unit: distanceUnit))"
        }
        let pace = gps.distanceM > 0 ? workout.durationS / (gps.distanceM / 1000) : 0
        return "\(time) · \(Formatters.pace(secPerKm: pace, unit: distanceUnit))"
    }
}

/// A route traced into the card bounds (lat/lon normalized, latitude inverted for screen space).
/// Downsamples to keep paths cheap for list thumbnails (PRD §13.1 jank-free at scale).
struct RouteSilhouette: Shape {
    let coords: [CLLocationCoordinate2D]
    var maxPoints: Int = 120

    func path(in rect: CGRect) -> Path {
        let coords = Self.downsample(self.coords, to: maxPoints)
        guard coords.count > 1 else { return Path() }
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!, minLon = lons.min()!, maxLon = lons.max()!
        let spanLon = max(maxLon - minLon, 1e-6), spanLat = max(maxLat - minLat, 1e-6)
        let scale = min(rect.width / spanLon, rect.height / spanLat) * 0.92
        let midLon = (minLon + maxLon) / 2, midLat = (minLat + maxLat) / 2
        var path = Path()
        for (i, c) in coords.enumerated() {
            let p = CGPoint(x: rect.midX + (c.longitude - midLon) * scale,
                            y: rect.midY - (c.latitude - midLat) * scale)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    /// Keep endpoints; evenly sample the middle down to `max` points.
    static func downsample(_ coords: [CLLocationCoordinate2D], to max: Int) -> [CLLocationCoordinate2D] {
        guard coords.count > max, max > 2 else { return coords }
        let stride = Double(coords.count - 1) / Double(max - 1)
        return (0..<max).map { coords[Int((Double($0) * stride).rounded())] }
    }
}
