import Foundation
import CoreLocation
import UIKit

/// Interpolates the athlete's dot between GPS fixes, Strava-style. Fixes land ~1 Hz, but the dot
/// (and its follow camera) should move CONTINUOUSLY — stepping once a second reads as choppy. A
/// `CADisplayLink` chases each new Kalman tip at display cadence and feeds the interpolated position
/// to the Mapbox puck; the follow camera then glides with it, and the trace — which is drawn as the
/// committed smooth curve up to the latest point — grows continuously right at the gliding dot.
///
/// Scope note: this smooths ONLY the displayed dot/camera. The trace line is owned by the view's
/// `RouteSmoothing.LiveSmoother` (centripetal spline) and drawn per fix; the dot rides at its tip.
/// An earlier version also animated the trace tip here, but appending the gliding dot to a tail that
/// already reached the newest point drew a backward hook every fix — the very choppiness we're
/// removing. The line's own smoothing is what keeps it fluid.
///
/// The chase is exponential (`displayed += (target − displayed) · dt·rate`), which converges ~97%
/// within one fix interval — the dot sits only ~0.3 s behind the raw signal and never overshoots.
@MainActor
final class LiveMotionSmoother {
    /// Receives every interpolated position — drives the Mapbox puck (and its follow camera).
    var puckSink: ((CLLocationCoordinate2D) -> Void)?

    private var displayed: CLLocationCoordinate2D?
    private var target: CLLocationCoordinate2D?
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0

    /// Chase rate (s⁻¹): high enough to track a 1 Hz fix stream with ~0.3 s of lag, low enough to
    /// read as a glide rather than a snap.
    private let chaseRate = 3.5
    /// Above this, a jump is a signal glitch/recovery (or first fix), not real movement — snap to it
    /// rather than sliding the dot across the map at an absurd speed. Normal 1 Hz movement is a few
    /// metres, so real running always glides; only teleports snap.
    private let snapMeters = 40.0

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
        // Standing still (paused, red light): the chase has converged — do nothing.
        guard Self.meters(current, target) > 0.05 else { return }
        let f = min(1, dt * chaseRate)
        let next = CLLocationCoordinate2D(
            latitude: current.latitude + (target.latitude - current.latitude) * f,
            longitude: current.longitude + (target.longitude - current.longitude) * f)
        displayed = next
        puckSink?(next)
    }

    private static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
