import SwiftUI
import CoreLocation
import MapboxMaps

/// The map base layers a user can switch between (Strava's "layers" control), kept in one place so
/// every map — route suggestion, live tracking, history — offers the same set (`pickable`).
/// `.realistic` (Mapbox Standard: 3D buildings, terrain, lighting) is the default; the athlete's
/// choice persists app-wide (`storageKey`), so the style they pick on one map is the style they get
/// on every map, every launch. Rendered by Mapbox.
enum MapStyleOption: String, CaseIterable, Identifiable {
    case standard, realistic, dusk, night, streets, outdoors, dark, satellite, standardSatellite

    var id: String { rawValue }

    /// One persisted, app-wide choice — every map surface binds to this key via `@AppStorage`, so
    /// switching the style anywhere switches it everywhere and it survives relaunch.
    static let storageKey = "com.momentum.mapStyle"

    /// Free tier gets the two defaults — Realistic and Light — one from each family; every other
    /// style is Pro (`Feature.mapStyles`). The picker gates selection and the map views normalize
    /// a persisted Pro style back to Realistic if entitlement lapses.
    var requiresPro: Bool { !(self == .realistic || self == .standard) }

    /// The stored choice for surfaces that read the style once at init (summary route cards). Live
    /// surfaces use `@AppStorage(MapStyleOption.storageKey)` instead so they update in place.
    static var persisted: MapStyleOption {
        UserDefaults.standard.string(forKey: storageKey).flatMap(MapStyleOption.init) ?? .realistic
    }

    var label: String {
        switch self {
        case .standard: "Light"
        case .realistic: "Realistic"
        case .dusk: "Dusk"
        case .night: "Night"
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
        case .dusk: "sun.horizon.fill"
        case .night: "moon.stars.fill"
        case .streets: "road.lanes"
        case .outdoors: "mountain.2.fill"
        case .dark: "moon.fill"
        case .satellite: "globe.americas.fill"
        case .standardSatellite: "cube.fill"
        }
    }

    /// A curated set of Mapbox styles — all rendered by the Mapbox SDK:
    /// • **Light** — Mapbox Light, the brand's muted monochrome canvas.
    /// • **Realistic** — Mapbox Standard (day): 3D buildings, terrain, dynamic lighting.
    /// • **Dusk** — Mapbox Standard at golden hour: warm low light, lit windows coming on.
    /// • **Night** — Mapbox Standard after dark: the lit city, realistic night lighting.
    /// • **Streets** — Mapbox Streets: classic detailed, colorful street map.
    /// • **Outdoors** — Mapbox Outdoors: terrain, contour lines, hillshading (great for trails).
    /// • **Dark** — Mapbox Dark: sleek flat night basemap.
    /// • **Satellite** — Mapbox Satellite Streets: aerial imagery + roads/labels.
    /// • **3D Satellite** — Mapbox Standard Satellite: aerial imagery draped over 3D terrain
    ///   and buildings — satellite, but with real depth.
    var mapboxStyle: MapboxMaps.MapStyle {
        switch self {
        case .standard: .light
        case .realistic: .standard
        case .dusk: .standard(lightPreset: .dusk)
        case .night: .standard(lightPreset: .night)
        case .streets: .streets
        case .outdoors: .outdoors
        case .dark: .dark
        case .satellite: .satelliteStreets
        case .standardSatellite: .standardSatellite
        }
    }

    /// Same base styles as a `StyleURI`, for UIKit `MapView`s (the heatmap) that load a style by
    /// URI. A URI can't carry the Standard light preset — Dusk/Night fall back to Standard day
    /// there, which only affects the heatmap backdrop.
    var styleURI: StyleURI {
        switch self {
        case .standard: .light
        case .realistic, .dusk, .night: .standard
        case .streets: .streets
        case .outdoors: .outdoors
        case .dark: .dark
        case .satellite: .satelliteStreets
        case .standardSatellite: .standardSatellite
        }
    }

