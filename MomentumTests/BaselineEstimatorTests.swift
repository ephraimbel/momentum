import Testing
import Foundation
@testable import Momentum

/// The Health-import baseline — a runner's history → current fitness + load. Conservative by design.
struct BaselineEstimatorTests {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func run(daysAgo: Double, km: Double, paceSPerKm: Double) -> BaselineEstimator.RunSample {
        .init(date: now.addingTimeInterval(-daysAgo * 86_400), distanceM: km * 1_000,
              durationS: paceSPerKm * km)
    }

    @Test func typicalRunnerGetsAFullBaseline() throws {
        // ~3 runs/week for 8 weeks: easy 5Ks at 6:00, a weekly 10K long at 6:30, one 5K tempo at 5:00.
        var runs: [BaselineEstimator.RunSample] = []
        for week in 0..<8 {
            let base = Double(week * 7)
            runs.append(run(daysAgo: base + 1, km: 5, paceSPerKm: 360))
            runs.append(run(daysAgo: base + 3, km: 5, paceSPerKm: 360))
            runs.append(run(daysAgo: base + 5, km: 10, paceSPerKm: 390))
        }
        runs.append(run(daysAgo: 10, km: 5, paceSPerKm: 300))     // the tempo — best sustained effort
        let b = try #require(BaselineEstimator.estimate(from: runs, now: now))
        #expect(abs(b.p5kSPerKm - 300) < 1)                       // seeded from the 5K tempo, no bonus
        #expect(abs(b.weeklyVolumeM - 20_625) < 100)              // (8*20km + 5km)/8wk
        #expect(b.longestRunM == 10_000)
        #expect(b.confidence == .high)                            // 25 runs
        #expect(b.runsPerWeek > 2.9 && b.runsPerWeek < 3.3)
    }

    @Test func tooLittleHistoryReturnsNil() {
        let runs = [run(daysAgo: 3, km: 5, paceSPerKm: 360), run(daysAgo: 10, km: 5, paceSPerKm: 360)]
        #expect(BaselineEstimator.estimate(from: runs, now: now) == nil)   // < 3 runs → honest "we don't know"
    }

    @Test func junkAndStaleRunsAreFilteredOut() throws {
        var runs: [BaselineEstimator.RunSample] = [
            run(daysAgo: 2, km: 5, paceSPerKm: 100),      // implausibly fast → GPS junk, dropped
            run(daysAgo: 4, km: 0.5, paceSPerKm: 360),    // too short, dropped
            run(daysAgo: 70, km: 20, paceSPerKm: 330),    // outside the 8-week window, dropped
        ]
        runs += (0..<4).map { run(daysAgo: Double($0 * 7) + 1, km: 6, paceSPerKm: 350) }
        let b = try #require(BaselineEstimator.estimate(from: runs, now: now))
        #expect(b.runCount == 4)                          // only the real recent runs count
        #expect(b.longestRunM == 6_000)                   // the stale 20K didn't leak in
        #expect(b.confidence == .low)
    }

    @Test func shortFastBurstsDoNotInflateTheEstimate() throws {
        // Daily easy 5Ks plus one 1.2 km sprint — the sprint must not become the fitness estimate.
        var runs = (0..<10).map { run(daysAgo: Double($0 * 3) + 1, km: 5, paceSPerKm: 360) }
        runs.append(run(daysAgo: 2, km: 1.2, paceSPerKm: 240))
        let b = try #require(BaselineEstimator.estimate(from: runs, now: now))
        #expect(b.p5kSPerKm > 350)                        // seeded from the sustained 5Ks, not the burst
    }
}
