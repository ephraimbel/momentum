import Testing
import Foundation
@testable import Momentum

/// The Athlete Panel's activation feed: logged sets → weekly set-equivalents per muscle over the
/// range picker's window, graded ABSOLUTELY by `MuscleMapGrading.weeklyVolume`. What the figure
/// lights, and how brightly, is arithmetic — and that arithmetic must not drift with the picker.
@MainActor
struct MuscleActivationTests {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func lift(daysAgo: Int, primary: [MuscleGroup], secondary: [MuscleGroup] = [],
                      working: Int, warmups: Int = 0, incomplete: Int = 0) -> Workout {
        let exercise = Exercise(name: "Lift", primaryMuscles: primary, secondaryMuscles: secondary,
                                equipment: .barbell, category: .compound)
        var sets: [SetEntry] = []
        for _ in 0..<working {
            let s = SetEntry(); s.reps = 5; s.weightKg = 60; s.isComplete = true; s.type = .working; sets.append(s)
        }
        for _ in 0..<warmups {
            let s = SetEntry(); s.reps = 5; s.weightKg = 40; s.isComplete = true; s.type = .warmup; sets.append(s)
        }
        for _ in 0..<incomplete {
            let s = SetEntry(); s.reps = 5; s.weightKg = 60; s.isComplete = false; s.type = .working; sets.append(s)
        }
        let row = WorkoutExercise(); row.exercise = exercise; row.sets = sets
        let session = StrengthSession(); session.exercises = [row]
        let w = Workout(); w.type = .strength; w.strength = session
        w.startedAt = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        return w
    }

    private func run(daysAgo: Int, km: Double) -> Workout {
        let gps = GPSDetail(); gps.distanceM = km * 1_000
        let w = Workout(); w.type = .run; w.gps = gps
        w.startedAt = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        return w
    }

    @Test func onlyCompleteWorkingSetsCountPrimaryFullSecondaryHalf() {
        let w = lift(daysAgo: 1, primary: [.chest], secondary: [.triceps], working: 4, warmups: 2, incomplete: 1)
        let rate = MuscleActivation.weeklyRate(workouts: [w], days: 7, now: now)
        #expect(rate[.chest] == 4)          // warm-ups and unfinished sets never light a muscle
        #expect(rate[.triceps] == 2)        // secondary credit is half (PRD §22)
        #expect(rate[.quads] == nil)        // untrained = absent, so the figure leaves it unlit
    }

    @Test func everyWindowIsTheSameYardstick() {
        // One set a day, every day, for 200 days: 7 sets/week is the truth at every window.
        // Integer-week division (30/7 = 4, 90/7 = 12) read 1M and 3M as 7.5 — the same training
        // ~7% brighter than at 7D — when the figure's own rule is one yardstick per window.
        let daily = (1...200).map { lift(daysAgo: $0, primary: [.quads], working: 1) }
        for days in [7, 30, 90, 180] {
            let rate = MuscleActivation.weeklyRate(workouts: daily, days: days, now: now)[.quads] ?? 0
            #expect(abs(rate - 7) < 0.000_1, "\(days)d read \(rate) sets/week")
        }
    }

    @Test func theWindowIsTheWindow() {
        // Training just outside the window contributes nothing — the figure re-windows with the picker.
        let old = lift(daysAgo: 8, primary: [.back], working: 5)
        let fresh = lift(daysAgo: 2, primary: [.chest], working: 2)
        let week = MuscleActivation.weeklyRate(workouts: [old, fresh], days: 7, now: now)
        #expect(week[.back] == nil)
        #expect(week[.chest] == 2)
        let month = MuscleActivation.weeklyRate(workouts: [old, fresh], days: 30, now: now)
        #expect(abs((month[.back] ?? 0) - 5 / (30.0 / 7)) < 0.000_1)   // exact weeks, not 4
    }

    @Test func runningLightsTheLegsNotTheArms() {
        // A pure runner is never a blank figure: ~20 km a week burns the calves to the panel's
        // full-burn bar (10 set-equivalents), quads just behind; nothing above the waist but core.
        let runs = [run(daysAgo: 1, km: 10), run(daysAgo: 4, km: 10)]
        let rate = MuscleActivation.weeklyRate(workouts: runs, days: 7, now: now)
        #expect(abs((rate[.calves] ?? 0) - 10) < 0.000_1)
        #expect((rate[.quads] ?? 0) > (rate[.hamstrings] ?? 0))
        #expect(rate[.chest] == nil && rate[.biceps] == nil)
        #expect(MuscleMapGrading.weeklyVolume.intensity(rate[.calves] ?? 0, maxVal: 10) == 1.0)
        // Half that mileage is visibly dimmer — brightness follows the rate, never the picker.
        let easy = MuscleActivation.weeklyRate(workouts: [run(daysAgo: 1, km: 10)], days: 7, now: now)
        #expect(MuscleMapGrading.weeklyVolume.intensity(easy[.calves] ?? 0, maxVal: 10) < 1.0)
    }

    @Test func emptyWindowIsABlankFigure() {
        #expect(MuscleActivation.weeklyRate(workouts: [], days: 30, now: now).isEmpty)
        let far = lift(daysAgo: 200, primary: [.chest], working: 10)
        #expect(MuscleActivation.weeklyRate(workouts: [far], days: 180, now: now).isEmpty)
    }
}
