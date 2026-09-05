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
    /// URI. A URI can't carry the Standard light preset; UIKit hosts must also apply
    /// `standardLightPreset` after loading (as HeatmapMapView and the picker snapshotter do).
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
        renderedStyle(for: scheme).mapboxStyle
    }

    /// Shared by live maps and picker previews. Only the adaptive default follows appearance;
    /// an explicit Light, Dusk or Night selection must remain literal.
    func renderedStyle(for scheme: ColorScheme) -> MapStyleOption {
        self == .realistic && scheme == .dark ? .night : self
    }

    func availableStyle(hasPro: Bool) -> MapStyleOption {
        requiresPro && !hasPro ? .realistic : self
    }

    /// URI variant for snapshot/UIKit surfaces — literal in either appearance. (A URI can't carry
    /// Realistic's night preset, so Realistic renders as Standard day here regardless, as before.)
    func styleURI(for _: ColorScheme) -> StyleURI { styleURI }

    /// The style a URI-only LIVE surface (the heatmap) should render for this appearance. A
    /// `StyleURI` can't carry Realistic's night preset, so in dark mode the two DEFAULT styles
    /// — Realistic and Light — fall back to Dark, the same pairing every other map makes
    /// (2026-08-28: the History map card was a bright white tile on a dark page). A style the
    /// athlete deliberately picked always renders as chosen.
    func uriStyle(for scheme: ColorScheme) -> MapStyleOption {
        guard scheme == .dark, self == .realistic || self == .standard else { return self }
        return .dark
    }

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

// MARK: - Perspective (the 2D/3D toggle)

/// The camera's tilt as the athlete's own call — a 2D/3D button on the map, persisted app-wide
/// (owner ask 2026-08-28). `nil` (never chosen) keeps each style's own default (`explorePitch`), so
/// nothing changes until the athlete taps; an explicit choice then overrides every style.
enum MapPerspective: String, CaseIterable, Sendable {
    case flat, tilted
    static let storageKey = "com.momentum.mapPerspective"
    /// The tilt an explicit 3D choice applies to a style that has none of its own.
    static let tiltedPitch: CGFloat = 45
    /// The live-run follow camera's tilt: flat unless the athlete chose 3D. A follow camera over a
    /// pitched basemap re-renders terrain and buildings on every GPS fix, so on the run it is
    /// opt-in — never a style's default.
    var pitch: CGFloat { self == .tilted ? Self.tiltedPitch : 0 }
}

extension MapStyleOption {
    /// The explore camera's tilt under the athlete's perspective choice: an explicit 2D flattens
    /// every style, an explicit 3D tilts every style (a style with a deeper tilt of its own — 3D
    /// Satellite's 55° — keeps it, so 3D never means LESS 3D than before), and no choice keeps the
    /// style's default.
    func explorePitch(_ perspective: MapPerspective?) -> CGFloat {
        switch perspective {
        case .flat: 0
        case .tilted: max(explorePitch, MapPerspective.tiltedPitch)
        case nil: explorePitch
        }
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

    /// Inside a shared glass rail (Today's vertical control stack) the button draws no glass of
    /// its own — the rail is the surface.
    var bare = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // A map glyph, not the 3D-layers stack — this button picks the MAP's look (user call 2026-07-16).
        Image(systemName: "map").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.ink)
            .frame(width: 44, height: 44)
            .modifier(OptionalGlass(on: !bare))
            .mapSafeTap("Map style") { showPicker = true }
        .sheet(isPresented: $showPicker) {
            MapStylePickerSheet(style: $style, previewCenter: previewCenter)
                .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(32)
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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var usesRows: Bool { dynamicTypeSize >= .accessibility3 }
    private var columns: Int { usesRows ? 1 : (dynamicTypeSize.isAccessibilitySize ? 2 : 3) }

    /// Previews frame the athlete's area when the host map knows it; a scenic downtown otherwise.
    private var center: CLLocationCoordinate2D {
        previewCenter ?? CLLocationCoordinate2D(latitude: 30.2672, longitude: -97.7431)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Map style")
                        .font(.display(22, weight: .black)).foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    if !dynamicTypeSize.isAccessibilitySize { scopeNote }
                }
                Spacer(minLength: 0)
                Button("Done") { dismiss() }
                    .font(.rounded(14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 16).frame(minHeight: 44)
                    .background(Theme.surface, in: Capsule())
                    .buttonStyle(RaisedPressStyle())
                    .accessibilityIdentifier("mapStyleDone")
            }
            .padding(.horizontal, Theme.Space.lg).padding(.top, Theme.Space.lg)
            .padding(.bottom, Theme.Space.md)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    // At accessibility sizes, explanatory text scrolls away so the pinned header
                    // doesn't consume the browsing area. Navigation itself stays full-size.
                    if dynamicTypeSize.isAccessibilitySize { scopeNote }
                    group("REALISTIC", MapStyleOption.realisticSet)
                    group("CLASSIC", MapStyleOption.classicSet)
                    Text("Realistic follows your app’s light or dark appearance. Other styles stay as shown.")
                        .font(.rounded(12, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Theme.Space.lg)
                .padding(.top, 2).padding(.bottom, Theme.Space.xl)
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("mapStyleOptions")
        }
        .background(Theme.background)
        .nestedPaywallHost()
        .onAppear { normalizeSelection() }
        .onChange(of: paywall.isPro) { normalizeSelection() }
    }

