import SwiftUI
import MapboxMaps
import CoreLocation

/// A Mapbox map with an iridescent route that **draws itself** — momentum's Strava-style motif, shared
/// by the welcome screen and the "building your plan" beat. The map fades in, a slow dolly frames the
/// loop, and an organic GPS-like path traces across it with an eased pen and a glowing comet head that
/// lands with a pop. A whisper-quiet live distance ticks up as it draws. It's a brand visual (not the
/// user's real route — location stays deferred). Honors Reduce Motion (static full route, no fly/draw).
/// Callers add their own scrim/overlay; `onComplete` fires when the draw + settle finishes.
struct RouteDrawMap: View {
    /// Show the live distance readout (the "this is a fitness app" signal). Off for embedded beats.
    var showsStats: Bool = false
    /// Called once the route has finished drawing and the head has landed — lets the caller time a handoff.
    var onComplete: (() -> Void)? = nil

    @State private var viewport: Viewport
    @State private var drawProgress = 0.0     // 0…1, eased; maps to how much of the path is drawn
    @State private var mapIn = false
    @State private var headPulse = false
    @State private var landed = false         // head "arrives" pop once the path completes
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let route: [CLLocationCoordinate2D]
    private let cumDist: [Double]             // cumulative metres along the route, for the live readout
    private let drawDuration = 2.6

    init(showsStats: Bool = false, onComplete: (() -> Void)? = nil) {
        self.showsStats = showsStats
        self.onComplete = onComplete
        let r = RouteDrawMap.makeRoute()
        self.route = r
        self.cumDist = RouteDrawMap.cumulativeDistances(r)
        // Open on a wide establishing frame; begin() dollies in to the full loop as it draws.
        _viewport = State(initialValue: .overview(geometry: LineString(r),
            geometryPadding: EdgeInsets(top: 130, leading: 130, bottom: 130, trailing: 130)))
    }

    /// Tight frame that snugly fits the loop — the dolly-in target.
    private var tightViewport: Viewport {
        .overview(geometry: LineString(route),
                  geometryPadding: EdgeInsets(top: 56, leading: 56, bottom: 56, trailing: 56))
    }

    private var shownCount: Int {
        max(2, min(route.count, Int((drawProgress * Double(route.count)).rounded())))
    }
    private var drawn: [CLLocationCoordinate2D] { Array(route.prefix(shownCount)) }
    private var comet: [CLLocationCoordinate2D] { Array(drawn.suffix(14)) } // brighter leading segment
    private var head: CLLocationCoordinate2D? { drawn.last }
    private var liveMeters: Double { cumDist[min(cumDist.count - 1, max(0, shownCount - 1))] }

    private var iridescent: LinearGradient {
        LinearGradient(colors: Theme.iridescent, startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        Map(viewport: $viewport) {
            // Soft white halo under the line so the iridescent route reads as glowing on the light map.
            PolylineAnnotation(lineCoordinates: drawn)
                .lineColor(StyleColor(UIColor.white.withAlphaComponent(0.5))).lineWidth(12).lineJoin(.round)
            PolylineAnnotation(lineCoordinates: drawn)
                .lineColor(StyleColor(UIColor(Theme.iridescent[0]))).lineWidth(6).lineJoin(.round)
            // Comet: a brighter white-cored streak trailing the head gives the draw direction + energy.
            PolylineAnnotation(lineCoordinates: comet)
                .lineColor(StyleColor(UIColor.white.withAlphaComponent(0.65))).lineWidth(8).lineJoin(.round)
            PolylineAnnotation(lineCoordinates: comet)
                .lineColor(StyleColor(UIColor(Theme.iridescent[2]))).lineWidth(4).lineJoin(.round)
            if let head {
                MapViewAnnotation(coordinate: head) { headDot }.allowOverlap(true)
            }
        }
        .mapStyle(MapStyleOption.standard.mapboxStyle)
        .ornamentOptions(MapChrome.hidden)
        .allowsHitTesting(false)
        .opacity(mapIn ? 1 : 0)
        .overlay(alignment: .bottom) { if showsStats { statsPill } }
        .onAppear(perform: begin)
        .accessibilityHidden(true)
    }

    private var headDot: some View {
        let dot = ZStack {
            Circle().fill(.white).frame(width: 18, height: 18)
                .shadow(color: Theme.iridescent[0].opacity(0.9), radius: 8)
            Circle().fill(iridescent).frame(width: 10, height: 10)
        }
        // Breathing pulse while drawing; a spring "pop" layered on top when the path lands.
        return dot
            .scaleEffect(headPulse ? 1.1 : 0.9)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: headPulse)
            .scaleEffect(landed ? 1.5 : 1)
            .animation(.spring(response: 0.45, dampingFraction: 0.5), value: landed)
    }

