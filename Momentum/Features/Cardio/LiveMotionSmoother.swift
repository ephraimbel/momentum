import Foundation
import CoreLocation
import MapboxMaps
import UIKit

/// Interpolates the live run's motion between GPS fixes, Strava-style. Fixes land ~1 Hz, but the
/// athlete's dot, the trace tip, and the follow camera should move CONTINUOUSLY — stepping once a
/// second reads as choppy. A display link chases each new Kalman tip at display cadence, feeding
/// the interpolated position to the Mapbox puck (whose follow camera then glides with it) and
/// extending the trace tail's tip vertex to the gliding dot, so the line stays pinned to "you"
/// instead of lurching forward per fix.
///
/// The chase is exponential (`displayed += (target − displayed) · dt·rate`), which converges ~97%
/// within one fix interval — the dot sits only ~0.3 s behind the raw signal and never overshoots.
@MainActor
final class LiveMotionSmoother {
    /// Receives every interpolated position — drives the Mapbox puck (and its follow camera).
    var puckSink: ((CLLocationCoordinate2D) -> Void)?
    /// The committed smoothed tail from `RouteSmoothing.LiveSmoother`; the animated tip extends its
    /// last point. Replaced by the view on every ingested fix.
    var tailBase: [CLLocationCoordinate2D] = []
    /// The live map, for per-frame tail-tip updates. Weak — the map view owns its lifetime.
    weak var map: MapboxMap?

    private var displayed: CLLocationCoordinate2D?
    private var target: CLLocationCoordinate2D?
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var tailParity = false

    /// Chase rate (s⁻¹): high enough to track a 1 Hz fix stream with ~0.3 s of lag, low enough to
    /// read as a glide rather than a snap.
    private let chaseRate = 3.5
    /// A jump this large is a signal restart (first fix, recovery, long background), not movement —
    /// snap to it instead of gliding the dot across the map.
    private let snapMeters = 150.0

    /// New filtered position from the engine (~per accepted fix).
    func push(lat: Double, lon: Double) {
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        if displayed == nil || Self.meters(displayed!, coord) > snapMeters {
            displayed = coord
            puckSink?(coord)
        }
        target = coord
        startIfNeeded()
    }

    /// Invalidate the display link (breaks its retain of self). Call when the run screen leaves.
    func stop() {
        link?.invalidate()
        link = nil
    }

    private func startIfNeeded() {
        guard link == nil else { return }
        lastTick = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        guard let current = displayed, let target else { return }
        let now = CACurrentMediaTime()
        // Clamp dt: after a background stretch (display link paused) a raw dt would slingshot.
        let dt = min(now - lastTick, 0.1)
        lastTick = now
        // Standing still (paused, red light): the chase has converged — skip all map work.
        guard Self.meters(current, target) > 0.05 else { return }
        let f = min(1, dt * chaseRate)
        let next = CLLocationCoordinate2D(
            latitude: current.latitude + (target.latitude - current.latitude) * f,
            longitude: current.longitude + (target.longitude - current.longitude) * f)
        displayed = next
        puckSink?(next)
        // The trace tip re-renders at half display cadence (~30 fps) — indistinguishable for line
        // growth, half the source-update work.
        tailParity.toggle()
        if tailParity { renderTail(tip: next) }
    }

    /// Replace the live tail with base + the gliding tip, so the trace draws continuously into the
    /// dot. Same feature id the per-fix sync uses ("trace-tail") — last write wins, geometry agrees.
    private func renderTail(tip: CLLocationCoordinate2D) {
        guard let map, map.isStyleLoaded, map.sourceExists(withId: "trace-src"),
              !tailBase.isEmpty else { return }
        var feature = MapboxMaps.Feature(geometry: .lineString(LineString(tailBase + [tip])))
        feature.identifier = .string("trace-tail")
        map.updateGeoJSONSourceFeatures(forSourceId: "trace-src", features: [feature])
    }

    private static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
