import Testing
import Foundation
@testable import Momentum

/// A coach's reading of generated plans, printed week by week (2026-09-06). Not an assertion
/// suite: `PlanProfessionalAuditTests` and the coach audits pin outcomes. This is the eyes —
/// run it to SEE what eight representative athletes are actually handed.
struct PlanCoachReviewHarnessTests {
    private let cal = Calendar(identifier: .gregorian)
    private var start: Date { cal.date(from: DateComponents(year: 2026, month: 9, day: 7))! }   // a Monday
    private func race(weeksOut: Int) -> Date { cal.date(byAdding: .day, value: (weeksOut - 1) * 7 + 6, to: start)! }

    private func pace(_ s: Double?) -> String {
        guard let s, s > 0 else { return "" }
        return String(format: "%d:%02d/km", Int(s) / 60, Int(s) % 60)
    }

    private func describe(_ label: String, _ inputs: PlanInputs, calibration: CalibrationSeed = .none) {
        let plan = PlanEngine.generate(profile: inputs, catalog: RunningPlannerTestFixtures.catalog,
                                       calibration: calibration, startDate: start, calendar: cal)
        let days = ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"]
        var lines: [String] = ["", "===== \(label) — \(plan.weeks.count) weeks, p5k \(pace(plan.p5kSPerKm)), threshold \(pace(plan.thresholdSPerKm))"]
        for w in plan.weeks {
            let runs = w.sessions.filter { $0.discipline == .running }
            let lifts = w.sessions.filter { $0.discipline == .strength }
            let km = w.runVolumeM / 1000
            lines.append(String(format: "W%02d %@%@%@ | %.1f km | %d runs / %d lifts",
                                w.index + 1, "\(w.phase)".padding(toLength: 6, withPad: " ", startingAt: 0),
                                w.isDeload ? " DELOAD" : "", w.isTaper ? " TAPER" : "", km, runs.count, lifts.count))
            for s in w.sessions.sorted(by: { $0.dayOffset < $1.dayOffset }) {
                let d = days[max(0, min(6, s.dayOffset))]
                if s.discipline == .strength {
                    lines.append("    \(d)  LIFT \(s.strengthLabel ?? "") (\(s.strengthTargets.count) ex)")
                } else {
                    let type = s.runType.map { "\($0)" } ?? "?"
                    let dist = s.targetDistanceM.map { String(format: "%.1f km", $0 / 1000) } ?? ""
                    let iv = s.intervals.map { " [\($0)]" } ?? ""
                    lines.append("    \(d)  \(type.uppercased().padding(toLength: 11, withPad: " ", startingAt: 0)) \(dist) \(pace(s.targetPaceSPerKm))\(iv)\(s.isHardRun ? " *hard*" : "")")
                }
            }
        }
        print(lines.joined(separator: "\n"))
    }

    /// The tune-up contract's two comparisons, printed side by side (control vs. the plan with the
    /// tune-up) so a scheduler change can be read against them.
    @Test func printTuneUpComparison() {
        var inp = PlanInputs(disciplines: [.running], goal: .raceDistance, daysPerWeek: 5, equipment: .fullGym,
                             sessionMinutes: 60, raceDate: cal.date(byAdding: .weekOfYear, value: 16, to: start)!,
                             runningExperience: .experienced, liftingExperience: .some)
        inp.raceDistanceM = 42_195; inp.currentWeeklyVolumeM = 48_000; inp.longestRunM = 18_000
        inp.preferredDayOffsets = [1, 2, 3, 5, 6]
        var seed = CalibrationSeed.none; seed.estimatedP5kSPerKm = 250
        let control = PlanEngine.generate(profile: inp, catalog: [], calibration: seed, startDate: start, calendar: cal)
        inp.tuneUpRaces = [PlanRaceEvent(id: UUID(), date: cal.date(byAdding: .day, value: 8 * 7 + 6, to: start)!, distanceM: 10_000, priority: .b)]
        let plan = PlanEngine.generate(profile: inp, catalog: [], calibration: seed, startDate: start, calendar: cal)
        func line(_ s: GeneratedSession) -> String {
            "d\(s.dayOffset) \(s.runType.map { "\($0)" } ?? "lift") \(Int(s.targetDistanceM ?? 0))\(s.intervals.map { " [\($0)]" } ?? "")\(s.isHardRun ? "*" : "")"
        }
        var out = ["===== TUNE-UP DIFF (control vs plan), weeks that differ before week 8:"]
        for w in 0..<8 where control.weeks[w].sessions != plan.weeks[w].sessions {
            out.append("W\(w + 1) control: " + control.weeks[w].sessions.map(line).joined(separator: " · "))
            out.append("W\(w + 1) plan:    " + plan.weeks[w].sessions.map(line).joined(separator: " · "))
        }
        out.append("===== TUNE-UP DIFF END")
        print(out.joined(separator: "\n"))
    }

