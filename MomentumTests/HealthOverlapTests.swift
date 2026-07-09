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
}
