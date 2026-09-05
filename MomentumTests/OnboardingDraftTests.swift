import Testing
import Foundation
@testable import Momentum

/// Interruption recovery: onboarding answers + the current step snapshot to a draft and restore
/// faithfully, survive a malformed/evolved payload without wiping everything, and resolve the step
/// by name so a reordered flow can never resume someone onto the wrong screen.
@MainActor
struct OnboardingDraftTests {

    /// A view model filled across the whole answer surface (every persisted field non-default).
    private func fullyAnswered() -> OnboardingViewModel {
        let vm = OnboardingViewModel()
        vm.name = "Maya Rivera"
        vm.handle = "maya"
        vm.activities = [.run, .strength]
        vm.goal = .raceDistance
        vm.experience = .experienced
        vm.liftExperience = .some
        vm.injuryAreas = [.knee, .hamstring]
        vm.daysPerWeek = 5
        vm.equipment = .dumbbellsOnly
        vm.sessionMinutes = 60
        vm.hasRace = true
        vm.raceDate = Date(timeIntervalSinceReferenceDate: 1_000_000)
        vm.reason = "performance"
        vm.raceDistance = .marathon
        vm.muscleFocus = [.quads, .glutes]
        vm.preferredDays = [2, 4, 6]
        vm.hybridPriority = .running
        vm.intensity = .podium
        vm.goalHours = 3
        vm.goalMinutes = 10
        vm.sex = .female
        vm.heightCm = 178
        vm.birthYear = 1994
        vm.bodyMassKg = 63
        vm.weeklyRunVolumeM = 45_000
        vm.longestRunM = 20_000
        vm.calibrationMode = .time
        vm.paceFeel = .regular
        vm.benchmark = .half
        vm.recentRunSeconds = 5_400
        vm.healthRestingHR = 48
        vm.plannedRaceName = "Chicago Marathon"
        vm.step = .days
        return vm
    }

    @Test func draftRoundTripsEveryAnswer() {
        let original = fullyAnswered()
        let restored = OnboardingViewModel()
        #expect(restored.restore(from: original.draft()) == true)

        #expect(restored.name == "Maya Rivera")
        #expect(restored.handle == "maya")
        #expect(restored.activities == [.run, .strength])
        #expect(restored.goal == .raceDistance)
        #expect(restored.experience == .experienced)
        #expect(restored.liftExperience == .some)
        #expect(restored.injuryAreas == [.knee, .hamstring])
        #expect(restored.daysPerWeek == 5)
        #expect(restored.equipment == .dumbbellsOnly)
        #expect(restored.sessionMinutes == 60)
        #expect(restored.hasRace == true)
        #expect(restored.raceDate == Date(timeIntervalSinceReferenceDate: 1_000_000))
        #expect(restored.reason == "performance")
        #expect(restored.raceDistance == .marathon)
        #expect(restored.muscleFocus == [.quads, .glutes])
        #expect(restored.preferredDays == [2, 4, 6])
        #expect(restored.hybridPriority == .running)
        #expect(restored.intensity == .podium)
        #expect(restored.goalHours == 3)
        #expect(restored.goalMinutes == 10)
        #expect(restored.sex == .female)
        #expect(restored.heightCm == 178)
        #expect(restored.birthYear == 1994)
        #expect(restored.bodyMassKg == 63)
        #expect(restored.weeklyRunVolumeM == 45_000)
        #expect(restored.longestRunM == 20_000)
        #expect(restored.calibrationMode == .time)
        #expect(restored.paceFeel == .regular)
        #expect(restored.benchmark == .half)
        #expect(restored.recentRunSeconds == 5_400)
        #expect(restored.healthRestingHR == 48)
        #expect(restored.plannedRaceName == "Chicago Marathon")
        #expect(restored.step == .days)                      // resumes on the exact screen
    }

    @Test func survivesJSONEncodeDecode() throws {
        // The real path is UserDefaults JSON, not an in-memory struct copy.
        let data = try JSONEncoder().encode(fullyAnswered().draft())
        let decoded = try JSONDecoder().decode(OnboardingDraft.self, from: data)
        let restored = OnboardingViewModel()
        #expect(restored.restore(from: decoded))
        #expect(restored.step == .days)
        #expect(restored.intensity == .podium)
        #expect(restored.raceDistance == .marathon)
    }

    @Test func olderDraftCollectsMissingIdentityWithoutLosingTrainingAnswers() {
        var draft = fullyAnswered().draft()
        draft.handle = ""
        draft.savedStep = "intensity"
        let restored = OnboardingViewModel()
        #expect(restored.restore(from: draft))
        #expect(restored.step == .name)
        #expect(restored.name == "Maya Rivera")
        #expect(restored.weeklyRunVolumeM == 45_000)
        #expect(restored.daysPerWeek == 5)
        #expect(restored.raceDistance == .marathon)
        #expect(restored.intensity == .podium)
        #expect(restored.restoredAtOrPast(.intensity))
    }

