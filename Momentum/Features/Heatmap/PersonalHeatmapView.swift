import SwiftUI
import SwiftData
import MapKit

/// "Your map" — every place the athlete has been active, drawn as an iridescent density heatmap from
/// their *own* routes (the private mirror, north-star). Switchable base layers; lights up as they log
/// more. No network, no other users — purely on-device SwiftData.
struct PersonalHeatmapView: View {
    var distanceUnit: DistanceUnit = .auto
    var onClose: () -> Void = {}

    @Query private var workouts: [Workout]

    @State private var cells: [HeatCell] = []
    @State private var region: MKCoordinateRegion?
    @State private var style: MapStyleOption = .standard
    @State private var totalMeters = 0.0
    @State private var activityCount = 0
    @State private var loaded = false

    var body: some View {
        ZStack(alignment: .bottom) {
            if cells.isEmpty {
                Color.clear.overlay { if loaded { emptyState } }
            } else {
                HeatmapMapView(cells: cells, style: style, region: region).ignoresSafeArea()
            }
            topBar
            if !cells.isEmpty { statsBar }
        }
        .background(Theme.background)
        .task { await build() }
    }

    /// Flatten accepted samples on the main actor (SwiftData models aren't Sendable), then bin off it.
    private func build() async {
        let gps = workouts.compactMap(\.gps)
        var coords: [GeoPoint] = []
        coords.reserveCapacity(gps.reduce(0) { $0 + $1.samples.count })
        var meters = 0.0
        for detail in gps {
            meters += detail.distanceM
            for s in detail.samples where s.accepted { coords.append(GeoPoint(lat: s.lat, lon: s.lon)) }
        }
        let count = gps.count
        let binned = await Task.detached { HeatmapBinning.bin(coords) }.value

        cells = binned
        region = Self.region(for: coords)
        totalMeters = meters
        activityCount = count
        loaded = true
    }

    // MARK: Chrome

    private var topBar: some View {
        VStack {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                        .frame(width: 38, height: 38)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().stroke(Theme.hairline))
                }
                Spacer()
                if !cells.isEmpty { MapLayersButton(style: $style) }
            }
            .padding(Theme.Space.md)
            Spacer()
        }
    }

    private var statsBar: some View {
        HStack {
            stat("\(activityCount)", activityCount == 1 ? "Activity" : "Activities")
            Spacer()
            stat(Formatters.distance(meters: totalMeters, unit: distanceUnit), "Mapped")
        }
        .padding(Theme.Space.lg)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.sheet))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sheet).stroke(Theme.hairline))
        .padding(Theme.Space.md)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.display(22, weight: .heavy)).monospacedDigit().foregroundStyle(Theme.ink)
            Text(label.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1).foregroundStyle(Theme.inkTertiary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.md) {
            ZStack {
                Circle().fill(IridescentMaterial()).frame(width: 72, height: 72).opacity(0.5)
                Image(systemName: "map.fill").font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.ink)
            }
            VStack(spacing: 4) {
                Text("Your map is empty").font(.display(20, weight: .bold)).foregroundStyle(Theme.ink)
                Text("Record a run, ride, or walk — your map lights up everywhere you've been.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Theme.Space.xl)
    }

    // MARK: Geometry

    private static func region(for coords: [GeoPoint]) -> MKCoordinateRegion? {
        guard !coords.isEmpty else { return nil }
        let lats = coords.map(\.lat), lons = coords.map(\.lon)
        let minLat = lats.min()!, maxLat = lats.max()!, minLon = lons.min()!, maxLon = lons.max()!
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.01, (maxLat - minLat) * 1.3),
                                    longitudeDelta: max(0.01, (maxLon - minLon) * 1.3))
        return MKCoordinateRegion(center: center, span: span)
    }
}
