import Foundation
#if DEBUG
import os
#endif

/// Real, street- and trail-following loops for the seeded community's posts — fetched once from the
/// Mapbox Directions API by `scripts/fetch_community_routes.py` and bundled as
/// `Resources/CommunityRoutes.json`. Deterministic at runtime: the app only picks among bundled
/// variants, never the network.
///
/// **Each loop knows where it starts (2026-09-07).** A loop ships with the `anchor` it was drawn
/// around — a real town or park from `CommunityPlaces` — so an athlete gets a loop from their own
/// neighbourhood. Until this the bundle held one downtown pin per metro and every loop radiated
/// from it, so all ~44 seeded athletes of a metro traced the same city-centre streets, including
/// the two thirds of them who say they live in a suburb or a commuter town. `pools(city:near:)` is
/// the whole fix: it keeps the loops anchored near a given home and hands back the rest only when
/// nothing is close.
///
/// **Three kinds.** `run` (walking profile — sidewalks, paths, greenways), `ride` (cycling), and
/// `trail`, anchored on parks and nature reserves, which is what a trail run finally draws instead
/// of being forced mapless.
///
/// **The bundle is length-first, geometry-on-demand.** The session ledger asks for lengths while it
/// folds ~2,900 careers but never needs a polyline — a tile's geometry matters only when that tile
/// is about to be drawn. So the launch parse is one number, one coordinate pair and one string per
/// loop, and `pts` materializes a polyline the first time something draws it, memoized so two
/// athletes running the same famous loop decode it once.
enum CommunityRoutes {

    /// One bundled loop. `km` is the length of the polyline **as shipped** (never the Directions
    /// API's road-network distance — see `fetch_community_routes.py`); `pts` is `[[lat, lon]]`,
    /// matching `FeedItem.routeLatLon`, and is decoded on first read.
    struct Loop: Sendable {
        let km: Double
        /// Where the loop was drawn from: the real place an athlete would start it. `(0, 0)` for a
        /// loop out of a bundle written before anchors existed.
        let anchor: Anchor
        /// Index into the flat geometry table — the memo key, so a `Loop` stays small and can be
        /// copied around the generator without dragging a polyline behind it.
        fileprivate let slot: Int
        var pts: [[Double]] { CommunityRoutes.points(slot) }
    }

    struct Anchor: Sendable, Equatable {
        let lat: Double
        let lon: Double
        static let unknown = Anchor(lat: 0, lon: 0)
        var isKnown: Bool { self != .unknown }
    }

    /// The loops one athlete can draw from: their own corner of their metro, by kind.
    struct Pools: Sendable {
        let run: [Loop]
        let ride: [Loop]
        let trail: [Loop]
        static let empty = Pools(run: [], ride: [], trail: [])

        func loops(for type: WorkoutType) -> [Loop] {
            switch kind(of: type) {
            case .ride: ride
            case .trail: trail
            case .run: run
            }
        }

        /// Just the lengths, in pool order — what the ledger folds a career out of. Index into this
        /// with the pool index a session stores; `loops(for:)` with the same index returns the
        /// matching geometry when a tile is finally materialized.
        func kms(for type: WorkoutType) -> [Double] { loops(for: type).map(\.km) }
    }

    enum Kind: String, Sendable { case run, ride, trail }

    /// Which bundled pool a sport draws from. Walks and hikes ride along with the run pool's
    /// pedestrian geometry; a hike anchored on a park comes from `trail`.
    static func kind(of type: WorkoutType) -> Kind {
        switch type {
        case .ride, .mountainBikeRide, .gravelRide, .eBikeRide: .ride
        case .trailRun, .hike: .trail
        default: .run
        }
    }

    // MARK: - Bundle

    private struct RawLoop: Decodable {
        let km: Double
        /// The anchor `[lat, lon]`. Optional so a bundle written before anchors still loads.
        let c: [Double]?
        /// base64, wire format v2 — see `decode`.
        let b: String
    }

    private struct RawCity: Decodable {
        let run: [RawLoop]
        let ride: [RawLoop]
        /// Optional: trails arrived with the 2026-09-07 regeneration.
        let trail: [RawLoop]?
    }

