import Testing
import Foundation
@testable import Momentum

/// `PlanWeekLedger` — the Plan board's planned-vs-done numbers and the masthead arc's per-week
/// buckets. The bar it drives is the first thing the page says about a week, so every fraction
/// rule (and especially the no-shame overrides) is pinned.
struct PlanWeekLedgerTests {

    private func session(_ meters: Double?, done: Bool = false) -> PlanWeekLedger.Session {
        .init(targetDistanceM: meters, completed: done)
    }

    // MARK: The fraction rules

    @Test func volumeDrivesTheBarWhenTheWeekHasDistanceTargets() {
        let l = PlanWeekLedger.ledger(sessions: [session(5_000), session(8_000, done: true)],
                                      actualCardioM: 6_500)
        #expect(abs(l.fraction - 0.5) < 0.001)   // 6.5 of 13 km, NOT 1 of 2 sessions
        #expect(l.plannedM == 13_000)
        #expect(l.doneM == 6_500)
    }

    @Test func aFullyCheckedWeekReadsFullEvenWithLittleRecordedMileage() {
        // Treadmill days, imported summaries, manual check-offs: the athlete said done, and the
        // bar must never quietly dispute them.
        let l = PlanWeekLedger.ledger(sessions: [session(5_000, done: true), session(8_000, done: true)],
                                      actualCardioM: 900)
        #expect(l.fraction == 1)
    }

    @Test func overVolumeCapsAtFullRatherThanOverflowing() {
        let l = PlanWeekLedger.ledger(sessions: [session(5_000)], actualCardioM: 9_000)
        #expect(l.fraction == 1)
    }

    @Test func aStrengthOnlyWeekFallsBackToSessionCounts() {
        let l = PlanWeekLedger.ledger(sessions: [session(nil, done: true), session(nil)],
                                      actualCardioM: 0)
        #expect(abs(l.fraction - 0.5) < 0.001)
        #expect(l.plannedM == 0)
    }

    @Test func anEmptyWeekIsZeroNotDivisionByZero() {
        let l = PlanWeekLedger.ledger(sessions: [], actualCardioM: 3_000)
        #expect(l.fraction == 0)
        #expect(l.totalSessions == 0)
    }

    @Test func negativeActualMileageIsClampedNotPropagated() {
        let l = PlanWeekLedger.ledger(sessions: [session(5_000)], actualCardioM: -50)
        #expect(l.doneM == 0)
        #expect(l.fraction == 0)
    }

    // MARK: The arc's buckets

    private static let cal = Calendar.current
    /// Monday-anchored week starts, `count` consecutive weeks from a fixed reference.
    private func weekStarts(_ count: Int) -> [Date] {
        let ref = Date(timeIntervalSince1970: 1_700_000_000)
        let first = Self.cal.dateInterval(of: .weekOfYear, for: ref)!.start
        return (0..<count).map { Self.cal.date(byAdding: .weekOfYear, value: $0, to: first)! }
    }

    @Test func sessionsBucketIntoTheirOwnWeeks() {
        let weeks = weekStarts(3)
        let sessions: [(date: Date, targetDistanceM: Double?)] = [
            (weeks[0].addingTimeInterval(2 * 86_400), 5_000),
            (weeks[0].addingTimeInterval(5 * 86_400), 8_000),
            (weeks[2].addingTimeInterval(1 * 86_400), 12_000),
        ]
        #expect(PlanWeekLedger.plannedMetersByWeek(sessions: sessions, weekStarts: weeks, calendar: Self.cal)
                == [13_000, 0, 12_000])
    }

    @Test func carriedHistoryBeforeTheBlockLandsNowhere() {
        // The strip starts at the block; a completed race from the week before must not grow a
        // phantom leading bar (the same rule that fixed the "Week 1 of 6 / WK 2" mismatch).
        let weeks = weekStarts(2)
        let before = Self.cal.date(byAdding: .weekOfYear, value: -1, to: weeks[0])!
        let sessions: [(date: Date, targetDistanceM: Double?)] = [
            (before.addingTimeInterval(3 * 86_400), 21_097),
            (weeks[1].addingTimeInterval(3 * 86_400), 6_000),
        ]
        #expect(PlanWeekLedger.plannedMetersByWeek(sessions: sessions, weekStarts: weeks, calendar: Self.cal)
                == [0, 6_000])
    }

    @Test func strengthSessionsAddNothingToTheArc() {
        let weeks = weekStarts(1)
        let sessions: [(date: Date, targetDistanceM: Double?)] = [
            (weeks[0].addingTimeInterval(86_400), nil),
            (weeks[0].addingTimeInterval(2 * 86_400), 0),
        ]
        #expect(PlanWeekLedger.plannedMetersByWeek(sessions: sessions, weekStarts: weeks, calendar: Self.cal)
                == [0])
    }

    @Test func emptyWeekListYieldsEmptyBuckets() {
        #expect(PlanWeekLedger.plannedMetersByWeek(sessions: [(Date(), 5_000)], weekStarts: [],
                                                   calendar: Self.cal).isEmpty)
    }
}
