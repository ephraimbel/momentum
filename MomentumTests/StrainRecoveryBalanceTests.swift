import Testing
import Foundation
@testable import Momentum

/// Recovery Hub plan §4.5 fixtures — the strain-vs-recovery balance behind the hub's signature chart.
struct StrainRecoveryBalanceTests {
    /// Fixed clock + UTC calendar so day-bucketing is deterministic on any machine.
    private let now = Date(timeIntervalSince1970: 1_760_000_000)   // 2025-10-09 09:33:20 UTC
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func pair(daysAgo: Int, strain: Double?, readiness: Double?)
        -> (day: Date, strain: Double?, readiness: Double?) {
        (now.addingTimeInterval(-Double(daysAgo) * 86_400), strain, readiness)
    }

    /// A full 7-day week where every day's readiness − strain equals `balance` exactly.
    private func week(balance: Double, strain: Double = 50) -> [(day: Date, strain: Double?, readiness: Double?)] {
        (0..<7).map { pair(daysAgo: $0, strain: strain, readiness: strain + balance) }
    }

    private func state(ofWeekBalance balance: Double, ctlDelta7: Double = 0) -> StrainRecoveryBalance.State {
        StrainRecoveryBalance(dailyPairs: week(balance: balance), spineDays: 7,
                              ctlDelta7: ctlDelta7, now: now, calendar: cal).state
    }

    // MARK: State bands

    @Test func oneStatePerBandAtExactBoundaries() {
        // §4.5 cuts on d̄: < −10 → overreaching · [−10, 25) → building · [25, 45) → balanced ·
        // ≥ 45 → CTL-guarded. Each boundary value lands in the band whose bracket includes it.
        #expect(state(ofWeekBalance: -11) == .overreaching)
        #expect(state(ofWeekBalance: -10) == .building)      // −10 exactly is building, not overreaching
        #expect(state(ofWeekBalance: 24) == .building)
        #expect(state(ofWeekBalance: 25) == .balanced)       // 25 exactly is balanced
        #expect(state(ofWeekBalance: 44) == .balanced)
        #expect(state(ofWeekBalance: 45) == .detraining)     // 45 exactly, fitness flat (ctlDelta7 = 0)
    }

    @Test func bandingHandlesFractionalMeans() {
        // The banding function directly — real weeks produce non-integer d̄.
        #expect(StrainRecoveryBalance.state(meanDelta: -10.001, ctlDelta7: 0) == .overreaching)
        #expect(StrainRecoveryBalance.state(meanDelta: -10, ctlDelta7: 0) == .building)
        #expect(StrainRecoveryBalance.state(meanDelta: 24.999, ctlDelta7: 0) == .building)
        #expect(StrainRecoveryBalance.state(meanDelta: 25, ctlDelta7: 0) == .balanced)
        #expect(StrainRecoveryBalance.state(meanDelta: 44.999, ctlDelta7: 0) == .balanced)
        #expect(StrainRecoveryBalance.state(meanDelta: 45, ctlDelta7: -1) == .detraining)
    }

    @Test func taperGuardBothDirections() {
        // d̄ ≥ 45 alone is ambiguous: on climbing fitness it's a plan working (balanced); on flat
        // or falling fitness it's detraining. Exactly zero counts as not climbing.
        #expect(state(ofWeekBalance: 50, ctlDelta7: 1.5) == .balanced)    // the taper guard fires
        #expect(state(ofWeekBalance: 50, ctlDelta7: 0) == .detraining)    // flat CTL → no guard
        #expect(state(ofWeekBalance: 50, ctlDelta7: -2) == .detraining)   // falling CTL → detraining
    }

    @Test func meanIsComputedAcrossMixedDays() {
        // Balances −40, −10, 0, +10 over the 4 valid days → d̄ = −40/4 = −10 exactly → building:
        // one rough morning inside an otherwise-even week is not overreaching.
        let pairs = [
            pair(daysAgo: 0, strain: 80, readiness: 40),   // −40
            pair(daysAgo: 1, strain: 60, readiness: 50),   // −10
            pair(daysAgo: 2, strain: 50, readiness: 50),   //   0
            pair(daysAgo: 3, strain: 40, readiness: 50),   // +10
        ]
        let r = StrainRecoveryBalance(dailyPairs: pairs, spineDays: 7,
                                      ctlDelta7: 0, now: now, calendar: cal)
        #expect(r.state == .building)
    }

    // MARK: Insufficient data

    @Test func threeValidDaysOfSevenIsInsufficientFourIsNot() {
        // 3 both-sided days + 4 strain-only days: the half-present days never count toward the
        // ≥ 4 bar, so the week gets no verdict — however extreme the valid days read.
        let three = (0..<3).map { pair(daysAgo: $0, strain: 90, readiness: 20) }
                  + (3..<7).map { pair(daysAgo: $0, strain: 60, readiness: nil) }
        let a = StrainRecoveryBalance(dailyPairs: three, spineDays: 7,
                                      ctlDelta7: 0, now: now, calendar: cal)
        #expect(a.state == .insufficient)

        // The 4th valid day crosses the bar and the verdict appears (d̄ = −70 → overreaching).
        let four = (0..<4).map { pair(daysAgo: $0, strain: 90, readiness: 20) }
        let b = StrainRecoveryBalance(dailyPairs: four, spineDays: 7,
                                      ctlDelta7: 0, now: now, calendar: cal)
        #expect(b.state == .overreaching)
    }