    /// Live distance — tabular figures on a frosted pill. The single "real fitness data" cue.
    private var statsPill: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(String(format: "%.2f", liveMeters / 1000))
                .font(.display(Theme.FontSize.headline, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
            Text("km")
                .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .momentumGlass()
        .opacity(mapIn ? 1 : 0)
        .padding(.bottom, 132)
    }

    private func begin() {
        withAnimation(.easeOut(duration: 0.6)) { mapIn = true }
        headPulse = true

        guard !reduceMotion else {
            drawProgress = 1
            viewport = tightViewport
            landed = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.6))
                onComplete?()
            }
            return
        }

        Task { @MainActor in
            // Pre-warm: hold on the establishing frame so MapKit can stream street tiles before the
            // route draws — otherwise a cold first launch traces the line over a blank grid.
            try? await Task.sleep(for: .seconds(0.5))

            // Slow dolly from the wide establishing frame to the full loop, finishing as the path does.
            withAnimation(.easeInOut(duration: drawDuration + 0.5)) {
                viewport = tightViewport
            }
            // Frame-stepped pen: advance `drawProgress` every frame so the polyline visibly *extends*
            // around the lake. A single `withAnimation` can't tween this — it slices the coordinate
            // array (a structural change), so it would pop to the full loop instead of drawing.
            let start = Date()
            while true {
                let t = min(1, Date().timeIntervalSince(start) / drawDuration)
                drawProgress = 1 - pow(1 - t, 3)            // ease-out: quick start, glide into the finish
                if t >= 1 { break }
                try? await Task.sleep(for: .seconds(1.0 / 60.0))
            }
            drawProgress = 1
            landed = true                                   // arrival pop on the head
            try? await Task.sleep(for: .seconds(0.45))      // let it settle before the handoff
            onComplete?()
        }
    }

    // MARK: Route + camera geometry

    /// The **Lady Bird Lake** hike-and-bike loop, Austin TX (~10-mile town-lake loop) — hand-traced
    /// shoreline waypoints, west (Mopac/Pfluger) along the north bank to Longhorn Dam and back along the
    /// south bank, smoothed with Catmull-Rom so it flows like a real GPS trace. The overview viewport
    /// frames the lake automatically. No location needed; it's a brand visual.
    static func makeRoute() -> [CLLocationCoordinate2D] {
        // Dense hand-trace of the trail (not the lake outline): the north bank west→east to Longhorn
        // Dam, across the dam, then the south bank (Boardwalk, Auditorium Shores) back to MoPac. Enough
        // points that the light Catmull-Rom rounds turns without collapsing the loop into an oval.
        let waypoints: [(lat: Double, lon: Double)] = [
            // North bank, west→east: MoPac, along the shore past the downtown bridges, then the lake
            // bends south-east toward Longhorn Dam. The banks stay ~300 m apart (a thin ribbon), so this
            // hugs the trail instead of ballooning into a loop around downtown.
            (30.2655, -97.7856),  // MoPac (Loop 1) bridge — north, west end
            (30.2650, -97.7818),
            (30.2645, -97.7780),
            (30.2640, -97.7740),
            (30.2635, -97.7700),
            (30.2632, -97.7660),
            (30.2630, -97.7620),  // Lamar bridge
            (30.2627, -97.7580),
            (30.2624, -97.7542),  // Pfluger / South 1st
            (30.2619, -97.7500),
            (30.2614, -97.7470),  // Congress Ave bridge — north
            (30.2606, -97.7440),
            (30.2594, -97.7408),
            (30.2578, -97.7376),
            (30.2560, -97.7344),  // lake bends south-east
            (30.2539, -97.7311),
            (30.2517, -97.7278),
            (30.2494, -97.7242),
            (30.2474, -97.7202),
            (30.2459, -97.7160),
            (30.2450, -97.7124),  // Longhorn Dam — east end, north side
            (30.2442, -97.7116),  // cross the dam to the south bank
            // South bank, east→west back to MoPac.
            (30.2446, -97.7152),
            (30.2456, -97.7192),  // Boardwalk — the over-water SE stretch
            (30.2472, -97.7232),
            (30.2491, -97.7268),
            (30.2512, -97.7302),
            (30.2533, -97.7336),
            (30.2553, -97.7370),
            (30.2569, -97.7402),  // Congress Ave bridge — south
            (30.2580, -97.7438),
            (30.2585, -97.7478),  // Auditorium Shores
            (30.2588, -97.7520),
            (30.2591, -97.7562),
            (30.2596, -97.7606),
            (30.2604, -97.7652),  // Lou Neff Point
            (30.2616, -97.7702),
            (30.2632, -97.7754),
            (30.2648, -97.7808),
            (30.2655, -97.7856),  // close the loop at MoPac
        ]
        let pts = catmullRom(waypoints.map { ($0.lat, $0.lon) }, subdivisions: 4)
        return pts.map { CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1) }
    }

    /// Smooth an open polyline through its points (Catmull-Rom), so straight-ish segments flow into
    /// rounded turns the way a run tracked on roads/paths does.
    private static func catmullRom(_ p: [(Double, Double)], subdivisions: Int) -> [(Double, Double)] {
        guard p.count >= 3 else { return p }
        var out: [(Double, Double)] = []
        for i in 0..<(p.count - 1) {
            let p0 = p[max(0, i - 1)], p1 = p[i], p2 = p[i + 1], p3 = p[min(p.count - 1, i + 2)]
            for s in 0..<subdivisions {
                let t = Double(s) / Double(subdivisions), t2 = t * t, t3 = t2 * t
                let x = 0.5 * (2 * p1.0 + (-p0.0 + p2.0) * t + (2 * p0.0 - 5 * p1.0 + 4 * p2.0 - p3.0) * t2 + (-p0.0 + 3 * p1.0 - 3 * p2.0 + p3.0) * t3)
                let y = 0.5 * (2 * p1.1 + (-p0.1 + p2.1) * t + (2 * p0.1 - 5 * p1.1 + 4 * p2.1 - p3.1) * t2 + (-p0.1 + 3 * p1.1 - 3 * p2.1 + p3.1) * t3)
                out.append((x, y))
            }
        }
        out.append(p[p.count - 1])
        return out
    }

    /// Cumulative metres along the route, so the live readout reflects believable run distance.
    private static func cumulativeDistances(_ coords: [CLLocationCoordinate2D]) -> [Double] {
        guard coords.count > 1 else { return [0] }
        var out = [0.0]; out.reserveCapacity(coords.count)
        for i in 1..<coords.count {
            let a = CLLocation(latitude: coords[i - 1].latitude, longitude: coords[i - 1].longitude)
            let b = CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
            out.append(out[i - 1] + b.distance(from: a))
        }
        return out
    }

}
