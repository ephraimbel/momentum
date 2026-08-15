import Testing
import Foundation
@testable import Momentum

/// The import overlap gate: a Watch/Garmin copy of a run we already have must not import as a
/// second workout (it double-counts volume, ACWR, and every stat).
struct HealthOverlapTests {

    private func span(_ startMin: Double, _ endMin: Double) -> (start: Date, end: Date) {
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        return (base.addingTimeInterval(startMin * 60), base.addingTimeInterval(endMin * 60))
    }

    @Test func identicalSpanIsADuplicate() {
        let existing = [span(0, 40)]
        let s = span(0, 40)
        #expect(HealthService.overlapsExisting(start: s.start, end: s.end, spans: existing))
    }

    @Test func watchCopyWithSlightlyDifferentBoundsIsADuplicate() {
        // The watch started 2 min early and stopped 1 min late — same physical run.
        let existing = [span(2, 42)]
        let s = span(0, 43)
        #expect(HealthService.overlapsExisting(start: s.start, end: s.end, spans: existing))
    }

    @Test func backToBackSessionsAreNotDuplicates() {
        // A run finishing at :40 and a separate ride starting at :40 share only a boundary.
        let existing = [span(0, 40)]
        let s = span(40, 80)
        #expect(!HealthService.overlapsExisting(start: s.start, end: s.end, spans: existing))
    }

    @Test func smallOverlapIsNotADuplicate() {
        // 10 of 60 minutes overlapping (17% of the shorter) — different sessions, e.g. a paused
        // watch recording bleeding into the next activity.
        let existing = [span(0, 60)]
        let s = span(50, 110)
        #expect(!HealthService.overlapsExisting(start: s.start, end: s.end, spans: existing))
    }

    @Test func shortSessionInsideLongOneIsADuplicate() {
        // A 20-min treadmill segment fully inside an hour-long recording: 100% of the shorter.
        let existing = [span(0, 60)]
        let s = span(20, 40)
        #expect(HealthService.overlapsExisting(start: s.start, end: s.end, spans: existing))
    }

    @Test func emptySpansNeverMatch() {
        let s = span(0, 40)
        #expect(!HealthService.overlapsExisting(start: s.start, end: s.end, spans: []))
        #expect(!HealthService.overlapsExisting(start: s.start, end: s.start, spans: [span(0, 40)]))
    }

    // MARK: - SpanIndex: the same verdicts, without the quadratic scan

    /// The index only narrows the candidate list, so every verdict above must survive it. A
    /// disagreement here means the day bucketing dropped a real neighbour.
    @Test func indexAgreesWithTheLinearCheck() {
        let cases: [(existing: [(start: Date, end: Date)], probe: (start: Date, end: Date))] = [
            ([span(0, 40)], span(0, 40)),
            ([span(2, 42)], span(0, 43)),
            ([span(0, 40)], span(40, 80)),
            ([span(0, 60)], span(50, 110)),
            ([span(0, 60)], span(20, 40)),
            ([], span(0, 40)),
        ]
        for c in cases {
            let index = HealthService.SpanIndex(c.existing)
            #expect(index.overlaps(start: c.probe.start, end: c.probe.end)
                    == HealthService.overlapsExisting(start: c.probe.start, end: c.probe.end,
                                                      spans: c.existing))
        }
    }

    /// A run that starts before midnight and ends after it lands in one bucket while its duplicate
    /// lands in the next. Neighbouring buckets are searched precisely so this still matches.
    @Test func midnightStraddlingDuplicateIsStillCaught() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let midnight = cal.date(from: DateComponents(year: 2026, month: 3, day: 14))!
        let existing = (start: midnight.addingTimeInterval(-20 * 60),
                        end: midnight.addingTimeInterval(20 * 60))
        let index = HealthService.SpanIndex([existing])
        #expect(index.overlaps(start: midnight.addingTimeInterval(-18 * 60),
                               end: midnight.addingTimeInterval(21 * 60)))
    }

    /// Distant sessions must not collide just because they share a bucket neighbourhood.
    @Test func indexKeepsDistinctDaysApart() {
        let index = HealthService.SpanIndex([span(0, 40)])
        let nextWeek = span(7 * 24 * 60, 7 * 24 * 60 + 40)
        #expect(!index.overlaps(start: nextWeek.start, end: nextWeek.end))
    }
}
