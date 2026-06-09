import Testing
@testable import Momentum

struct StrengthMathTests {
    typealias WS = StrengthMath.WorkingSet

    @Test func epleyE1RM() {
        #expect(abs(StrengthMath.e1RM(weightKg: 100, reps: 5) - 116.6667) < 0.001)
        #expect(abs(StrengthMath.e1RM(weightKg: 100, reps: 1) - 103.3333) < 0.001)
        #expect(StrengthMath.e1RM(weightKg: 100, reps: 0) == 0)
    }

    @Test func volume() {
        let sets = [WS(weightKg: 100, reps: 5), WS(weightKg: 100, reps: 5)]
        #expect(StrengthMath.sessionVolume(sets) == 1000)
        #expect(StrengthMath.bestSetVolume(sets) == 500)
        #expect(StrengthMath.heaviestWeight(sets) == 100)
    }

    @Test func repMaxTable() {
        let sets = [WS(weightKg: 100, reps: 5), WS(weightKg: 105, reps: 5), WS(weightKg: 60, reps: 10)]
        let table = StrengthMath.repMaxes(sets)
        #expect(table[5] == 105)
        #expect(table[10] == 60)
    }

    @Test func weeklySetsByMuscleCredits() {
        let entries: [(primary: [MuscleGroup], secondary: [MuscleGroup], sets: Int)] = [
            ([.chest], [.triceps, .shoulders], 4),
            ([.triceps], [], 3),
        ]
        let totals = StrengthMath.weeklySetsByMuscle(entries)
        #expect(totals[.chest] == 4)
        #expect(totals[.shoulders] == 2)       // 0.5 * 4
        #expect(totals[.triceps] == 5)         // 0.5*4 + 3
    }
}
