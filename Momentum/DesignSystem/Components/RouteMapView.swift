import SwiftUI
import CoreLocation
import MapboxMaps

/// Lets the surface that OWNS the overlay chrome (the immersive pager page) talk to the map's
/// camera without RouteMapView knowing anything about that surface's layout: the page renders its
/// own re-center control wherever its design wants it, and the map just reports "the athlete has
/// explored away from the fitted overview" and answers the re-center call.
@Observable
final class RouteMapCameraHandle {
    /// True once a gesture has moved the camera off the fitted whole-route overview.
    fileprivate(set) var isExplored = false
    fileprivate var recenterAction: (() -> Void)?
    /// Animate the camera back to the whole-route overview.
    func recenter() { recenterAction?() }
}

/// A Mapbox map that frames a single completed route — shared by the cardio summary and history
/// detail. The route is drawn as a **periwinkle→lilac gradient** with a white casing (a `LineLayer`,
/// which is safe here because the route is static — a live-updating gradient crashes Mapbox).
/// Non-interactive by default (a display canvas, not an explorable map).
struct RouteMapView: View {
    let coordinates: [CLLocationCoordinate2D]
    /// Defaults to the athlete's persisted app-wide style, read at init (summary/history cards).
    var style: MapStyleOption = .persisted
    var interactive: Bool = false
    /// Draw the route head-to-tail once when this map's style becomes ready. Callers own the
    /// persistence decision; this view only performs the polished Mapbox-layer reveal.
    var revealOnLoad: Bool = false
    /// How much room to leave around the route, per edge.
    ///
    /// Asymmetric on purpose (2026-08-22). Both hosts that show the hero map — the save editors and
    /// the history detail — float their chrome (back, ⋯, Done/Edit/Share) OVER the top of the map,
    /// and the fit is width-constrained on a typical loop, so an even inset centred the route in the
    /// FRAME and left the top of the loop sitting behind those buttons. Padding the top more than
    /// the bottom moves the centre down by half the difference, which is what actually clears it.
    var insets: SwiftUI.EdgeInsets = SwiftUI.EdgeInsets(top: 28, leading: 28,
                                                        bottom: 28, trailing: 28)
    /// See `RouteMapCameraHandle`; only meaningful when `interactive`.
    var cameraHandle: RouteMapCameraHandle? = nil
    /// Community supplies a painted route preview underneath the live map, so its loader must be
    /// transparent. Other hosts retain the quiet surface they have always used.
    var loadingBackground: Color = Theme.surface
    /// Lets a lazy pager remember that this exact entrance finished. Without this handshake, a
    /// recycled page starts the same reveal again when the athlete swipes back to it.
    var onRevealCompleted: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A live viewport BINDING, not `initialViewport`: the initial form is applied exactly once,
    /// at whatever size the map happens to have at creation — inside a lazy container (the
    /// profile's immersive pager) that's a placeholder-sized frame, so the "fit the whole route"
    /// camera was computed for the wrong canvas and stuck zoomed-in (caught on device
    /// 2026-07-24). The `.overview` viewport STATE re-fits whenever the map's real size lands —
    /// the whole route, every time, on every surface.
    @State private var viewport: Viewport
    /// True once the basemap + route layers are in — gates the fade-in (see `.opacity` below).
    @State private var styleReady = false
    @State private var hasRevealed = false
    @State private var revealCompletionSent = false
    @State private var revealTask: Task<Void, Never>?

    init(coordinates: [CLLocationCoordinate2D], style: MapStyleOption = .persisted,
         interactive: Bool = false, padding: CGFloat = 28,
         cameraHandle: RouteMapCameraHandle? = nil, revealOnLoad: Bool = false,
         loadingBackground: Color = Theme.surface,
         onRevealCompleted: (() -> Void)? = nil) {
        self.init(coordinates: coordinates, style: style, interactive: interactive,
                  insets: SwiftUI.EdgeInsets(top: padding, leading: padding,
                                             bottom: padding, trailing: padding),
                  cameraHandle: cameraHandle, revealOnLoad: revealOnLoad,
                  loadingBackground: loadingBackground,
                  onRevealCompleted: onRevealCompleted)
    }

    init(coordinates: [CLLocationCoordinate2D], style: MapStyleOption = .persisted,
         interactive: Bool = false, insets: SwiftUI.EdgeInsets,
         cameraHandle: RouteMapCameraHandle? = nil, revealOnLoad: Bool = false,
         loadingBackground: Color = Theme.surface,
         onRevealCompleted: (() -> Void)? = nil) {
        self.coordinates = coordinates
        self.style = style
        self.interactive = interactive
        self.insets = insets
        self.cameraHandle = cameraHandle
        self.revealOnLoad = revealOnLoad
        self.loadingBackground = loadingBackground
        self.onRevealCompleted = onRevealCompleted
        _viewport = State(initialValue: Self.fit(coordinates, insets: insets))
    }

