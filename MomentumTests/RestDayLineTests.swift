import Testing
import Foundation
@testable import Momentum

/// `RestDayLine` — the one quiet line a rest day earns on the Plan board. The rules are a strict
/// priority ladder (tomorrow beats yesterday, the biggest sessions beat the rest), and the default
/// is deliberately nil: a manufactured reason on every row would devalue the real ones.
struct RestDayLineTests {

    private func line(y: RestDayLine.Neighbor = .none, t: RestDayLine.Neighbor = .none,
                      d2: RestDayLine.Neighbor = .none, phase: PlanPhase? = nil) -> String? {
        RestDayLine.line(yesterday: y, tomorrow: t, dayAfter: d2, phase: phase)
    }

    // MARK: The ladder, rung by rung

    @Test func tomorrowsRaceOutranksEverything() {
        #expect(line(y: .long, t: .race, d2: .long, phase: .taper)
                == "Rest — everything banked for race day.")
    }

    @Test func tomorrowsLongRunReadsAsPreparation() {
        #expect(line(t: .long) == "Rest — fresh legs for tomorrow's long run.")
    }

    @Test func tomorrowsQualityReadsAsPreparation() {
        #expect(line(t: .quality) == "Rest — fresh for tomorrow's speed work.")
    }

    @Test func preparationOutranksAbsorption() {
        // The future is actionable; the past is done. A rest between intervals and a long run is
        // ABOUT the long run.
        #expect(line(y: .quality, t: .long) == "Rest — fresh legs for tomorrow's long run.")
    }

    @Test func yesterdaysLongRunReadsAsAbsorption() {
        #expect(line(y: .long) == "Rest — absorbing yesterday's long run.")
        #expect(line(y: .quality) == "Rest — absorbing yesterday's hard work.")
        #expect(line(y: .race) == "Rest — you earned this one.")
    }

    @Test func twoDaysOutFromTheLongRunStillEarnsALine() {
        #expect(line(d2: .long) == "Rest — two days out from the long run.")
        #expect(line(d2: .race) == "Rest — two days out from the race.")
    }

    @Test func phaseLinesAreTheLastResort() {
        #expect(line(phase: .taper) == "Rest — the taper is doing its work.")
        #expect(line(phase: .recovery) == "Rest — down week, lighter on purpose.")
        // But any neighbour rule still wins over the phase.
        #expect(line(y: .long, phase: .taper) == "Rest — absorbing yesterday's long run.")
    }

    // MARK: What deliberately says nothing

    @Test func ordinaryNeighboursEarnNoLine() {
        // Easy runs and lifts don't justify a rest story; nor does a bare week. The plain
        // "Rest day" fallback is the honest default, not a failure to think of something.
        #expect(line() == nil)
        #expect(line(y: .easy, t: .easy) == nil)
        #expect(line(y: .strength, t: .strength) == nil)
        #expect(line(phase: .base) == nil)
        #expect(line(phase: .build) == nil)
        #expect(line(phase: .peak) == nil)
    }

    // MARK: The strongest-claim reducer

    @Test func aDayWithSeveralSessionsIsNamedByItsBiggest() {
        #expect(RestDayLine.strongest([.easy, .long, .strength]) == .long)
        #expect(RestDayLine.strongest([.strength, .quality]) == .quality)
        #expect(RestDayLine.strongest([.easy, .race]) == .race)
        #expect(RestDayLine.strongest([.strength, .easy]) == .strength)
        #expect(RestDayLine.strongest([]) == .none)
    }

    // MARK: Voice

    @Test func noLineShamesOrShouts() {
        let all: [RestDayLine.Neighbor] = [.race, .long, .quality, .strength, .easy, .none]
        let phases: [PlanPhase?] = [nil, .base, .build, .peak, .recovery, .taper]
        for y in all { for t in all { for d2 in all { for p in phases {
            guard let s = line(y: y, t: t, d2: d2, phase: p) else { continue }
            #expect(!s.contains("!"))
            #expect(s.hasPrefix("Rest — "))
            for banned in ["missed", "behind", "should have", "failed", "lazy"] {
                #expect(!s.lowercased().contains(banned))
            }
        }}}}
    }
}