    /// The style to RENDER: the athlete's chosen style, EXACTLY as picked. The old code also paired
    /// the Light basemap → Dark under dark mode, so choosing Light in dark mode silently stayed dark
    /// (user report 2026-07-16). Now Light — and every other explicit pick — is literal in both
    /// appearances. The ONE exception is **Realistic**: it's the app default and its whole identity is
    /// dynamic real-world lighting, so it slides into night lighting under dark mode — which keeps the
    /// DEFAULT dark-mode map dark. Anyone wanting a fixed day/dusk/night/dark look picks that style
    /// (Dusk, Night, Dark are their own picker choices).
    func mapboxStyle(for scheme: ColorScheme) -> MapboxMaps.MapStyle {
        if scheme == .dark, self == .realistic { return .standard(lightPreset: .night) }
        return mapboxStyle
    }

    /// URI variant for snapshot/UIKit surfaces — literal in either appearance. (A URI can't carry
    /// Realistic's night preset, so Realistic renders as Standard day here regardless, as before.)
    func styleURI(for _: ColorScheme) -> StyleURI { styleURI }

    /// True when a baked snapshot of this style comes back DARK or photographic. Overlay ink on a
    /// route card keys off this: the pale basemaps take fixed dark ink, these take white-with-a-halo
    /// (the treatment that survives any luminance). Satellite counts even though imagery varies —
    /// snow and desert are bright, forest and water are near-black, so it is never safe to assume.
    ///
    /// Dusk/Night are NOT here: a `StyleURI` can't carry the Standard light preset (see `styleURI`),
    /// so they bake as Standard *day*, a light canvas. If `RouteSnapshotter` ever sets
    /// `lightPreset` on the basemap import, revisit this.
    var bakesDarkCanvas: Bool {
        switch self {
        case .dark, .satellite, .standardSatellite: true
        case .standard, .realistic, .dusk, .night, .streets, .outdoors: false
        }
    }

    /// The Standard style's light preset, when this option is one of its moods — applied to
    /// snapshot previews via the style-import config (the URI alone can't express it).
    var standardLightPreset: String? {
        switch self {
        case .dusk: "dusk"
        case .night: "night"
        default: nil
        }
    }

    /// The styles offered in the layers picker, grouped: the realistic Standard family first (the
    /// hero looks), then the classic flat basemaps. Kept as two arrays so the picker can section them.
    static let realisticSet: [MapStyleOption] = [.realistic, .dusk, .night, .standardSatellite]
    static let classicSet: [MapStyleOption] = [.standard, .streets, .outdoors, .dark, .satellite]
    static let pickable: [MapStyleOption] = realisticSet + classicSet

    /// The style to RENDER on the LIVE-tracking map: **the athlete's choice, unchanged.**
    ///
    /// This used to silently downgrade the 3D looks (Realistic/Dusk/Night/3D Satellite) to their
    /// flat 2D equivalents for follow-camera performance — but on a real device that reads as a
    /// bug: you picked Realistic and the run showed Light (caught on the 2026-07-23 demo-video
    /// recording). The original jank was since fixed at the source (the per-fix `PuckFeed` — the
    /// camera moves once per GPS fix, not per frame), so the downgrade's reason is gone. The
    /// property remains as the single seam if a specific style ever needs a live variant again.
    var liveTrackingStyle: MapStyleOption { self }

    /// True over aerial imagery — route accents/labels need a heavier white halo + lighter ink there
    /// than over the non-imagery basemaps.
    var isImagery: Bool { self == .satellite || self == .standardSatellite }

    /// True when the basemap itself is dark — floating chrome and route casings adapt.
    var isDarkBase: Bool { self == .night || self == .dark }

    /// Camera tilt (degrees) for the explore map. The 3D styles tilt so terrain + buildings read
    /// as a real skyline; the flat styles stay top-down.
    var explorePitch: CGFloat {
        switch self {
        case .standardSatellite: 55
        case .dusk, .night: 45
        default: 0
        }
    }
}

