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

    /// Caches the Kalman-filtered route so re-rendering the card (format/size passes, style swipes
    /// that land back here) doesn't re-run the causal filter — it's deterministic per `GPSDetail`.
    /// Computed synchronously on first read, so the off-screen export renders the route exactly.
    @State private var routeCache = RouteCache()

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
        if workout.type.isStrengthStyle, let s = workout.strength {
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
        } else {
            // Timed activity — duration is the hero.
            VStack(alignment: .leading, spacing: size.height * 0.01) {
                bigStat(Formatters.duration(s: workout.durationS), "elapsed")
                accentBar
                Text(workout.type.title)
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
        let coords = routeCache.coordinates(for: gps, type: workout.type)
        if coords.count > 1 {
            // 800, not the 120 default: this is a full-size card, not a list thumbnail, and a
            // multi-lap track needs the budget to draw every lap (owner report 2026-08-29).
            RouteSilhouette(coords: coords, maxPoints: 800)
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
        if workout.type.isCycling {
            let speed = workout.durationS > 0 ? gps.distanceM / workout.durationS : 0
            return "\(time) · \(Formatters.speed(ms: speed, unit: distanceUnit))"
        }
        let pace = gps.distanceM > 0 ? workout.durationS / (gps.distanceM / 1000) : 0
        return "\(time) · \(Formatters.pace(secPerKm: pace, unit: distanceUnit))"
    }
}

/// Memoizes one `GPSDetail`'s Kalman-filtered route so repeated card renders reuse it instead of
/// re-running the (deterministic, causal) filter on every body/size pass.
@MainActor
private final class RouteCache {
    private var key: ObjectIdentifier?
    private var coords: [CLLocationCoordinate2D] = []

    func coordinates(for gps: GPSDetail, type: WorkoutType) -> [CLLocationCoordinate2D] {
        let k = ObjectIdentifier(gps)
        if key != k {
            key = k
            coords = gps.routeCoordinates(type: type)
        }
        return coords
    }
}

/// A route traced into the card bounds (lat/lon normalized, latitude inverted for screen space).
/// Downsamples to keep paths cheap for list thumbnails (PRD §13.1 jank-free at scale).
struct RouteSilhouette: Shape {
    let coords: [CLLocationCoordinate2D]
    var maxPoints: Int = 120

    func path(in rect: CGRect) -> Path {
        let pts = Self.points(coords, in: rect, maxPoints: maxPoints)
        guard pts.count > 1 else { return Path() }
        var path = Path()
        path.move(to: pts[0])
        pts.dropFirst().forEach { path.addLine(to: $0) }
        return path
    }

    /// The projected screen points — shared with `RouteEndpointMarks` so a start/finish mark lands
    /// exactly on the drawn line rather than on a second, subtly different projection.
    static func points(_ coords: [CLLocationCoordinate2D], in rect: CGRect,
                       maxPoints: Int = 120) -> [CGPoint] {
        let coords = downsample(coords, to: maxPoints)
        guard coords.count > 1 else { return [] }
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!, minLon = lons.min()!, maxLon = lons.max()!
        // A degree of longitude spans cos(latitude) of a degree of latitude on the ground —
        // without the correction every silhouette renders stretched wide (~16% at Austin's
        // latitude): a square loop drew as a rectangle. Same equirectangular projection
        // RouteSmoothing uses.
        let cosLat = max(cos((minLat + maxLat) / 2 * .pi / 180), 0.01)
        let spanLon = max((maxLon - minLon) * cosLat, 1e-6), spanLat = max(maxLat - minLat, 1e-6)
        let scale = min(rect.width / spanLon, rect.height / spanLat) * 0.92
        let midLon = (minLon + maxLon) / 2, midLat = (minLat + maxLat) / 2
        return coords.map { c in
            CGPoint(x: rect.midX + (c.longitude - midLon) * cosLat * scale,
                    y: rect.midY - (c.latitude - midLat) * scale)
        }
    }

    /// Reduce to at most `max` points while keeping the SHAPE — Ramer–Douglas–Peucker, not an
    /// every-Nth stride.
    ///
    /// **Why this is not a stride any more (owner report 2026-08-29).** A track session — twenty
    /// laps of a 400 m oval, a few thousand fixes — came out as a solid blob with the inside of
    /// the track coloured in. Nothing was filling the path: every call site strokes it. The stride
    /// was the bug. Twenty laps sampled down to 120 points is ~6 points per lap, and each lap's
    /// six land at a different phase of the oval, so the laps drew as twenty different jagged
    /// hexagons crossing each other — a scribble dense enough to read as fill.
    ///
    /// RDP drops only points that do not move the line: the straights collapse to their endpoints
    /// and every bend survives, so a lap stays a lap at any budget. Epsilon starts fine and
    /// doubles until the budget is met, so a simple out-and-back keeps its handful of points and a
    /// track keeps its ovals.
    static func downsample(_ coords: [CLLocationCoordinate2D], to max: Int) -> [CLLocationCoordinate2D] {
        guard coords.count > max, max > 2 else { return coords }
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let diag = hypot((lats.max()! - lats.min()!), (lons.max()! - lons.min()!))
        guard diag > 0 else { return Array(coords.prefix(max)) }
        var epsilon = diag / 4_000            // ~a couple of metres on a typical route
        for _ in 0..<24 {
            let simplified = rdp(coords, epsilon: epsilon)
            if simplified.count <= max { return simplified }
            epsilon *= 2
        }
        // Pathological input only (a route that is all corner) — the old stride as the backstop.
        let stride = Double(coords.count - 1) / Double(max - 1)
        return (0..<max).map { coords[Int((Double($0) * stride).rounded())] }
    }

    /// Ramer–Douglas–Peucker in lat/lon space. Iterative (a recursive one blows the stack on the
    /// ~40k-point polyline an ultra produces).
    static func rdp(_ pts: [CLLocationCoordinate2D], epsilon: Double) -> [CLLocationCoordinate2D] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true; keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            var worst = 0.0, index = first
            let a = pts[first], b = pts[last]
            let dx = b.longitude - a.longitude, dy = b.latitude - a.latitude
            let den = hypot(dx, dy)
            for i in (first + 1)..<last {
                let p = pts[i]
                // Perpendicular distance to the segment; a degenerate segment (start == end,
                // which a closed lap produces) falls back to distance from the point itself.
                let d = den < 1e-12
                    ? hypot(p.longitude - a.longitude, p.latitude - a.latitude)
                    : abs(dy * (p.longitude - a.longitude) - dx * (p.latitude - a.latitude)) / den
                if d > worst { worst = d; index = i }
            }
            if worst > epsilon {
                keep[index] = true
                stack.append((first, index)); stack.append((index, last))
            }
        }
        return zip(pts, keep).compactMap { $1 ? $0 : nil }
    }
}
