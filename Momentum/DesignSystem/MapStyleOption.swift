import SwiftUI
import MapboxMaps

/// The map base layers a user can switch between (Strava's "layers" control), kept in one place so
/// every map — route suggestion, live tracking, history — offers the same set. `.standard` is the
/// brand default (Mapbox Light — muted, the light hero look); `.hybrid` / `.satellite` are opt-in for
/// athletes who want real terrain and greenery. Rendered by Mapbox.
enum MapStyleOption: String, CaseIterable, Identifiable {
    case standard, realistic, streets, outdoors, dark, satellite, standardSatellite

    var id: String { rawValue }

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

    /// True over aerial imagery — route accents/labels need a heavier white halo + lighter ink there
    /// than over the non-imagery basemaps.
    var isImagery: Bool { self == .satellite || self == .standardSatellite }

    /// Camera tilt (degrees) for the explore map. 3D Satellite tilts so its 3D terrain + buildings
    /// read as a real skyline; the flat styles stay top-down.
    var explorePitch: CGFloat { self == .standardSatellite ? 55 : 0 }
}

/// Strava-style layers control — a floating glass button that switches the map base. Shared by every
/// map screen so the affordance is identical everywhere.
struct MapLayersButton: View {
    @Binding var style: MapStyleOption

    var body: some View {
        Menu {
            Picker("Map style", selection: $style) {
                ForEach(MapStyleOption.allCases) { option in
                    Label(option.label, systemImage: option.systemImage).tag(option)
                }
            }
        } label: {
            Image(systemName: "square.3.layers.3d").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 38, height: 38)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(Theme.hairline))
        }
        .accessibilityLabel("Map style")
    }
}
