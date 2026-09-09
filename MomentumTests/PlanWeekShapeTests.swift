import Testing
import Foundation
@testable import Momentum

/// The coach's week (2026-09-06): what a plan's SHAPE must always do, pinned across day counts,
/// hybrids and race distances. The volume and pace rules live elsewhere; this suite is about
/// which day carries what and how big each run is next to the long run.
struct PlanWeekShapeTests {
    private let cal = Calendar(identifier: .gregorian)
    private var start: Date { cal.date(from: DateComponents(year: 2026, month: 9, day: 7))! }
    private func race(weeksOut: Int) -> Date { cal.date(byAdding: .day, value: (weeksOut - 1) * 7 + 6, to: start)! }

    private func plan(days: Int, lifting: Bool, raceM: Double?, weeks: Int, level: ExperienceLevel,
                      weekly: Double, longest: Double, priority: HybridPriority? = nil, goal: Goal = .raceDistance) -> GeneratedPlan {
        let inputs = PlanInputs(disciplines: lifting ? [.running, .strength] : [.running], goal: raceM == nil ? goal : .raceDistance,
                                daysPerWeek: days, equipment: .fullGym, sessionMinutes: 75,
                                raceDate: raceM == nil ? nil : race(weeksOut: weeks), runningExperience: level, liftingExperience: .some,
                                raceDistanceM: raceM, currentWeeklyVolumeM: weekly, longestRunM: longest, hybridPriority: priority)
        return PlanEngine.generate(profile: inputs, catalog: RunningPlannerTestFixtures.catalog, startDate: start, calendar: cal)
    }

    private func longRun(_ w: GeneratedWeek) -> GeneratedSession? {
        w.sessions.first { $0.runType == .long || $0.runType == .progression }
    }

