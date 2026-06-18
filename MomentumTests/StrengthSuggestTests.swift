import Testing
import Foundation
@testable import Momentum

struct StrengthSuggestTests {

    @Test func onlyCompoundBarbellOrMachineGetsAWeight() {
        // Isolation / bodyweight → no prescribed weight.
        #expect(StrengthSuggest.estimate(primary: .biceps, category: .isolation, equipment: .dumbbell,
                                         bodyMassKg: 80, female: false, level: .some) == nil)
        #expect(StrengthSuggest.estimate(primary: .core, category: .compound, equipment: .bodyweight,
                                         bodyMassKg: 80, female: false, level: .some) == nil)
        // Compound barbell → a weight.
        #expect(StrengthSuggest.estimate(primary: .quads, category: .compound, equipment: .barbell,
                                         bodyMassKg: 80, female: false, level: .new) != nil)
    }

    @Test func scalesWithSexAndExperience() {
        func squat(female: Bool, _ level: ExperienceLevel) -> Double {
            StrengthSuggest.estimate(primary: .quads, category: .compound, equipment: .barbell,
                                     bodyMassKg: 80, female: female, level: level) ?? 0
        }
        // A woman's suggestion is lighter than a man's at the same bodyweight/experience.
        #expect(squat(female: true, .new) < squat(female: false, .new))
        // More experience → heavier.
        #expect(squat(female: false, .experienced) > squat(female: false, .new))
        // Rounded to 2.5 kg.
        let v = squat(female: false, .some)
        #expect((v / 2.5).rounded() * 2.5 == v)
    }

    @Test func lowerBodyHeavierThanOverheadPress() {
        let squat = StrengthSuggest.estimate(primary: .quads, category: .compound, equipment: .barbell,
                                             bodyMassKg: 80, female: false, level: .some) ?? 0
        let ohp = StrengthSuggest.estimate(primary: .shoulders, category: .compound, equipment: .barbell,
                                           bodyMassKg: 80, female: false, level: .some) ?? 0
        #expect(squat > ohp)
    }
}