    /// Three scenarios the tripwires flag, printed with each week's volume so the jump can be read.
    @Test func printTripwireScenarios() {
        func volumes(_ label: String, _ inputs: PlanInputs) {
            let plan = PlanEngine.generate(profile: inputs, catalog: RunningPlannerTestFixtures.catalog, startDate: start, calendar: cal)
            var lines = ["===== TRIPWIRE \(label)"]
            for w in plan.weeks {
                let s = w.sessions.filter { $0.discipline == .running }.sorted { $0.dayOffset < $1.dayOffset }
                    .map { "d\($0.dayOffset) \($0.runType.map { "\($0)" } ?? "?") \(Int(($0.targetDistanceM ?? 0) / 100))\($0.isMediumLong ? "m" : "")\($0.isHardRun ? "*" : "")" }
                    .joined(separator: " ")
                lines.append(String(format: "W%02d %@%@ %.1f km | %@", w.index + 1, "\(w.phase)".padding(toLength: 8, withPad: " ", startingAt: 0), w.isDeload ? " D" : (w.isTaper ? " T" : "  "), w.runVolumeM / 1000, s))
            }
            print(lines.joined(separator: "\n"))
        }
        volumes("10pct endurance 4d experienced",
                PlanInputs(disciplines: [.running], goal: .endurance, daysPerWeek: 4, equipment: .fullGym, sessionMinutes: 60,
                           raceDate: nil, runningExperience: .experienced, liftingExperience: .some))
        var seed80 = PlanInputs(disciplines: [.running], goal: .raceDistance, daysPerWeek: 5, equipment: .fullGym, sessionMinutes: 45,
                                raceDate: race(weeksOut: 14), runningExperience: .experienced, liftingExperience: .some,
                                raceDistanceM: 10_000, intensity: .balanced)
        seed80.currentWeeklyVolumeM = 80 * 1609.344; seed80.longestRunM = 80 * 1609.344 * 0.3
        volumes("seed80 5d 10K 14wk", seed80)
        var adv = PlanInputs(disciplines: [.running, .strength], goal: .raceDistance, daysPerWeek: 3, equipment: .fullGym, sessionMinutes: 60,
                             raceDate: cal.date(byAdding: .day, value: 252, to: start)!, runningExperience: .experienced, liftingExperience: .some,
                             raceDistanceM: 5_000, currentWeeklyVolumeM: 130_500, targetWeeklyVolumeM: 227_000, hybridPriority: .lifting,
                             avoidDayOffsets: [2, 4, 6], intensity: .gentle, age: 59)
        adv.longestRunM = 30_000
        volumes("adversarial 3769 5K 3d lifting 130km", adv)
    }

