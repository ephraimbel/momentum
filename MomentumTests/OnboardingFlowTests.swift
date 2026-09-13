import Testing
import Foundation
import SwiftData
@testable import Momentum

/// End-to-end: onboarding answers → UserProfile → generated, persisted plan with resolved exercises.
@MainActor
struct OnboardingFlowTests {

    @Test func producesProfileAndUnifiedPlan() throws {
        let pc = PersistenceController.inMemory()   // seeds the curated library
        let ctx = pc.container.mainContext

        let vm = OnboardingViewModel()
        vm.activities = [.run, .strength]
        vm.goal = .buildMuscle
        vm.experience = .some
        vm.daysPerWeek = 4
        vm.equipment = .fullGym
        vm.sessionMinutes = 60
        vm.name = "Maya Rivera"
        vm.handle = "maya_runs"
        vm.avatarData = Data([0xFF, 0xD8])

        let profile = try vm.finish(in: ctx)

        // Identity from the onboarding identity step lands on the profile.
        #expect(profile.displayName == "Maya Rivera")
        #expect(profile.handle == "maya_runs")
        #expect(profile.avatarData != nil)

        #expect(profile.disciplines.contains("running"))
        #expect(profile.disciplines.contains("strength"))
        let plan = try #require(profile.plan)
        #expect(!plan.sessions.isEmpty)

        let strengthDays = plan.sessions.filter { $0.discipline == .strength }
        let runDays = plan.sessions.filter { $0.discipline == .running }
        #expect(!strengthDays.isEmpty)
        #expect(!runDays.isEmpty)

        // Strength targets resolved to real catalog exercises.
        #expect(strengthDays.allSatisfy { !$0.strengthTargets.isEmpty })
        #expect(strengthDays.first?.strengthTargets.first?.exercise != nil)

        // Week one fills the requested number of days.
        let sorted = plan.sessions.sorted { $0.date < $1.date }
        let firstDate = try #require(sorted.first?.date)
        let weekEnd = Calendar.current.date(byAdding: .day, value: 7, to: firstDate)!
        let weekOneDays = Set(sorted.filter { $0.date < weekEnd }.map { Calendar.current.startOfDay(for: $0.date) })
        #expect(weekOneDays.count == 4)
    }

    @Test func healthRestingHRUnlocksKarvonenZones() throws {
        // Resting HR captured at the Health consent moment persists to the profile — and Karvonen
        // zones differ measurably from the %-max fallback (plan-quality audit fix #6).
        let pc = PersistenceController.inMemory()
        let ctx = pc.container.mainContext
        let vm = OnboardingViewModel()
        vm.activities = [.run]
        vm.goal = .endurance
        vm.birthYear = Calendar.current.component(.year, from: Date()) - 30
        vm.healthRestingHR = 52

        let profile = try vm.finish(in: ctx)
        #expect(profile.restingHR == 52)
        let maxHR = try #require(profile.maxHR)              // Tanaka estimate from age
        let karvonen = try #require(HRZones.zones(maxHR: maxHR, restingHR: 52))
        let percentMax = try #require(HRZones.zones(maxHR: maxHR, restingHR: nil))
        #expect(karvonen[0].bpm.lowerBound > percentMax[0].bpm.lowerBound)   // Z1 floor rises off resting HR
        // No Health resting-HR signal → profile stays nil and zones fall back (regression).
        let bare = OnboardingViewModel()
        bare.activities = [.run]
        #expect(try bare.finish(in: ctx).restingHR == nil)
    }

