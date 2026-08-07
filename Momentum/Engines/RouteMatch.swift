import Foundation

/// Did this run retrace a route the athlete has run before?
///
/// The post-run verdict could only ever compare runs of a *similar distance* — a proxy so loose that
/// two 5Ks on different terrain ranked against each other as if they were the same test. Runners
/// don't experience it that way: they have a Tuesday loop and a river out-and-back, and the question
/// they actually ask at the finish is "how did that go *for this route*". This answers it.
///
/// **The method.** Each trace is reduced to the set of ~`cellMeters` grid cells its fixes fall in —
/// the route's footprint, stripped of speed, direction and start point. Two runs are the same route
/// when each one's footprint is almost entirely contained in the other's, *and* their distances
/// agree. Both halves matter:
///  • Mutual containment (not one-sided) stops a 3 km leg of a 10 km run from "matching" the 3 km run.
///  • The distance gate stops an out-and-back from matching the one-way version of itself, which
///    covers exactly the same streets and is emphatically not the same test.
///
/// Comparison is deliberately **direction-agnostic**: a loop run clockwise and anticlockwise is the
/// same route, and a runner would be surprised to be told otherwise.
///
/// **Why containment is measured against a dilated set.** Two runs down the same street land their
/// fixes a few metres apart, which straddles a cell boundary perhaps a fifth of the time. Testing
/// each cell against the *other* footprint's 3×3 neighbourhood absorbs that jitter without widening
/// the match to the next street over: at 40 m cells the effective tolerance is 40–80 m, which is
/// narrower than a city block.
///
/// Pure and CoreLocation-free, like the other engines — every branch is fixture-testable.
enum RouteMatch {

    /// Grid resolution. Chosen against GPS reality rather than taste: accepted fixes carry
    /// ≤25 m horizontal accuracy (PRD §20), so a cell must be wider than the noise or the same
    /// street scatters across cells — and narrower than a city block or parallel streets merge.
    static let cellMeters = 40.0

    /// The fraction of one route's cells that must fall inside the other's (dilated) footprint,
    /// in *both* directions, for the two to be the same route. 0.6 tolerates the ordinary
    /// differences between two runs of one route — a crossing taken on the other side, a block cut
    /// short at the end, a lap ended a little early — while a genuinely different route through the
    /// same neighbourhood lands far below it.
    static let minCoverage = 0.6

    /// Distances must agree within this fraction. Shares the intent of `RunVerdict`'s own tolerance
    /// but is tighter: once the footprints already coincide, a fifth of the distance in difference
    /// means a lap more or a leg cut, which is a different session.
    static let distanceTolerance = 0.2

    /// Floors below which a footprint is too small to identify anything. A 300 m walk to the shop
    /// occupies a handful of cells that half the athlete's runs pass through.
    static let minCells = 10
    static let minDistanceM = 500.0

    /// Start and finish within this far of each other reads as a loop — used only to pick the right
    /// noun ("this loop" vs "this route"), never to decide a match.
    static let loopClosureM = 250.0

    /// Metres per degree of latitude. Constant enough at any latitude for a grid this coarse.
    private static let metersPerDegLat = 111_320.0

    /// One cell of the shared grid. Integer coordinates, so equality is exact and hashing is cheap.
    struct Cell: Hashable, Sendable {
        let i: Int
        let j: Int
    }

    /// A route reduced to what a comparison needs: where it went, how far, and whether it closed.
    struct Signature: Sendable, Equatable {
        let cells: Set<Cell>
        let distanceM: Double
        let isLoop: Bool

        /// Whether this footprint is substantial enough to identify a route at all.
        var isUsable: Bool { cells.count >= minCells && distanceM >= minDistanceM }
    }

    // MARK: - Building

    /// The latitude every signature in one comparison must be anchored on.
    ///
    /// **This is load-bearing, not a detail.** Longitude degrees shrink with latitude, so the grid's
    /// longitude step is derived from a cosine. Deriving it from each run's *own* mean latitude
    /// would give two runs of the same route infinitesimally different steps — and since the cell
    /// index is `lon / step` at a longitude near ±100, a relative difference of one part in 10⁵
    /// shifts the index by whole cells and the two footprints stop overlapping at all. So the caller
    /// takes this once, from the run being judged, and builds *every* signature with it.
    static func referenceLat(_ coords: [GeoPoint]) -> Double {
        guard !coords.isEmpty else { return 0 }
        return coords.reduce(0) { $0 + $1.lat } / Double(coords.count)
    }

    /// Reduce a trace to its footprint. `distanceM` comes from the caller's canonical reducer
    /// (`GPSDetail.distanceM`) rather than being re-derived here — the app has exactly one distance
    /// number per run and a second opinion computed off raw fixes would disagree with every screen.
    static func signature(coords: [GeoPoint], distanceM: Double, referenceLat: Double) -> Signature {
        guard !coords.isEmpty else {
            return Signature(cells: [], distanceM: distanceM, isLoop: false)
        }
        let latDeg = cellMeters / metersPerDegLat
        let lonDeg = cellMeters / (metersPerDegLat * max(0.01, cos(referenceLat * .pi / 180)))

        var cells = Set<Cell>()
        cells.reserveCapacity(coords.count / 4)
        for c in coords {
            cells.insert(Cell(i: Int((c.lat / latDeg).rounded()),
                              j: Int((c.lon / lonDeg).rounded())))
        }
        let closed = (coords.first.flatMap { f in coords.last.map { f.distance(to: $0) } } ?? .infinity) <= loopClosureM
        return Signature(cells: cells, distanceM: distanceM, isLoop: closed)
    }