    private struct Table {
        var byCity: [String: Pools] = [:]
        /// slot → the loop's encoded polyline. Parallel to the `Loop.slot` values above.
        var encoded: [String] = []
    }

    private static let table: Table = {
        #if DEBUG
        let _t0 = CFAbsoluteTimeGetCurrent()
        defer {
            if ProcessInfo.processInfo.arguments.contains("--community-perf") {
                os_log("TIME CommunityRoutes.table %.1fms main=%{public}@", log: .default, type: .default,
                       (CFAbsoluteTimeGetCurrent() - _t0) * 1000, Thread.isMainThread ? "Y" : "N")
            }
        }
        #endif
        // Memory-mapped: every byte is read exactly once, by the parser.
        guard let url = Bundle.main.url(forResource: "CommunityRoutes", withExtension: "json"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let decoded = try? JSONDecoder().decode([String: RawCity].self, from: data)
        else { return Table() }
        var out = Table()
        out.encoded.reserveCapacity(4_096)
        for (city, entry) in decoded {
            func admit(_ raws: [RawLoop]) -> [Loop] {
                raws.map { raw in
                    out.encoded.append(raw.b)
                    let anchor = (raw.c?.count ?? 0) >= 2
                        ? Anchor(lat: raw.c![0], lon: raw.c![1]) : Anchor.unknown
                    return Loop(km: raw.km, anchor: anchor, slot: out.encoded.count - 1)
                }
            }
            out.byCity[city] = Pools(run: admit(entry.run), ride: admit(entry.ride),
                                     trail: admit(entry.trail ?? []))
        }
        return out
    }()

    /// The polyline for `slot`, decoded once and held.
    ///
    /// `km` is read as shipped — no re-measure. `fetch_community_routes.py` measures each loop
    /// after simplification and rounding, so the shipped value already IS the drawn length. **If a
    /// future regeneration ever writes the API's road distance back,
    /// `CommunityContentAuditTests.mapsAndStatsAgree` is what will catch it — do not re-add a
    /// runtime re-measure to paper over it, fix the script.**
    fileprivate static func points(_ slot: Int) -> [[Double]] {
        guard table.encoded.indices.contains(slot) else { return [] }
        if let hit = geometry.cached(slot) { return hit }
        let pts = decode(table.encoded[slot])
        geometry.store(pts, at: slot)
        return pts
    }

    /// base64 → `[[lat, lon]]`. The exact inverse of `community_routes_lib.encode`.
    ///
    /// **Wire format v2**: a magic byte `0x02`, then two zigzag varints per point holding the DELTA
    /// from the previous point in units of 1e-5 degrees (the first point's delta is from zero, so it
    /// is the absolute coordinate).
    ///
    /// v1 packed absolute little-endian `Int32` pairs at 1e-4 degrees, and to hold the file size it
    /// kept only every Nth point of each route — which is what drew runners across San Francisco
    /// Bay, Lake Michigan and Sydney Harbour: dropping points replaces real bridge and shoreline
    /// geometry with straight chords kilometres long, and a chord goes where the road did not.
    /// Deltas cost about half what absolutes did, which is what pays for keeping the geometry.
    /// Only v2 ships. A v1 latitude can start with 0x02, so byte-sniffed legacy fallback was
    /// ambiguous. Reject malformed payloads in full rather than drawing a valid prefix as a route.
    static func decode(_ encoded: String) -> [[Double]] {
        guard let raw = Data(base64Encoded: encoded), raw.first == 2 else { return [] }
        let bytes = Array(raw)
        var index = 1
        func read() -> Int? {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 28, by: 7) {
                guard index < bytes.count else { return nil }
                let byte = bytes[index]
                index += 1
                guard shift < 28 || byte <= 15 else { return nil }
                value |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { return Int(value >> 1) ^ -Int(value & 1) }
            }
            return nil
        }
        var out: [[Double]] = []
        out.reserveCapacity(bytes.count / 4)
        var lat = 0, lon = 0
        while index < bytes.count {
            guard let dLat = read(), let dLon = read() else { return [] }
            lat += dLat
            lon += dLon
            guard (-9_000_000...9_000_000).contains(lat),
                  (-18_000_000...18_000_000).contains(lon) else { return [] }
            out.append([Double(lat) / 100_000, Double(lon) / 100_000])
        }
        return out
    }

