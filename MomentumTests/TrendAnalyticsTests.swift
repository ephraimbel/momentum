import Testing
import Foundation
@testable import Momentum

/// The Pro-trends numeric layer — CTL/ATL/TSB series, weekly cadence/climb, aerobic decoupling,
/// and the summary tiles. Pure, so fully fixture-testable.
@MainActor
struct TrendAnalyticsTests {

    private func run(daysAgo: Int, minutes: Double, cadence: Int? = nil,
                     climbM: Double = 0, distanceM: Double = 8000) -> Workout {
        let w = Workout(); w.type = .run
        w.startedAt = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        w.durationS = minutes * 60
        let g = GPSDetail(); g.distanceM = distanceM; g.avgCadence = cadence; g.elevationGainM = climbM
        w.gps = g
        return w
    }

    @Test func fitnessFreshnessProducesADailyCurve() {
        // Four weeks of steady running → a non-empty CTL/ATL curve where fitness has accrued.
        let ws = (0..<28).filter { $0 % 2 == 0 }.map { run(daysAgo: $0, minutes: 45) }
        let curve = TrendAnalytics.fitnessFreshness(workouts: ws, days: 60)
        #expect(curve.count == 60)
        #expect(curve.last!.ctl > 0)
        #expect(curve.first!.date < curve.last!.date)   // chronological
    }

    @Test func weeklyCadenceAveragesOnlyRunsWithCadence() {
        let ws = [run(daysAgo: 1, minutes: 40, cadence: 176),
                  run(daysAgo: 3, minutes: 40, cadence: 180),
                  run(daysAgo: 5, minutes: 40, cadence: nil)]   // no cadence → excluded
        let series = TrendAnalytics.weeklyCadence(workouts: ws, weeks: 2)
        #expect(series.last?.value == 178)   // (176+180)/2, the nil ignored
    }

    @Test func weeklyClimbSumsElevation() {
        let ws = [run(daysAgo: 1, minutes: 40, climbM: 120),
                  run(daysAgo: 4, minutes: 40, climbM: 80)]
        let series = TrendAnalytics.weeklyClimb(workouts: ws, weeks: 2)
        #expect(series.last?.value == 200)
    }

    @Test func decouplingIsNilWithoutEnoughData() {
        // A run with no HR series can't have decoupling — must be nil, never a fake number.
        #expect(TrendAnalytics.decoupling(run(daysAgo: 1, minutes: 40)) == nil)
        // A short run (<20 min) is excluded even with data.
        let short = run(daysAgo: 1, minutes: 10)
        #expect(TrendAnalytics.decoupling(short) == nil)
    }

    @Test func decouplingRisesWhenHeartDriftsUpAtSamePace() {
        // Build a 30-min run: constant speed, but HR climbs in the second half → positive decoupling.
        let w = run(daysAgo: 1, minutes: 30)
        let start = w.startedAt
        var hr: [HeartRateSample] = []
        var loc: [LocationSample] = []
        for i in 0..<60 {   // one sample every 30s over 30 min
            let t = start.addingTimeInterval(Double(i) * 30)
            let h = HeartRateSample(); h.t = t; h.bpm = i < 30 ? 150 : 165   // drift up second half
            hr.append(h)
            let l = LocationSample(); l.t = t; l.speedMS = 3.0; l.accepted = true   // steady pace
            l.lat = 37 + Double(i) * 1e-4; l.lon = -122
            loc.append(l)
        }
        w.gps?.hrSamples = hr
        w.gps?.samples = loc
        let d = TrendAnalytics.decoupling(w)
        #expect(d != nil)
        #expect(d! > 5)   // ~10% — HR up ~10% at unchanged pace
    }

    @Test func trendComparesRecentToPriorThird() {
        // Rising series → positive trend; falling → negative.
        #expect(TrendAnalytics.trend([10, 10, 10, 20, 20, 20])! > 0)
        #expect(TrendAnalytics.trend([20, 20, 20, 10, 10, 10])! < 0)
        #expect(TrendAnalytics.trend([5]) == nil)          // too little history
        #expect(TrendAnalytics.trend([0, 0, 0, 0]) == nil) // zero baseline → undefined, not ∞
    }

    @Test func summaryReturnsAllSixMetrics() {
        let ws = (0..<20).map { run(daysAgo: $0, minutes: 45, cadence: 178, climbM: 60) }
        let metrics = TrendAnalytics.summary(workouts: ws)
        #expect(metrics.count == 6)
        #expect(Set(metrics.map(\.kind)).count == 6)   // no dupes
        // Fitness and cadence have data; efficiency (no HR) is unavailable, not a fake 0.
        #expect(metrics.first { $0.kind == .fitness }!.available)
        #expect(metrics.first { $0.kind == .cadence }!.available)
        #expect(!metrics.first { $0.kind == .efficiency }!.available)
    }
}
