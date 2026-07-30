import Testing
import Foundation
import SwiftData
@testable import Momentum

/// The canonical replay (`GPSDetail.routePoints`) — the ONE reduction behind splits, the post-run
/// charts, the achievement badges, and the record book.
///
/// The regression it exists for: those four sites each summed raw haversine hops between raw stored
/// fixes. GPS jitter makes that sum run long, so the splits contradicted the headline distance and
/// `fastestWindow` reached each benchmark hundreds of metres early — recording a "Fastest 5K"
/// minutes faster than the athlete ran, which `RecordsBook.beats` then defended forever against
/// every genuine record. These tests drive a NOISY trace (a clean one can't tell the two apart,
/// which is exactly why `GPSReplayTests`' noise-free square loop never caught it).
@MainActor
struct RouteReplayTests {

    // A local frame around a fixed origin; ~1 m precision is plenty here.
    let lat0 = 37.79, lon0 = -122.40
    var mPerDegLat: Double { 111_320.0 }
    var mPerDegLon: Double { 111_320.0 * cos(37.79 * .pi / 180) }

    /// Deterministic pseudo-noise — a fixed LCG, so a failure is always reproducible.
    struct Noise {
        var state: UInt64 = 0x5DEECE66D
        mutating func next() -> Double {
            state = 6364136223846793005 &* state &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        /// Correlated (AR-1) position error, the way real GPS drifts rather than sparkling.
        mutating func gauss() -> Double {
            let u1 = Swift.max(next(), 1e-12), u2 = next()
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
    }

    /// A straight 3 m/s run with correlated position error, captured at 1 Hz — fed through the REAL
    /// `GPSProcessor` so the stored samples and the stored distance come from the live path.
    /// Returns the persisted detail plus the ground truth the athlete actually covered.
    func recordRun(seconds: Int, sigma: Double = 5, speed: Double = 3.0,
                   pause: Range<Int>? = nil) -> (gps: GPSDetail, engineM: Double, truthM: Double) {
        var processor = GPSProcessor(config: .forType(.run))
        var noise = Noise()
        let detail = GPSDetail()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let a = exp(-1.0 / 15.0), inn = sigma * (1 - a * a).squareRoot()
        var ex = 0.0, ey = 0.0, travelled = 0.0, truth = 0.0

        for i in 0..<seconds {
            let paused = pause?.contains(i) ?? false
            if !paused { travelled += speed; truth += speed }
            ex = a * ex + inn * noise.gauss()
            ey = a * ey + inn * noise.gauss()
            let fix = GPSProcessor.Fix(
                t: t0.addingTimeInterval(Double(i)),
                lat: lat0 + (travelled + ey) / mPerDegLat,
                lon: lon0 + ex / mPerDegLon,
                accuracyM: sigma, speedMS: paused ? 0 : speed, altitudeM: 10)
            let result = processor.ingest(fix, paused: paused)
            // Mirrors `GPSTrackingEngine` exactly: a paused fix is stored, but not as accepted.
            let sample = LocationSample()
            sample.t = fix.t; sample.lat = fix.lat; sample.lon = fix.lon
            sample.accuracyM = fix.accuracyM; sample.altitudeM = fix.altitudeM; sample.speedMS = fix.speedMS
            sample.accepted = result != .rejected && !paused
            sample.pausedSpan = paused
            detail.samples.append(sample)
        }
        detail.distanceM = processor.distanceM
        return (detail, processor.distanceM, truth)
    }

    /// The headline and the splits must describe the same run. The replay reproduces the engine's
    /// own distance; the raw walk the four call sites used to do runs long by double digits.
    @Test func replayReproducesTheEngineDistanceWhereTheRawWalkInflatesIt() {
        let run = recordRun(seconds: 1_800)
        let replayed = run.gps.routePoints(type: .run).last?.cumulativeM ?? 0

        // Within 1% of what the engine accumulated live and persisted on the row.
        let drift = abs(replayed - run.engineM) / run.engineM
        #expect(drift < 0.01, "replay \(replayed)m vs engine \(run.engineM)m → \(drift * 100)% apart")

        // And the old reducer really was inflating: a raw hop-sum over the same accepted fixes.
        let accepted = run.gps.samples.filter(\.accepted).sorted { $0.t < $1.t }
        var raw = 0.0
        for (a, b) in zip(accepted, accepted.dropFirst()) {
            raw += Geo.distance(lat1: a.lat, lon1: a.lon, lat2: b.lat, lon2: b.lon)
        }
        #expect(raw > run.engineM * 1.05,
                "the fixture must actually exercise jitter: raw \(raw)m vs engine \(run.engineM)m")
    }