    private var scopeNote: some View {
        Text("Applies to all your maps.")
            .font(.rounded(13, weight: .medium)).foregroundStyle(Theme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
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
                ForEach(Array(stride(from: 0, to: options.count, by: columns)), id: \.self) { start in
                    GridRow(alignment: .top) {
                        ForEach(options[start..<min(start + columns, options.count)]) { option in
                            let locked = option.requiresPro && !paywall.isEntitled(to: .mapStyles)
                            StylePreviewCell(option: option, center: center,
                                             selected: option == style, locked: locked, usesRow: usesRows) {
                                if locked { paywall.present(for: .mapStyles); return }
                                guard option != style else { return }
                                Haptics.light()
                                style = option
                            }
                        }
                        ForEach(0..<(columns - min(columns, options.count - start)), id: \.self) { _ in
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
        }
    }

    private func normalizeSelection() {
        let available = style.availableStyle(hasPro: paywall.isEntitled(to: .mapStyles))
        if available != style { style = available }
    }
}

/// One style card: the static snapshot preview with the name beneath; the selected card wears a
/// lavender border + a check badge. Cached snapshots avoid a live map renderer per card.
private struct StylePreviewCell: View {
    let option: MapStyleOption
    let center: CLLocationCoordinate2D
    let selected: Bool
    var locked: Bool = false
    var usesRow: Bool = false
    let onPick: () -> Void

    @State private var image: UIImage?
    @State private var loadedRequest: MapStylePreviewRequest?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    /// Rendered a touch larger than display for crisp corners on 3x screens.
    private var request: MapStylePreviewRequest {
        MapStylePreviewRequest(option: option, center: center, scheme: colorScheme,
                               size: CGSize(width: 220, height: 165), scale: displayScale)
    }

    private var resolvedImage: UIImage? {
        loadedRequest == request ? image : MapStylePreviews.cachedImage(for: request)
    }

    var body: some View {
        let layout = usesRow
            ? AnyLayout(HStackLayout(alignment: .center, spacing: Theme.Space.md))
            : AnyLayout(VStackLayout(spacing: Theme.Space.xs))
        Button(action: onPick) {
            layout {
                Theme.surface
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .frame(width: usesRow ? 96 : nil)
                    .overlay {
                        Image(systemName: option.systemImage)
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    }
                    .overlay {
                        if let image = resolvedImage {
                            Image(uiImage: image).resizable().scaledToFit()
                                .transition(.opacity)
                        }
                    }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Theme.purple : Theme.hairline, lineWidth: selected ? 2 : 1)
                )
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white, Theme.purple)
                            .background(Circle().fill(.white).padding(2))
                            .padding(6)
                    } else if locked {
                        Image(systemName: "lock.circle.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white, Color.black.opacity(0.8))
                            .padding(6)
                    }
                }
                Text(option.label)
                    .font(.rounded(Theme.FontSize.label, weight: .semibold))
                    .foregroundStyle(selected ? Theme.ink : Theme.inkSecondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(usesRow ? .leading : .center)
                    .frame(maxWidth: .infinity, alignment: usesRow ? .leading : .center)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RaisedPressStyle())
        .task(id: request) {
            let requested = request
            let result = await MapStylePreviews.snapshot(requested)
            guard !Task.isCancelled else { return }
            withAnimation(Motion.crossfade) {
                image = result
                loadedRequest = requested
            }
        }
        .accessibilityIdentifier("mapStyle.\(option.rawValue)")
        .accessibilityLabel(locked ? "\(option.label) — locked, unlock with Pro"
                                   : "\(option.label)\(selected ? ", selected" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(locked ? "Opens Momentum Pro. Your current style stays selected."
                           : "Applies immediately. Use Done to return to the map.")
    }
}

/// Glass circle when `on`, nothing otherwise — so one control can live alone on the map or
/// inside a shared rail.
struct OptionalGlass: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.momentumGlass(in: Circle()) } else { content }
    }
}
