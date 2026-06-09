import Testing
import Foundation
@testable import Momentum

/// Verifies the ACWR training-status logic that drives the Progress coach (PRD §9).
@MainActor
struct ProgressInsightsTests {
    private func run(daysAgo: Int, minutes: Double) -> Workout {
        let w = Workout()
        w.type = .run
        w.startedAt = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
        w.durationS = minutes * 60
        return w
    }

    @Test func emptyHistoryIsGettingStarted() {
        let i = ProgressInsights(workouts: [])
        #expect(!i.hasData)
        #expect(i.status == .starting)
        #expect(i.recommendation == .start)
    }

    @Test func loadSpikeRecommendsEasingOrRest() {
        var ws = [run(daysAgo: 20, minutes: 30)]                 // small chronic base
        ws += (0..<4).map { run(daysAgo: $0, minutes: 60) }      // big acute week
        let i = ProgressInsights(workouts: ws)
        #expect(i.acwr > 1.5)
        #expect(i.recommendation == .ease || i.recommendation == .rest)
        #expect(i.status == .overreaching)
    }

    @Test func steadyLoadHolds() {
        let ws = stride(from: 1, through: 27, by: 3).map { run(daysAgo: $0, minutes: 40) }
        let i = ProgressInsights(workouts: ws)
        #expect(i.acwr > 0.8)
        #expect(i.recommendation == .hold)
    }

    @Test func eightWeekSeriesIsProduced() {
        let i = ProgressInsights(workouts: [run(daysAgo: 2, minutes: 40)])
        #expect(i.weeks.count == 8)
        #expect(i.weeks.last!.load > 0)   // current week has the workout
    }
}
