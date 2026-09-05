import SwiftUI
import SwiftData
import CoreLocation

/// "Your map" — every place the athlete has been active, drawn as an iridescent density heatmap from
/// their *own* routes (the private mirror, north-star). Switchable base layers; lights up as they log
/// more. No network, no other users — purely on-device SwiftData.
struct PersonalHeatmapView: View {
    var distanceUnit: DistanceUnit = .auto
    /// Nil when shown as a tab (no close affordance); set when presented as a sheet/cover.
    var onClose: (() -> Void)? = nil

    @Query private var workouts: [Workout]

    @State private var cells: [HeatCell] = []
    @AppStorage(MapStyleOption.storageKey) private var style: MapStyleOption = .realistic
    /// The card on History previews THIS view, so both must resolve the same basemap.
    @Environment(\.colorScheme) private var colorScheme
    @State private var totalMeters = 0.0
    @State private var activityCount = 0
    @State private var loaded = false

    var body: some View {
        ZStack(alignment: .bottom) {
            if cells.isEmpty {
                Color.clear.overlay { if loaded { emptyState } }
            } else {
                HeatmapMapView(cells: cells, style: style.renderedStyle(for: colorScheme)).ignoresSafeArea()
            }
            topBar
            if !cells.isEmpty { statsBar }
        }
        .background(Theme.background)
        .navigationBarHidden(true)
        .task { await build() }
    }

    private func build() async {
        let r = await HeatmapSource.build(from: workouts)
        cells = r.cells
        totalMeters = r.totalMeters
        activityCount = r.activityCount
        loaded = true
    }

    // MARK: Chrome

    private var topBar: some View {
        VStack {
            HStack {
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                            .frame(width: 38, height: 38)
                            .background(.regularMaterial, in: Circle())
                            .overlay(Circle().stroke(Theme.hairline))
                    }
                }
                Spacer()
                if !cells.isEmpty {
                    MapLayersButton(style: $style,
                                    previewCenter: cells.first.map {
                                        CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                                    })
                }
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
}
