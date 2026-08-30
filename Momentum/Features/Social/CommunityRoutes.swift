import Foundation
#if DEBUG
import os
#endif

/// Real, street-following loops for the seeded community's posts — fetched once from the Mapbox
/// Directions API by `scripts/fetch_community_routes.py` and bundled as
/// `Resources/CommunityRoutes.json`. The old geometric loops cut straight across buildings and
/// read as fake in one glance; these are actual runnable/rideable city loops, and each carries
/// its true length so a post's distance/pace stats can agree with the map it shows.
/// Deterministic at runtime: the app only picks among bundled variants (no network).
///
/// **The bundle is length-first, geometry-on-demand (2026-08-29).** The session ledger asks
/// `loopKms` for every athlete's city while it folds ~2,900 careers, but it never needs a single
/// polyline — a tile's geometry matters only when that tile is about to be drawn. The file used to
/// be 967 loops × ~90 `[[lat, lon]]` arrays of plain JSON numbers: **86,887 point arrays parsed on
/// the very first `loopKms` call**, 108 ms on a cold Community open, all of it for lengths that are
/// 967 doubles. Each loop's polyline now ships as one base64 string of little-endian
/// `Int32` lat/lon pairs at 1e-4 (exactly the 4-decimal rounding the fetch already writes, so the
/// round trip is bit-exact and `km` still measures the SHIPPED shape). The launch parse is 967
/// numbers and 967 strings — measured 87× cheaper than the old decode — and `pts` materializes a
/// loop's point array the first time something draws it, memoized so two athletes running the same
/// famous loop decode it once.
enum CommunityRoutes {

    /// One bundled street loop. `km` is the length of the polyline **as shipped** (never the
    /// Directions API's road-network distance — see `fetch_community_routes.py`); `pts` is
    /// `[[lat, lon]]`, matching `FeedItem.routeLatLon`, and is decoded on first read.
    struct Loop: Sendable {
        let km: Double
        /// Index into the flat geometry table — the memo key, so a `Loop` value stays 16 bytes and
        /// can be copied around the generator without dragging a polyline behind it.
        fileprivate let slot: Int
        var pts: [[Double]] { CommunityRoutes.points(slot) }
    }

    private struct RawLoop: Decodable {
        let km: Double
        /// base64 of little-endian Int32 pairs, each value = degrees × 10,000.
        let b: String
    }

    private struct RawCity: Decodable {
        let run: [RawLoop]
        let ride: [RawLoop]
    }

    private struct Table {
        var byCity: [String: (run: [Loop], ride: [Loop])] = [:]
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
        // Memory-mapped: the file is ~925 KB and every byte is read exactly once, by the parser.
        guard let url = Bundle.main.url(forResource: "CommunityRoutes", withExtension: "json"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let decoded = try? JSONDecoder().decode([String: RawCity].self, from: data)
        else { return Table() }
        var out = Table()
        out.encoded.reserveCapacity(1_024)
        for (city, entry) in decoded {
            func admit(_ raws: [RawLoop]) -> [Loop] {
                raws.map { raw in
                    out.encoded.append(raw.b)
                    return Loop(km: raw.km, slot: out.encoded.count - 1)
                }
            }
            out.byCity[city] = (run: admit(entry.run), ride: admit(entry.ride))
        }
        return out
    }()

    /// The polyline for `slot`, decoded once and held.
    ///
    /// `km` is read as shipped — no re-measure. It used to be re-derived from the points here, and
    /// that was load-bearing for a long time: the fetch stored the Directions API's road-network
    /// length while the bundled geometry is downsampled, so the two disagreed by a median of
    /// 1.05 km and up to 18 km, and a tile would print a distance its own drawn shape could not
    /// account for (`CommunityContentAuditTests.mapsAndStatsAgree`, bound 0.3 mi).
    /// `fetch_community_routes.py` now measures each loop AFTER downsampling and rounding, so the
    /// shipped value already IS the drawn length. **If a future regeneration ever writes the API
    /// distance back, `mapsAndStatsAgree` is what will catch it — do not re-add a runtime
    /// re-measure to paper over it, fix the script.**
    fileprivate static func points(_ slot: Int) -> [[Double]] {
        guard table.encoded.indices.contains(slot) else { return [] }
        if let hit = geometry.cached(slot) { return hit }
        let pts = decode(table.encoded[slot])
        geometry.store(pts, at: slot)
        return pts
    }

