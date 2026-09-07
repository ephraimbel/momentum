import Testing
import Foundation
@testable import Momentum

/// `PlanWeekEdit` is the week-shaped edit: take days out of a week and let the work find somewhere
/// to go. Its contract is that it never quietly makes the week harder — no doubling up, no work
/// crammed in before a trip, and anything it cannot place is left alone for the caller to report.
@Suite("PlanWeekEdit")
struct PlanWeekEditTests {

    private func ids(_ n: Int) -> [UUID] { (0..<n).map { _ in UUID() } }

    // MARK: Placement

    @Test func aBlockedSessionMovesToTheNearestOpenDay() {
        let id = UUID()
        // Work on Thursday (3); the athlete is away Thursday. Friday (4) is open.
        let out = PlanWeekEdit.awayPlacements(sessions: [(id, 3)], blocked: [3])
        #expect(out[id] == 4)
    }

    @Test func tiesGoForward() {
        // Wednesday (2) blocked, with Tuesday (1) and Thursday (3) both open and equidistant.
        // Work you miss while away belongs after the trip, not crammed in before you leave.
        let id = UUID()
        let out = PlanWeekEdit.awayPlacements(sessions: [(id, 2)], blocked: [2])
        #expect(out[id] == 3)
    }

    @Test func itSearchesBackwardWhenForwardIsFull() {
        let (away, sat, sun) = (UUID(), UUID(), UUID())
        // Friday (4) blocked; Saturday and Sunday already hold work; Thursday (3) is open.
        let out = PlanWeekEdit.awayPlacements(
            sessions: [(away, 4), (sat, 5), (sun, 6)], blocked: [4])
        #expect(out[away] == 3)
        #expect(out[sat] == nil && out[sun] == nil)   // unblocked days never move
    }

    @Test func itNeverDoublesUpADay() {
        let all = ids(3)
        // Three sessions on blocked Thu/Fri/Sat (3,4,5); Sun (6), Mon (0), Tue (1) are open.
        let out = PlanWeekEdit.awayPlacements(
            sessions: [(all[0], 3), (all[1], 4), (all[2], 5)], blocked: [3, 4, 5])
        let landed = all.compactMap { out[$0] }
        #expect(landed.count == 3)
        #expect(Set(landed).count == 3, "two sessions must never land on the same day")
        #expect(landed.allSatisfy { ![3, 4, 5].contains($0) })
    }

    @Test func aSessionWithNowhereToGoStaysPut() {
        // Every day either blocked or already busy: the engine reports nothing rather than
        // stacking work onto a week the athlete is already losing days from.
        let stuck = UUID()
        let busy = ids(4)
        let sessions = [(stuck, 0), (busy[0], 3), (busy[1], 4), (busy[2], 5), (busy[3], 6)]
        let out = PlanWeekEdit.awayPlacements(sessions: sessions, blocked: [0, 1, 2])
        #expect(out[stuck] == nil)
    }

    // MARK: Ordering is deterministic

    @Test func earlierSessionsClaimTheirDayFirst() {
        let (thu, fri) = (UUID(), UUID())
        let early = ids(3)
        // Mon–Wed (0,1,2) already hold work, Thu (3) and Fri (4) are blocked and hold the two
        // sessions that must move, Sat (5) and Sun (6) are the only open days. Thursday's session
        // takes Saturday and Friday's takes Sunday — the earlier one is never leapfrogged, whatever
        // order the sessions arrive in.
        let out = PlanWeekEdit.awayPlacements(
            sessions: [(fri, 4), (thu, 3), (early[0], 0), (early[1], 1), (early[2], 2)],
            blocked: [3, 4])
        #expect(out[thu] == 5)
        #expect(out[fri] == 6)
    }

    @Test func aCloserOpenDayBeatsOneOnTheFarSideOfTheTrip() {
        // Thu (3) blocked with Wed (2) open and Sat (5) open: Wednesday is closer, so the session
        // keeps the spacing the plan gave it rather than being pushed past the absence. Nearest
        // wins; forward only breaks ties.
        let id = UUID()
        let sat = UUID()
        let out = PlanWeekEdit.awayPlacements(sessions: [(id, 3), (sat, 4)], blocked: [3, 4])
        #expect(out[id] == 2)
    }

    @Test func theSameInputAlwaysPlacesTheSameWay() {
        let a = UUID(), b = UUID()
        let forward = PlanWeekEdit.awayPlacements(sessions: [(a, 2), (b, 2)], blocked: [2])
        let reversed = PlanWeekEdit.awayPlacements(sessions: [(b, 2), (a, 2)], blocked: [2])
        #expect(forward == reversed, "placement must not depend on the order sessions arrive in")
    }

    // MARK: Nothing to do

    @Test func anUnblockedWeekIsUntouched() {
        let all = ids(3)
        let out = PlanWeekEdit.awayPlacements(
            sessions: [(all[0], 1), (all[1], 3), (all[2], 5)], blocked: [])
        #expect(out.isEmpty)
    }

    @Test func blockedDaysWithNoWorkMoveNothing() {
        let id = UUID()
        let out = PlanWeekEdit.awayPlacements(sessions: [(id, 1)], blocked: [4, 5])
        #expect(out.isEmpty)
    }
}
