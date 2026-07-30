import Foundation
import CoreLocation

/// Stage 3 of the tracing pipeline (§8.5): snaps a finished GPS trace onto the road/path network via
/// the **Mapbox Map Matching API**, so a city run or ride sits exactly on the sidewalk instead of
/// wobbling beside it. A direct publishable-token + `URLSession`/JSON call — no extra SDK
/// (`MapboxDirections` is a separate package we deliberately don't pull in).
///
/// **Confidence-gated, and that gate is the whole safety story.** Map matching is wrong for
/// off-network activity (trail runs, tracks, open-water) — snapping to the nearest road would falsify
/// the route. Rather than maintain a discipline allowlist, we let Mapbox tell us: a trace that
/// doesn't align to the network comes back with low confidence, and the caller keeps the raw
/// Kalman-filtered trace. Good road runs come back high-confidence and get the clean snap.
struct MapMatchingService {

    struct Match: Sendable {
        let coordinates: [CLLocationCoordinate2D]
        let confidence: Double
    }

    /// Mapbox routing profile. Foot sports (run/walk/hike) match against the walking network (which
    /// includes footways and most trails); bike variants against cycling.
    enum Profile: String, Sendable {
        case walking = "mapbox/walking"
        case cycling = "mapbox/cycling"
    }

    static func profile(for type: WorkoutType) -> Profile {
        type.discipline == .cycling ? .cycling : .walking
    }

    /// Below this average match confidence we discard the result and keep the raw trace — the guard
    /// that stops an off-network route from being snapped to the wrong path.
    static let minConfidence = 0.5

    /// Kill-switch (default on); no settings UI yet, but flippable via defaults for support/debug.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "mapMatchingEnabled") as? Bool ?? true
    }

    // API limits (from the Map Matching docs): ≤100 coordinates per request; best with points spaced
    // out rather than clustered. We downsample to a sensible spacing, then chunk with a 1-point
    // overlap so adjacent matched segments join without a gap.
    private static let maxCoordsPerRequest = 100
    private static let minSpacingM = 18.0
    private static let searchRadiusM = 25   // per-point search radius (API max 50)

    private let token: String
    private let session: URLSession

    init(token: String? = nil, session: URLSession = .shared) {
        self.token = token ?? (Bundle.main.object(forInfoDictionaryKey: "MBXAccessToken") as? String) ?? ""
        self.session = session
    }

    /// Match a full trace: downsample → chunk → match each chunk → stitch. Returns nil (⇒ keep the raw
    /// trace) on a missing token, any failed/low-confidence chunk, or a too-short input.
    func match(coordinates: [CLLocationCoordinate2D], profile: Profile) async -> Match? {
        guard !token.isEmpty else { return nil }
        let thinned = Self.downsample(coordinates, minSpacingM: Self.minSpacingM)
        guard thinned.count >= 2 else { return nil }

        var stitched: [CLLocationCoordinate2D] = []
        var confidenceSum = 0.0
        var chunks = 0
        for chunk in Self.chunk(thinned, maxPerRequest: Self.maxCoordsPerRequest, overlap: 1) {
            guard let match = await matchChunk(chunk, profile: profile) else { return nil }
            // Any single low-confidence chunk fails the whole route — better an honest raw trace than
            // a route that's crisp in some blocks and snapped to the wrong street in others.
            guard match.confidence >= Self.minConfidence else { return nil }
            // Drop the first point of every chunk after the first — it overlaps the prior chunk's last.
            stitched.append(contentsOf: stitched.isEmpty ? match.coordinates : Array(match.coordinates.dropFirst()))
            confidenceSum += match.confidence
            chunks += 1
        }
        guard chunks > 0, stitched.count >= 2 else { return nil }
        return Match(coordinates: stitched, confidence: confidenceSum / Double(chunks))
    }

    /// One Map Matching request for a single ≤100-point chunk.
    private func matchChunk(_ coords: [CLLocationCoordinate2D], profile: Profile) async -> Match? {
        let path = coords.map { "\($0.longitude),\($0.latitude)" }.joined(separator: ";")
        var comps = URLComponents(string: "https://api.mapbox.com/matching/v5/\(profile.rawValue)/\(path)")!
        comps.queryItems = [
            .init(name: "access_token", value: token),
            .init(name: "geometries", value: "geojson"),
            .init(name: "overview", value: "full"),
            .init(name: "radiuses", value: Array(repeating: String(Self.searchRadiusM), count: coords.count).joined(separator: ";")),
        ]
        guard let url = comps.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return Self.parse(data)
        } catch {
            return nil   // offline / transient — caller keeps the raw trace
        }
    }

    // MARK: Pure helpers (testable without a network)

    /// Thin a dense trace to roughly `minSpacingM` between kept points. Map matching works better on
    /// spaced points than clustered ones, and it keeps long routes within the per-request budget.
    /// Endpoints are always kept.
    static func downsample(_ coords: [CLLocationCoordinate2D], minSpacingM: Double) -> [CLLocationCoordinate2D] {
        guard let first = coords.first, coords.count > 2 else { return coords }
        var out = [first]
        for c in coords.dropFirst() {
            let last = out[out.count - 1]
            if Geo.distance(lat1: last.latitude, lon1: last.longitude, lat2: c.latitude, lon2: c.longitude) >= minSpacingM {
                out.append(c)
            }
        }
        if let actualLast = coords.last,
           actualLast.latitude != out[out.count - 1].latitude || actualLast.longitude != out[out.count - 1].longitude {
            out.append(actualLast)
        }
        return out
    }

    /// Split into chunks of at most `maxPerRequest`, repeating `overlap` trailing points at the head of
    /// the next chunk so the matched segments can be stitched without a seam.
    static func chunk(_ coords: [CLLocationCoordinate2D], maxPerRequest: Int, overlap: Int) -> [[CLLocationCoordinate2D]] {
        guard coords.count > maxPerRequest else { return coords.isEmpty ? [] : [coords] }
        let step = max(1, maxPerRequest - overlap)
        var chunks: [[CLLocationCoordinate2D]] = []
        var start = 0
        while start < coords.count {
            let end = min(start + maxPerRequest, coords.count)
            chunks.append(Array(coords[start..<end]))
            if end == coords.count { break }
            start += step
        }
        return chunks
    }

    /// Decode the first (best) matching from a Map Matching response. Returns nil unless the response
    /// code is `Ok` and a matching with geometry is present.
    static func parse(_ data: Data) -> Match? {
        guard let resp = try? JSONDecoder().decode(Response.self, from: data),
              resp.code == "Ok",
              let best = resp.matchings.first else { return nil }
        let coords = best.geometry.coordinates.compactMap { pair -> CLLocationCoordinate2D? in
            pair.count == 2 ? CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0]) : nil
        }
        guard coords.count >= 2 else { return nil }
        return Match(coordinates: coords, confidence: best.confidence)
    }

    private struct Response: Decodable {
        let code: String
        let matchings: [Matching]
    }
    private struct Matching: Decodable {
        let confidence: Double
        let geometry: Geometry
    }
    private struct Geometry: Decodable {
        let coordinates: [[Double]]   // GeoJSON [lon, lat]
    }
}