    /// base64 → `[[lat, lon]]`. The encoding is exact at the 1e-4 the bundle rounds to, so this is
    /// a lossless inverse of what the fetch script wrote.
    private static func decode(_ encoded: String) -> [[Double]] {
        guard let raw = Data(base64Encoded: encoded) else { return [] }
        let n = raw.count / 8
        var out: [[Double]] = []
        out.reserveCapacity(n)
        raw.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for i in 0..<n {
                let lat = buf.loadUnaligned(fromByteOffset: i * 8, as: Int32.self)
                let lon = buf.loadUnaligned(fromByteOffset: i * 8 + 4, as: Int32.self)
                out.append([Double(lat) / 10_000, Double(lon) / 10_000])
            }
        }
        return out
    }

    /// Decoded polylines, keyed by slot. Locked rather than actor-isolated: the wall's assembly
    /// runs on a detached task while a profile grid materializes on the main actor, and both draw
    /// routes. The house pattern (`WorkoutLogParser.RegexCache`).
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

        /// How many of the 967 bundled loops have actually been drawn this session.
        var residentCount: Int {
            lock.lock(); defer { lock.unlock() }
            return store.count
        }
    }

    private static let geometry = GeometryMemo()

    /// How many bundled polylines have been materialized — the "only what was drawn" claim, made
    /// checkable.
    static var materializedLoopCount: Int { geometry.residentCount }

    /// A deterministic real loop for a city + discipline; nil when the city isn't bundled
    /// (callers fall back to no map rather than a fake one).
    static func loop(city: String, discipline: WorkoutType, rng: inout SeededRNG) -> Loop? {
        guard let entry = table.byCity[city] else { return nil }
        let pool = isRide(discipline) ? entry.ride : entry.run
        guard !pool.isEmpty else { return nil }
        return pool[rng.int(0...(pool.count - 1))]
    }

    /// The bundled loop at `slot` in the city's pool, offset so different athletes start at
    /// different places in it. Only 3 run loops shipped per city once, so re-rolling per post
    /// clustered the SAME shape several times in one athlete's grid (5x "5.7 mi" with identical
    /// geometry — found 2026-08-26 filming a profile). Rotating instead spreads the pool evenly and
    /// makes an adjacent repeat impossible, while every polyline stays a bundled street loop
    /// point-for-point (`everyRouteFollowsBundledStreetGeometry` — the guarantee that no route
    /// crosses water).
    static func loop(city: String, discipline: WorkoutType, slot: Int, offset: Int) -> Loop? {
        guard let entry = table.byCity[city] else { return nil }
        let pool = isRide(discipline) ? entry.ride : entry.run
        guard !pool.isEmpty else { return nil }
        let i = ((slot &+ offset) % pool.count + pool.count) % pool.count
        return pool[i]
    }

    /// Just the LENGTHS of a city's loop pool, in pool order. The session ledger
    /// (`CommunityLedger`) needs a route's true distance for every session an athlete ever ran —
    /// hundreds of them per athlete — but not one of its polylines. Index into this with the pool
    /// index a session stores; `loop(city:discipline:slot:offset:)` with the same index (offset 0)
    /// returns the matching geometry when a tile is finally materialized.
    static func loopKms(city: String, discipline: WorkoutType) -> [Double] {
        guard let entry = table.byCity[city] else { return [] }
        return (isRide(discipline) ? entry.ride : entry.run).map(\.km)
    }

    /// The full bundle, exposed for the realism-audit tests: every routed post's polyline must be
    /// one of these street-fetched loops, which is what makes over-water routes impossible.
    static var auditCities: [String] { Array(table.byCity.keys) }
    static func auditLoops(city: String) -> [Loop] {
        guard let entry = table.byCity[city] else { return [] }
        return entry.run + entry.ride
    }

    /// The bundled loop closest to a target distance — for hand-curated featured posts whose
    /// copy implies a specific kind of session (long vs short).
    static func loop(city: String, discipline: WorkoutType, nearestKm target: Double) -> Loop? {
        guard let entry = table.byCity[city] else { return nil }
        let pool = isRide(discipline) ? entry.ride : entry.run
        return pool.min(by: { abs($0.km - target) < abs($1.km - target) })
    }

    #if DEBUG
    /// The website marketing hero's route — a real ~10km San Francisco street loop (coherent with
    /// the app's other SF captures). DEBUG-only; drives `--marketing-hero`.
    static func heroLoop() -> Loop? {
        loop(city: "San Francisco, CA", discipline: .run, nearestKm: 10)
    }
    #endif

    private static func isRide(_ type: WorkoutType) -> Bool {
        switch type {
        case .ride, .mountainBikeRide, .gravelRide, .eBikeRide: true
        default: false
        }
    }
}