    // MARK: - Comparing

    /// Every cell of `cells` plus its 8 neighbours — the tolerance band a containment test is
    /// measured against.
    static func dilated(_ cells: Set<Cell>) -> Set<Cell> {
        var out = Set<Cell>()
        out.reserveCapacity(cells.count * 9)
        for c in cells {
            for di in -1...1 {
                for dj in -1...1 {
                    out.insert(Cell(i: c.i + di, j: c.j + dj))
                }
            }
        }
        return out
    }

    /// The fraction of `cells` that falls inside `band` (an already-dilated footprint). 0 when
    /// there is nothing to measure — an empty route is not "fully contained" in anything.
    static func coverage(of cells: Set<Cell>, within band: Set<Cell>) -> Double {
        guard !cells.isEmpty else { return 0 }
        return Double(cells.filter { band.contains($0) }.count) / Double(cells.count)
    }

    /// Are these two runs the same route? Both signatures must be usable, their distances must
    /// agree, and each footprint must sit inside the other's tolerance band.
    static func matches(_ a: Signature, _ b: Signature) -> Bool {
        matches(a, band: dilated(a.cells), against: b)
    }

    /// `matches` with one side's tolerance band supplied. A caller testing today's run against a
    /// whole history dilates today's footprint once here instead of once per prior run, and shares
    /// this exact code path so the two forms can never drift apart.
    static func matches(_ a: Signature, band: Set<Cell>, against b: Signature) -> Bool {
        guard a.isUsable, b.isUsable else { return false }
        guard withinDistanceTolerance(a.distanceM, b.distanceM) else { return false }
        guard coverage(of: b.cells, within: band) >= minCoverage else { return false }
        return coverage(of: a.cells, within: dilated(b.cells)) >= minCoverage
    }

    /// The distance half of `matches`, split out so a caller can reject most of a history before
    /// paying to materialise any geometry at all.
    static func withinDistanceTolerance(_ a: Double, _ b: Double) -> Bool {
        let span = max(a, b)
        guard span > 0 else { return false }
        return abs(a - b) <= span * distanceTolerance
    }
}

// MARK: - Adapter

/// The thin adapter layer that feeds the pure matcher from stored workouts, mirroring how
/// `PaceInsights` splits its classifier from its gatherer. Not `@MainActor` (2026-08-06): the
/// summary's record/verdict analysis moved to a background context so the post-run screen stops
/// freezing after first paint, and this adapter walks the same models — the caller owns the
/// isolation by owning the `ModelContext` its workouts came from.
extension RouteMatch {

    /// The trace a footprint is built from: the athlete's own **accepted raw fixes**.
    ///
    /// Deliberately not `routeCoordinates`, which prefers the map-matched line when one exists.
    /// Matching is a comparison between two runs, and snapping one of them to the road network
    /// while leaving the other raw would move one footprint relative to the other for reasons that
    /// have nothing to do with where the athlete went. Raw on both sides is the honest comparison.
    ///
    /// A run with no stored fixes (an Apple Health import, which carries a summary and no trace)
    /// therefore has no footprint and never matches. That is correct: no geometry, no claim.
    ///
    /// **Sorted by timestamp, and that is not cosmetic.** SwiftData hands a to-many relationship
    /// back in no particular order on a refetch. The cell *set* does not care, but `isLoop` reads
    /// the first and last fix, so on an unordered array the same run decided it was a loop or a
    /// route at random and the verdict changed nouns between one launch and the next. Caught on the
    /// simulator, where a route best read "this loop" and the outing after it read "this route"
    /// over identical geometry.
    static func trace(_ gps: GPSDetail) -> [GeoPoint] {
        gps.samples.filter(\.accepted).sorted { $0.t < $1.t }.map { GeoPoint(lat: $0.lat, lon: $0.lon) }
    }

    /// Earlier runs over the same route as `workout`, packaged for `RunVerdict`, or nil when this
    /// run has no usable footprint or nothing in the history retraces it.
    ///
    /// `priors` may be handed over unfiltered — anything on or after `workout`, of another
    /// discipline, or without geometry is discarded here.
    static func context(for workout: Workout, gps: GPSDetail,
                        priors: [Workout]) -> RunVerdict.RouteContext? {
        let todayTrace = trace(gps)
        guard todayTrace.count > 1 else { return nil }
        let ref = referenceLat(todayTrace)
        let today = signature(coords: todayTrace, distanceM: gps.distanceM, referenceLat: ref)
        guard today.isUsable else { return nil }
        // Dilated once, not once per prior run: this is the loop that runs over a whole history.
        let todayBand = dilated(today.cells)

        var runs: [RunVerdict.Run] = []
        for w in priors {
            guard w.startedAt < workout.startedAt, w.type == workout.type,
                  let g = w.gps, g.distanceM > 0,
                  // Cheapest gate first: distance needs no geometry and rejects most of a history
                  // before we fault a single sample relationship.
                  withinDistanceTolerance(today.distanceM, g.distanceM) else { continue }
            let pts = trace(g)
            guard pts.count > 1 else { continue }
            // Same reference latitude as today's, or the two grids do not line up. See `referenceLat`.
            let sig = signature(coords: pts, distanceM: g.distanceM, referenceLat: ref)
            guard matches(today, band: todayBand, against: sig) else { continue }
            runs.append(RunVerdict.Run(date: w.startedAt, distanceM: g.distanceM,
                                       durationS: w.durationS, avgHR: g.avgHR))
        }
        guard !runs.isEmpty else { return nil }
        return RunVerdict.RouteContext(priors: runs, isLoop: today.isLoop)
    }
}