    var body: some View {
        MapReader { proxy in
            Map(viewport: $viewport) {
                // The numbered per-mile/km badges that used to render here were REMOVED entirely
                // (owner call 2026-07-30 — they read as noise, not information). The route keeps
                // exactly two annotations: where it began and where it ended.
                if let start = coordinates.first, coordinates.count > 1 {
                    MapViewAnnotation(coordinate: start) { startPin }.allowOverlap(true)
                }
                if let finish = coordinates.last, coordinates.count > 1 {
                    MapViewAnnotation(coordinate: finish) { finishPin }.allowOverlap(true)
                }
            }
            .mapStyle(style.mapboxStyle(for: colorScheme))
            .ornamentOptions(MapChrome.minimal)
            .gestureOptions(interactive ? Self.exploreGestures : GestureOptions())
            .onStyleLoaded { _ in
                // A second style-ready event can arrive while the first route is drawing (for
                // example after an appearance/style reload). Settle that old generation before
                // installing the new one so it cannot write a stale partial trim afterward.
                if revealTask != nil { finishReveal(on: proxy.map) }
                // Before the route goes on: the basemap's POI and transit pins are the only thing
                // that ever competes with it for the frame. See `MapChrome.hidePointsOfInterest`.
                MapChrome.hidePointsOfInterest(on: proxy.map)
                let wantsReveal = revealOnLoad && !hasRevealed
                let shouldAnimate = wantsReveal && !reduceMotion
                let routeReady = addRouteLayers(
                    proxy.map, visibleProgress: shouldAnimate ? 0 : 1)
                styleReady = routeReady
                guard routeReady, wantsReveal else { return }
                hasRevealed = true
                if shouldAnimate {
                    startReveal(on: proxy.map)
                } else {
                    finishReveal(on: proxy.map)
                }
            }
            // Held on the quiet surface until the style (and the route layers) are actually in —
            // an empty half-loaded basemap frame is never the first thing a summary shows.
            .opacity(styleReady ? 1 : 0)
            .background(loadingBackground)
            .animation(.easeOut(duration: 0.25), value: styleReady)
            .allowsHitTesting(interactive)
            .onChange(of: viewport.isIdle) { _, idle in
                // A gesture parks the viewport at .idle — that's the "explored" signal.
                cameraHandle?.isExplored = idle
            }
            .onAppear {
                cameraHandle?.recenterAction = { [coordinates, insets] in
                    withViewportAnimation(.easeOut(duration: 0.7)) {
                        viewport = Self.fit(coordinates, insets: insets)
                    }
                }
            }
            .onChange(of: reduceMotion) { _, enabled in
                // Accessibility can change while the pager is open. Finish immediately instead
                // of letting a no-longer-appropriate motion continue in the background.
                if enabled, hasRevealed, !revealCompletionSent {
                    finishReveal(on: proxy.map)
                }
            }
            .onChange(of: colorScheme) { _, _ in
                // The adaptive style is about to rebuild. Reveal the caller's painted fallback
                // during that window instead of leaving a now-empty Mapbox platform view opaque.
                styleReady = false
            }
            .onChange(of: style) { _, _ in
                // Explicit in-app map-style changes take the same loading path as appearance
                // changes. `onStyleLoaded` turns the live map back on only after both route layers
                // are present in the new style.
                styleReady = false
            }
            .onDisappear {
                // Never leave a cached/reused map with a half-drawn route if paging or a media
                // swap interrupts the reveal. The next time this surface appears it should show
                // the athlete's complete route, not the frame where cancellation happened.
                if hasRevealed { finishReveal(on: proxy.map) }
                else { revealTask?.cancel(); revealTask = nil }
            }
        }
    }

    /// The immersive pager owns single-finger vertical drags (that's how you swipe between
    /// workouts), so exploring is everything BUT a one-finger pan: pinch to zoom (with pan while
    /// pinching), double-tap / two-finger-tap zoom, and quick-zoom. No rotate/pitch — a route
    /// study, not a flight sim.
    private static var exploreGestures: GestureOptions {
        var options = GestureOptions()
        options.panEnabled = false
        options.pinchEnabled = true
        options.pinchZoomEnabled = true
        options.pinchPanEnabled = true
        options.rotateEnabled = false
        options.pitchEnabled = false
        options.simultaneousRotateAndPinchZoomEnabled = false
        options.doubleTapToZoomInEnabled = true
        options.doubleTouchToZoomOutEnabled = true
        options.quickZoomEnabled = true
        return options
    }

    /// Start and finish use the SHARED marks (`RouteEndpoints`) — the same objects the grid tiles
    /// and snapshots draw. They used to be this file's own 18pt dot and 22pt black flag-disc, which
    /// is why opening a route from the profile showed a visibly different marker than the tile you
    /// tapped (owner report 2026-07-30). One definition, one look, every surface.
    private var startPin: some View { RouteStartMark(diameter: 12) }
    private var finishPin: some View { RouteFinishMark(diameter: 12) }

