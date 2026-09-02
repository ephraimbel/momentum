import Foundation
import Testing
@testable import Momentum

struct FeedEarnedContextTests {
    private func run(_ id: UUID = UUID(), day: Int, meters: Double,
                     planned: String? = nil) -> FeedEarnedContext.WorkoutFacts {
        FeedEarnedContext.WorkoutFacts(
            id: id,
            date: Date(timeIntervalSince1970: Double(day) * 86_400),
            type: .run,
            distanceM: meters,
            plannedLabel: planned)
    }

    @Test func persistedRecordWinsOverDistanceMilestoneAndPlan() {
        let workout = run(day: 1, meters: 10_000, planned: "Planned long run")

        let labels = FeedEarnedContext.resolve(
            workouts: [workout],
            recordLabels: [workout.id: "Fastest 10K"])

        #expect(labels[workout.id] == "Fastest 10K")
        #expect(labels.count == 1)
    }

    @Test func distanceMilestonesAreOnlyEarnedOnce() {
        let first5K = run(day: 1, meters: 5_000)
        let second5K = run(day: 2, meters: 5_500)
        let first10K = run(day: 3, meters: 10_000)

        let labels = FeedEarnedContext.resolve(
            workouts: [first10K, second5K, first5K], recordLabels: [:])

        #expect(labels[first5K.id] == "First 5K")
        #expect(labels[second5K.id] == "Longest run")
        #expect(labels[first10K.id] == "First 10K")
    }

    @Test func firstLoggedLongRunUsesItsHighestCrossedMilestone() {
        let firstRun = run(day: 1, meters: 21_500)

        let labels = FeedEarnedContext.resolve(workouts: [firstRun], recordLabels: [:])

        #expect(labels[firstRun.id] == "First half marathon")
    }

    @Test func planContextIsTheTruthfulFallback() {
        let baseline = run(day: 1, meters: 4_000)
        let planned = run(day: 2, meters: 3_000, planned: "Planned recovery run")

        let labels = FeedEarnedContext.resolve(workouts: [planned, baseline], recordLabels: [:])

        #expect(labels[planned.id] == "Planned recovery run")
    }
}
