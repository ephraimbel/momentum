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

        let profile = vm.finish(in: ctx)

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

    @Test func importedRestingHRUnlocksKarvonenZones() throws {
        // Resting HR captured at the Health consent moment persists to the profile — and Karvonen
        // zones differ measurably from the %-max fallback (plan-quality audit fix #6).
        let pc = PersistenceController.inMemory()
        let ctx = pc.container.mainContext
        let vm = OnboardingViewModel()
        vm.activities = [.run]
        vm.goal = .endurance
        vm.birthYear = Calendar.current.component(.year, from: Date()) - 30
        vm.importedRestingHR = 52

        let profile = vm.finish(in: ctx)
        #expect(profile.restingHR == 52)
        let maxHR = try #require(profile.maxHR)              // Tanaka estimate from age
        let karvonen = try #require(HRZones.zones(maxHR: maxHR, restingHR: 52))
        let percentMax = try #require(HRZones.zones(maxHR: maxHR, restingHR: nil))
        #expect(karvonen[0].bpm.lowerBound > percentMax[0].bpm.lowerBound)   // Z1 floor rises off resting HR
        // Nothing imported → profile stays nil and zones fall back (regression).
        let bare = OnboardingViewModel()
        bare.activities = [.run]
        #expect(bare.finish(in: ctx).restingHR == nil)
    }

    @Test func progressAdvancesAndSkipsEquipmentForNonLifters() {
        let vm = OnboardingViewModel()
        vm.activities = [.run]                        // no lifting
        #expect(!vm.steps.contains(.equipment))
        vm.activities = [.strength]
        #expect(vm.steps.contains(.equipment))

        vm.step = .disciplines
        #expect(vm.canAdvance)                        // activities chosen
        vm.activities = []
        #expect(!vm.canAdvance)                        // must pick at least one

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
        let profile = vm.finish(in: ctx)
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
        #expect(try idx(.name) < idx(.identity))             // your name → your @handle
        #expect(try idx(.identity) < idx(.goal))             // identity settles before training questions
        #expect(try idx(.experience) < idx(.injuries))       // who you are → what to protect
        #expect(try idx(.injuries) < idx(.race))             // before the race specifics
        #expect(try idx(.calibration) < idx(.health))        // fitness baseline → recovery consent
        #expect(try idx(.health) < idx(.intensity))          // consent → how hard to push
        #expect(try idx(.intensity) < idx(.building))        // last decision before the build
        #expect(!steps.contains(.equipment))                 // no lifting → no gym questions

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
        let profile = vm.finish(in: ctx)
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
}
