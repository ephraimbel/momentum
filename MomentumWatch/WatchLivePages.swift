import SwiftUI
import MapKit
import WatchKit

// The four live session pages. Design DNA: Apple Workout's big-type metric stack, Garmin/COROS's
// zone gauge + auto-lap splits, Strava's hold-to-end guard, and a live route map. Monochrome on
// true black; colour only where it carries information (zone colours, HR, energy) or marks live
// progress (the periwinkle accent).

// MARK: - Metrics — the default page: time hero, pace + last lap, distance, zone-coloured HR, energy

struct MetricsPage: View {
    @Bindable var model: WatchCardioModel
    private let unit: DistanceUnit = .auto

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    if model.paused { pausedChip }
                    Text(Formatters.duration(s: model.elapsed))
                        .font(.system(size: 38, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(WatchTheme.ink)
                        .minimumScaleFactor(0.6).lineLimit(1)
                        .contentTransition(.numericText(countsDown: false))
                        .opacity(model.paused ? 0.55 : 1)

                    metric(heroLabel, heroValue, WatchTheme.accent, size: 30, caption: lastLapCaption)
                    heartMetric
                    HStack(alignment: .top, spacing: 12) {
                        metric("Distance", Formatters.distance(meters: model.distanceM, unit: unit),
                               WatchTheme.ink, size: 20)
                        metric("Cal", "\(Int(model.activeEnergyKcal))", WatchTheme.energy, size: 20)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
            }
        }
    }

