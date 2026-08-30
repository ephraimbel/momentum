import Foundation
#if DEBUG
import os
#endif

/// The real towns of each seeded-community metro — fetched once from the Mapbox geocoder by
/// `scripts/fetch_community_places.py` and bundled as `Resources/CommunityPlaces.json`.
///
/// **Why this exists.** Every one of the ~2,863 seeded athletes used to live within ±0.02°
/// (~2.2 km) of one of 65 downtown coordinates, so the community map drew 65 tight knots instead
/// of a population and forty-four people in a row introduced themselves as "Austin, TX". Widening
/// the jitter was the obvious fix and the wrong one: at metro scale a random offset drops people
/// into the Atlantic off Miami and the harbour at Sydney. So the towns are not invented — a ring
/// grid around each metro was reverse-geocoded and whatever real place each sample landed in was
/// kept. Every point is therefore on land (a reverse geocode over water returns no place at all,
/// which is why Miami ships 20 places and Dallas 55), carries a real name, and sits where people
/// actually live, because that is where the named places are.
///
/// **A place is a HOME, never a route key.** A suburb has no bundled street loop of its own, so
/// `CommunityRoutes` is still keyed by the metro. That split is why `CommunityAthlete` carries
/// both `location` (what they say: "Buda, TX") and `metro` (what their routes are drawn from:
/// "Austin, TX"), and why `CommunityAthlete.routeCity` — never `location` — is what reaches the
/// ledger.
///
/// **The pick spends no draw of the athlete rng.** The name/city/discipline sequence in
/// `CommunityGenerator.athlete(index:)` is a contract (see the ledger note there); a home is
/// chosen from a separate handle-derived seed, exactly as `handle` and the post rng already are.
enum CommunityPlaces {

    /// One real place inside a metro.
    struct Place: Sendable, Hashable {
        /// What the athlete says they are from — "Buda, TX" for a US core-state place, or the
        /// metro string verbatim ("Austin, TX", "London") when this IS the metro's core city.
        let display: String
        /// The bare geocoded name, for audits.
        let name: String
        let lat: Double
        let lon: Double
        /// Raw sample hits from the fetch — a rough footprint proxy, deliberately NOT a population
        /// figure. See `weights` for what the runtime does with it.
        let hits: Int
    }

    private struct RawPlace: Decodable {
        let n: String
        let lat: Double
        let lon: Double
        let w: Int
        /// Region/country label, when the fetch recorded one ("TX", "ON", "Germany"). Absent in the
        /// bundle as shipped 2026-08-29 — see `display(name:region:metro:)`.
        let r: String?
    }

    private struct Metro: Sendable {
        let places: [Place]
        /// Prefix sums of the weights below, so a pick is one modulo and a binary-free scan.
        let cumulative: [Int]
        let total: Int
    }

    private static let table: [String: Metro] = {
        #if DEBUG
        let _t0 = CFAbsoluteTimeGetCurrent()
        defer {
            if ProcessInfo.processInfo.arguments.contains("--community-perf") {
                os_log("TIME CommunityPlaces.table %.1fms main=%{public}@", log: .default, type: .default,
                       (CFAbsoluteTimeGetCurrent() - _t0) * 1000, Thread.isMainThread ? "Y" : "N")
            }
        }
        #endif
        // Memory-mapped like `CommunityRoutes`: ~173 KB read exactly once, by the parser, on the
        // detached task that builds the directory — never on the main actor (2026-08-29 perf pass).
        guard let url = Bundle.main.url(forResource: "CommunityPlaces", withExtension: "json"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let decoded = try? JSONDecoder().decode([String: [RawPlace]].self, from: data)
        else { return [:] }
        var out: [String: Metro] = [:]
        out.reserveCapacity(decoded.count)
        for (metro, raws) in decoded {
            guard !raws.isEmpty else { continue }
            let core = coreName(of: metro)
            let places = raws.map {
                Place(display: display(name: $0.n, region: $0.r, metro: metro, core: core),
                      name: $0.n, lat: $0.lat, lon: $0.lon, hits: $0.w)
            }
            let weights = Self.weights(places, core: core)
            var cumulative: [Int] = []
            cumulative.reserveCapacity(weights.count)
            var running = 0
            for w in weights { running += w; cumulative.append(running) }
            out[metro] = Metro(places: places, cumulative: cumulative, total: running)
        }
        return out
    }()

    /// The metro's own city, without its state: "Austin, TX" → "Austin".
    private static func coreName(of metro: String) -> String {
        String(metro.split(separator: ",").first ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// What a resident of this place writes on their profile.
    ///
    /// **The suffix is only ever one the DATA supports.** Appending the metro's state to every
    /// place would have been the obvious thing and would have printed "Hoboken, NY", "Camden, PA"
    /// and "Arlington, DC": the fetch's 80 km rings cross a state line in roughly twenty of the 45
    /// US metros. So a place carries a region only when the fetch recorded one (`r`), and
    /// otherwise says its bare name. The metro's own core city keeps the full metro string, so the
    /// familiar "Austin, TX" / "London" grammar survives for the plurality who live there.
    private static func display(name: String, region: String?, metro: String, core: String) -> String {
        if let region, !region.isEmpty { return "\(name), \(region)" }
        return name == core ? metro : name
    }

    /// Per-place pick weights.
    ///
    /// The raw `w` is a count of grid samples that landed in a place, which measures AREA, not
    /// people: Manhattan is one sample and so is an empty county an hour out, so weighting by `w`
    /// alone left only 3% of New Yorkers saying "New York, NY". A metro's core city really does
    /// hold roughly a third of its metro's population (Austin ~40%, NYC ~44%), so the core is
    /// floored at 35% of the metro's weight and the towns share the rest in proportion to their
    /// footprint. Integer arithmetic throughout, so the pick is identical on every machine.
    private static func weights(_ places: [Place], core: String) -> [Int] {
        var w = places.map { max(1, $0.hits) }
        guard let coreIndex = places.firstIndex(where: { $0.name == core }) else { return w }
        let rest = w.enumerated().reduce(0) { $1.offset == coreIndex ? $0 : $0 + $1.element }
        // share 0.35 → core ≥ rest * 35/65 = rest * 7/13, rounded up.
        w[coreIndex] = max(w[coreIndex], (rest * 7 + 12) / 13)
        return w
    }

    /// Where one athlete of `metro` lives — deterministic in `seed`, which must come from a
    /// generator OTHER than the athlete rng (see the type note). nil when the metro isn't bundled;
    /// callers fall back to the metro's own downtown coordinate rather than inventing one.
    static func home(metro: String, seed: UInt64) -> Place? {
        guard let entry = table[metro], entry.total > 0 else { return nil }
        let target = Int(seed % UInt64(entry.total))
        for (i, cum) in entry.cumulative.enumerated() where target < cum {
            return entry.places[i]
        }
        return entry.places.last
    }

    // MARK: Audit surface (tests)

    /// Every bundled metro key. These match `CommunityGenerator.seedMetros` exactly — the fetch
    /// script parses the generator's own city list so the two cannot drift.
    static var auditMetros: [String] { Array(table.keys) }
    static func auditPlaces(metro: String) -> [Place] { table[metro]?.places ?? [] }
}