    /// Ensures every route component independently. A prior source-only guard meant one transient
    /// layer insertion failure could strand a post with a source but no visible line forever.
    @discardableResult
    private func addRouteLayers(_ map: MapboxMap?, visibleProgress: Double) -> Bool {
        guard let map, map.isStyleLoaded, coordinates.count > 1 else { return false }
        if !map.sourceExists(withId: "route-src") {
            var source = GeoJSONSource(id: "route-src")
            source.lineMetrics = true                   // required for the line-progress gradient
            source.data = .geometry(.lineString(LineString(coordinates)))
            try? map.addSource(source)
        }
        guard map.sourceExists(withId: "route-src") else { return false }

        // Full emissive strength: Standard-family styles (Realistic/Dusk/Night — and the paired
        // dark looks) light custom layers with the 3D scene's lighting, which dims an unlit line
        // to ~35% at night — the route read near-black instead of the brand purple. Emissive
        // layers self-illuminate; classic flat styles ignore the property.
        let hiddenTail = RouteReplayLineTrim.hiddenTail(afterVisibleProgress: visibleProgress)
        if !map.layerExists(withId: "route-casing") {
            let casing = LineLayer(id: "route-casing", source: "route-src")
                .lineColor(StyleColor(UIColor.white))
                .lineWidth(6).lineCap(.round).lineJoin(.round)
                .lineEmissiveStrength(1)
                .lineTrimOffset(start: hiddenTail[0], end: hiddenTail[1])
            try? map.addLayer(casing)
        }

        if !map.layerExists(withId: "route-line") {
            var line = LineLayer(id: "route-line", source: "route-src")
                .lineWidth(4).lineCap(.round).lineJoin(.round)
                .lineEmissiveStrength(1)
                .lineTrimOffset(start: hiddenTail[0], end: hiddenTail[1])
            // One solid trace color on every map (owner call 2026-08-19) — the old lavender→lilac
            // gradient end is gone; direction reads from the endpoint dots, not a color shift.
            line.lineGradient = .expression(Exp(.interpolate) {
                Exp(.linear)
                Exp(.lineProgress)
                0.0
                UIColor(Theme.route)
                1.0
                UIColor(Theme.route)
            })
            try? map.addLayer(line)
        }

        let ready = map.layerExists(withId: "route-casing")
            && map.layerExists(withId: "route-line")
        if ready { setRevealProgress(visibleProgress, on: map) }
        return ready
    }

    /// Mapbox owns the pixels; this task only advances its trim property. Drive the reveal from
    /// elapsed time instead of a fixed frame count so a busy render loop can drop frames without
    /// shortening the animation or stopping before the route's finish.
    private func startReveal(on map: MapboxMap?) {
        revealTask?.cancel()
        revealTask = Task { @MainActor in
            let clock = ContinuousClock()
            let started = clock.now
            while true {
                guard !Task.isCancelled else { return }
                let elapsed = started.duration(to: clock.now).components
                let elapsedS = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                let progress = RouteMapRevealMotion.progress(elapsedS: elapsedS)
                setRevealProgress(progress, on: map)
                if progress >= 1 { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
            // Commit the exact terminal state. This avoids a sub-pixel missing tail when the last
            // display-link-sized update lands fractionally before the duration boundary.
            finishReveal(on: map)
        }
    }

    private func finishReveal(on map: MapboxMap?) {
        setRevealProgress(1, on: map)
        revealTask?.cancel()
        revealTask = nil
        guard !revealCompletionSent else { return }
        revealCompletionSent = true
        onRevealCompleted?()
    }

    private func setRevealProgress(_ progress: Double, on map: MapboxMap?) {
        let value = RouteReplayLineTrim.hiddenTail(afterVisibleProgress: progress)
        try? map?.setLayerProperty(for: "route-casing", property: "line-trim-offset", value: value)
        try? map?.setLayerProperty(for: "route-line", property: "line-trim-offset", value: value)
    }

    /// Frame the whole route with padding; fall back to a centered camera for a single point.
    private static func fit(_ coordinates: [CLLocationCoordinate2D], insets: SwiftUI.EdgeInsets) -> Viewport {
        guard coordinates.count > 1 else {
            if let c = coordinates.first { return .camera(center: c, zoom: 14) }
            return .idle
        }
        // maxZoom: a tiny route (a 100 m test lap, a track repeat) otherwise fits to
        // building-level zoom where the line is a scribble on one rooftop — clamp to street level.
        return .overview(geometry: LineString(coordinates),
                         geometryPadding: insets,
                         maxZoom: 17)
    }
}

/// One deliberate head-to-finish sweep for the immersive post opener. Smoothstep keeps both ends
/// polished without the old cubic ease-out racing through most of the route in its first instant.
enum RouteMapRevealMotion {
    static let durationS = 1.25

    static func progress(elapsedS: Double) -> Double {
        let t = min(1, max(0, elapsedS / durationS))
        return t * t * (3 - 2 * t)
    }
}
