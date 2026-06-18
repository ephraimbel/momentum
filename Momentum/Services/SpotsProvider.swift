import Foundation

/// Finds real running/hiking spots near the athlete. Injected so the UI can run on a fixture without
/// the network (same seam as `DirectionsProviding`). The production adapter is `MapboxSpotsProvider`.
protocol SpotsProviding: Sendable {
    /// Fetch spots of the given kinds near `point`. Best-effort: a failed category contributes nothing
    /// rather than failing the whole call. `distanceM`/`popularity` are filled later by the ranker.
    func nearbySpots(around point: GeoPoint, kinds: [SpotKind], limitPerKind: Int) async -> [Spot]
}

/// Where a spot's *popularity* comes from — kept a separate seam so the honest community-heat layer
/// can be switched on later without touching the provider or UI (see [[social-layer]]). v1 wires the
/// no-op; a future `CommunityHeatPopularity` will count how many real Momentum activities pass near
/// each spot. Never fabricates a crowd.
protocol SpotPopularitySource: Sendable {
    /// Popularity per spot id. Spots absent from the map stay `.unknown`.
    func popularity(for spots: [Spot]) async -> [String: SpotPopularity]
}

/// v1 popularity: we don't claim any yet (no fabricated numbers). Lights up when the heat source ships.
struct NoSpotPopularity: SpotPopularitySource {
    func popularity(for spots: [Spot]) async -> [String: SpotPopularity] { [:] }
}

/// Caches spot lookups by coarse location + kind-set for a short TTL, so reopening "Spots near you"
/// is instant and costs nothing (Mapbox Search bills per request). An actor, so concurrent opens are
/// safe. Best-effort — never throws, and an empty result isn't cached (so a transient failure retries).
actor CachingSpotsProvider: SpotsProviding {
    private let base: any SpotsProviding
    private let ttl: TimeInterval
    private var cache: [String: (at: Date, spots: [Spot])] = [:]

    init(wrapping base: any SpotsProviding, ttl: TimeInterval = 600) {
        self.base = base
        self.ttl = ttl
    }

    func nearbySpots(around point: GeoPoint, kinds: [SpotKind], limitPerKind: Int) async -> [Spot] {
        let key = Self.key(point: point, kinds: kinds, limit: limitPerKind)
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < ttl { return hit.spots }
        let fresh = await base.nearbySpots(around: point, kinds: kinds, limitPerKind: limitPerKind)
        if !fresh.isEmpty { cache[key] = (Date(), fresh) }
        return fresh
    }

    /// Bucket location to ~110m (3 dp) so small movements reuse the cache; key also pins kinds + limit.
    static func key(point: GeoPoint, kinds: [SpotKind], limit: Int) -> String {
        let lat = (point.lat * 1000).rounded() / 1000
        let lon = (point.lon * 1000).rounded() / 1000
        return "\(lat),\(lon)|\(kinds.map(\.rawValue).sorted().joined(separator: ","))|\(limit)"
    }
}

/// No-op provider for previews/tests that don't exercise the network.
struct StubSpotsProvider: SpotsProviding {
    func nearbySpots(around point: GeoPoint, kinds: [SpotKind], limitPerKind: Int) async -> [Spot] { [] }
}

/// Spots from the **Mapbox Search Box** category API — real, named parks/trailheads/reserves/etc.
/// near the athlete. Uses the same publishable token as the map SDK (`MBXAccessToken` in Info.plist),
/// no extra dependency — just `URLSession` + JSON, the no-SDK approach the rest of the app uses.
struct MapboxSpotsProvider: SpotsProviding {
    private let token: String
    private let session: URLSession

    init(token: String? = nil, session: URLSession = .shared) {
        self.token = token ?? (Bundle.main.object(forInfoDictionaryKey: "MBXAccessToken") as? String) ?? ""
        self.session = session
    }

    func nearbySpots(around point: GeoPoint, kinds: [SpotKind], limitPerKind: Int) async -> [Spot] {
        guard !token.isEmpty else { return [] }
        // One request per category, concurrently; a failure drops that category only.
        let batches = await withTaskGroup(of: [Spot].self) { group -> [[Spot]] in
            for kind in kinds {
                group.addTask { await fetch(kind: kind, around: point, limit: limitPerKind) }
            }
            var all: [[Spot]] = []
            for await batch in group { all.append(batch) }
            return all
        }
        return Self.dedupe(batches.flatMap { $0 })
    }

    private func fetch(kind: SpotKind, around point: GeoPoint, limit: Int) async -> [Spot] {
        var comps = URLComponents(string: "https://api.mapbox.com/search/searchbox/v1/category/\(kind.mapboxCategory)")!
        comps.queryItems = [
            .init(name: "access_token", value: token),
            .init(name: "proximity", value: "\(point.lon),\(point.lat)"),
            .init(name: "limit", value: String(limit)),
            .init(name: "language", value: "en"),
        ]
        guard let url = comps.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8                    // don't hang the UI on a slow network
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
            return Self.parse(data, kind: kind)
        } catch {
            return []   // offline / transient — best-effort
        }
    }

    /// Pure JSON → `[Spot]` (testable against a captured fixture).
    static func parse(_ data: Data, kind: SpotKind) -> [Spot] {
        guard let resp = try? JSONDecoder().decode(CategoryResponse.self, from: data) else { return [] }
        return resp.features.compactMap { f in
            guard let name = f.properties.name,
                  let c = f.properties.coordinates else { return nil }
            return Spot(
                id: f.properties.mapbox_id ?? "\(name)@\(c.latitude),\(c.longitude)",
                name: name,
                kind: kind,
                point: GeoPoint(lat: c.latitude, lon: c.longitude),
                neighborhood: f.properties.context?.neighborhood?.name ?? f.properties.context?.place?.name,
                distanceM: 0)
        }
    }

    /// Collapse the same place arriving under two categories (e.g. a nature reserve also tagged park):
    /// keep one per id, and one per ~11m coordinate cell.
    static func dedupe(_ spots: [Spot]) -> [Spot] {
        var seenIDs = Set<String>(), seenCells = Set<String>(), out: [Spot] = []
        for s in spots {
            let cell = "\(Int((s.point.lat * 10_000).rounded())),\(Int((s.point.lon * 10_000).rounded()))"
            if seenIDs.contains(s.id) || seenCells.contains(cell) { continue }
            seenIDs.insert(s.id); seenCells.insert(cell); out.append(s)
        }
        return out
    }

    // MARK: Response shape (subset of Mapbox Search Box category JSON)

    private struct CategoryResponse: Decodable { let features: [Feature] }
    private struct Feature: Decodable {
        let properties: Props
        struct Props: Decodable {
            let name: String?
            let mapbox_id: String?
            let coordinates: Coord?
            let context: Context?
        }
        struct Coord: Decodable { let latitude: Double; let longitude: Double }
        struct Context: Decodable {
            let neighborhood: Named?
            let place: Named?
        }
        struct Named: Decodable { let name: String? }
    }
}
