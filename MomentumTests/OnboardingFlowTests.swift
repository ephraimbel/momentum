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

        let profile = vm.finish(in: ctx)

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
    }

    @Test func crossTrainingAddOnsLandInThePlan() throws {
        let pc = PersistenceController.inMemory()
        let ctx = pc.container.mainContext
        let vm = OnboardingViewModel()
        vm.activities = [.run, .swim, .yoga]         // run is programmed; swim/yoga are tracked add-ons
        vm.daysPerWeek = 3
        let profile = vm.finish(in: ctx)
        let plan = try #require(profile.plan)
        let sports = Set(plan.sessions.compactMap { $0.workoutType })
        #expect(sports.contains(.swimming))
        #expect(sports.contains(.yoga))
        #expect(profile.disciplines == ["running"])  // only the programmable one drives the engine
    }
}