// MARK: - Preview snapshots

/// Renders one static preview image per (style, area) via Mapbox's `Snapshotter` and caches it for
/// the app's lifetime. The picker used to run a LIVE map engine per row — with nine styles that's
/// nine GPU render loops behind a sheet animation, which is exactly where the jank came from. A
/// snapshot is rendered once, joins in-flight requests, and every later open is instant.
@MainActor
enum MapStylePreviews {
    private static var cache: [String: UIImage] = [:]
    private static var active: [String: Snapshotter] = [:]
    private static var tokens: [String: AnyCancelable] = [:]
    private static var waiters: [String: [CheckedContinuation<UIImage?, Never>]] = [:]

    /// The Snapshotter hard-draws the logo + attribution strip into the image with no opt-out.
    /// Attribution lives on the live map this sheet floats over, so previews render this much
    /// taller and crop the strip away — thumbnails are UI chrome, not a map.
    private static let attributionStripPt: CGFloat = 28

    static func snapshot(_ option: MapStyleOption, center: CLLocationCoordinate2D,
                         size: CGSize) async -> UIImage? {
        // Bucket the center (~2 km) so tiny GPS drift between opens doesn't defeat the cache.
        let key = "\(option.rawValue)|\(Int(center.latitude * 50))|\(Int(center.longitude * 50))"
        if let hit = cache[key] { return hit }

        return await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
            guard active[key] == nil else { return }   // join the in-flight render

            let padded = CGSize(width: size.width, height: size.height + attributionStripPt)
            let snapshotter = Snapshotter(options: MapSnapshotOptions(
                size: padded, pixelRatio: UIScreen.main.scale))
            active[key] = snapshotter
            snapshotter.styleURI = option.styleURI
            snapshotter.setCamera(to: CameraOptions(center: center, zoom: 13.8,
                                                    pitch: option.explorePitch))
            tokens[key] = snapshotter.onStyleLoaded.observeNext { _ in
                if let preset = option.standardLightPreset {
                    try? snapshotter.style.setStyleImportConfigProperty(
                        for: "basemap", config: "lightPreset", value: preset)
                }
                snapshotter.start(overlayHandler: nil) { result in
                    let image = (try? result.get()).map { cropBottomStrip($0, to: size) }
                    if let image { cache[key] = image }
                    (waiters.removeValue(forKey: key) ?? []).forEach { $0.resume(returning: image) }
                    active[key] = nil
                    tokens[key] = nil
                }
            }
        }
    }

    private static func cropBottomStrip(_ image: UIImage, to size: CGSize) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let scale = image.scale
        let rect = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        guard let cropped = cg.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped, scale: scale, orientation: image.imageOrientation)
    }
}

// MARK: - Layers control

/// Strava-style layers control — a floating glass button that opens the style picker sheet. Shared
/// by every map screen so the affordance is identical everywhere.
struct MapLayersButton: View {
    @Binding var style: MapStyleOption
    /// Center for the style preview thumbnails — pass the map's focus so previews show *your* area.
    var previewCenter: CLLocationCoordinate2D? = nil

    #if DEBUG
    // --map-picker: open the style sheet on arrival (sim verification of the picker itself).
    @State private var showPicker = ProcessInfo.processInfo.arguments.contains("--map-picker")
    #else
    @State private var showPicker = false
    #endif

