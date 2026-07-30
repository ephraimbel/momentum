import Testing
import Foundation
@testable import Momentum

/// Realism tripwires for the seeded community wall (owner ask 2026-07-29: "every grid tile should
/// feel real"). The generator is deterministic per calendar day, so these run against exactly the
/// wall a user opens today — if a fake tell regresses (a "Track night" over a street map, a trail
/// run with road pace, a wall that's mostly mapless glyphs), a test trips before a user sees it.
@MainActor
struct CommunityContentAuditTests {

    /// Today's assembled page, exactly as `CommunityView` builds it (newest-first, capped like the
    /// Global scope's deep well).
    private func todaysWall() -> [FeedItem] {
        Array(CommunityFeed.seed().sorted { $0.date > $1.date }.prefix(400))
    }

    @Test func wallIsFullAndRunDominant() {
        let wall = todaysWall()
        #expect(wall.count == 400)   // a deep, full well — never a sparse one
        let runs = wall.filter { $0.type == .run || $0.type == .trailRun }
        // Run-first community: the wall should read like a running app (~65% weight ± daily jitter).
        #expect(runs.count >= 200, "wall should be run-dominant, got \(runs.count)/400")
        // The community itself is thousands strong (feed, strip, and globe share this number).
        #expect(CommunityGenerator.count > 2_000)
    }

    @Test func routedPostsDominateTheWall() {
        let wall = todaysWall()
        let gps = wall.filter { $0.type.isGPS }
        let routed = gps.filter { ($0.routeLatLon?.count ?? 0) > 1 }
        // Glyph tiles are the exception (watch-only track nights, trail runs) — never the pattern.
        // Every generator city carries bundled street loops, so ≥70% of GPS posts must ship a map.
        #expect(Double(routed.count) >= Double(gps.count) * 0.7,
                "only \(routed.count)/\(gps.count) GPS posts carry routes")
    }

    @Test func workoutTitlesNeverSitOverAStreetMap() {
        // "Track night" / "Tempo" / "8×400" over a downtown street loop is the loudest fake tell —
        // structured sessions must be mapless, and so must every trail title.
        let workoutWords = ["track", "tempo", "×", "repeats", "fartlek", "hill", "interval",
                            "speed", "strides", "1k", "400", "800"]
        let trailWords = ["trail", "ridge", "singletrack", "dirt", "woods", "switchback",
                          "vert", "fire road", "creek"]
        for item in todaysWall() where item.routeLatLon != nil {
            let t = item.title.lowercased()
            #expect(!workoutWords.contains(where: t.contains),
                    "workout title '\(item.title)' carries a street map")
            #expect(!trailWords.contains(where: t.contains),
                    "trail title '\(item.title)' carries a street map")
        }
    }

    @Test func trailRunsCarryClimbAndTrailPace() {
        for item in todaysWall() where item.type == .trailRun {
            #expect(item.routeLatLon == nil, "no bundled trail geometry exists — trail posts are mapless")
            #expect(item.statLine.contains("ft"), "trail stat '\(item.statLine)' should carry climb")
        }
    }

    @Test func mapsAndStatsAgree() {
        // The distance printed on a tile must be the route's true length — a 2 mi stat over an
        // 8 mi loop is a coherence tell. Loops store km; stats print miles at 0.6214.
        for item in todaysWall() where item.type.isGPS && item.routeLatLon != nil {
            guard let miToken = item.statLine.split(separator: " ").first,
                  let statMi = Double(miToken) else { continue }
            let km = routeLengthKm(item.routeLatLon!)
            let mi = km * 0.621371
            #expect(abs(mi - statMi) < 0.3,
                    "stat says \(statMi) mi but the route measures \(String(format: "%.1f", mi)) mi (\(item.title))")
        }
    }

    @Test func everyRouteFollowsBundledStreetGeometry() {
        // Over-water/over-rooftop routes are structurally impossible: every routed post's polyline
        // must be one of the bundled Directions-fetched street loops, point-for-point.
        var bundled: Set<Int> = []
        for city in CommunityRoutes.auditCities {
            for loop in CommunityRoutes.auditLoops(city: city) {
                bundled.insert(fingerprint(loop.pts))
            }
        }
        for item in todaysWall() where item.routeLatLon != nil {
            #expect(bundled.contains(fingerprint(item.routeLatLon!)),
                    "'\(item.title)' carries a route that isn't a bundled street loop")
        }
    }

    @Test func noAdjacentDuplicateRoutes() {
        // Two identical shapes side by side read generated even when each is individually real.
        // At 400 posts over ~195 bundled loops the occasional popular-loop repeat is statistically
        // honest (real cities have famous loops) — the tripwire is a PATTERN of them.
        let wall = todaysWall()
        var collisions = 0
        for i in wall.indices.dropLast() {
            guard let a = wall[i].routeLatLon, let b = wall[i + 1].routeLatLon else { continue }
            if fingerprint(a) == fingerprint(b) { collisions += 1 }
        }
        #expect(collisions <= 2, "\(collisions) adjacent tile pairs share a route")
    }

    // MARK: Helpers

    private func fingerprint(_ pts: [[Double]]) -> Int {
        var h = Hasher()
        h.combine(pts.count)
        if let f = pts.first?.first { h.combine(Int(f * 1e6)) }
        if let l = pts.last?.last { h.combine(Int(l * 1e6)) }
        if pts.count > 2, let m = pts[pts.count / 2].first { h.combine(Int(m * 1e6)) }
        return h.finalize()
    }

    private func routeLengthKm(_ pts: [[Double]]) -> Double {
        var meters = 0.0
        for i in 1..<pts.count {
            let (lat1, lon1, lat2, lon2) = (pts[i-1][0], pts[i-1][1], pts[i][0], pts[i][1])
            let mLat = (lat2 - lat1) * 111_132.0
            let mLon = (lon2 - lon1) * 111_320.0 * cos(lat1 * .pi / 180)
            meters += (mLat * mLat + mLon * mLon).squareRoot()
        }
        return meters / 1000
    }
}
