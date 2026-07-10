import SwiftUI
import CoreLocation
import MapboxMaps

/// The map base layers a user can switch between (Strava's "layers" control), kept in one place so
/// every map — route suggestion, live tracking, history — offers the same set (`pickable`).
/// `.realistic` (Mapbox Standard: 3D buildings, terrain, lighting) is the default; the athlete's
/// choice persists app-wide (`storageKey`), so the style they pick on one map is the style they get
/// on every map, every launch. Rendered by Mapbox.
enum MapStyleOption: String, CaseIterable, Identifiable {
    case standard, realistic, streets, outdoors, dark, satellite, standardSatellite

    var id: String { rawValue }

    /// One persisted, app-wide choice — every map surface binds to this key via `@AppStorage`, so
    /// switching the style anywhere switches it everywhere and it survives relaunch.
    static let storageKey = "com.momentum.mapStyle"

    /// The stored choice for surfaces that read the style once at init (summary route cards). Live
    /// surfaces use `@AppStorage(MapStyleOption.storageKey)` instead so they update in place.
    static var persisted: MapStyleOption {
        UserDefaults.standard.string(forKey: storageKey).flatMap(MapStyleOption.init) ?? .realistic
    }

    var label: String {
        switch self {
        case .standard: "Map"
        case .realistic: "Realistic"
        case .streets: "Streets"
        case .outdoors: "Outdoors"
        case .dark: "Dark"
        case .satellite: "Satellite"
        case .standardSatellite: "3D Satellite"
        }
    }

    var systemImage: String {
        switch self {
        case .standard: "map"
        case .realistic: "building.2"
        case .streets: "road.lanes"
        case .outdoors: "mountain.2.fill"
        case .dark: "moon.fill"
        case .satellite: "globe.americas.fill"
        case .standardSatellite: "cube.fill"
        }
    }

    /// A curated set of Mapbox styles — all rendered by the Mapbox SDK:
    /// • **Map** — Mapbox Light, the brand's muted canvas.
    /// • **Realistic** — Mapbox Standard: 3D buildings, terrain, dynamic lighting.
    /// • **Streets** — Mapbox Streets: classic detailed, colorful street map.
    /// • **Outdoors** — Mapbox Outdoors: terrain, contour lines, hillshading (great for trails).
    /// • **Dark** — Mapbox Dark: sleek night basemap.
    /// • **Satellite** — Mapbox Satellite Streets: aerial imagery + roads/labels.
    /// • **3D Satellite** — Mapbox Standard Satellite: aerial imagery with 3D terrain + buildings.
    var mapboxStyle: MapboxMaps.MapStyle {
        switch self {
        case .standard: .light
        case .realistic: .standard
        case .streets: .streets
        case .outdoors: .outdoors
        case .dark: .dark
        case .satellite: .satelliteStreets
        case .standardSatellite: .standardSatellite
        }
    }

    /// Same base styles as a `StyleURI`, for UIKit `MapView`s (the heatmap) that load a style by URI.
    var styleURI: StyleURI {
        switch self {
        case .standard: .light
        case .realistic: .standard
        case .streets: .streets
        case .outdoors: .outdoors
        case .dark: .dark
        case .satellite: .satelliteStreets
        case .standardSatellite: .standardSatellite
        }
    }

    /// The styles offered in the layers picker, default first. Satellite (aerial imagery + labels)
    /// is user-selectable (decision 2026-07-09 — brought back by request); route accents keep their
    /// white halos over imagery via `isImagery`. `.standardSatellite` (3D) stays internal.
    static let pickable: [MapStyleOption] = [.realistic, .standard, .streets, .outdoors, .dark, .satellite]

    /// True over aerial imagery — route accents/labels need a heavier white halo + lighter ink there
    /// than over the non-imagery basemaps.
    var isImagery: Bool { self == .satellite || self == .standardSatellite }

    /// Camera tilt (degrees) for the explore map. 3D Satellite tilts so its 3D terrain + buildings
    /// read as a real skyline; the flat styles stay top-down.
    var explorePitch: CGFloat { self == .standardSatellite ? 55 : 0 }
}

/// Strava-style layers control — a floating glass button that opens the style picker sheet. Shared
/// by every map screen so the affordance is identical everywhere.
struct MapLayersButton: View {
    @Binding var style: MapStyleOption
    /// When set, the picker offers "World" — fly out to the globe of everyone on momentum (Today only).
    var onWorld: (() -> Void)? = nil
    /// Center for the style preview thumbnails — pass the map's focus so previews show *your* area.
    var previewCenter: CLLocationCoordinate2D? = nil

    @State private var showPicker = false

    var body: some View {
        Image(systemName: "square.3.layers.3d").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.ink)
            .frame(width: 44, height: 44)
            .momentumGlass(in: Circle())
            .mapSafeTap("Map style") { showPicker = true }
        .sheet(isPresented: $showPicker) {
            MapStylePickerSheet(style: $style, previewCenter: previewCenter,
                                onWorld: onWorld.map { world in { showPicker = false; world() } })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

/// The map-style picker (Strava's layers sheet): one row per style with a live rounded-square
/// preview of that base map next to its name, so you see what you're choosing before you choose it.
/// Picking stays open — the map behind updates instantly, and the choice persists app-wide.
struct MapStylePickerSheet: View {
    @Binding var style: MapStyleOption
    var previewCenter: CLLocationCoordinate2D? = nil
    var onWorld: (() -> Void)? = nil

    /// Previews frame the athlete's area when the host map knows it; a scenic downtown otherwise.
    private var center: CLLocationCoordinate2D {
        previewCenter ?? CLLocationCoordinate2D(latitude: 30.2672, longitude: -97.7431)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("MAP STYLE")
                    .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4)
                    .foregroundStyle(Theme.inkTertiary)
                    .padding(.horizontal, Theme.Space.lg).padding(.top, Theme.Space.lg)
                    .padding(.bottom, Theme.Space.sm)
                ForEach(Array(MapStyleOption.pickable.enumerated()), id: \.element.id) { i, option in
                    if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 84) }
                    row(option)
                }
                if let onWorld {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    Button(action: onWorld) {
                        HStack(spacing: Theme.Space.md) {
                            Image(systemName: "globe.americas.fill")
                                .font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.ink)
                                .frame(width: 56, height: 56)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.hairline))
                            Text("World").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                            Spacer()
                        }
                        .padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.sm)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("World — see everyone on momentum")
                }
            }
            .padding(.bottom, Theme.Space.lg)
        }
        .background(Theme.background)
    }

    private func row(_ option: MapStyleOption) -> some View {
        let selected = option == style
        return Button {
            guard !selected else { return }
            Haptics.light()
            style = option
        } label: {
            HStack(spacing: Theme.Space.md) {
                preview(option, selected: selected)
                Text(option.label)
                    .font(.rounded(Theme.FontSize.body, weight: selected ? .bold : .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.ink)
                }
            }
            .padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.label)\(selected ? ", selected" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A small live render of the actual base style — rounded square, non-interactive. Live beats a
    /// bundled screenshot: it's always faithful to the style, the region, and the season of imagery.
    private func preview(_ option: MapStyleOption, selected: Bool) -> some View {
        Map(initialViewport: .camera(center: center, zoom: 14.8, bearing: 0, pitch: option.explorePitch))
            .mapStyle(option.mapboxStyle)
            .ornamentOptions(MapChrome.hidden)
            .allowsHitTesting(false)
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? Theme.ink : Theme.hairline, lineWidth: selected ? 2 : 1)
            )
            .accessibilityHidden(true)
    }
}
