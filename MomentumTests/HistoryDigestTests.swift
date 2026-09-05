import Testing
import SwiftUI
import Foundation
@testable import Momentum

/// The History summary's arithmetic (2026-08-28) — the card is only as good as these numbers.
@MainActor
struct HistoryDigestTests {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private var now: Date { cal.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: 12))! }

    private func workout(_ day: Int, month: Int = 8, meters: Double = 0, seconds: Double = 1800,
                         type: WorkoutType = .run) -> Workout {
        let w = Workout()
        w.type = type
        w.startedAt = cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: 7))!
        w.durationS = seconds
        if meters > 0 {
            let gps = GPSDetail(); gps.distanceM = meters; w.gps = gps
        }
        return w
    }

    @Test func sumsThisMonthAndComparesWithLast() {
        let ws = [workout(2, meters: 10_000), workout(9, meters: 5_000, seconds: 900),
                  workout(14, month: 7, meters: 10_000)]                      // last month: 10 km
        let d = HistoryDigest.build(workouts: ws, prDates: [], now: now, calendar: cal)
        #expect(d.sessions == 2)
        #expect(d.meters == 15_000)
        #expect(d.seconds == 2_700)
        #expect(d.previousSessions == 1)
        #expect(abs((d.distanceDeltaFraction ?? 0) - 0.5) < 0.0001)           // 15 vs 10 km = +50%
    }

    @Test func neverInventsADeltaWithoutABaseline() {
        // Nothing last month → no chip (a "+100%" against zero is a lie).
        let only = [workout(3, meters: 8_000)]
        #expect(HistoryDigest.build(workouts: only, prDates: [], now: now, calendar: cal).distanceDeltaFraction == nil)
        // A strength-only month has no distance on either side → still no chip, but the sessions
        // and time are counted honestly.
        let lifts = [workout(3, seconds: 3_600, type: .strength), workout(12, month: 7, seconds: 3_600, type: .strength)]
        let d = HistoryDigest.build(workouts: lifts, prDates: [], now: now, calendar: cal)
        #expect(d.distanceDeltaFraction == nil)
        #expect(d.sessions == 1 && d.seconds == 3_600 && d.previousSessions == 1)
    }

    @Test func prsAreMonthScopedNotLifetime() {
        let ws = [workout(4, meters: 5_000)]
        let prs = [cal.date(from: DateComponents(year: 2026, month: 8, day: 4))!,
                   cal.date(from: DateComponents(year: 2026, month: 8, day: 18))!,
                   cal.date(from: DateComponents(year: 2025, month: 11, day: 2))!]   // last year
        #expect(HistoryDigest.build(workouts: ws, prDates: prs, now: now, calendar: cal).prs == 2)
    }

    @Test func filtersBucketEverySportAndCountThemselves() {
        let ws = [workout(2, meters: 5_000, type: .run), workout(3, type: .strength),
                  workout(4, meters: 20_000, type: .ride), workout(5, type: .yoga),
                  workout(6, meters: 3_000, type: .trailRun)]
        #expect(HistoryFilter.runs.matches(ws[0]) && HistoryFilter.runs.matches(ws[4]))
        #expect(HistoryFilter.strength.matches(ws[1]))
        #expect(HistoryFilter.rides.matches(ws[2]))
        #expect(HistoryFilter.other.matches(ws[3]))
        // Every workout lands in exactly one non-all bucket — no session can hide from the filter.
        for w in ws {
            let hits = [HistoryFilter.runs, .rides, .strength, .other].filter { $0.matches(w) }
            #expect(hits.count == 1, "\(w.type.rawValue) matched \(hits.count) buckets")
        }
        let chips = HistoryFilter.available(in: ws)
        #expect(chips.first?.filter == .all && chips.first?.count == 5)
        #expect(chips.map(\.filter) == [.all, .runs, .rides, .strength, .other])
        #expect(chips.first(where: { $0.filter == .runs })?.count == 2)
        #expect(HistoryFilter.available(in: []).isEmpty)
    }

    @Test func aSingleSportAthleteGetsNoChipRow() {
        let runsOnly = [workout(2, meters: 5_000), workout(3, meters: 6_000)]
        #expect(HistoryFilter.available(in: runsOnly).count == 2)   // .all + .runs → caller shows none
    }

    /// The History map card previews the full heatmap, so both resolve one basemap — and the two
    /// adaptive Realistic style follows appearance while every explicit pick stays literal.
    @Test func mapStylePairsWithTheAppearance() {
        #expect(MapStyleOption.realistic.renderedStyle(for: .dark) == .night)
        #expect(MapStyleOption.standard.renderedStyle(for: .dark) == .standard)
        #expect(MapStyleOption.realistic.renderedStyle(for: .light) == .realistic)
        #expect(MapStyleOption.standard.renderedStyle(for: .light) == .standard)
        // Deliberate choices are never overridden, in either appearance.
        for deliberate in [MapStyleOption.satellite, .streets, .outdoors, .dark, .night, .dusk, .standardSatellite] {
            #expect(deliberate.renderedStyle(for: .dark) == deliberate)
            #expect(deliberate.renderedStyle(for: .light) == deliberate)
        }
    }

    /// A month's total is a SPAN, never a clock reading ("23h 40m", not "23:40:37").
    @Test func compactDurationReadsAsASpan() {
        #expect(Formatters.compactDuration(s: 85_237) == "23h 40m")
        #expect(Formatters.compactDuration(s: 3_600) == "1h")
        #expect(Formatters.compactDuration(s: 2_700) == "45m")
        #expect(Formatters.compactDuration(s: 12) == "12s")
        #expect(Formatters.compactDuration(s: 0) == "0s")
        #expect(Formatters.compactDuration(s: -5) == "0s")
    }
}
