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
        return decoded
    }()

    /// A deterministic real loop for a city + discipline; nil when the city isn't bundled
    /// (callers fall back to no map rather than a fake one).
    static func loop(city: String, discipline: WorkoutType, rng: inout SeededRNG) -> Loop? {
        guard let entry = byCity[city] else { return nil }
        let pool = isRide(discipline) ? entry.ride : entry.run
        guard !pool.isEmpty else { return nil }
        return pool[rng.int(0...(pool.count - 1))]
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
