import Testing
import Foundation
@testable import Momentum

/// The celebration ring is the app's most prominent iridescent surface, so what it claims has to be
/// exactly true — and, per the no-shame rule, it must never be able to travel backwards.
struct WeekRingTests {

    @Test func theSweepIsExactlyWhatThisSessionAdded() throws {
        // 8 km already logged, 12 km target, a 4 km run just finished.
        let r = try #require(WeekRing.reading(justFinishedM: 4_000, earlierThisWeekM: 8_000, targetM: 12_000))
        #expect(abs(r.from - 8.0 / 12.0) < 0.0001)
        #expect(abs(r.to - 1.0) < 0.0001)
        #expect(r.completedM == 12_000)
    }

    @Test func aFirstRunOfTheWeekStartsFromEmpty() throws {
        let r = try #require(WeekRing.reading(justFinishedM: 5_000, earlierThisWeekM: 0, targetM: 20_000))
        #expect(r.from == 0)
        #expect(abs(r.to - 0.25) < 0.0001)
    }

    /// The whole point: the ring can only ever move forward.
    @Test func theRingNeverTravelsBackwards() {
        for finished in stride(from: 100.0, through: 30_000, by: 700) {
            for earlier in stride(from: 0.0, through: 30_000, by: 900) {
                guard let r = WeekRing.reading(justFinishedM: finished, earlierThisWeekM: earlier, targetM: 20_000)
                else { continue }
                #expect(r.to >= r.from)
                #expect(r.from >= 0 && r.to <= 1)
            }
        }
    }

    @Test func overshootingTheTargetClampsRatherThanOverfilling() throws {
        // 18 of 20 km banked, then a 30 km run blows past the target.
        let r = try #require(WeekRing.reading(justFinishedM: 30_000, earlierThisWeekM: 18_000, targetM: 20_000))
        #expect(abs(r.from - 0.9) < 0.0001)      // where the week genuinely stood
        #expect(r.to == 1)                       // clamped — the ring can't overfill
        #expect(r.completedM == 48_000)          // but the caption still tells the truth
        #expect(r.closedTheWeek)                 // this is the run that crossed the line
    }

    @Test func aWeekAlreadyPastItsTargetStartsAndStaysFull() throws {
        let r = try #require(WeekRing.reading(justFinishedM: 4_000, earlierThisWeekM: 24_000, targetM: 20_000))
        #expect(r.from == 1)
        #expect(r.to == 1)
    }

    // MARK: Closing the week — the one earned claim

    @Test func closingTheWeekIsRecognised() throws {
        let r = try #require(WeekRing.reading(justFinishedM: 4_000, earlierThisWeekM: 16_000, targetM: 20_000))
        #expect(r.closedTheWeek)
    }

    @Test func aWeekAlreadyClosedIsNotClosedAgain() throws {
        // Credit belongs to the run that crossed the line, not to every run after it.
        let r = try #require(WeekRing.reading(justFinishedM: 4_000, earlierThisWeekM: 21_000, targetM: 20_000))
        #expect(!r.closedTheWeek)
    }

    @Test func fallingShortOfTheWeekMakesNoClaim() throws {
        let r = try #require(WeekRing.reading(justFinishedM: 4_000, earlierThisWeekM: 8_000, targetM: 20_000))
        #expect(!r.closedTheWeek)
    }

    // MARK: Nothing honest to draw

    @Test func noTargetMeansNoRing() {
        #expect(WeekRing.reading(justFinishedM: 5_000, earlierThisWeekM: 0, targetM: 0) == nil)
        #expect(WeekRing.reading(justFinishedM: 5_000, earlierThisWeekM: 0, targetM: -1) == nil)
    }

    /// A treadmill run that never locked GPS has nothing to contribute — better a plain sweep than a
    /// ring claiming a contribution of zero.
    @Test func aSessionWithNoDistanceMeansNoRing() {
        #expect(WeekRing.reading(justFinishedM: 0, earlierThisWeekM: 8_000, targetM: 20_000) == nil)
    }

    @Test func negativePriorVolumeIsTreatedAsNone() throws {
        let r = try #require(WeekRing.reading(justFinishedM: 5_000, earlierThisWeekM: -400, targetM: 20_000))
        #expect(r.from == 0)
        #expect(abs(r.to - 0.25) < 0.0001)
    }
}