    var body: some View {
        // A map glyph, not the 3D-layers stack — this button picks the MAP's look (user call 2026-07-16).
        Image(systemName: "map").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.ink)
            .frame(width: 44, height: 44)
            .momentumGlass(in: Circle())
            .mapSafeTap("Map style") { showPicker = true }
        .sheet(isPresented: $showPicker) {
            MapStylePickerSheet(style: $style, previewCenter: previewCenter)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

/// The map-style picker: a clean two-section grid of static style previews (Apple Maps' chooser,
/// momentum-styled). Realistic Standard moods lead; the classic basemaps follow. Picking stays
/// open — the map behind updates instantly, and the choice persists app-wide.
struct MapStylePickerSheet: View {
    @Binding var style: MapStyleOption
    var previewCenter: CLLocationCoordinate2D? = nil
    @Environment(PaywallController.self) private var paywall

    /// Previews frame the athlete's area when the host map knows it; a scenic downtown otherwise.
    private var center: CLLocationCoordinate2D {
        previewCenter ?? CLLocationCoordinate2D(latitude: 30.2672, longitude: -97.7431)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("Map style")
                    .font(.display(22, weight: .black)).foregroundStyle(Theme.ink)
                    .padding(.top, Theme.Space.lg)
                group("REALISTIC", MapStyleOption.realisticSet)
                group("CLASSIC", MapStyleOption.classicSet)
                // The "World" globe row is gone with the social layer (2026-07-16) — the picker is
                // purely map styles now.
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.bottom, Theme.Space.xl)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background)
    }

    private func group(_ title: String, _ options: [MapStyleOption]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title)
                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4)
                .foregroundStyle(Theme.inkTertiary)
            // Eager Grid, deliberately not lazy: nine image cells cost nothing, every style stays
            // in the accessibility tree even below the medium-detent fold, and there's no cell
            // pop-in while the sheet scrolls.
            Grid(horizontalSpacing: Theme.Space.sm, verticalSpacing: Theme.Space.md) {
                ForEach(Array(stride(from: 0, to: options.count, by: 3)), id: \.self) { start in
                    GridRow {
                        ForEach(options[start..<min(start + 3, options.count)]) { option in
                            let locked = option.requiresPro && !paywall.isEntitled(to: .mapStyles)
                            StylePreviewCell(option: option, center: center,
                                             selected: option == style, locked: locked) {
                                if locked { paywall.present(for: .mapStyles); return }
                                guard option != style else { return }
                                Haptics.light()
                                style = option
                            }
                        }
                        // Pad the last row so partial rows keep three equal columns.
                        ForEach(0..<(3 - min(3, options.count - start)), id: \.self) { _ in Color.clear }
                    }
                }
            }
        }
    }

}

/// One style card: the static snapshot preview with the name beneath; the selected card wears an
/// ink border + a check badge. The snapshot loads once (cached app-wide), so reopening the sheet
/// is instant and scrolling it never drops a frame.
private struct StylePreviewCell: View {
    let option: MapStyleOption
    let center: CLLocationCoordinate2D
    let selected: Bool
    var locked: Bool = false
    let onPick: () -> Void

    @State private var image: UIImage?

    /// Rendered a touch larger than display for crisp corners on 3x screens.
    private static let renderSize = CGSize(width: 132, height: 100)

    var body: some View {
        Button(action: onPick) {
            VStack(spacing: Theme.Space.xs) {
                ZStack {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                            .transition(.opacity)
                    } else {
                        Theme.surface
                        Image(systemName: option.systemImage)
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    }
                }
                .frame(height: 82)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Theme.ink : Theme.hairline, lineWidth: selected ? 2 : 1)
                )
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.background, Theme.ink)
                            .padding(5)
                    } else if locked {
                        Image(systemName: "lock.circle.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.background, Theme.ink.opacity(0.75))
                            .padding(5)
                    }
                }
                Text(option.label)
                    .font(.rounded(Theme.FontSize.label, weight: selected ? .bold : .semibold))
                    .foregroundStyle(selected ? Theme.ink : Theme.inkSecondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.2), value: image != nil)
        .task(id: option.id) {
            image = await MapStylePreviews.snapshot(option, center: center, size: Self.renderSize)
        }
        .accessibilityLabel(locked ? "\(option.label) — locked, unlock with Pro"
                                   : "\(option.label)\(selected ? ", selected" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
