import Foundation

/// Real, street-following loops for the seeded community's posts — fetched once from the Mapbox
/// Directions API by `scripts/fetch_community_routes.py` and bundled as
/// `Resources/CommunityRoutes.json`. The old geometric loops cut straight across buildings and
/// read as fake in one glance; these are actual runnable/rideable city loops, and each carries
/// its true length so a post's distance/pace stats can agree with the map it shows.
/// Deterministic at runtime: the app only picks among bundled variants (no network).
enum CommunityRoutes {

    struct Loop: Decodable {
        let km: Double
        /// [[lat, lon]] — matches `FeedItem.routeLatLon`.
        let pts: [[Double]]
    }

    private struct CityEntry: Decodable {
        let run: [Loop]
        let ride: [Loop]
    }

    private static let byCity: [String: CityEntry] = {
        guard let url = Bundle.main.url(forResource: "CommunityRoutes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: CityEntry].self, from: data)
        else { return [:] }
        // Re-measure every loop from its SHIPPED points. The fetch stored the Directions API's
        // road-network length, but the bundled geometry is simplified — up to ~30% shorter than
        // the road it traces — and the DRAWN shape is what a post's tile shows. Stats must agree
        // with the map the athlete is looking at (CommunityContentAuditTests measures exactly
        // this), so the drawn length is the honest one.
        return decoded.mapValues { entry in
            CityEntry(run: entry.run.map(remeasured), ride: entry.ride.map(remeasured))
        }
    }()

    private static func remeasured(_ loop: Loop) -> Loop {
        Loop(km: lengthKm(loop.pts), pts: loop.pts)
    }

    /// Flat-earth polyline length — exact to well under 1% at city scale.
    private static func lengthKm(_ pts: [[Double]]) -> Double {
        guard pts.count > 1 else { return 0 }
        var meters = 0.0
        for i in 1..<pts.count where pts[i].count >= 2 && pts[i - 1].count >= 2 {
            let mLat = (pts[i][0] - pts[i - 1][0]) * 111_132.0
            let mLon = (pts[i][1] - pts[i - 1][1]) * 111_320.0 * cos(pts[i - 1][0] * .pi / 180)
            meters += (mLat * mLat + mLon * mLon).squareRoot()
        }
        return meters / 1000
    }

    /// A deterministic real loop for a city + discipline; nil when the city isn't bundled
    /// (callers fall back to no map rather than a fake one).
    static func loop(city: String, discipline: WorkoutType, rng: inout SeededRNG) -> Loop? {
        guard let entry = byCity[city] else { return nil }
        let pool = isRide(discipline) ? entry.ride : entry.run
        guard !pool.isEmpty else { return nil }
        return pool[rng.int(0...(pool.count - 1))]
    }

    /// The full bundle, exposed for the realism-audit tests: every routed post's polyline must be
    /// one of these street-fetched loops, which is what makes over-water routes impossible.
    static var auditCities: [String] { Array(byCity.keys) }
    static func auditLoops(city: String) -> [Loop] {
        guard let entry = byCity[city] else { return [] }
        return entry.run + entry.ride
    }

    /// The bundled loop closest to a target distance — for hand-curated featured posts whose
    /// copy implies a specific kind of session (long vs short).
    static func loop(city: String, discipline: WorkoutType, nearestKm target: Double) -> Loop? {
        guard let entry = byCity[city] else { return nil }
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
