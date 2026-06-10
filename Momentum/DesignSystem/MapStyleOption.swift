import SwiftUI
import MapKit

/// The map base layers a user can switch between (Strava's "layers" control), kept in one place so
/// every map — route suggestion, live tracking, history — offers the same set. `.standard` is the
/// brand default (muted monochrome, the light hero look); `.hybrid` / `.satellite` are opt-in for
/// athletes who want real terrain and greenery. All 100% Apple-native (MapKit `MapStyle`).
enum MapStyleOption: String, CaseIterable, Identifiable {
    case standard, hybrid, satellite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: "Map"
        case .hybrid: "Hybrid"
        case .satellite: "Satellite"
        }
    }

    var systemImage: String {
        switch self {
        case .standard: "map"
        case .hybrid: "globe.americas"
        case .satellite: "globe.americas.fill"
        }
    }

    /// Points of interest are excluded everywhere — the map is a canvas for the route, not a directory.
    var mapStyle: MapStyle {
        switch self {
        case .standard: .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll)
        case .hybrid:   .hybrid(elevation: .realistic, pointsOfInterest: .excludingAll)
        case .satellite: .imagery(elevation: .realistic)
        }
    }

    /// True once we leave the monochrome base — route accents/labels need brighter contrast over
    /// satellite imagery (a heavier white halo, lighter ink) than over the muted standard map.
    var isImagery: Bool { self != .standard }
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