    @Test func heightPersistsAndSharpensTheFuelBMR() throws {
        // Height was added to the metrics step (2026-07-24) because the Fuel BMR needs it — the
        // step promised sharper calorie targets but was skipping the input that matters most.
        let pc = PersistenceController.inMemory()
        let ctx = pc.container.mainContext
        let vm = OnboardingViewModel()
        vm.activities = [.run]
        vm.goal = .endurance
        vm.sex = .male
        vm.birthYear = Calendar.current.component(.year, from: Date()) - 30
        vm.bodyMassKg = 70
        vm.heightCm = 185                         // a tall athlete, far from the 172 cm fallback

        let profile = try vm.finish(in: ctx)
        #expect(profile.heightCm == 185)          // the calorie inputs are now complete

        // Mifflin–St Jeor actually consumes it — the real height shifts BMR off the assumed one.
        let real = FuelReadiness.bmr(kg: 70, heightCm: 185, age: 30, isMale: true)
        let assumed = FuelReadiness.bmr(kg: 70, heightCm: FuelReadiness.fallbackHeightCm, age: 30, isMale: true)
        #expect(abs(real - assumed) > 50)         // 13 cm × 6.25 ≈ 81 kcal — a meaningful target shift

        // Skipping the (optional) step leaves it nil → fueling honestly falls back, never a fabricated height.
        let bare = OnboardingViewModel(); bare.activities = [.run]
        #expect(try bare.finish(in: ctx).heightCm == nil)
    }

    @Test func progressAdvancesAndSkipsEquipmentForNonLifters() throws {
        let vm = OnboardingViewModel()
        vm.activities = [.run]                        // no lifting
        #expect(!vm.steps.contains(.equipment))
        // Session length is asked of EVERYONE (2026-08-30). It used to be hidden from pure
        // runners on the grounds that it only sized a lifting day — but running honours it too
        // now (`PlanEngine.cardioSessions` caps a midweek session at the stated time), so hiding
        // it meant a runner's plan was shaped by an answer they were never allowed to give.
        #expect(vm.steps.contains(.days))
        vm.activities = [.strength]
        #expect(vm.steps.contains(.equipment))
        #expect(vm.steps.contains(.days))          // lifters set it (it drives exercise count)
        #expect(vm.running)                           // every coached plan keeps its running foundation
        vm.activities = [.run, .strength]
        #expect(vm.steps.contains(.days))          // hybrids lift too → keep it

        vm.step = .disciplines
        #expect(vm.canAdvance)                        // activities chosen
        vm.activities = []
        #expect(vm.canAdvance)                         // running itself is already a complete plan

        // The identity step is the (optional) profile photo since the @handle claim left with
        // the community back-burner (2026-07-16) — always passable, photo or not.
        vm.step = .identity
        vm.handle = ""
        #expect(vm.canAdvance)
    }

    @Test func crossTrainingAddOnsHonorChosenDayCount() throws {
        let pc = PersistenceController.inMemory()
        let ctx = pc.container.mainContext
        let vm = OnboardingViewModel()
        vm.activities = [.run, .swim, .yoga]         // run is programmed; swim/yoga are tracked add-ons
        vm.daysPerWeek = 3
        let profile = try vm.finish(in: ctx)
        let plan = try #require(profile.plan)

        // The add-ons share the 3-day budget — they don't add extra days (the reported bug).
        let cal = Calendar.current
        let firstDate = try #require(plan.sessions.map(\.date).min())
        let weekEnd = cal.date(byAdding: .day, value: 7, to: cal.startOfDay(for: firstDate))!
        let weekOneDays = Set(plan.sessions.filter { $0.date < weekEnd }.map { cal.startOfDay(for: $0.date) })
        #expect(weekOneDays.count <= 3)

        let sports = Set(plan.sessions.compactMap { $0.workoutType })
        #expect(sports.contains(.swimming))          // add-ons still land in the plan
        #expect(profile.disciplines == ["running"])  // only the programmable one drives the engine
        #expect(profile.daysPerWeek == 3)            // the athlete's choice is preserved for display
    }

