import Testing
@testable import Momentum

/// Making cross-discipline sequencing legible — the run/lift spacing narration. Pure + deterministic.
struct HybridSequencingTests {

    private func item(_ day: Int, run: RunType? = nil, hard: Bool = false, leg: Bool = false) -> HybridSequencing.Item {
        .init(dayIndex: day, runType: run, isHardRun: hard, isLegDay: leg)
    }

    @Test func weekInsightNarratesSpacing() {
        // Leg day Tue (1) + long run Sat (5) → a well-spaced, fresh-legs read.
        let a = HybridSequencing.weekInsight([item(1, leg: true), item(5, run: .long, hard: true)])
        #expect(a?.contains("4 days after leg day") == true)
        // Long run before leg day.
        let b = HybridSequencing.weekInsight([item(4, leg: true), item(1, run: .long, hard: true)])
        #expect(b?.contains("before leg day") == true)
        // A hard run the day after legs (the case the scheduler tries to avoid).
        let c = HybridSequencing.weekInsight([item(2, leg: true), item(3, run: .intervals, hard: true)])
        #expect(c?.contains("the next day") == true)
    }

    @Test func weekInsightNilWhenNotHybrid() {
        // Only runs, no leg day → no cross-discipline story.
        #expect(HybridSequencing.weekInsight([item(1, run: .intervals, hard: true), item(3, run: .long, hard: true)]) == nil)
        // A leg day but no hard/long run → nothing to sequence around.
        #expect(HybridSequencing.weekInsight([item(1, leg: true), item(3, run: .easy)]) == nil)
    }

    @Test func runRationaleExplainsPlacement() {
        #expect(HybridSequencing.runRationale(dayIndex: 5, runType: .long, legDays: [1])?.contains("4 days after leg day") == true)
        #expect(HybridSequencing.runRationale(dayIndex: 1, runType: .intervals, legDays: [3])?.contains("before leg day") == true)
        #expect(HybridSequencing.runRationale(dayIndex: 3, runType: .intervals, legDays: []) == nil)
    }
}
