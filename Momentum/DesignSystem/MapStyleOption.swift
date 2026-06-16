import SwiftUI
import MapboxMaps

/// The map base layers a user can switch between (Strava's "layers" control), kept in one place so
/// every map — route suggestion, live tracking, history — offers the same set. `.standard` is the
/// brand default (Mapbox Light — muted, the light hero look); `.hybrid` / `.satellite` are opt-in for
/// athletes who want real terrain and greenery. Rendered by Mapbox.
enum MapStyleOption: String, CaseIterable, Identifiable {
    case standard, realistic, hybrid, satellite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: "Map"
        case .realistic: "Realistic"
        case .hybrid: "Hybrid"
        case .satellite: "Satellite"
        }
    }

    var systemImage: String {
        switch self {
        case .standard: "map"
        case .realistic: "building.2"
        case .hybrid: "globe.americas"
        case .satellite: "globe.americas.fill"
        }
    }

    /// The Mapbox base style. Light is the brand's muted canvas; Realistic is Mapbox Standard (3D
    /// buildings, terrain, dynamic lighting); hybrid/satellite add aerial imagery.
    var mapboxStyle: MapboxMaps.MapStyle {
        switch self {
        case .standard: .light
        case .realistic: .standard
        case .hybrid: .standardSatellite
        case .satellite: .satelliteStreets
        }
    }

    /// Same base styles as a `StyleURI`, for UIKit `MapView`s (the heatmap) that load a style by URI.
    var styleURI: StyleURI {
        switch self {
        case .standard: .light
        case .realistic: .standard
        case .hybrid: .satelliteStreets
        case .satellite: .satellite
        }
    }

    /// True over aerial imagery — route accents/labels need a heavier white halo + lighter ink there
    /// than over the muted/standard basemaps.
    var isImagery: Bool { self == .hybrid || self == .satellite }
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