    /// Full-flow integrity for the endurance profiler: a race-goal runner walks every step in the
    /// designed order (injuries after experience, health consent before intensity), and everything
    /// they answered persists onto the profile that seeds the plan.
    @Test func enduranceProfilerWalksInOrderAndPersists() throws {
        let pc = PersistenceController.inMemory()
        let ctx = pc.container.mainContext

        let vm = OnboardingViewModel()
        vm.activities = [.run]
        vm.goal = .raceDistance
        vm.raceDistance = .half
        vm.hasRace = true
        vm.experience = .some
        vm.injuryAreas = [.shins, .itBand]
        vm.weeklyRunVolumeM = 30_000
        vm.longestRunM = 12_000
        vm.intensity = .aggressive

        let steps = vm.steps
        #expect(steps == [.name, .goal, .experience, .pace, .race, .runVolume, .injuries, .metrics, .days, .intensity, .building, .reveal, .review, .health, .primers])

        // Walk the whole flow front to back — advance() must traverse every step without a dead end.
        vm.step = steps.first!
        var visited: [OnboardingViewModel.Step] = [vm.step]
        while vm.step != steps.last {
            let before = vm.step
            vm.advance()
            #expect(vm.step != before)                       // never stuck
            visited.append(vm.step)
            if visited.count > steps.count { break }         // safety against an infinite loop
        }
        #expect(visited == steps)                            // exactly the designed order, no skips

        // Everything they answered lands on the profile.
        let profile = try vm.finish(in: ctx)
        #expect(profile.injuryHistory == ["itBand", "shins"])
        #expect(profile.planIntensity == "aggressive")
        #expect(profile.weeklyRunVolumeM == 30_000)
        #expect(profile.raceDistanceM == RaceDistance.half.meters)
        #expect(profile.plan != nil)

        // The macrocycle persists (§6.1): opens on Base, ends in Taper for a dated race.
        let phases = try #require(profile.plan?.weekPhases)
        #expect(phases.first == PlanPhase.base.rawValue)
        #expect(phases.last == PlanPhase.taper.rawValue)
        #expect(phases.contains(PlanPhase.build.rawValue))

        // The feasibility read honors the injury history: on-track + injuries → gentle recommendation.
        let easy = PlanFeasibility.assess(raceDistanceM: RaceDistance.fiveK.meters, goalFinishTimeS: nil,
                                          currentP5kSPerKm: 320, currentWeeklyVolumeM: 30_000,
                                          weeksAvailable: 16, experience: .some, injuryProne: true)
        #expect(easy.verdict == .onTrack)
        #expect(easy.recommended == .gentle)
    }

    /// Owner call 2026-09-12: reveal → review → Health → location, then checkout. None of the
    /// four adds a question, so the progress bar is full from the reveal on.
    @Test func reviewThenPermissionBeatsFollowRevealWithoutAddingAQuestion() {
        let vm = OnboardingViewModel()
        for retired in [OnboardingViewModel.Step.notifications, .account] {
            #expect(!vm.steps.contains(retired))
        }
        #expect(vm.steps.suffix(5) == [.building, .reveal, .review, .health, .primers])
        vm.step = .reveal
        #expect(vm.progress == 1)
        #expect(!vm.isQuestionStep)
        for expected in [OnboardingViewModel.Step.review, .health, .primers] {
            vm.advance()
            #expect(vm.step == expected)
            #expect(vm.progress == 1)
            #expect(!vm.isQuestionStep)
            #expect(vm.canAdvance)
            #expect(OnboardingViewModel.currentStep(for: expected) == expected)
        }
        vm.advance()
        #expect(vm.step == .primers)   // the last beat: checkout opens from here, not another step
    }

    @Test func namelessAthletePersistsARealPlanWithoutInventedBodyMeasurements() throws {
        let pc = PersistenceController.inMemory()
        let vm = OnboardingViewModel()
        vm.goal = .stayConsistent
        vm.chooseRunningBackground(.new)
        let profile = try vm.finish(in: pc.container.mainContext)
        #expect(profile.displayName.isEmpty)
        #expect(profile.handle.isEmpty)
        #expect(profile.bodyMassKg == nil)
        #expect(profile.heightCm == nil)
        #expect(profile.birthYear == nil)
        #expect(profile.maxHR == nil)
        #expect(profile.plan?.sessions.isEmpty == false)
        #expect(vm.steps.filter { vm.step = $0; return vm.isQuestionStep }.count == 8)
    }

