import Testing
import Foundation
import SwiftData
@testable import Momentum

/// Verifies the curated "Highlights" reel derived from history — longest run, biggest lifting day,
/// PRs, streak — and that each highlight links back to the workout that earned it.
@MainActor
struct ProfileHighlightsTests {

    @Test func curatesBestsAndLinksWorkouts() {
        // Two runs (7 km is the longest) + one strength day.
        let shortRun = Workout(); shortRun.type = .run; shortRun.durationS = 1200
        let sg = GPSDetail(); sg.distanceM = 4000; shortRun.gps = sg

        let longRun = Workout(); longRun.type = .run; longRun.durationS = 2400
        let lg = GPSDetail(); lg.distanceM = 7000; longRun.gps = lg

        let lift = Workout(); lift.type = .strength; lift.durationS = 3000
        let session = StrengthSession(); session.totalVolumeKg = 5000; session.totalSets = 20
        let row = WorkoutExercise()
        row.exercise = Exercise(name: "Squat", primaryMuscles: [.quads], equipment: .barbell, category: .compound)
        let set = SetEntry(); set.weightKg = 100; set.reps = 5; set.isComplete = true; set.type = .working
        row.sets = [set]; session.exercises = [row]; lift.strength = session

        let workouts = [longRun, shortRun, lift]
        let stats = ProfileStats(workouts: workouts)
        let hl = ProfileHighlights(stats: stats, workouts: workouts, weightUnit: .kg, distanceUnit: .metric)

        // Longest run points at the 7 km workout, not the 4 km one.
        let longest = hl.items.first { $0.kind == .longestRun }
        #expect(longest?.workoutID == longRun.id)

        // Longest session is the 50-min lift.
        let session2 = hl.items.first { $0.kind == .longestSession }
        #expect(session2?.workoutID == lift.id)

        // Biggest day is the lift; and there's a PR for Squat.
        #expect(hl.items.contains { $0.kind == .volumeDay && $0.workoutID == lift.id })
        #expect(hl.items.contains { $0.kind == .pr && $0.title == "Squat" })

        // Streak is active today, so a streak highlight leads (not tied to one workout).
        #expect(hl.items.first?.kind == .streak)
    }

    @Test func emptyHistoryHasNoHighlights() {
        let hl = ProfileHighlights(stats: ProfileStats(workouts: []), workouts: [])
        #expect(hl.items.isEmpty)
    }
}
