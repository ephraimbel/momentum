import Testing
import CoreLocation
@testable import Momentum

/// Where Today's map opens. The case the owner asked for (2026-08-28) is the first one: an athlete
/// who has just finished onboarding — location granted at the "Map your runs" beat, no workout
/// history at all — must land ON THEMSELVES, never on a world map.
struct TodayMapOpeningTests {
    private let me = CLLocationCoordinate2D(latitude: 40.7580, longitude: -73.9855)
    private let home = CLLocationCoordinate2D(latitude: 30.2672, longitude: -97.7431)

    @Test func freshlyOnboardedAthleteOpensOnThemselves() {
        // Granted at onboarding, a fix already in hand, zero history — the exact first launch.
        #expect(TodayMapOpening.decide(fix: me, history: nil, authorized: true) == .athlete(me))
        // Granted, but the fix hasn't landed yet: follow the puck so the map arrives with it —
        // still never the world camera.
        #expect(TodayMapOpening.decide(fix: nil, history: nil, authorized: true) == .followPuck)
    }

    @Test func aLiveFixBeatsTheHistoryNeighbourhood() {
        // Travelling: today's fix wins over the neighbourhood their old routes imply.
        #expect(TodayMapOpening.decide(fix: me, history: home, authorized: true) == .athlete(me))
        // Offline or permission not yet granted, but they have history — open where they train.
        #expect(TodayMapOpening.decide(fix: nil, history: home, authorized: false) == .athlete(home))
    }

    @Test func nothingKnownStaysHonest() {
        // No fix, no history, no permission: the neutral camera — never a guessed neighbourhood,
        // and it's flagged as still owing the athlete a centre.
        let opening = TodayMapOpening.decide(fix: nil, history: nil, authorized: false)
        #expect(opening == .unlocated)
        #expect(opening.awaitsFirstFix)
        #expect(!TodayMapOpening.decide(fix: me, history: nil, authorized: true).awaitsFirstFix)
        #expect(!TodayMapOpening.decide(fix: nil, history: nil, authorized: true).awaitsFirstFix)
    }
}