    @Test func raceRevealFramesTheTargetAsAPursuitNotAGuarantee() throws {
        let vm = OnboardingViewModel()
        vm.goal = .raceDistance
        vm.raceDistance = .fiveK
        vm.goalHours = 0
        vm.goalMinutes = 20
        vm.hasRace = true
        vm.raceDate = Calendar.current.date(byAdding: .day, value: 90, to: Date())!

        let timed = vm.projectedOutcome()
        #expect(timed.hasPrefix("Chasing 20 min for your 5K on "))
        #expect(!timed.localizedCaseInsensitiveContains("ready"))

        vm.goalMinutes = 0
        let untimed = vm.projectedOutcome()
        #expect(untimed.hasPrefix("Building toward your 5K on "))
        #expect(!untimed.localizedCaseInsensitiveContains("ready"))
    }
    @Test func shorterInterviewKeepsEveryPlanInputAndWalksBackwards() throws {
        let vm = OnboardingViewModel()
        vm.goal = .stayConsistent
        vm.calibrationMode = .feel
        vm.paceFeel = .regular
        #expect(vm.steps.filter { vm.step = $0; return vm.isQuestionStep }.count == 9)
        #expect(vm.steps.contains(.name))
        #expect(!vm.steps.contains(.identity))
        #expect(!vm.steps.contains(.units))
        #expect(!vm.steps.contains(.preferredDays))
        #expect(!vm.steps.contains(.why))
        for step in [OnboardingViewModel.Step.experience, .pace, .runVolume, .injuries, .metrics, .days, .intensity] {
            #expect(vm.steps.contains(step))
        }
        // Walk back from the LAST beat, whatever it is (the location primer since 2026-09-12),
        // so this stays a statement about back-navigation rather than about where the flow ends.
        vm.step = try #require(vm.steps.last)
        var backwards: [OnboardingViewModel.Step] = [vm.step]
        while vm.canGoBack {
            vm.back()
            backwards.append(vm.step)
        }
        #expect(backwards == Array(vm.steps.reversed()))
        #expect(vm.step == .name)
        vm.activities = [.run, .strength]
        #expect(vm.steps.contains(.equipment))
        #expect(vm.steps.contains(.hybridFocus))
        #expect(!vm.steps.contains(.strengthSplit))
        vm.experience = .new
        #expect(!vm.steps.contains(.runVolume))
    }

    @Test func startingFitnessRequiresAnAnswerAndProgressFinishesBeforeReveal() throws {
        let vm = OnboardingViewModel()
        vm.step = .experience
        #expect(!vm.canAdvance)
        vm.chooseRunningBackground(.new)
        #expect(vm.canAdvance)
        // The pace page (2026-09-12) needs its own answer; a by-feel pick is one.
        vm.step = .pace
        #expect(!vm.canAdvance)
        vm.choosePaceFeel(.newRunner)
        #expect(vm.canAdvance)
        vm.step = .days
        #expect(vm.progress > 0 && vm.progress < 1)
        vm.step = .intensity
        #expect(vm.progress == 1)
        vm.step = .building
        #expect(vm.progress == 1)
    }

    @Test func identityAndBodyDetailsAreExplicitBeforeGeneration() {
        let vm = OnboardingViewModel()
        #expect(vm.step == .name)
        #expect(!vm.canAdvance)
        vm.name = "Maya Rivera"
        vm.suggestHandle(afterEditing: "")
        #expect(vm.canAdvance)
        vm.handle = "maya_runs"
        vm.name = "Maya R"
        vm.suggestHandle(afterEditing: "Maya Rivera")
        #expect(vm.handle == "maya_runs")
        vm.step = .metrics
        #expect(!vm.canAdvance)
        vm.sex = .female; vm.birthYear = 1996; vm.heightCm = 172
        #expect(!vm.canAdvance)
        vm.bodyMassKg = 63
        #expect(vm.canAdvance)
    }

}

extension OnboardingFlowTests {
    /// The pace page (2026-09-12): every runner sets one anchor. A result is one; an easy pace they
    /// touched is one; a by-feel pick is one. The background alone is not, and never seeds a pace.
    @Test func everyRunnerSetsAPaceAnchorAndTheBackgroundNoLongerGuessesOne() {
        let vm = OnboardingViewModel()
        vm.activities = [.run]
        vm.chooseRunningBackground(.some)
        #expect(vm.calibrationMode == .none, "the background must not pick a pace for the athlete")
        #expect(vm.steps.contains(.pace))
        #expect(vm.suggestedPaceEntry == .easy)
        vm.step = .pace
        #expect(!vm.canAdvance)
        // An easy pace of 6:00/km implies the 5K pace whose Daniels E zone is 6:00/km, so the
        // plan's easy runs land on the pace the athlete said they run.
        vm.chooseEasyPace(360)
        #expect(vm.canAdvance)
        let implied = try! #require(vm.impliedPaces)
        #expect(abs(implied.easy - 360) <= 2)
        #expect(implied.steady < implied.easy && implied.repeats < implied.steady)
        // A by-feel pick opens first for someone new; a result for someone training consistently.
        let newcomer = OnboardingViewModel(); newcomer.activities = [.run]; newcomer.chooseRunningBackground(.new)
        #expect(newcomer.suggestedPaceEntry == .feel && newcomer.suggestedPaceFeel == .newRunner)
        let seasoned = OnboardingViewModel(); seasoned.activities = [.run]; seasoned.chooseRunningBackground(.experienced)
        #expect(seasoned.suggestedPaceEntry == .result)
    }

