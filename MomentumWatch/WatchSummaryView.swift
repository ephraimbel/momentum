import SwiftUI
import MapKit
import CoreLocation

/// The finish moment (Runna's best idea): an iridescent ring draws itself closed around a check,
/// the earned stats sit in a clean grid, the route sits on a real map fitted to the run, and the
/// splits tell the story lap by lap. Iridescence here is *earned* — the workout is done.
struct WatchSummaryView: View {
    let model: WatchCardioModel
    let onDone: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ringDrawn = false
    private let unit: DistanceUnit = .auto

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 12) {
                header
                if model.route.count > 1 {
                    SummaryMap(route: model.route)
                        .frame(height: 104)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                statsGrid.id("stats")
                if !model.splits.isEmpty { splitsSection }
                Button(action: onDone) {
                    Text("Done")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(WatchTheme.accent)
                .foregroundStyle(.black)
                Text("Saved to Apple Health")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(WatchTheme.inkTertiary)
                    .id("end")
            }
            .padding(.bottom, 6)
        }
        .navigationBarBackButtonHidden(true)
        .onAppear {
            if reduceMotion { ringDrawn = true }
            else { withAnimation(.easeOut(duration: 0.9).delay(0.15)) { ringDrawn = true } }
            #if DEBUG
            // Sim verification: `--watch-scroll=stats|bottom` jumps down the summary
            // (crown/swipe input is unreliable on the watch sim).
            if ProcessInfo.processInfo.arguments.contains("--watch-scroll=bottom") {
                proxy.scrollTo("end", anchor: .bottom)
            } else if ProcessInfo.processInfo.arguments.contains("--watch-scroll=stats") {
                proxy.scrollTo("stats", anchor: .top)
            }
            #endif
        }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(WatchTheme.surface, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: ringDrawn ? 1 : 0)
                    .stroke(WatchTheme.iridescentAngular, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .black))
                    .foregroundStyle(WatchTheme.ink)
                    .opacity(ringDrawn ? 1 : 0)
                    .scaleEffect(ringDrawn ? 1 : 0.6)
            }
            .frame(width: 56, height: 56)
            Text("\(model.type.title) complete")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(WatchTheme.ink)
        }
        .padding(.top, 2)
    }

    private var statsGrid: some View {
        let isRide = model.type.discipline == .cycling
        let e = model.elapsed, d = model.distanceM
        let paceValue: String = {
            if isRide { return Formatters.speed(ms: e > 0 ? d / e : 0, unit: unit) }
            let secPerKm = (d > 0 && e > 0) ? e / (d / 1000) : 0
            return Formatters.pace(secPerKm: secPerKm, unit: unit)
        }()
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            stat("Time", Formatters.duration(s: e))
            stat("Distance", Formatters.distance(meters: d, unit: unit))
            stat(isRide ? "Avg Speed" : "Avg Pace", paceValue)
            stat("Calories", "\(Int(model.activeEnergyKcal))")
            stat("Avg HR", model.avgHR > 0 ? "\(model.avgHR)" : "--")
            stat("Max HR", model.maxObservedHR > 0 ? "\(model.maxObservedHR)" : "--")
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold)).tracking(0.5)
                .foregroundStyle(WatchTheme.inkSecondary)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(WatchTheme.ink)
                .minimumScaleFactor(0.7).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7).padding(.horizontal, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WatchTheme.surface))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    /// Lap-by-lap bars, fastest lap in the accent — the Garmin splits table, watch-sized.
    private var splitsSection: some View {
        let lapLabel = model.splitLengthM > 1200 ? "MI" : "KM"
        let fastest = model.splits.min() ?? 0
        let slowest = max(model.splits.max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 5) {
            Text("SPLITS")
                .font(.system(size: 10, weight: .semibold)).tracking(0.8)
                .foregroundStyle(WatchTheme.inkSecondary)
            ForEach(Array(model.splits.enumerated()), id: \.offset) { i, s in
                let isFastest = s == fastest && model.splits.count > 1
                HStack(spacing: 6) {
                    Text("\(lapLabel) \(i + 1)")
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(WatchTheme.inkSecondary)
                        .frame(width: 36, alignment: .leading)
                    GeometryReader { geo in
                        Capsule()
                            .fill(isFastest ? AnyShapeStyle(WatchTheme.iridescent) : AnyShapeStyle(WatchTheme.surfaceStrong))
                            .frame(width: max(8, geo.size.width * s / slowest))
                    }
                    .frame(height: 7)
                    Text(Formatters.duration(s: s))
                        .font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(isFastest ? WatchTheme.accent : WatchTheme.ink)
                        .frame(width: 42, alignment: .trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The finished route on real tiles — camera fitted to the whole run, spline-smoothed polyline in
/// the brand accent, start dot (white) and finish dot (accent). The trace DRAWS ITSELF over ~1.6 s
/// when the summary lands (the onboarding's self-drawing-route motion, brought to the finish
/// line); Reduce Motion shows it complete. Static camera: the crown keeps scrolling the summary.
/// (MapKit — Mapbox has no watchOS SDK.)
private struct SummaryMap: View {
    let line: [CLLocationCoordinate2D]
    let region: MKCoordinateRegion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawnCount = 2

    init(route: [CLLocationCoordinate2D]) {
        // Smoothing multiplies point count ~6× — skip it for very long routes; raw is fine there.
        line = route.count > 800 ? route : RouteSmoothing.smooth(route)
        let lats = route.map(\.latitude), lons = route.map(\.longitude)
        let minLat = lats.min() ?? 0, maxLat = lats.max() ?? 0
        let minLon = lons.min() ?? 0, maxLon = lons.max() ?? 0
        region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                           longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.4, 0.003),
                                   longitudeDelta: max((maxLon - minLon) * 1.4, 0.003)))
    }

    private var drawnLine: [CLLocationCoordinate2D] {
        Array(line.prefix(max(2, min(drawnCount, line.count))))
    }

    var body: some View {
        Map(initialPosition: .region(region), interactionModes: []) {
            if drawnLine.count > 1 {
                MapPolyline(coordinates: drawnLine)
                    .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 5.5, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: drawnLine)
                    .stroke(WatchTheme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            if let start = line.first {
                Annotation("", coordinate: start) {
                    Circle().fill(.white).frame(width: 7, height: 7)
                        .overlay(Circle().stroke(.black.opacity(0.5), lineWidth: 1.5))
                }
            }
            if let end = line.last, drawnCount >= line.count {
                Annotation("", coordinate: end) {
                    Circle().fill(WatchTheme.accent).frame(width: 9, height: 9)
                        .overlay(Circle().stroke(.black.opacity(0.6), lineWidth: 1.5))
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .accessibilityLabel("Route map")
        .task {
            guard !reduceMotion, line.count > 2 else { drawnCount = line.count; return }
            // ~1.6 s draw at 25 fps, eased by stepping more points per frame toward the end.
            let frames = 40
            for f in 1...frames {
                let t = Double(f) / Double(frames)
                let eased = 1 - pow(1 - t, 2.2)
                drawnCount = max(2, Int(eased * Double(line.count)))
                try? await Task.sleep(for: .milliseconds(40))
                if Task.isCancelled { return }
            }
            drawnCount = line.count
        }
    }
}