    private var pausedChip: some View {
        Text("PAUSED")
            .font(.system(size: 11, weight: .bold)).tracking(1.2)
            .foregroundStyle(WatchTheme.accent)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(WatchTheme.accent.opacity(0.18)))
    }

    /// HR line — the heart beats (symbol pulse) and the number wears its zone's colour.
    private var heartMetric: some View {
        let zone = model.currentZone
        let color = zone > 0 ? WatchTheme.zone(zone) : WatchTheme.heart
        return VStack(alignment: .leading, spacing: 1) {
            Text("HEART RATE")
                .font(.system(size: 11, weight: .semibold)).tracking(0.5)
                .foregroundStyle(WatchTheme.inkSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(color)
                    .symbolEffect(.pulse, options: .repeating, isActive: model.heartRateBPM > 0 && !model.paused)
                Text(model.heartRateBPM > 0 ? "\(model.heartRateBPM)" : "--")
                    .font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(color)
                if zone > 0 {
                    Text("Z\(zone)")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(color.opacity(0.8))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heart rate")
        .accessibilityValue("\(model.heartRateBPM) beats per minute\(zone > 0 ? ", zone \(zone)" : "")")
    }

    private func metric(_ label: String, _ value: String, _ color: Color,
                        size: CGFloat, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(label.uppercased())
                    .font(.system(size: 11, weight: .semibold)).tracking(0.5)
                    .foregroundStyle(WatchTheme.inkSecondary)
                if let caption {
                    Text(caption)
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(WatchTheme.inkTertiary)
                }
            }
            Text(value)
                .font(.system(size: size, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(color).minimumScaleFactor(0.7).lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    private var heroLabel: String { model.type.discipline == .cycling ? "Speed" : "Pace" }

    private var heroValue: String {
        let e = model.elapsed, d = model.distanceM
        if model.type.discipline == .cycling {
            return Formatters.speed(ms: e > 0 ? d / e : 0, unit: unit)
        }
        let secPerKm = (d > 0 && e > 0) ? e / (d / 1000) : 0
        return Formatters.pace(secPerKm: secPerKm, unit: unit)
    }

    private var lastLapCaption: String? {
        guard model.lastSplitS > 0 else { return nil }
        let lapLabel = model.splitLengthM > 1200 ? "MI" : "KM"
        return "LAST \(lapLabel) \(Formatters.duration(s: model.lastSplitS))"
    }
}

// MARK: - Zones — Garmin/COROS-style: current-zone hero, five-segment gauge, time-in-zone bars

struct ZonesPage: View {
    @Bindable var model: WatchCardioModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                hero
                gauge
                timeInZoneBars
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
        }
    }

    private var hero: some View {
        let zone = model.currentZone
        let color = zone > 0 ? WatchTheme.zone(zone) : WatchTheme.inkTertiary
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(zone > 0 ? "Z\(zone)" : "--")
                .font(.system(size: 44, weight: .black, design: .rounded)).monospacedDigit()
                .foregroundStyle(color)
                .contentTransition(.numericText())
            VStack(alignment: .leading, spacing: 0) {
                Text(zone > 0 ? model.zones[zone - 1].name : "No signal")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(WatchTheme.ink)
                Text(model.heartRateBPM > 0 ? "\(model.heartRateBPM) BPM" : "waiting for heart rate")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(WatchTheme.inkSecondary)
            }
        }
        .animation(.smooth(duration: 0.5), value: zone)
    }

    /// Five rounded segments; the live one glows, a pointer tracks the exact HR position.
    private var gauge: some View {
        let zone = model.currentZone
        return VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geo in
                let w = geo.size.width
                HStack(spacing: 3) {
                    ForEach(1...5, id: \.self) { i in
                        Capsule()
                            .fill(WatchTheme.zone(i).opacity(i == zone ? 1 : 0.28))
                            .frame(height: i == zone ? 10 : 7)
                    }
                }
                .frame(height: 14, alignment: .center)
                .overlay(alignment: .leading) {
                    if model.heartRateBPM > 0 {
                        Circle()
                            .fill(WatchTheme.ink)
                            .frame(width: 5, height: 5)
                            .offset(x: max(2, min(w - 7, model.zoneFraction * w - 2.5)))
                            .animation(.smooth(duration: 0.8), value: model.zoneFraction)
                    }
                }
            }
            .frame(height: 14)
            .animation(.smooth(duration: 0.5), value: zone)
        }
    }

    /// Where the session has lived — one bar per zone, scaled to the longest.
    private var timeInZoneBars: some View {
        let longest = max(1, model.timeInZone.max() ?? 1)
        return VStack(spacing: 5) {
            ForEach(1...5, id: \.self) { i in
                let t = model.timeInZone[i - 1]
                HStack(spacing: 6) {
                    Text("Z\(i)")
                        .font(.system(size: 11, weight: .bold)).monospacedDigit()
                        .foregroundStyle(WatchTheme.zone(i))
                        .frame(width: 22, alignment: .leading)
                    GeometryReader { geo in
                        Capsule().fill(WatchTheme.surface)
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(WatchTheme.zone(i))
                                    .frame(width: max(t > 0 ? 6 : 0, geo.size.width * t / longest))
                                    .animation(.smooth(duration: 0.8), value: t)
                            }
                    }
                    .frame(height: 6)
                    Text(Formatters.duration(s: t))
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(t > 0 ? WatchTheme.inkSecondary : WatchTheme.inkTertiary)
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - Map — live route on real tiles. Mapbox has no watchOS SDK, so this page (alone) uses
// MapKit; the brand shows in the periwinkle polyline and the pulsing position dot.

struct MapPage: View {
    @Bindable var model: WatchCardioModel
    @State private var camera: MapCameraPosition = .automatic
    @State private var centeredOn: CLLocationCoordinate2D?
    private let unit: DistanceUnit = .auto

    var body: some View {
        Group {
            if let last = model.route.last {
                map(last)
            } else {
                waiting
            }
        }
        .onChange(of: model.route.count) { recenterIfNeeded() }
        .onAppear { recenterIfNeeded() }
    }

    private func map(_ last: CLLocationCoordinate2D) -> some View {
        // Glance-only: the camera follows the runner. Interactive pan/zoom would swallow the
        // vertical-pager drags and fight the crown — reliability of paging wins on the wrist.
        Map(position: $camera, interactionModes: []) {
            if model.route.count > 1 {
                // White casing under the accent core — the route reads luminous on the dark
                // tiles (watchOS has no light/satellite tile variant; brightness lives in our layer).
                MapPolyline(coordinates: model.route)
                    .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 6.5, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: model.route)
                    .stroke(WatchTheme.accent, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
            }
            Annotation("", coordinate: last) { PositionDot(paused: model.paused) }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .overlay(alignment: .bottom) {
            Text(Formatters.distance(meters: model.distanceM, unit: unit))
                .font(.system(size: 14, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(WatchTheme.ink)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(.black.opacity(0.55)))
                .padding(.bottom, 6)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private var waiting: some View {
        VStack(spacing: 8) {
            Image(systemName: model.locationDenied ? "location.slash" : "location.viewfinder")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(model.locationDenied ? WatchTheme.inkSecondary : WatchTheme.accent)
                .symbolEffect(.pulse, options: .repeating, isActive: !model.locationDenied)
            Text(model.locationDenied ? "Location is off" : "Finding GPS…")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(WatchTheme.inkSecondary)
            if model.locationDenied {
                Text("Allow location in Settings to map your route. The workout still records.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(WatchTheme.inkTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 6)
    }

    /// Follow the runner: recenter once they've moved ~30 m from the last camera fix.
    private func recenterIfNeeded() {
        guard let last = model.route.last else { return }
        if let c = centeredOn {
            let moved = CLLocation(latitude: c.latitude, longitude: c.longitude)
                .distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude))
            guard moved > 30 else { return }
        }
        centeredOn = last
        withAnimation(.smooth(duration: 0.8)) {
            camera = .region(MKCoordinateRegion(center: last, latitudinalMeters: 450, longitudinalMeters: 450))
        }
    }
}

/// The live position marker — accent core with a slow breathing halo (static under Reduce Motion).
private struct PositionDot: View {
    var paused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        ZStack {
            Circle()
                .fill(WatchTheme.accent.opacity(0.25))
                .frame(width: 30, height: 30)
                .scaleEffect(breathe ? 1.0 : 0.55)
                .opacity(breathe ? 0.15 : 0.6)
            Circle()
                .fill(WatchTheme.accent)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(.black.opacity(0.6), lineWidth: 2))
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { breathe = true }
        }
        .opacity(paused ? 0.5 : 1)
    }
}

// MARK: - Controls — Pause · Lap on top, hold-to-end (Strava's guard) · water lock below

struct ControlsPage: View {
    @Bindable var model: WatchCardioModel
    let onEnd: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 18) {
                controlButton(model.paused ? "Resume" : "Pause",
                              icon: model.paused ? "play.fill" : "pause.fill",
                              tint: WatchTheme.accent, iconColor: .black) {
                    model.togglePause()
                }
                controlButton("Lap", icon: "arrow.triangle.capsulepath",
                              tint: WatchTheme.control, iconColor: .white) {
                    model.lap()
                }
            }
            HStack(spacing: 18) {
                HoldToEndButton(action: onEnd)
                controlButton("Lock", icon: "drop.fill", tint: WatchTheme.control, iconColor: .white) {
                    WKInterfaceDevice.current().enableWaterLock()
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private func controlButton(_ label: String, icon: String, tint: Color, iconColor: Color,
                               action: @escaping () -> Void) -> some View {
        VStack(spacing: 5) {
            Button(action: action) {
                ZStack {
                    Circle().fill(tint)
                    Image(systemName: icon).font(.system(size: 20, weight: .bold))
                        .foregroundStyle(iconColor)
                }
                .frame(width: 54, height: 54)
            }
            .buttonStyle(.plain)
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(WatchTheme.inkSecondary)
        }
    }
}

/// End needs intent: press and hold ~0.8 s while a white ring sweeps the button (Strava-style).
/// A quick tap just shows the hint.
private struct HoldToEndButton: View {
    let action: () -> Void
    @State private var pressing = false
    @State private var hinting = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().fill(Color(red: 0.95, green: 0.26, blue: 0.3))
                Circle()
                    .trim(from: 0, to: pressing ? 1 : 0)
                    .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(2)
                    .animation(pressing ? .linear(duration: 0.8) : .easeOut(duration: 0.2), value: pressing)
                Image(systemName: "stop.fill").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 54, height: 54)
            .scaleEffect(pressing ? 0.92 : 1)
            .animation(.spring(response: 0.3), value: pressing)
            .onLongPressGesture(minimumDuration: 0.8) {
                WKInterfaceDevice.current().play(.stop)
                action()
            } onPressingChanged: { down in
                pressing = down
                if !down { hinting = true }
            }
            Text(hinting && !pressing ? "hold to end" : "End")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hinting && !pressing ? WatchTheme.ink : WatchTheme.inkSecondary)
                .animation(.smooth(duration: 0.3), value: hinting)
        }
    }
}