    @Test func unknownEnumValuesFallBackWithoutWipingTheRest() {
        // A draft written by a future build carries a case this build no longer knows. It must NOT
        // fail the whole restore — the bad field falls back, everything else survives.
        var d = fullyAnswered().draft()
        d.intensity = "ultrahardcore"          // removed/renamed tier
        d.goal = "timeTravel"                  // unknown goal
        d.raceDistance = "100miler"            // unknown distance
        d.calibrationMode = "telepathy"
        let restored = OnboardingViewModel()
        #expect(restored.restore(from: d) == true)
        #expect(restored.intensity == .balanced)       // non-optional → default
        #expect(restored.goal == .generalFitness)      // non-optional → default
        #expect(restored.raceDistance == nil)          // optional → nil
        #expect(restored.calibrationMode == .none)     // non-optional → default
        #expect(restored.name == "Maya Rivera")        // untouched fields intact
        #expect(restored.daysPerWeek == 5)
        #expect(restored.step == .days)
    }

    @Test func unrecognizedStepIsDiscardedNotMisplaced() {
        // A reordered/removed step name must abort the restore rather than resume onto whatever
        // enum case happens to sit at that position now.
        var d = fullyAnswered().draft()
        d.savedStep = "aStepThatNoLongerExists"
        let vm = OnboardingViewModel()
        #expect(vm.restore(from: d) == false)
    }

    @Test func stepIsStoredByNameNotOrdinal() {
        // The whole point of name-based step IDs: insertion/reordering can't corrupt a resume.
        #expect(fullyAnswered().draft().savedStep == "days")
    }

    @Test func permissionBeatsBeforeGenerationCanResume() {
        // Step.allCases keeps historical raw values and does NOT match the live screen order.
        // Notifications + primers are before Building in computeSteps and must not be rejected
        // merely because their enum cases have larger raw values.
        for step in [OnboardingViewModel.Step.notifications, .primers] {
            var draft = fullyAnswered().draft()
            draft.savedStep = String(describing: step)
            let restored = OnboardingViewModel()
            #expect(restored.restore(from: draft))
            #expect(restored.step == step)
        }
    }

    @Test func outputBeatsCannotResumeWithoutAProfile() {
        for step in [OnboardingViewModel.Step.building, .reveal, .account] {
            var draft = fullyAnswered().draft()
            draft.savedStep = String(describing: step)
            #expect(OnboardingViewModel().restore(from: draft) == false)
        }
    }

    @Test func storeSaveLoadClearRoundTrips() {
        OnboardingDraftStore.clear()
        #expect(OnboardingDraftStore.load() == nil)
        OnboardingDraftStore.save(fullyAnswered().draft())
        let loaded = OnboardingDraftStore.load()
        #expect(loaded?.savedStep == "days")
        #expect(loaded?.intensity == PlanIntensity.podium.rawValue)
        OnboardingDraftStore.clear()
        #expect(OnboardingDraftStore.load() == nil)       // clear removes it
    }
    @Test func retiredPagesResumeOnTheirCombinedPageWithoutLosingAnswers() {
        let pairs: [(OnboardingViewModel.Step, OnboardingViewModel.Step)] = [
            (.name, .name), (.identity, .name), (.units, .disciplines), (.raceGoalTime, .race),
            (.preferredDays, .days), (.strengthSplit, .equipment), (.why, .health)
        ]
        for (old, current) in pairs {
            var draft = fullyAnswered().draft()
            draft.savedStep = String(describing: old)
            let restored = OnboardingViewModel()
            #expect(restored.restore(from: draft))
            #expect(restored.step == current)
            #expect(restored.preferredDays == [2, 4, 6])
            #expect(restored.goalFinishTimeS == 11_400)
            #expect(restored.name == "Maya Rivera")
            #expect(restored.intensity == .podium)
            restored.advance()
            #expect(restored.step != current, "A migrated draft must never have a dead Continue")
        }
    }

    @Test func olderDraftCollectsRaceDestinationBeforeContinuing() {
        var draft = fullyAnswered().draft()
        draft.savedStep = "metrics"
        draft.raceDistance = nil
        let restored = OnboardingViewModel()
        #expect(restored.restore(from: draft))
        #expect(restored.step == .race)
        #expect(!restored.canAdvance)
        #expect(restored.weeklyRunVolumeM == 45_000)
    }

    @Test func resumedIntensityUsesLiveOrderInsteadOfHistoricalEnumOrder() {
        var draft = fullyAnswered().draft()
        draft.savedStep = "notifications"
        let restored = OnboardingViewModel()
        #expect(restored.restore(from: draft))
        #expect(restored.restoredAtOrPast(.intensity))
        restored.back()
        #expect(restored.step == .intensity)
        #expect(restored.intensity == .podium)
    }

}