    /// Decoded polylines, keyed by slot. Locked rather than actor-isolated: the wall's assembly runs
    /// on a detached task while a profile grid materializes on the main actor, and both draw routes.
    /// The house pattern (`WorkoutLogParser.RegexCache`).
    private final class GeometryMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var store: [Int: [[Double]]] = [:]

        func cached(_ slot: Int) -> [[Double]]? {
            lock.lock(); defer { lock.unlock() }
            return store[slot]
        }

        func store(_ pts: [[Double]], at slot: Int) {
            lock.lock(); defer { lock.unlock() }
            store[slot] = pts
        }

        /// How many bundled loops have actually been drawn this session.
        var residentCount: Int {
            lock.lock(); defer { lock.unlock() }
            return store.count
        }
    }

    private static let geometry = GeometryMemo()

    /// How many bundled polylines have been materialized — the "only what was drawn" claim, made
    /// checkable.
    static var materializedLoopCount: Int { geometry.residentCount }

    // MARK: - Picking

    /// How far past the nearest anchor a loop still counts as "round here".
    private static let localSpreadM = 6_000.0
    /// And the floor, so a dense metro still offers a few streets to choose between.
    private static let localFloorM = 8_000.0

    /// The loops an athlete of `city` who lives at `home` can draw from.
    ///
    /// Everything anchored near their home, and everything in the metro when nothing is (a rural
    /// athlete gets the metro's loops rather than no map at all). Pure — no RNG — so the same
    /// athlete resolves the same pool in the ledger and again when a tile is drawn.
    static func pools(city: String, near home: (lat: Double, lon: Double)?) -> Pools {
        guard let entry = table.byCity[city] else { return .empty }
        guard let home else { return entry }
        guard home.lat.isFinite, home.lon.isFinite else { return .empty }
        let key = PoolKey(city: city, lat: home.lat, lon: home.lon)
        if let hit = poolMemo.cached(key) { return hit }
        let result = Pools(run: local(entry.run, home), ride: local(entry.ride, home),
                           trail: local(entry.trail, home))
        poolMemo.store(result, for: key)
        return result
    }

    private struct PoolKey: Hashable { let city: String; let lat: Double; let lon: Double }
    /// Homes repeat across athletes and surfaces. Cache only lengths/slots, never materialize
    /// geometry here. Bounded even if a caller supplies arbitrary coordinates while browsing.
    private final class PoolMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [PoolKey: Pools] = [:]
        func cached(_ key: PoolKey) -> Pools? {
            lock.lock(); defer { lock.unlock() }
            return values[key]
        }
        func store(_ value: Pools, for key: PoolKey) {
            lock.lock(); defer { lock.unlock() }
            if values.count >= 4096 { values.removeAll(keepingCapacity: true) }
            values[key] = value
        }
    }
    private static let poolMemo = PoolMemo()

    /// Two passes and one allocation, deliberately. This runs three times for every one of ~2,900
    /// athletes while the directory builds, and the intermediate arrays a `filter`/`zip`/`map`
    /// chain would allocate are the kind of launch cost this file has been trimmed for twice.
    private static func local(_ loops: [Loop], _ home: (lat: Double, lon: Double)) -> [Loop] {
        guard !loops.isEmpty else { return [] }
        var nearest = Double.greatestFiniteMagnitude
        for loop in loops where loop.anchor.isKnown {
            nearest = min(nearest, meters(loop.anchor, home))
        }
        guard nearest < .greatestFiniteMagnitude else { return loops }   // a bundle with no anchors
        let cutoff = max(nearest + localSpreadM, localFloorM)
        var kept: [Loop] = []
        kept.reserveCapacity(loops.count)
        for loop in loops where loop.anchor.isKnown && meters(loop.anchor, home) <= cutoff {
            kept.append(loop)
        }
        return kept.isEmpty ? loops : kept
    }

    /// Flat-earth metres — the same approximation the fetch script and `lengthKm` use. Exact enough
    /// at metro scale and far cheaper than haversine over ~150,000 comparisons at launch.
    private static func meters(_ a: Anchor, _ b: (lat: Double, lon: Double)) -> Double {
        let dLat = (a.lat - b.lat) * 111_132
        let dLon = (a.lon - b.lon) * 111_320 * cos(b.lat * .pi / 180)
        return (dLat * dLat + dLon * dLon).squareRoot()
    }

    /// A deterministic real loop for a city + discipline; nil when the city isn't bundled (callers
    /// fall back to no map rather than a fake one).
    static func loop(city: String, discipline: WorkoutType, near home: (lat: Double, lon: Double)? = nil,
                     rng: inout SeededRNG) -> Loop? {
        let pool = pools(city: city, near: home).loops(for: discipline)
        guard !pool.isEmpty else { return nil }
        return pool[rng.int(0...(pool.count - 1))]
    }

    /// The loop at `slot` in the athlete's pool, offset so different athletes start at different
    /// places in it. Re-rolling per post used to cluster the same shape several times in one
    /// athlete's grid; rotating spreads the pool evenly and makes an adjacent repeat impossible,
    /// while every polyline stays a bundled street loop point-for-point
    /// (`everyRouteFollowsBundledStreetGeometry`).
    static func loop(city: String, discipline: WorkoutType, near home: (lat: Double, lon: Double)? = nil,
                     slot: Int, offset: Int) -> Loop? {
        let pool = pools(city: city, near: home).loops(for: discipline)
        guard !pool.isEmpty else { return nil }
        let i = ((slot &+ offset) % pool.count + pool.count) % pool.count
        return pool[i]
    }

    /// Just the LENGTHS of a pool, in pool order.
    static func loopKms(city: String, discipline: WorkoutType,
                        near home: (lat: Double, lon: Double)? = nil) -> [Double] {
        pools(city: city, near: home).kms(for: discipline)
    }

    /// The bundled loop closest to a target distance — for hand-curated featured posts whose copy
    /// implies a specific kind of session (long vs short).
    static func loop(city: String, discipline: WorkoutType, near home: (lat: Double, lon: Double)? = nil,
                     nearestKm target: Double) -> Loop? {
        pools(city: city, near: home).loops(for: discipline)
            .min(by: { abs($0.km - target) < abs($1.km - target) })
    }

    // MARK: - Audit surface (tests)

    /// The full bundle, exposed for the realism-audit tests: every routed post's polyline must be
    /// one of these fetched loops, which verifies pool consistency, not geographic access.
    static var auditCities: [String] { Array(table.byCity.keys) }

    static func auditLoops(city: String) -> [Loop] {
        guard let entry = table.byCity[city] else { return [] }
        return entry.run + entry.ride + entry.trail
    }

    static func auditPools(city: String) -> Pools { table.byCity[city] ?? .empty }

    /// The longest straight segment of a drawn loop, in metres. This is a review trigger, not a
    /// road/water proof — short segments can leave a road too. For context: the pre-2026-09-07
    /// bundle carried chords up to 10.3 km, and seventeen of its forty worst were drawn over open
    /// water (San Francisco Bay, Lake Michigan, Sydney Harbour).
    static func longestChordM(_ pts: [[Double]]) -> Double {
        guard pts.count > 1 else { return 0 }
        var worst = 0.0
        for i in 1..<pts.count where pts[i].count > 1 && pts[i - 1].count > 1 {
            let dLat = (pts[i][0] - pts[i - 1][0]) * 111_132
            let dLon = (pts[i][1] - pts[i - 1][1]) * 111_320 * cos(pts[i - 1][0] * .pi / 180)
            worst = max(worst, (dLat * dLat + dLon * dLon).squareRoot())
        }
        return worst
    }

    #if DEBUG
    /// The website marketing hero's route — a real ~10km San Francisco street loop (coherent with
    /// the app's other SF captures). DEBUG-only; drives `--marketing-hero`.
    static func heroLoop() -> Loop? {
        loop(city: "San Francisco, CA", discipline: .run, nearestKm: 10)
    }
    #endif
}