    @Test func emptyInputYieldsAFullNilSpineAndInsufficient() {
        // Day one with nothing synced still gets a designed chart: a full spine of holes.
        let r = StrainRecoveryBalance(dailyPairs: [], spineDays: 7,
                                      ctlDelta7: 0, now: now, calendar: cal)
        #expect(r.days.count == 7)
        #expect(r.days.allSatisfy { $0.strain == nil && $0.readiness == nil && $0.balance == nil })
        #expect(r.state == .insufficient)
    }

    // MARK: The spine

    @Test func nilHolesStayOnTheSpineButNeverEnterTheMean() {
        // 5 valid days at balance +30; days 2 and 5 missing entirely. d̄ over the 5 valid days
        // = 30 → balanced. If the holes leaked in as zeros the mean would read 150/7 ≈ 21.4 →
        // building — so the .balanced verdict proves the exclusion.
        let pairs = [0, 1, 3, 4, 6].map { pair(daysAgo: $0, strain: 40, readiness: 70) }
        let r = StrainRecoveryBalance(dailyPairs: pairs, spineDays: 7,
                                      ctlDelta7: 0, now: now, calendar: cal)
        #expect(r.days.count == 7)                          // gap-free: holes present, not dropped
        #expect(r.days[4].balance == nil)                   // 2 days ago → spine index 4
        #expect(r.days[1].balance == nil)                   // 5 days ago → spine index 1
        #expect(r.state == .balanced)
        // Oldest → today, one calendar day per slot, ending today.
        for (a, b) in zip(r.days, r.days.dropFirst()) {
            #expect(b.date.timeIntervalSince(a.date) == 86_400)
        }
        #expect(r.days.last?.date == cal.startOfDay(for: now))
    }

    @Test func balanceIsNilWhenEitherSideIsMissing() {
        let pairs = [
            pair(daysAgo: 0, strain: 55, readiness: 70),    // both → +15
            pair(daysAgo: 1, strain: 55, readiness: nil),   // no morning signals that day
            pair(daysAgo: 2, strain: nil, readiness: 80),   // no strain read that day
        ]
        let r = StrainRecoveryBalance(dailyPairs: pairs, spineDays: 7,
                                      ctlDelta7: 0, now: now, calendar: cal)
        #expect(r.days[6].balance == 15)
        #expect(r.days[5].balance == nil && r.days[5].strain == 55)
        #expect(r.days[4].balance == nil && r.days[4].readiness == 80)
    }

    @Test func thirtyDaySpineIsGapFreeAndStateReadsOnlyTheTrailingSeven() {
        // Days 7–29 read deeply overreached (balance −80); the trailing 7 sit at +30. The spine
        // carries all 30 entries, but the state only ever judges the last week.
        let old = (7..<30).map { pair(daysAgo: $0, strain: 90, readiness: 10) }
        let recent = (0..<7).map { pair(daysAgo: $0, strain: 40, readiness: 70) }
        let r = StrainRecoveryBalance(dailyPairs: old + recent, spineDays: 30,
                                      ctlDelta7: 0, now: now, calendar: cal)
        #expect(r.days.count == 30)
        #expect(r.days.first?.balance == -80)
        #expect(r.state == .balanced)
    }

    @Test func pairsOutsideTheSpineAreDropped() {
        // A 7-day spine: a pair from 10 days back and a future-dated one never land.
        let pairs = [
            pair(daysAgo: 10, strain: 90, readiness: 10),
            pair(daysAgo: -1, strain: 90, readiness: 10),
            pair(daysAgo: 0, strain: 50, readiness: 60),
        ]
        let r = StrainRecoveryBalance(dailyPairs: pairs, spineDays: 7,
                                      ctlDelta7: 0, now: now, calendar: cal)
        #expect(r.days.count == 7)
        #expect(r.days.compactMap(\.balance) == [10])
        #expect(r.state == .insufficient)                   // one valid day inside the week
    }

    @Test func duplicateDayEntriesLastWriteWins() {
        // Callers compute one pair per day; if two land on the same day the later entry wins
        // rather than silently blending two versions of one day.
        let pairs = [
            pair(daysAgo: 0, strain: 90, readiness: 10),
            pair(daysAgo: 0, strain: 40, readiness: 70),
        ]
        let r = StrainRecoveryBalance(dailyPairs: pairs, spineDays: 7,
                                      ctlDelta7: 0, now: now, calendar: cal)
        #expect(r.days.last?.strain == 40)
        #expect(r.days.last?.balance == 30)
    }
}
