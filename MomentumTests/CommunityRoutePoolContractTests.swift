import Foundation
import Testing
@testable import Momentum

@MainActor
struct CommunityRoutePoolContractTests {
    @Test func examplePostsNeverPretendToHaveMeasuredAnalysis() {
        for athlete in CommunityDirectory.all() where athlete.isSample {
            #expect(athlete.posts.allSatisfy { $0.aiRead == nil })
        }
    }

    @Test func everyMappedLeadUsesTheSameHomePoolAsItsLedger() {
        var checked = 0
        let athletes = CommunityDirectory.all()
        let start = ProcessInfo.processInfo.systemUptime
        for athlete in athletes where athlete.isSample {
            guard athlete.ledgerLead == nil,
                  let post = athlete.posts.first,
                  let lead = CommunityLedger.lead(handle: athlete.handle, primary: athlete.primaryType,
                    city: athlete.routeCity, count: athlete.totalWorkouts,
                    clock: CommunityDirectory.seedClock, home: athlete.homeCoordinate),
                  let slot = lead.session.routePool else { continue }
            let pool = CommunityRoutes.pools(city: athlete.routeCity, near: athlete.homeCoordinate)
            let lengths = pool.kms(for: lead.session.type)
            #expect(lengths.indices.contains(slot))
            guard lengths.indices.contains(slot) else { continue }
            let loop = CommunityRoutes.loop(city: athlete.routeCity, discipline: lead.session.type,
                                            near: athlete.homeCoordinate, slot: slot, offset: 0)
            #expect(loop?.pts == post.routeLatLon, "@\(athlete.handle): ledger/wall geometry diverged")
            #expect(abs(lengths[slot] * 1000 - lead.session.distanceM) < 0.01)
            checked += 1
        }
        print("COMMUNITY-POOL \(checked) mapped leads checked in \((ProcessInfo.processInfo.systemUptime - start) * 1000) ms")
        #expect(checked > 1000)
    }

    @Test func featuredHomesRemainTheWrittenHomeRatherThanAHashPickedSuburb() {
        for athlete in CommunityDirectory.featured() {
            #expect(athlete.homeCoordinate?.lat == athlete.lat)
            #expect(athlete.homeCoordinate?.lon == athlete.lon)
        }
    }

    @Test func demoSamplesPreserveEveryVertexEvenAboveTheOldCap() {
        let loops = CommunityRoutes.auditCities.flatMap { CommunityRoutes.auditLoops(city: $0) }
        guard let loop = loops.first(where: { $0.pts.count > 200 }) else {
            Issue.record("No detailed route fixture"); return
        }
        let samples = DemoSeed.samplesFromLoop(loop, laps: 2, start: Date(),
                                              durationS: 7200, speedMS: 3, dense: false)
        let expected = loop.pts + loop.pts
        #expect(samples.count == expected.count)
        #expect(zip(samples, expected).allSatisfy { $0.lat == $1[0] && $0.lon == $1[1] })
    }

    @Test func malformedGeometryNeverDrawsAPartialRoute() {
        for encoded in ["", "!?", "AQ==", "AgE=", "AoA=", "AgAAgA==", "Av////9/AA=="] {
            #expect(CommunityRoutes.decode(encoded).isEmpty)
        }
        #expect(CommunityRoutes.decode("AgAA") == [[0, 0]])
    }
}
