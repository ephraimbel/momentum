import Testing
import Foundation
@testable import Momentum

/// The bundled community routes have to look like somebody actually ran them (2026-09-07).
///
/// Two defects motivated this file, and both were in the DATA rather than the code, which is why
/// the existing audit could not see them:
///
/// 1. **Runners crossed water.** The fetch script downsampled every route to 90 points by keeping
///    every Nth vertex, so real bridge and shoreline geometry became straight chords kilometres
///    long, and the chords went where the road did not. Sampling the shipped bundle against
///    Mapbox's own water polygons, seventeen of the forty worst-chord loops were drawn over open
///    water: an 8.8 km line from Sausalito across the Golden Gate, a Chicago "run" out in Lake
///    Michigan, Sydney Harbour, Lake Ontario, the Hudson. `everyRouteFollowsBundledStreetGeometry`
///    passed the whole time — every drawn polyline WAS a bundled loop; the bundled loop was wrong.
/// 2. **Everyone ran downtown.** Every loop of a metro was anchored on that metro's one downtown
///    pin, so all ~44 seeded athletes of a metro traced the same city-centre streets — including
///    the two thirds who say they live in a suburb or a commuter town.
///
/// A unit test cannot ask Mapbox whether a line is over water. What it CAN do is pin the shape
/// properties that made the crossing possible, so the defect cannot come back silently:
/// extreme chords and uniform point counts can expose damage, but neither proves road access.
/// Short segments can cross water too. The Python/Swift parity test covers every coordinate.
/// `scripts/audit_community_routes.py` does the empirical half against the live water layer.
struct CommunityRouteRealismTests {

    /// A sanity ceiling on a single straight segment, not a water test.
    ///
    /// It was 4 km until the regenerated bundle was measured. Roads on the Alberta grid, the
    /// Colorado front range and the Central Valley really do run dead straight for kilometres:
    /// Calgary's longest is 6.9 km of routed highway, and it is on land. The pre-regeneration
    /// bundle's 10.3 km chord across San Francisco Bay still trips this, but the honest detector
    /// for decimation is `geometryIsNotUniformlyDecimated` below, and the honest detector for water
    /// is `scripts/audit_community_routes.py` against the live water layer.
    private let maxChordM = 8_000.0
    /// Bundle-level alarm for a fixed vertex cap; this heuristic cannot prove fidelity.
    /// The independent Python simplification fixtures pin the actual 5 m error contract.
    private let maxUniformShare = 0.15

    private func loops() -> [(city: String, loop: CommunityRoutes.Loop)] {
        CommunityRoutes.auditCities.sorted().flatMap { city in
            CommunityRoutes.auditLoops(city: city).map { (city, $0) }
        }
    }