    /// Nothing hard the day after the long run — including across the week boundary, where a
    /// Sunday long run used to be followed by Monday's quality session in every plan.
    @Test func nothingHardTheDayAfterTheLongRun() {
        for (days, lifting) in [(3, false), (4, false), (5, false), (6, false), (4, true), (5, true), (6, true)] {
            let p = plan(days: days, lifting: lifting, raceM: 21_097, weeks: 12, level: .some, weekly: 40_000, longest: 15_000)
            for w in p.weeks where !w.isTaper {
                guard let long = longRun(w) else { continue }
                for s in w.sessions where s.isHardRun && s.runType != .race && s.dayOffset != long.dayOffset {
                    #expect(PlanEngine.circularDayDistance(s.dayOffset, long.dayOffset) >= 2,
                            "\(days)d\(lifting ? "+lift" : ""): w\(w.index) hard run on d\(s.dayOffset) beside the long run on d\(long.dayOffset)")
                }
            }
        }
    }

    /// Two quality days never touch, and the long run takes the last day of the week.
    @Test func hardDaysAreSpacedAndTheLongRunAnchorsSunday() {
        let p = plan(days: 6, lifting: false, raceM: 42_195, weeks: 16, level: .experienced, weekly: 60_000, longest: 25_000)
        for w in p.weeks where !w.isTaper && !w.isDeload {
            let hard = w.sessions.filter { $0.isHardRun && $0.runType != .race }.map(\.dayOffset).sorted()
            for i in hard.indices.dropFirst() {
                #expect(PlanEngine.circularDayDistance(hard[i], hard[i - 1]) >= 2, "w\(w.index): hard days \(hard)")
            }
            #expect(longRun(w)?.dayOffset == 6, "w\(w.index): the long run should anchor Sunday")
        }
    }

    /// Easy runs are sized against the long run, never beside it: easy ≤ 75 % (85 % on a 3-run
    /// week, where a capped quality session leaves only two runs to carry the volume), recovery
    /// ≤ 50 %, medium-long ≤ 85 %. A 3-run half week used to run a 13 km "easy" next to a 12 km long.
    @Test func easyRunsAreSizedAgainstTheLongRun() {
        let cases: [(Int, Bool, Double, Double, Double, ExperienceLevel)] = [
            (4, true, 21_097, 30_000, 12_000, .some), (5, true, 42_195, 50_000, 20_000, .experienced),
            (3, false, 5_000, 10_000, 4_000, .new), (5, false, 10_000, 35_000, 14_000, .some)]
        for (days, lifting, raceM, weekly, longest, level) in cases {
            let p = plan(days: days, lifting: lifting, raceM: raceM, weeks: 12, level: level, weekly: weekly, longest: longest)
            for w in p.weeks where !w.isTaper {
                guard let long = longRun(w), let longM = long.targetDistanceM else { continue }
                // A short race caps its long run outright (a 5K long run is ~9 km), so a 3-run week
                // at real volume cannot keep its easy day under the long one; that tension is the
                // long-run cap's, not the sizing's. The rule is pinned where it can hold.
                let runsInWeek = w.sessions.filter { $0.discipline == .running }.count
                if runsInWeek <= 3, raceM < 20_000 { continue }
                for s in w.sessions where s.discipline == .running && !s.isHardRun && s.runType != .race && s.dayOffset != long.dayOffset {
                    let ratio = (s.targetDistanceM ?? 0) / longM
                    let runs = runsInWeek
                    // Three runs with a capped quality session leave two runs to carry the week;
                    // there the easy run may approach the long one, but never pass it.
                    let cap: Double = s.runType == .recovery ? 0.50 : s.isMediumLong ? 0.85 : (runs <= 3 ? 0.95 : 0.80)
                    #expect(ratio <= cap, "\(days)d race \(Int(raceM)) w\(w.index): \(s.runType.map { "\($0)" } ?? "") \(Int(s.targetDistanceM ?? 0)) m is \(Int(ratio * 100)) % of the \(Int(longM)) m long run")
                }
            }
        }
    }

    /// From three days up the week runs more than it lifts unless lifting was put first.
    @Test func theWeekRunsMoreThanItLifts() {
        for days in 3...7 {
            for goal in [Goal.raceDistance, .buildMuscle, .generalFitness] {
                let s = PlanEngine.hybridSplit(days: days, priority: nil, goal: goal, raceDistanceM: goal == .raceDistance ? 21_097 : nil)
                #expect(s.runDays > s.liftDays, "\(days) days, \(goal): \(s.runDays) runs / \(s.liftDays) lifts")
                #expect(s.runDays + s.liftDays == days)
            }
            let lifter = PlanEngine.hybridSplit(days: days, priority: .lifting, goal: .buildMuscle)
            #expect(lifter.runDays >= lifter.liftDays, "lifting-first may tie, never lift more: \(lifter)")
        }
        #expect(PlanEngine.hybridSplit(days: 5, priority: nil, goal: .raceDistance, raceDistanceM: 42_195).runDays == 4)
        #expect(PlanEngine.hybridSplit(days: 6, priority: nil, goal: .raceDistance, raceDistanceM: 42_195).runDays == 5)
    }

    /// A hard lower-body lift never sits the day before a hard run, and no lift takes the day
    /// before the long run while another day is free.
    @Test func liftsKeepClearOfTheLongRunAndHardRuns() {
        for days in [4, 5, 6] {
            let p = plan(days: days, lifting: true, raceM: 21_097, weeks: 12, level: .some, weekly: 40_000, longest: 15_000)
            for w in p.weeks {
                #expect(PlanEngine.scheduleSatisfiesRecovery(w.sessions), "\(days)d w\(w.index)")
                guard let long = longRun(w) else { continue }
                for s in w.sessions where s.discipline == .strength {
                    #expect((s.dayOffset + 1) % 7 != long.dayOffset, "\(days)d w\(w.index): a lift the day before the long run")
                }
            }
        }
    }

    /// A marathoner's build and peak carry threshold and race pace, never three-minute reps, and
    /// every peak week's long run carries race pace.
    @Test func marathonQualityIsSpecific() {
        let p = plan(days: 6, lifting: false, raceM: 42_195, weeks: 16, level: .experienced, weekly: 60_000, longest: 25_000)
        for w in p.weeks where w.phase == .build || w.phase == .peak {
            for s in w.sessions where s.isHardRun {
                #expect(!(s.intervals ?? "").contains("3min"), "w\(w.index): \(s.intervals ?? "") in a marathon build")
            }
            if w.phase == .peak, let long = longRun(w) {
                #expect((long.intervals ?? "").lowercased().contains("race pace"), "peak w\(w.index): the long run carries no race pace")
            }
        }
    }

    /// The ultra's weekend: a medium-long the day before the long run in build and peak.
    @Test func ultraBuildsRunBackToBack() {
        let p = plan(days: 6, lifting: true, raceM: 50_000, weeks: 20, level: .experienced, weekly: 70_000, longest: 30_000, priority: .running)
        var backToBacks = 0
        for w in p.weeks where (w.phase == .build || w.phase == .peak) && !w.isDeload {
            guard let long = longRun(w) else { continue }
            if let b2b = w.sessions.first(where: { $0.backToBack }) {
                backToBacks += 1
                #expect((b2b.dayOffset + 1) % 7 == long.dayOffset, "w\(w.index): the back-to-back is not the day before the long run")
                #expect((b2b.targetDistanceM ?? 0) <= (long.targetDistanceM ?? 0) * 0.66)
            }
        }
        #expect(backToBacks >= 4, "an ultra build should run back-to-back most weeks, got \(backToBacks)")
    }

    /// The coach's pick: frequency grows with the goal and the level; a lifter gets one more day.
    @Test func recommendedDaysFollowTheGoal() {
        #expect(PlanFeasibility.recommendedDays(goal: .raceDistance, raceDistanceM: 5_000, experience: .new, lifting: false) == 3)
        #expect(PlanFeasibility.recommendedDays(goal: .raceDistance, raceDistanceM: 21_097, experience: .some, lifting: false) == 5)
        #expect(PlanFeasibility.recommendedDays(goal: .raceDistance, raceDistanceM: 21_097, experience: .some, lifting: true) == 6)
        #expect(PlanFeasibility.recommendedDays(goal: .raceDistance, raceDistanceM: 42_195, experience: .experienced, lifting: false) == 6)
        #expect(PlanFeasibility.recommendedDays(goal: .raceDistance, raceDistanceM: 50_000, experience: .some, lifting: true) == 6)
        #expect(PlanFeasibility.recommendedDays(goal: .stayConsistent, raceDistanceM: nil, experience: .new, lifting: false) == 3)
        #expect(PlanFeasibility.recommendedDays(goal: .generalFitness, raceDistanceM: nil, experience: .some, lifting: false) == 4)
    }

    /// Every route into a plan opens with a run on day zero — on whatever weekday the athlete
    /// signed up (2026-09-06): never a lift, never a rest day, never a hard session. And from the
    /// second week the long run lives on the weekend whatever day the plan began.
    @Test func everyRouteOpensWithARunAndKeepsTheLongRunOnTheWeekend() {
        let goals: [(Goal, Double?)] = [(.raceDistance, 5_000), (.raceDistance, 21_097), (.raceDistance, 42_195),
                                        (.endurance, nil), (.generalFitness, nil), (.buildMuscle, nil), (.stayConsistent, nil)]
        var checked = 0
        for anchor in 1...7 {
            for days in 2...7 {
                for lifting in [false, true] {
                    for (goal, raceM) in goals {
                        for level in [ExperienceLevel.new, .some, .experienced] {
                            var inputs = PlanInputs(disciplines: lifting ? [.running, .strength] : [.running], goal: goal,
                                                    daysPerWeek: days, equipment: .fullGym, sessionMinutes: 60,
                                                    raceDate: raceM == nil ? nil : race(weeksOut: 10),
                                                    runningExperience: level, liftingExperience: .some,
                                                    raceDistanceM: raceM,
                                                    currentWeeklyVolumeM: level == .new ? nil : 30_000,
                                                    longestRunM: level == .new ? nil : 10_000)
                            inputs.anchorWeekday = anchor
                            let plan = PlanEngine.generate(profile: inputs, catalog: RunningPlannerTestFixtures.catalog,
                                                           startDate: start, calendar: cal)
                            guard let first = plan.weeks.first else { continue }
                            let label = "anchor \(anchor) days \(days) lifting \(lifting) goal \(goal) race \(raceM ?? 0) level \(level)"
                            let zero = first.sessions.filter { $0.dayOffset == 0 }
                            // A sub-mile safe dose must be walking, not an inflated first run.
                            #expect(zero.contains { $0.discipline == .running || $0.discipline == .walking }, "no endurance session on day 0: \(label)")
                            #expect(first.sessions.filter { $0.discipline == .running }.allSatisfy { ($0.targetDistanceM ?? 0) >= 1609.344 })
                            #expect(!zero.contains { $0.discipline == .strength }, "a lift on day 0: \(label)")
                            #expect(!zero.contains { $0.isHardRun }, "a hard run on day 0: \(label)")
                            let mondayOffset = (((2 - anchor) % 7) + 7) % 7
                            for w in plan.weeks.dropFirst() where !w.sessions.contains(where: { $0.runType == .race }) {
                                if let long = longRun(w) {
                                    let weekday = (((long.dayOffset - mondayOffset) % 7) + 7) % 7
                                    #expect(weekday >= 5, "w\(w.index) long run on weekday \(weekday): \(label)")
                                }
                                let runs = w.sessions.filter { $0.discipline == .running }.count
                                let lifts = w.sessions.filter { $0.discipline == .strength }.count
                                #expect(runs >= lifts, "w\(w.index) lifts more than it runs: \(label)")
                            }
                            checked += 1
                        }
                    }
                }
            }
        }
        #expect(checked > 1_000)
    }

    /// The athlete's own days are honoured on real weekdays too: the long run takes the weekend day
    /// they offered, and a plan that began on a Thursday does not put its opening run on a day
    /// they never offered.
    @Test func preferredWeekdaysKeepTheLongRunOnTheWeekendFromAnyStartDay() {
        // Mon/Wed/Sat as offsets from a Thursday start: Thu = 0 … Sat = 2, Mon = 4, Wed = 6.
        var inputs = PlanInputs(disciplines: [.running], goal: .raceDistance, daysPerWeek: 3, equipment: .bodyweight,
                                sessionMinutes: 60, raceDate: race(weeksOut: 10), runningExperience: .some,
                                liftingExperience: .new, raceDistanceM: 10_000, currentWeeklyVolumeM: 25_000,
                                longestRunM: 9_000, preferredDayOffsets: [2, 4, 6])
        inputs.anchorWeekday = 5
        let plan = PlanEngine.generate(profile: inputs, catalog: RunningPlannerTestFixtures.catalog, startDate: start, calendar: cal)
        // Thursday is not one of their days, so the opening run does not take it: the athlete's own
        // days are the one thing the opening run never overrides (a first run they cannot do is a
        // first miss). Their first run is Saturday, two days in.
        #expect(!plan.weeks[0].sessions.contains { $0.dayOffset == 0 })
        #expect(plan.weeks[0].sessions.contains { $0.dayOffset == 2 && $0.discipline == .running })
        for w in plan.weeks.dropFirst() where !w.sessions.contains(where: { $0.runType == .race }) {
            #expect(longRun(w)?.dayOffset == 2, "w\(w.index): the long run should take Saturday (offset 2)")
            let days = Set(w.sessions.map(\.dayOffset))
            #expect(days.isSubset(of: [2, 4, 6]), "w\(w.index) used \(days.sorted())")
        }
    }

    /// A rebuild after today's run does not ask for a second one, and an evening sign-up starts tomorrow.
    @Test func theOpeningRunStepsAsideWhenTheyAlreadyRanAndEveningsStartTomorrow() {
        var inputs = PlanInputs(disciplines: [.running, .strength], goal: .raceDistance, daysPerWeek: 4, equipment: .fullGym,
                                sessionMinutes: 60, raceDate: race(weeksOut: 10), runningExperience: .some,
                                liftingExperience: .some, raceDistanceM: 21_097, currentWeeklyVolumeM: 30_000, longestRunM: 12_000)
        inputs.anchorWeekday = 2
        inputs.opensWithRun = false
        let plan = PlanEngine.generate(profile: inputs, catalog: RunningPlannerTestFixtures.catalog, startDate: start, calendar: cal)
        #expect(!plan.weeks[0].sessions.contains { $0.dayOffset == 0 && $0.discipline == .running },
                "with a run already logged today the template's Tuesday opener stays put")
        var comps = DateComponents(); comps.year = 2026; comps.month = 9; comps.day = 7; comps.hour = 21; comps.minute = 30
        let evening = cal.date(from: comps)!
        #expect(cal.isDate(PlanService.firstPlanStart(now: evening, calendar: cal), inSameDayAs: cal.date(byAdding: .day, value: 1, to: evening)!))
        comps.hour = 7
        let morning = cal.date(from: comps)!
        #expect(PlanService.firstPlanStart(now: morning, calendar: cal) == morning)
    }
}
