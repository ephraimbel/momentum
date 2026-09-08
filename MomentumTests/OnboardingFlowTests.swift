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
        #expect(vm.steps.contains(.session))
        vm.activities = [.strength]
        #expect(vm.steps.contains(.equipment))
        #expect(vm.steps.contains(.session))          // lifters set it (it drives exercise count)
        #expect(vm.running)                           // every coached plan keeps its running foundation
        vm.activities = [.run, .strength]
        #expect(vm.steps.contains(.session))          // hybrids lift too → keep it

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

        // Step order: the coach-interview arc holds (broad → specific → consent → commitment).
        let steps = vm.steps
        func idx(_ s: OnboardingViewModel.Step) throws -> Int { try #require(steps.firstIndex(of: s)) }
        #expect(steps.first == .name)
        #expect(try idx(.goal) < idx(.experience))
        #expect(try idx(.experience) < idx(.disciplines))           // destination → starting point
        #expect(try idx(.experience) < idx(.injuries))       // who you are → what to protect
        #expect(try idx(.runVolume) < idx(.injuries))        // baseline stays together
        #expect(try idx(.metrics) < idx(.days))              // starting point → training week
        #expect(try idx(.experience) < idx(.health))         // running level + pace → recovery consent
        #expect(try idx(.health) < idx(.intensity))          // consent → how hard to push
        #expect(try idx(.intensity) < idx(.notifications))   // decisions → required permission context
        #expect(try idx(.notifications) < idx(.primers))     // reminders → location
        #expect(try idx(.primers) < idx(.building))          // permissions settle before generation
        #expect(try idx(.building) < idx(.reveal))           // anticipation → personalized payoff
        // The review beat sits BETWEEN the payoff and checkout (2026-09-05) — never before the
        // plan exists, and never as the last thing standing between the athlete and the app.
        #expect(try idx(.reveal) < idx(.review))             // payoff → the ask
        #expect(try idx(.review) < idx(.account))            // the ask → checkout + account
        #expect(!steps.contains(.equipment))                 // no lifting → no gym questions
        #expect(steps.contains(.session))                    // …but session length is everyone's

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

    /// Where the review beat may sit (owner call 2026-09-05, reversing the 2026-08-22 removal).
    ///
    /// A rating ask shipped from 2026-07-26 as the last screen before checkout and this app was
    /// rejected under App Review 5.6.3 with it in place. It is back, but only in one position: it
    /// follows the reveal, so the plan exists before anything is asked for, and it precedes the
    /// paywall + account beats, so it is never the last thing between the athlete and the app.
    /// `OnboardingReviewUITests` pins the page's own shape; this pins its seat in the flow.
    @Test func theReviewBeatSitsBetweenTheRevealAndCheckout() throws {
        let steps = OnboardingViewModel().steps
        #expect(steps.firstIndex(of: .primers)! < steps.firstIndex(of: .building)!)
        #expect(steps.firstIndex(of: .review)! == steps.firstIndex(of: .reveal)! + 1,
                "the ask follows the plan and nothing comes between them")
        #expect(steps.firstIndex(of: .account)! == steps.firstIndex(of: .review)! + 1,
                "the review beat raises checkout, which advances to account")
        #expect(steps.last == .account, "the ask is never the last beat")
    }

    /// The account beat is the LAST step, AFTER the paywall (owner call 2026-07-27 — the sign-in
    /// screen used to gate the app on launch, which is the cheapest place in the funnel to lose
    /// someone). It must not be an answerable question, and onboarding must read as *finished* by
    /// the time it shows, since every question was answered a while back.
    @Test func accountBeatIsTheFinalStepAndIsNotAQuestion() throws {
        let vm = OnboardingViewModel()
        let all = vm.steps
        #expect(all.last == .account, "account must be the last step — nothing follows it")
        #expect(all.firstIndex(of: .account)! == all.firstIndex(of: .review)! + 1,
                "the paywall is raised from the review beat, then advances to account")

        vm.step = .account
        #expect(!vm.isQuestionStep, "no header, no Continue bar, no progress notch")
        #expect(vm.progress == 1, "every question is long since answered")

        // `advance()` from the REVIEW beat lands here — that is how the paywall's onDismiss
        // reaches it (`goToAccountBeat` → `goNext`), since the wall never changed the step
        // underneath it. The wall is now raised one beat later than it used to be (the review
        // page's Continue calls `finishOnboarding`), so this is the step it returns to.
        vm.step = .reveal
        vm.advance()
        #expect(vm.step == .review)
        vm.advance()
        #expect(vm.step == .account)
        // And it is a genuine terminus: advancing off the end must not wrap or stall elsewhere.
        vm.advance()
        #expect(vm.step == .account)
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
        #expect(vm.steps.filter { vm.step = $0; return vm.isQuestionStep }.count == 10)
        #expect(vm.steps.contains(.name))
        #expect(!vm.steps.contains(.identity))
        #expect(!vm.steps.contains(.units))
        #expect(!vm.steps.contains(.preferredDays))
        #expect(!vm.steps.contains(.why))
        for step in [OnboardingViewModel.Step.experience, .runVolume, .injuries, .metrics, .days, .session, .intensity] {
            #expect(vm.steps.contains(step))
        }
        vm.step = .account
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
        vm.calibrationMode = .feel
        vm.paceFeel = .newRunner
        #expect(vm.canAdvance)
        vm.step = .health
        #expect(vm.progress > 0 && vm.progress < 1)
        vm.step = .notifications
        #expect(vm.progress == 1)
        vm.step = .primers
        #expect(vm.progress == 1)
    }

    @Test func identityStartsTheFlowAndKeepsCustomUsernames() throws {
        let vm = OnboardingViewModel()
        #expect(vm.step == .name)
        #expect(!vm.canAdvance)
        vm.name = "Maya Rivera"
        vm.suggestHandle(afterEditing: "")
        #expect(!vm.handle.isEmpty)
        #expect(vm.canAdvance)
        vm.handle = "maya_runs"
        vm.name = "Maya R"
        vm.suggestHandle(afterEditing: "Maya Rivera")
        #expect(vm.handle == "maya_runs")
        let restored = OnboardingViewModel()
        #expect(restored.restore(from: vm.draft()))
        #expect(restored.name == "Maya R")
        #expect(restored.handle == "maya_runs")
        vm.handle = "admin"
        #expect(!vm.canAdvance)
        vm.handle = ""
        #expect(!vm.canAdvance)
    }

}

extension OnboardingFlowTests {
    @Test func benchmarkDoesNotAnswerTrainingBackground() {
        let vm = OnboardingViewModel()
        vm.step = .experience
        vm.calibrationMode = .time
        vm.benchmark = .fiveK
        vm.recentRunSeconds = 1200
        #expect(!vm.canAdvance)
        vm.chooseRunningBackground(.some)
        #expect(vm.canAdvance)
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
