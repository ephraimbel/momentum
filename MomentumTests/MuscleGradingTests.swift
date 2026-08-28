import Testing
@testable import Momentum

/// The two muscle-map intensity scales (2026-08-05 user call): session surfaces keep the rich
/// relative burn; the Athlete Panel grades ABSOLUTELY by weekly volume — blank with no training,
/// faint for light touches, full only for sustained work. Onboarding's focus step starts blank
/// and lights exactly what's picked.
@Suite("Muscle map grading")
struct MuscleGradingTests {

    @Test func unworkedMusclesStayUnlit() {
        #expect(MuscleMapGrading.session.intensity(0, maxVal: 8) == 0)
        #expect(MuscleMapGrading.weeklyVolume.intensity(0, maxVal: 8) == 0)
        #expect(MuscleMapGrading.session.intensity(3, maxVal: 0) == 0)   // degenerate map
    }

    @Test func sessionGradingShowsTheDifference() {
        let light = MuscleMapGrading.session.intensity(1, maxVal: 10)
        let top = MuscleMapGrading.session.intensity(10, maxVal: 10)
        // Contrast (owner call 2026-08-28): a lightly worked muscle must read clearly dimmer
        // than the session's top muscle — the old 0.62 floor made every body look fully lit.
        #expect(light < 0.4 && light > 0.2)
        #expect(MuscleMapGrading.session.intensity(5, maxVal: 10) < 0.6)
        #expect(light < top)
        #expect(top == 1.0)
    }

    @Test func weeklyVolumeGradesAbsolutely() {
        let g = MuscleMapGrading.weeklyVolume
        // maxVal must NOT rescue a light week: one set/week is faint even if it's the window's top.
        let casual = g.intensity(1, maxVal: 1)
        let moderate = g.intensity(5, maxVal: 5)
        let full = g.intensity(MuscleMapGrading.fullBurnWeeklySets,
                               maxVal: MuscleMapGrading.fullBurnWeeklySets)
        #expect(casual > 0 && casual < 0.4)
        #expect(moderate > casual && moderate < full)
        #expect(full == 1.0)
        #expect(g.intensity(30, maxVal: 30) == 1.0)   // caps — never blows past full
    }

    @Test func weeklyVolumeIsMonotonic() {
        let g = MuscleMapGrading.weeklyVolume
        var last = 0.0
        for sets in stride(from: 0.5, through: 12.0, by: 0.5) {
            let v = g.intensity(sets, maxVal: 12)
            #expect(v > last || v == 1.0)
            last = v
        }
    }

    @MainActor
    @Test func onboardingFocusStartsBlankAndLightsOnlyPicks() {
        let vm = OnboardingViewModel()
        #expect(vm.targetMuscles().isEmpty)           // no pre-filled body on the focus step
        vm.muscleFocus = [.shoulders]
        #expect(vm.targetMuscles() == [.shoulders: 1.0])
        vm.muscleFocus = [.biceps, .triceps]
        #expect(vm.targetMuscles() == [.biceps: 1.0, .triceps: 1.0])
    }
}