    /// A benchmark window may not close early. The raw walk hit "5 km" while the athlete was still
    /// well short of it, which is how a phantom PR gets minted — and `RecordsBook.beats` then keeps
    /// it forever, so no genuine record can ever displace it.
    ///
    /// The assertion is comparative on purpose. What's under test is the reducer, not the capture
    /// engine's absolute accuracy: on a synthetic σ=5 m trace the engine itself measures a few per
    /// cent long (its ±2% bar is stated against real device traces — `GPSReplayTests`), and the
    /// replay tracks the engine by design. The defect was the *gap* between the two.
    @Test func fastestWindowIsNotMintedFromJitter() throws {
        let run = recordRun(seconds: 2_400)          // ~11 min beyond 5 km at 3 m/s
        let truth5K = 5_000.0 / 3.0                  // 27:46

        let corrected = try #require(CardioMetrics.fastestWindow(run.gps.samplePoints(type: .run),
                                                                distanceM: 5_000))
        // The old reducer, verbatim: raw hops between raw accepted fixes, wall-clock axis.
        let accepted = run.gps.samples.filter(\.accepted).sorted { $0.t < $1.t }
        var cumulative = 0.0
        var previous: LocationSample?
        let rawPoints: [CardioMetrics.SamplePoint] = accepted.map { s in
            if let p = previous {
                cumulative += Geo.distance(lat1: p.lat, lon1: p.lon, lat2: s.lat, lon2: s.lon)
            }
            previous = s
            return .init(t: s.t.timeIntervalSince(accepted[0].t), cumulativeM: cumulative)
        }
        let raw = try #require(CardioMetrics.fastestWindow(rawPoints, distanceM: 5_000))

        #expect(raw < corrected - 60,
                "fixture must exercise the defect: raw \(raw)s vs corrected \(corrected)s")
        #expect(corrected > truth5K * 0.90,
                "recorded 5K \(corrected)s vs true \(truth5K)s — impossibly fast")
        #expect(raw < truth5K * 0.90,
                "the raw walk really did record an unreachable time: \(raw)s vs \(truth5K)s")
    }

    /// A pause accrues neither metres nor seconds — the same contract the live engine honours, so
    /// the splits' clock agrees with `durationS` instead of the wall clock.
    @Test func pausedSpansAccrueNeitherDistanceNorTime() throws {
        let run = recordRun(seconds: 1_200, pause: 400..<700)   // 5 minutes standing still
        let points = run.gps.routePoints(type: .run)
        let last = try #require(points.last)

        // 1200 s of wall clock, 300 s of it paused ⇒ ~900 s of moving time.
        #expect(abs(last.t - 900) < 5, "moving time \(last.t)s should exclude the 300 s pause")
        // And the stationary wander during the pause contributed no distance.
        let drift = abs(last.cumulativeM - run.engineM) / Swift.max(run.engineM, 1)
        #expect(drift < 0.01, "replay \(last.cumulativeM)m vs engine \(run.engineM)m")
    }

    /// Splits are derived from that same replay, so they add up to the run they describe.
    @Test func splitsSumToTheHeadlineDistanceAndDuration() throws {
        let run = recordRun(seconds: 1_800)
        let splits = run.gps.kilometreSplits(type: .run)
        #expect(splits.count >= 4)

        let summed = splits.reduce(0.0) { $0 + $1.distanceM }
        let replayed = run.gps.routePoints(type: .run).last?.cumulativeM ?? 0
        #expect(abs(summed - replayed) < 2, "splits sum \(summed)m vs total \(replayed)m")

        let time = splits.reduce(0.0) { $0 + $1.durationS }
        let movingS = run.gps.routePoints(type: .run).last?.t ?? 0
        #expect(abs(time - movingS) < 2, "splits time \(time)s vs moving time \(movingS)s")
    }

    /// Persisted rows win when present; a run recorded before splits were written (or imported,
    /// with no samples at all) still answers rather than reporting "no splits" forever.
    @Test func splitResultsFallBackToComputingWhenNothingWasPersisted() {
        let run = recordRun(seconds: 1_200)
        #expect(run.gps.splits.isEmpty)
        #expect(!run.gps.splitResults(type: .run).isEmpty)

        let persisted = Split()
        persisted.index = 0; persisted.distanceM = 1_000; persisted.durationS = 333
        run.gps.splits.append(persisted)
        let read = run.gps.splitResults(type: .run)
        #expect(read.count == 1 && read.first?.durationS == 333)
    }
}