    @Test func benchmarkDoesNotAnswerTrainingBackground() {
        let vm = OnboardingViewModel()
        vm.step = .experience
        vm.chooseResult(.fiveK, seconds: 1200, performedAt: nil)
        #expect(!vm.canAdvance, "a result is a pace, not a training background")
        vm.chooseRunningBackground(.some)
        #expect(vm.canAdvance)
        vm.step = .pace
        #expect(vm.canAdvance, "and the result already anchors the pace page")
        #expect(vm.calibration.recentRun?.timeS == 1200)
        #expect(vm.experience == .some)
        #expect(vm.weeklyRunVolumeM == nil)
    }

    @Test func goalAndBackgroundPrecedeTheDetailedQuestions() throws {
        let vm = OnboardingViewModel()
        vm.goal = .raceDistance
        let steps = vm.steps
        #expect(Array(steps.prefix(3)) == [.name, .goal, .experience])
        #expect(try #require(steps.firstIndex(of: .building)) < #require(steps.firstIndex(of: .reveal)))
    }
}

extension OnboardingFlowTests {
    @Test func raceTimeEntryRejectsMalformedClocksAndKeepsCommonShortcuts() {
        #expect(OnboardingViewModel.benchmarkSeconds("330", benchmark: .marathon) == 12600)
        #expect(OnboardingViewModel.benchmarkSeconds("3:30", benchmark: .marathon) == 12600)
        #expect(OnboardingViewModel.benchmarkSeconds("2145", benchmark: .fiveK) == 1305)
        #expect(OnboardingViewModel.benchmarkSeconds("1:38:20", benchmark: .half) == 5900)
        for raw in ["22:xx:30", "22:99", "22::30", "-22:30", "0:00", "999999999999999999999999999"] {
            #expect(OnboardingViewModel.benchmarkSeconds(raw, benchmark: .fiveK) == nil)
        }
    }
}

extension OnboardingFlowTests {
    @Test func returningRunnerKeepsMileageQuestionsAndDraftSelection() throws {
        let vm = OnboardingViewModel()
        vm.goal = .stayConsistent
        vm.chooseReturningBackground()
        #expect(vm.returningRunner && vm.runningBackgroundChosen)
        #expect(vm.steps.contains(.runVolume))
        vm.weeklyRunVolumeM = 12_000; vm.longestRunM = 5_000
        let restored = OnboardingViewModel()
        _ = restored.restore(from: vm.draft())
        #expect(restored.returningRunner && restored.steps.contains(.runVolume))
        #expect(restored.weeklyRunVolumeM == 12_000 && restored.longestRunM == 5_000)
        restored.chooseRunningBackground(.new)
        #expect(!restored.returningRunner && !restored.steps.contains(.runVolume))
    }

    @Test func returningRunnerCanDeclareZeroRecentRunningWithoutRevivingOldMileage() throws {
        let pc = PersistenceController.inMemory(), vm = OnboardingViewModel()
        vm.name = "Returning runner"; vm.handle = "returning_runner"
        vm.goal = .stayConsistent; vm.chooseReturningBackground()
        vm.weeklyRunVolumeM = 0; vm.longestRunM = 0
        let profile = try vm.finish(in: pc.container.mainContext)
        #expect(profile.weeklyRunVolumeM == 0 && profile.longestRunM == 0)
        #expect(profile.plan?.sessions.isEmpty == false)
        #expect(profile.experience[Discipline.running.rawValue] == ExperienceLevel.some.rawValue)
    }
}
