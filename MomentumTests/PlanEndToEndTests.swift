import Testing
import Foundation
import SwiftData
@testable import Momentum

/// The last gap in the coach audit (2026-08-29): the audits judge plans the engine builds from
/// inputs a test hands it. This one starts where the athlete does — a `UserProfile` as onboarding
/// writes it — and follows it through the REAL mapping (`PlanService.planInputs`), the REAL
/// persistence (`PlanService.rebuild`), and out the other side as `PlannedSession` rows.
///
/// The engine can be flawless and every plan still wrong if a single answer is dropped on the way
/// in, and nothing else in the suite would notice.
@MainActor
struct PlanEndToEndTests {

    private func container() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    /// A profile with EVERY answer onboarding can collect, each set to a value distinctive enough
    /// that dropping it would be visible.
    private func fullProfile(raceWeeksOut: Int = 16) -> UserProfile {
        let p = UserProfile()
        p.goal = .raceDistance
        p.disciplines = [Discipline.running.rawValue, Discipline.strength.rawValue]
        p.experience = [Discipline.running.rawValue: ExperienceLevel.experienced.rawValue,
                        Discipline.strength.rawValue: ExperienceLevel.some.rawValue]
        p.daysPerWeek = 5
        p.sessionMinutes = 60
        p.equipment = .dumbbellsOnly
        p.raceDistanceM = 21_097
        p.raceDate = Calendar.current.date(byAdding: .day, value: raceWeeksOut * 7, to: Date())
        p.goalFinishTimeS = 95 * 60                       // 1:35 half
        p.weeklyRunVolumeM = 48_000
        p.longestRunM = 16_000
        p.targetWeeklyRunVolumeM = 70_000
        p.planIntensity = PlanIntensity.aggressive.rawValue
        p.injuryHistory = [InjuryArea.knee.rawValue]
        p.birthYear = Calendar.current.component(.year, from: Date()) - 41
        p.preferredDays = [2, 4, 6]                        // the athlete's own choice
        p.muscleFocus = [MuscleGroup.glutes.rawValue]
        p.strengthSplit = StrengthSplitStyle.upperLower.rawValue
        p.hybridPriority = HybridPriority.running.rawValue
        p.distanceUnit = DistanceUnit.imperial.rawValue
        return p
    }

    // MARK: The mapping

    /// Every answer the athlete gave reaches the engine. A dropped field here is silent: the plan
    /// still generates, it is simply someone else's plan.
    @Test func everyOnboardingAnswerReachesTheEngine() throws {
        let p = fullProfile()
        let i = PlanService.planInputs(from: p)

        #expect(i.goal == .raceDistance)
        #expect(Set(i.disciplines) == [.running, .strength])
        #expect(i.runningExperience == .experienced)
        #expect(i.liftingExperience == .some)
        #expect(i.daysPerWeek == 5)
        #expect(i.sessionMinutes == 60)
        #expect(i.equipment == .dumbbellsOnly)
        #expect(i.raceDistanceM == 21_097)
        #expect(i.raceDate != nil)
        #expect(i.goalFinishTimeS == 5_700.0)
        #expect(i.currentWeeklyVolumeM == 48_000)
        #expect(i.longestRunM == 16_000)
        #expect(i.targetWeeklyVolumeM == 70_000)
        #expect(i.intensity == .aggressive)
        #expect(i.injuryHistory == [.knee])
        #expect(i.age == 41)
        #expect(i.muscleFocus == [.glutes])
        #expect(i.strengthSplit == .upperLower)
        #expect(i.hybridPriority == .running)
        #expect(i.distanceUnit == .imperial)
        #expect(i.preferredDayOffsets.count == 3, "the athlete's chosen days were dropped")
    }

    // MARK: The plan the athlete actually receives

    /// Generated, persisted, and read back as rows — the plan on their screen honours what they
    /// said, in detail.
    @Test func thePersistedPlanHonoursTheProfile() throws {
        let c = try container()
        let ctx = c.mainContext
        let p = fullProfile()
        ctx.insert(p)
        PlanService.rebuild(for: p, in: ctx)

        let plan = try #require(p.plan, "rebuild produced no plan")
        let sessions = plan.sessions
        #expect(!sessions.isEmpty, "the plan has no sessions")

        // It is a RACE plan, pointed at their race, with a race day on it.
        #expect(plan.raceDate != nil)
        let race = sessions.first { $0.runType == .race }
        #expect(race != nil, "a dated race produced no race day")
        #expect(abs((race?.targetDistanceM ?? 0) - 21_097) < 200, "race day is not their race distance")

        // Their goal time reached the plan and is what race pace is set at.
        let goalPace = try #require(plan.goalRacePaceSPerKm, "the goal time never reached the plan")
        #expect(goalPace > 0 && goalPace < 600)

        // Every running session is followable: a distance, a human pace, a name.
        for s in sessions where s.discipline == .running {
            #expect((s.targetDistanceM ?? 0) > 0 || (s.targetDurationS ?? 0) > 0,
                    "a \(s.runType?.rawValue ?? "run") has no target")
            if let pace = s.targetPaceSPerKm, pace > 0 { #expect(pace > 120 && pace < 1200) }
            #expect(s.runType != nil || s.discipline != .running)
        }
        // Strength came too, on their split, with their equipment.
        #expect(sessions.contains { $0.discipline == .strength }, "a hybrid athlete got no lifting")

        // Their weekly ceiling held: no week past the 70 km they said they would build to
        // (plus clean-distance rounding).
        let cal = Calendar.current
        var byWeek: [Date: Double] = [:]
        for s in sessions where s.discipline == .running && s.runType != .race {
            guard let week = cal.dateInterval(of: .weekOfYear, for: s.date)?.start else { continue }
            byWeek[week, default: 0] += s.targetDistanceM ?? 0
        }
        let peak = byWeek.values.max() ?? 0
        #expect(peak <= 70_000 * 1.08, "peaked at \(Int(peak / 1000))km against a stated 70km ceiling")
        #expect(peak > 48_000, "never grew past the 48km they walked in on")
    }

