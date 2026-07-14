import Testing
import Foundation
@testable import Momentum

/// The Pro strength-progression layer — top lifts, e1RM vitals, weekly volume, muscle balance.
@MainActor
struct StrengthTrendsTests {

    private func lift(_ name: String, primary: [MuscleGroup], secondary: [MuscleGroup] = []) -> Exercise {
        Exercise(name: name, primaryMuscles: primary, secondaryMuscles: secondary,
                 equipment: .barbell, category: .compound)
    }

    private func session(daysAgo: Int, sets: [(Exercise, kg: Double, reps: Int)]) -> Workout {
        let w = Workout(); w.type = .strength
        w.startedAt = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        let s = StrengthSession()
        for (ex, kg, reps) in sets {
            let row = WorkoutExercise(); row.exercise = ex
            let set = SetEntry(); set.weightKg = kg; set.reps = reps; set.type = .working; set.isComplete = true
            row.sets = [set]
            s.exercises.append(row)
        }
        w.strength = s
        return w
    }

    @Test func topLiftsRankByFrequencyAndNeedTwoSessions() {
        let squat = lift("Squat", primary: [.quads])
        let bench = lift("Bench", primary: [.chest])
        let curl = lift("Curl", primary: [.biceps])
        let ws = [
            session(daysAgo: 10, sets: [(squat, 100, 5), (bench, 80, 5)]),
            session(daysAgo: 7, sets: [(squat, 102, 5), (bench, 82, 5)]),
            session(daysAgo: 3, sets: [(squat, 105, 5), (curl, 20, 10)]),   // curl only once
        ]
        let top = StrengthTrends.topLifts(in: ws)
        #expect(top.contains("Squat"))
        #expect(top.contains("Bench"))
        #expect(!top.contains("Curl"))   // one session → no curve → excluded
        #expect(top.first == "Squat")    // 3 sessions, most frequent, ranks first
    }

    @Test func liftSummaryCarriesE1RMAndGain() {
        let squat = lift("Squat", primary: [.quads])
        let ws = [session(daysAgo: 14, sets: [(squat, 100, 5)]),
                  session(daysAgo: 3, sets: [(squat, 110, 5)])]
        let metrics = StrengthTrends.liftSummary(in: ws)
        let s = metrics.first { $0.name == "Squat" }!
        // e1RM(110,5) = 110 * (1+5/30) = 128.33
        #expect(abs(s.currentE1RMKg - 110 * (1 + 5.0/30)) < 0.1)
        #expect(s.gainPct > 0)            // got stronger
        #expect(s.spark.count == 2)
    }

    @Test func weeklyVolumeSumsWorkingSets() {
        let squat = lift("Squat", primary: [.quads])
        // Two sets this week: 100×5 + 100×5 = 1000 kg volume.
        let w = session(daysAgo: 1, sets: [(squat, 100, 5), (squat, 100, 5)])
        let series = StrengthTrends.weeklyVolume(in: [w], weeks: 2)
        #expect(series.last?.value == 1000)
    }

    @Test func muscleBalanceWeightsPrimaryAndSecondary() {
        // Bench: chest primary (1.0), triceps secondary (0.5). One working set.
        let bench = lift("Bench", primary: [.chest], secondary: [.triceps])
        let w = session(daysAgo: 2, sets: [(bench, 80, 5)])
        let loads = StrengthTrends.muscleBalance(in: [w])
        let chest = loads.first { $0.muscle == .chest }!.sets
        let tri = loads.first { $0.muscle == .triceps }!.sets
        #expect(chest == 1.0)             // primary full credit
        #expect(tri == 0.5)               // secondary half credit
        #expect(loads.first?.muscle == .chest)   // sorted heaviest-first
    }

    @Test func emptyHistoryIsClean() {
        #expect(StrengthTrends.topLifts(in: []).isEmpty)
        #expect(StrengthTrends.liftSummary(in: []).isEmpty)
        #expect(StrengthTrends.muscleBalance(in: []).isEmpty)
    }
}