    @Test func extremeChordLengthsRequireReview() {
        var worst = (city: "", km: 0.0, chord: 0.0)
        var offenders: [String] = []
        for (city, loop) in loops() {
            let chord = CommunityRoutes.longestChordM(loop.pts)
            if chord > worst.chord { worst = (city, loop.km, chord) }
            if chord > maxChordM {
                offenders.append("\(city) \(String(format: "%.1f", loop.km))km: "
                                 + "\(Int(chord))m straight")
            }
        }
        #expect(offenders.isEmpty, """
            \(offenders.count) bundled loops draw a straight line longer than \(Int(maxChordM)) m. \
            This requires a routing review, not an assumption about water. Re-run the fetch rather \
            than raising this bound: \(offenders.prefix(6).joined(separator: "; "))
            """)
        #expect(worst.chord > 0, "no bundled geometry decoded at all")
    }

    /// **The decimation detector.** A routed path's vertex count is a property of the road: a
    /// twisting park loop needs hundreds, a straight grid loop needs thirty. So in a real bundle
    /// the counts scatter. When a fetch caps every route at N points instead, the counts collapse
    /// onto N — and that collapse is the fingerprint, at any scale, with no network and no
    /// per-city tuning.
    ///
    /// Measured: the pre-regeneration bundle had SEVEN distinct point counts across 967 loops and
    /// 99.4% of them sat at exactly 90, which is what drew straight lines across San Francisco Bay
    /// and Lake Michigan. The regenerated bundle has 295 distinct counts across 2,849 loops and its
    /// most common covers 1.3%.
    ///
    /// A per-loop "points per kilometre" floor was tried first and thrown away: it cannot tell a
    /// decimated route from a genuinely straight prairie road, and the value that passed the real
    /// bundle (1.0/km) would also have passed the broken one (1.3/km).
    @Test func geometryIsNotUniformlyDecimated() {
        var histogram: [Int: Int] = [:]
        var total = 0
        var tiny: [String] = []
        for (city, loop) in loops() {
            let n = loop.pts.count
            histogram[n, default: 0] += 1
            total += 1
            if n < 12 { tiny.append("\(city) \(loop.km)km: \(n) points") }
        }
        #expect(total > 1_000, "expected the bundle to hold thousands of loops, saw \(total)")
        #expect(tiny.isEmpty, "\(tiny.prefix(5).joined(separator: "; "))")
        let (commonest, count) = histogram.max(by: { $0.value < $1.value }) ?? (0, 0)
        let share = Double(count) / Double(max(total, 1))
        #expect(share < maxUniformShare, """
            \(Int(share * 100))% of bundled loops have exactly \(commonest) points. A routed path's \
            vertex count follows its road; a bundle that agrees this closely has been downsampled \
            to a fixed size, which is what draws chords across water.
            """)
        #expect(histogram.count > 50,
                "only \(histogram.count) distinct point counts across \(total) loops")
    }

    /// Every loop knows the real place it starts from, and that place is inside its own metro.
    ///
    /// Run and ride loops are anchored ON a town, so they are held to 12 km — enough slack for a
    /// places regeneration to move a geocoded centre without turning this red. Trail loops are
    /// anchored on parks and nature reserves, which is exactly where towns are not, so they only
    /// have to be within the fetcher's 40 km park catchment (100 m projection tolerance).
    @Test func everyLoopIsAnchoredOnARealPlaceOfItsOwnMetro() {
        var anchorless = 0
        var strays: [String] = []
        for city in CommunityRoutes.auditCities.sorted() {
            let towns = CommunityPlaces.auditPlaces(metro: city)
            guard !towns.isEmpty else { continue }
            let pools = CommunityRoutes.auditPools(city: city)
            func check(_ loops: [CommunityRoutes.Loop], bound: Double, kind: String) {
                for loop in loops {
                    guard loop.anchor.isKnown else { anchorless += 1; continue }
                    let nearest = towns.map {
                        CommunityRoutes.longestChordM([[loop.anchor.lat, loop.anchor.lon], [$0.lat, $0.lon]])
                    }.min() ?? .greatestFiniteMagnitude
                    if nearest > bound {
                        strays.append("\(city) \(kind): anchor is \(Int(nearest / 1000)) km "
                                      + "from any town of the metro")
                    }
                }
            }
            check(pools.run, bound: 12_000, kind: "run")
            check(pools.ride, bound: 12_000, kind: "ride")
            check(pools.trail, bound: 40_100, kind: "trail")
        }
        #expect(anchorless == 0, "\(anchorless) bundled loops ship without an anchor")
        #expect(strays.isEmpty, "\(strays.prefix(5).joined(separator: "; "))")
    }

    /// A metro's own city carries loops. The anchors are chosen by name, not by the raw sample
    /// weight `w`, because `w` measures AREA: seeding from the fattest entry put Sydney's biggest
    /// share of loops in Blue Mountains National Park 78 km out and Tokyo's in Ichihara 43 km out,
    /// while `CommunityPlaces.weights` was flooring a THIRD of each metro's athletes into the core
    /// city those loops had left.
    @Test func theCoreCityOfEveryMetroCarriesLoops() {
        var missing: [String] = []
        for city in CommunityRoutes.auditCities.sorted() {
            let towns = CommunityPlaces.auditPlaces(metro: city)
            let coreName = String(city.split(separator: ",").first ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard let centre = CommunityGenerator.seedMetroCentres[city] else {
                Issue.record("Missing metro centre: \(city)"); continue
            }
            guard let core = towns.first(where: { $0.name == coreName }) ?? towns.min(by: {
                CommunityRoutes.longestChordM([[$0.lat, $0.lon], [centre.lat, centre.lon]])
                < CommunityRoutes.longestChordM([[$1.lat, $1.lon], [centre.lat, centre.lon]])
            }) else { Issue.record("Missing towns: \(city)"); continue }
            let runs = CommunityRoutes.auditPools(city: city).run
            guard !runs.isEmpty else { Issue.record("No run pool: \(city)"); continue }
            let nearest = runs.filter(\.anchor.isKnown).map {
                CommunityRoutes.longestChordM([[$0.anchor.lat, $0.anchor.lon], [core.lat, core.lon]])
            }.min() ?? .greatestFiniteMagnitude
            if nearest > 3_000 {
                missing.append("\(city): nearest run anchor is \(Int(nearest / 1000)) km "
                               + "from \(coreName) itself")
            }
        }
        #expect(missing.isEmpty, "\(missing.prefix(6).joined(separator: "; "))")
    }

    /// A regional coverage regression guard, not a promise that every run starts near home.
    /// Measure the first coordinate of the actual mapped lead post, including rides and trails;
    /// a pool's first anchor is not necessarily the geometry selected by the ledger.
    @Test func mappedLeadRoutesStayWithinRegionalCoverageBounds() {
        var distances: [Double] = []
        for athlete in CommunityDirectory.all().filter(\.isSample) {
            guard let home = athlete.homeCoordinate else { continue }
            guard let start = athlete.posts.first?.routeLatLon?.first, start.count == 2 else { continue }
            distances.append(CommunityRoutes.longestChordM(
                [start, [home.lat, home.lon]]) / 1000)
        }
        #expect(distances.count > 200, "expected most seeded athletes to resolve a run pool")
        guard !distances.isEmpty else { Issue.record("No route distances"); return }
        let sorted = distances.sorted()
        let median = sorted[sorted.count / 2]
        let p90 = sorted[Int(Double(sorted.count) * 0.9)]
        // These limits detect a return to metro-wide assignment. They are deliberately regional:
        // 50 km is not a neighbourhood. Improving sparse coverage must change anchors, not relax
        // these bounds after seeing a failed fetch. Individual outliers remain visible in audits.
        print("COMMUNITY-HOME samples=\(sorted.count) medianKm=\(median) p90Km=\(p90)")
        #expect(median < 20, "the median athlete starts \(Int(median)) km from home")
        #expect(p90 < 50, "nine in ten athletes should start within 50 km of home, saw \(Int(p90))")
    }

    /// Park-anchored walking geometry exists; this does not establish trail surface. Before the regeneration `mappable` excluded `.trailRun`
    /// outright, with the honest reason that no trail geometry was bundled — so the one sport this
    /// community runs in nature was the one that never showed where.
    @Test func trailGeometryIsBundledAndItIsNotTheStreetPool() {
        let cities = CommunityRoutes.auditCities.sorted()
        let withTrails = cities.filter { !CommunityRoutes.auditPools(city: $0).trail.isEmpty }
        #expect(withTrails.count > cities.count / 2,
                "only \(withTrails.count) of \(cities.count) metros bundle trail loops")
        // A trail loop is its own geometry, not a run loop under another name.
        for city in withTrails {
            let pools = CommunityRoutes.auditPools(city: city)
            let runStarts = Set(pools.run.compactMap { $0.pts.first.map { "\($0)" } })
            for trail in pools.trail {
                guard let start = trail.pts.first else { continue }
                #expect(!runStarts.contains("\(start)"),
                        "\(city): a trail loop starts exactly where a run loop does")
            }
        }
    }

    /// A trail run reaches the wall with a map now, in the metros that have the geometry.
    @Test func aTrailRunPostCanCarryItsRoute() {
        let mapped = CommunityDirectory.all()
            .filter { $0.isSample && $0.primaryType == .trailRun }
            .flatMap(\.posts)
            .filter { $0.type == .trailRun }
        #expect(!mapped.isEmpty, "the community posts no trail runs at all")
        let withRoute = mapped.filter { ($0.routeLatLon?.count ?? 0) > 1 }
        let metrosWithTrails = CommunityRoutes.auditCities
            .filter { !CommunityRoutes.auditPools(city: $0).trail.isEmpty }.count
        #expect(!withRoute.isEmpty,
                """
                \(mapped.count) trail-run cards on the wall and not one draws its route, \
                though \(metrosWithTrails) metros bundle trail geometry
                """)
    }

    /// Local coordinate/length sanity. Actual encoder/decoder equivalence is proved by the
    /// Python test that compiles this production Swift decoder and compares every coordinate.
    @Test func theBundleDecodesToPlausibleCoordinates() {
        var checked = 0
        for (city, loop) in loops() {
            let pts = loop.pts
            #expect(pts.count > 3, "\(city): a loop decoded to \(pts.count) points")
            for p in pts {
                #expect(p.count == 2)
                #expect(p[0] > -90 && p[0] < 90, "\(city): latitude \(p[0]) is not on Earth")
                #expect(p[1] > -180 && p[1] < 180, "\(city): longitude \(p[1]) is not on Earth")
            }
            // The shipped length is the drawn length — the contract `mapsAndStatsAgree` rests on.
            var drawn = 0.0
            for i in 1..<pts.count {
                drawn += CommunityRoutes.longestChordM([pts[i - 1], pts[i]])
            }
            #expect(abs(drawn / 1000 - loop.km) < max(0.35, loop.km * 0.02),
                    "\(city): ships \(loop.km) km, draws \(String(format: "%.2f", drawn / 1000)) km")
            checked += 1
        }
        #expect(checked > 300)
    }
}