    @Test func printEightAthletes() {
        describe("A. Beginner 5K · 3 days · run only · 8 wk · 10 km/wk",
                 PlanInputs(disciplines: [.running], goal: .raceDistance, daysPerWeek: 3, equipment: .bodyweight,
                            sessionMinutes: 45, raceDate: race(weeksOut: 8), runningExperience: .new, liftingExperience: .new,
                            raceDistanceM: 5_000, currentWeeklyVolumeM: 10_000, longestRunM: 4_000))
        describe("B. Half · 4 days · run + strength (no priority) · 12 wk · some · 30 km/wk",
                 PlanInputs(disciplines: [.running, .strength], goal: .raceDistance, daysPerWeek: 4, equipment: .fullGym,
                            sessionMinutes: 60, raceDate: race(weeksOut: 12), runningExperience: .some, liftingExperience: .some,
                            raceDistanceM: 21_097, currentWeeklyVolumeM: 30_000, longestRunM: 12_000))
        describe("C. Marathon · 5 days · run + strength · priority running · 16 wk · experienced · 50 km/wk",
                 PlanInputs(disciplines: [.running, .strength], goal: .raceDistance, daysPerWeek: 5, equipment: .fullGym,
                            sessionMinutes: 60, raceDate: race(weeksOut: 16), runningExperience: .experienced, liftingExperience: .some,
                            raceDistanceM: 42_195, currentWeeklyVolumeM: 50_000, longestRunM: 20_000, hybridPriority: .running))
        describe("D. Marathon · 6 days · run only · aggressive · 16 wk · experienced · 60 km/wk",
                 PlanInputs(disciplines: [.running], goal: .raceDistance, daysPerWeek: 6, equipment: .bodyweight,
                            sessionMinutes: 75, raceDate: race(weeksOut: 16), runningExperience: .experienced, liftingExperience: .new,
                            raceDistanceM: 42_195, currentWeeklyVolumeM: 60_000, longestRunM: 25_000, intensity: .aggressive))
        describe("E. Build running fitness · 4 days · run + strength (no priority) · no race · some · 20 km/wk",
                 PlanInputs(disciplines: [.running, .strength], goal: .generalFitness, daysPerWeek: 4, equipment: .dumbbellsOnly,
                            sessionMinutes: 45, raceDate: nil, runningExperience: .some, liftingExperience: .some,
                            currentWeeklyVolumeM: 20_000, longestRunM: 8_000))
        describe("F. Build muscle · 5 days · run + strength (no priority) · no race · some · 15 km/wk",
                 PlanInputs(disciplines: [.running, .strength], goal: .buildMuscle, daysPerWeek: 5, equipment: .fullGym,
                            sessionMinutes: 60, raceDate: nil, runningExperience: .some, liftingExperience: .some,
                            currentWeeklyVolumeM: 15_000, longestRunM: 6_000))
        describe("G. 10K · 5 days · run only · 10 wk · some · 35 km/wk",
                 PlanInputs(disciplines: [.running], goal: .raceDistance, daysPerWeek: 5, equipment: .bodyweight,
                            sessionMinutes: 60, raceDate: race(weeksOut: 10), runningExperience: .some, liftingExperience: .new,
                            raceDistanceM: 10_000, currentWeeklyVolumeM: 35_000, longestRunM: 14_000))
        describe("H. 50K · 6 days · run + strength · priority running · 20 wk · experienced · 70 km/wk",
                 PlanInputs(disciplines: [.running, .strength], goal: .raceDistance, daysPerWeek: 6, equipment: .fullGym,
                            sessionMinutes: 90, raceDate: race(weeksOut: 20), runningExperience: .experienced, liftingExperience: .some,
                            raceDistanceM: 50_000, currentWeeklyVolumeM: 70_000, longestRunM: 30_000, hybridPriority: .running))
    }

    /// The same half-marathon athlete as B, signed up on a WEDNESDAY: the week must still read as a
    /// coach's week on real weekdays, and day zero (Wednesday) opens with an easy run.
    @Test func printWednesdaySignup() {
        var inputs = PlanInputs(disciplines: [.running, .strength], goal: .raceDistance, daysPerWeek: 4, equipment: .fullGym,
                                sessionMinutes: 60, raceDate: race(weeksOut: 12), runningExperience: .some, liftingExperience: .some,
                                raceDistanceM: 21_097, currentWeeklyVolumeM: 30_000, longestRunM: 12_000)
        inputs.anchorWeekday = 4
        let plan = PlanEngine.generate(profile: inputs, catalog: RunningPlannerTestFixtures.catalog, startDate: start, calendar: cal)
        let names = ["Wed", "Thu", "Fri", "Sat", "Sun", "Mon", "Tue"]
        var out = ["===== WEDNESDAY SIGN-UP · Half · 4 days · run + strength"]
        for w in plan.weeks.prefix(3) {
            out.append(String(format: "W%02d %@ | %.1f km", w.index + 1, "\(w.phase)", w.runVolumeM / 1000))
            for s in w.sessions.sorted(by: { $0.dayOffset < $1.dayOffset }) {
                let what = s.discipline == .strength ? "LIFT \(s.strengthLabel ?? "")" : "\(s.runType.map { "\($0)" } ?? "run") \(Int((s.targetDistanceM ?? 0) / 100))00 m\(s.isHardRun ? " *" : "")"
                out.append("    d\(s.dayOffset) \(names[s.dayOffset])  \(what)  \(s.rationale ?? "")")
            }
        }
        out.append("===== WEDNESDAY SIGN-UP END")
        print(out.joined(separator: "\n"))
    }
}