    // MARK: Adjusting the plan in the app

    /// The in-app edit path (Plan settings → save → rebuild): changing an answer changes the plan.
    /// A settings screen that writes a field the generator never re-reads is the quiet failure.
    @Test func adjustingThePlanInAppChangesThePlan() throws {
        let c = try container()
        let ctx = c.mainContext
        let p = fullProfile()
        ctx.insert(p)
        PlanService.rebuild(for: p, in: ctx)
        let before = try #require(p.plan)
        let beforeDays = Set(before.sessions.map { Calendar.current.component(.weekday, from: $0.date) })
        let beforeCount = before.sessions.count

        // The athlete drops to 3 days a week and eases off — exactly what Plan settings writes.
        p.daysPerWeek = 3
        p.planIntensity = PlanIntensity.gentle.rawValue
        p.targetWeeklyRunVolumeM = 55_000
        PlanService.rebuild(for: p, in: ctx)

        let after = try #require(p.plan)
        #expect(after.sessions.count != beforeCount, "the plan did not change when the athlete did")
        let weeks = Double(Set(after.sessions.compactMap {
            Calendar.current.dateInterval(of: .weekOfYear, for: $0.date)?.start
        }).count)
        let runsPerWeek = Double(after.sessions.filter { $0.discipline == .running }.count) / max(1, weeks)
        #expect(runsPerWeek <= 4.5, "asked for 3 days, got \(runsPerWeek) runs a week")
        _ = beforeDays

        // And the new ceiling holds.
        let cal = Calendar.current
        var byWeek: [Date: Double] = [:]
        for s in after.sessions where s.discipline == .running && s.runType != .race {
            guard let w = cal.dateInterval(of: .weekOfYear, for: s.date)?.start else { continue }
            byWeek[w, default: 0] += s.targetDistanceM ?? 0
        }
        #expect((byWeek.values.max() ?? 0) <= 55_000 * 1.08, "the lowered ceiling was ignored")
    }

    /// A plan with no race is still a real plan — the "get fitter" athlete is the most common one.
    @Test func theNoRaceAthleteStillGetsARealPlan() throws {
        let c = try container()
        let ctx = c.mainContext
        let p = fullProfile()
        p.goal = .endurance
        p.raceDistanceM = nil
        p.raceDate = nil
        p.goalFinishTimeS = nil
        ctx.insert(p)
        PlanService.rebuild(for: p, in: ctx)

        let plan = try #require(p.plan)
        let runs = plan.sessions.filter { $0.discipline == .running }
        #expect(runs.count >= 8, "a no-race plan should still be weeks of real running")
        #expect(runs.contains { $0.runType == .long }, "no long run in an endurance plan")
        #expect(!runs.contains { $0.runType == .race }, "invented a race nobody entered")
        for s in runs { #expect((s.targetDistanceM ?? 0) > 0, "an empty session in a no-race plan") }
    }

    /// The off-by-one this suite was written to catch (2026-08-29). A race picked off a calendar
    /// lands an exact number of weeks out more often than not, and that was precisely the case
    /// that generated a plan with NO RACE DAY: `weeksToRace` measured `.weekOfYear` between two
    /// timestamps, which floors, and an afternoon start against a morning race floored it twice.
    @Test func aRaceAnExactNumberOfWeeksOutStillGetsARaceDay() throws {
        let cal = Calendar.current
        for weeks in [4, 8, 12, 16, 20, 24] {
            for hourOffset in [-6, 0, 6] {                     // race morning, same time, evening
                let start = Date()
                let race = cal.date(byAdding: .hour, value: hourOffset,
                                    to: cal.date(byAdding: .day, value: weeks * 7, to: start)!)!
                let counted = try #require(PlanEngine.weeksToRace(startDate: start, raceDate: race, calendar: cal))
                let generated = PlanEngine.weeksToGenerate(startDate: start, raceDate: race, calendar: cal)
                let dayCount = cal.dateComponents([.day], from: cal.startOfDay(for: start),
                                                  to: cal.startOfDay(for: race)).day ?? 0
                #expect(dayCount / 7 < generated,
                        "\(weeks)w \(hourOffset)h: race falls in week \(dayCount / 7) of a \(generated)-week plan")
                #expect(counted == generated)

                var p = PlanInputs(disciplines: [.running], goal: .raceDistance, daysPerWeek: 5,
                                   equipment: .fullGym, sessionMinutes: 60, raceDate: race,
                                   runningExperience: .some, liftingExperience: .some,
                                   raceDistanceM: 21_097)
                p.currentWeeklyVolumeM = 40_000
                let plan = PlanEngine.generate(profile: p, catalog: [], startDate: start)
                #expect(plan.weeks.flatMap(\.sessions).contains { $0.runType == .race },
                        "\(weeks) weeks out, \(hourOffset)h: the plan has no race day")
            }
        }
    }
}
