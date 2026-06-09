import Testing
@testable import Momentum

struct StrengthSplitTests {
    @Test func pushDominantIsPushDay() {
        let sets: [MuscleGroup: Double] = [.chest: 6, .triceps: 3, .shoulders: 3]
        #expect(StrengthSplit.title(forSetsByMuscle: sets) == "Push Day")
    }

    @Test func pullDominantIsPullDay() {
        let sets: [MuscleGroup: Double] = [.back: 8, .biceps: 4]
        #expect(StrengthSplit.title(forSetsByMuscle: sets) == "Pull Day")
    }

    @Test func legsDominantIsLegDay() {
        let sets: [MuscleGroup: Double] = [.quads: 6, .hamstrings: 4, .glutes: 3, .calves: 3]
        #expect(StrengthSplit.title(forSetsByMuscle: sets) == "Leg Day")
    }

    @Test func pushPlusPullIsUpperBody() {
        let sets: [MuscleGroup: Double] = [.chest: 5, .back: 5]
        #expect(StrengthSplit.title(forSetsByMuscle: sets) == "Upper Body")
    }

    @Test func upperPlusLegsIsFullBody() {
        let sets: [MuscleGroup: Double] = [.chest: 4, .back: 4, .quads: 4]
        #expect(StrengthSplit.title(forSetsByMuscle: sets) == "Full Body")
    }

    @Test func emptyIsStrength() {
        #expect(StrengthSplit.title(forSetsByMuscle: [:]) == "Strength")
    }

    @Test func coreOnlyIsCore() {
        #expect(StrengthSplit.title(forSetsByMuscle: [.core: 4]) == "Core")
    }
}
