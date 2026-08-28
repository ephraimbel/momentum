import Testing
import Foundation
@testable import Momentum

/// The volume audit (2026-08-28): prints a race × experience × intensity matrix of generated plans
/// in MILES, week by week, so the "plans cap at 15-17 mpw" class of complaint is judged on the
/// engine's actual output. The assertions are the floors a plan must clear to be worth the name;
/// the printout is the coach's eyeball review.
struct PlanVolumeMatrixTests {

    private let start = Date(timeIntervalSinceReferenceDate: 0)
    private let cal = Calendar.current
    private func race(weeksOut: Int) -> Date { cal.date(byAdding: .day, value: (weeksOut - 1) * 7 + 6, to: start)! }

    private struct Row { let label: String; let peakMi: Double; let longMi: Double; let firstMi: Double; let weeks: [Double] }

    private func run(_ label: String, raceM: Double, weeksOut: Int, level: ExperienceLevel, intensity: PlanIntensity,
                     days: Int, startMi: Double, longestMi: Double) -> Row {
        let inputs = PlanInputs(disciplines: [.running], goal: .raceDistance, daysPerWeek: days,
                                equipment: .fullGym, sessionMinutes: 60,
                                raceDate: race(weeksOut: weeksOut), runningExperience: level,
                                liftingExperience: .some, raceDistanceM: raceM,
                                currentWeeklyVolumeM: startMi * 1609.344, longestRunM: longestMi * 1609.344,
                                intensity: intensity, distanceUnit: .imperial)
        let plan = PlanEngine.generate(profile: inputs, catalog: [], startDate: start, calendar: cal)
        let mi = 1609.344
        var weeksMi: [Double] = []
        var peakM = 0.0
        var longM = 0.0
        for w in plan.weeks {
            weeksMi.append(w.runVolumeM / mi)
            if !w.isTaper { peakM = max(peakM, w.runVolumeM) }
            for s in w.sessions where s.runType == .long || s.runType == .progression {
                longM = max(longM, s.targetDistanceM ?? 0)
            }
        }
        return Row(label: label, peakMi: peakM / mi, longMi: longM / mi, firstMi: weeksMi.first ?? 0, weeks: weeksMi)
    }

    @Test func printTheMatrixAndPinTheFloors() {
        var rows: [Row] = []
        // The complaint's shape: a real runner (already on ~20 mpw) training for each distance,
        // 5-6 days, at each of the three serious tiers, with a realistic runway.
        let cases: [(String, Double, Int, Double, Double)] = [
            ("5K       12w", 5_000, 12, 20, 6),
            ("10K      12w", 10_000, 12, 20, 7),
            ("Half     14w", 21_097, 14, 20, 8),
            ("Marathon 18w", 42_195, 18, 25, 10),
        ]
        for (name, raceM, weeks, startMi, longMi) in cases {
            for level in [ExperienceLevel.some, .experienced] {
                for tier in [PlanIntensity.balanced, .aggressive, .podium] {
                    let days = tier == .podium ? 6 : 5
                    rows.append(run("\(name) \(level == .some ? "some" : "exp ") \(tier.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(days)d",
                                    raceM: raceM, weeksOut: weeks, level: level, intensity: tier,
                                    days: days, startMi: startMi, longestMi: longMi))
                }
            }
        }
        var out = "\n════ PLAN VOLUME MATRIX (miles/week; start → peak, long-run peak) ════\n"
        for r in rows {
            let path = r.weeks.map { String(format: "%2.0f", $0) }.joined(separator: " ")
            out += String(format: "%@  start %4.1f → peak %4.1f  long %4.1f | %@\n", r.label, r.firstMi, r.peakMi, r.longMi, path)
        }
        print(out)

        // Floors a serious plan must clear (mpw). These are deliberately BELOW what a good plan
        // reaches — they exist to catch a plan that never leaves the athlete's starting volume.
        func floor(_ label: String) -> Double {
            if label.hasPrefix("Marathon") { return label.contains("podium") ? 50 : label.contains("aggressive") ? 42 : 38 }
            if label.hasPrefix("Half")     { return label.contains("podium") ? 40 : label.contains("aggressive") ? 34 : 30 }
            if label.hasPrefix("10K")      { return label.contains("podium") ? 34 : label.contains("aggressive") ? 28 : 25 }
            return label.contains("podium") ? 30 : label.contains("aggressive") ? 26 : 22   // 5K
        }
        for r in rows {
            #expect(r.peakMi >= floor(r.label), "\(r.label): peak \(Int(r.peakMi)) mpw is under the \(Int(floor(r.label))) mpw floor")
        }
    }

    /// A goal is a load, not a wish: the same 25 mpw runner asking for a sub-3 marathon is built
    /// toward sub-3 mileage; asking for 4:30 leaves the table's peak alone. And the athlete's own
    /// ceiling wins over both, with the feasibility read saying what the cap costs.
    @Test func goalTimeSetsTheFloorAndTheAthletesCeilingWins() {
        let mi = 1609.344
        func peakMi(goalS: Double?, cap: Double? = nil, tier: PlanIntensity = .aggressive) -> Double {
            var inputs = PlanInputs(disciplines: [.running], goal: .raceDistance, daysPerWeek: 6,
                                    equipment: .fullGym, sessionMinutes: 60,
                                    raceDate: race(weeksOut: 20), runningExperience: .some,
                                    liftingExperience: .some, raceDistanceM: 42_195,
                                    currentWeeklyVolumeM: 25 * mi, longestRunM: 10 * mi, intensity: tier)
            inputs.goalFinishTimeS = goalS
            inputs.targetWeeklyVolumeM = cap
            let plan = PlanEngine.generate(profile: inputs, catalog: [], startDate: start, calendar: cal)
            return (plan.weeks.filter { !$0.isTaper }.map(\.runVolumeM).max() ?? 0) / mi
        }
        let easy = peakMi(goalS: 4.5 * 3600), sub3 = peakMi(goalS: 3 * 3600)
        #expect(sub3 >= 60, "sub-3 marathon peaked at \(Int(sub3)) mpw")
        #expect(sub3 > easy + 5, "the goal time moved nothing: \(Int(easy)) vs \(Int(sub3))")
        // The athlete caps at 40 mpw: the plan holds there (snapping slack), even for sub-3.
        let capped = peakMi(goalS: 3 * 3600, cap: 40 * mi)
        #expect(capped <= 40 * 1.05 && capped >= 36, "cap not honored: \(capped)")
        // …and the verdict names the shortfall in meters the UI can phrase.
        let f = PlanFeasibility.assess(raceDistanceM: 42_195, goalFinishTimeS: 3 * 3600, currentP5kSPerKm: 270,
                                       currentWeeklyVolumeM: 25 * mi, weeksAvailable: 20, experience: .some,
                                       daysPerWeek: 6, intensity: .aggressive, targetWeeklyVolumeM: 40 * mi)
        #expect((f.weeklyCapShortfallM ?? 0) > 40 * mi)
        let roomy = PlanFeasibility.assess(raceDistanceM: 42_195, goalFinishTimeS: 4.5 * 3600, currentP5kSPerKm: 330,
                                           currentWeeklyVolumeM: 25 * mi, weeksAvailable: 20, experience: .some,
                                           daysPerWeek: 5, intensity: .balanced, targetWeeklyVolumeM: 60 * mi)
        #expect(roomy.weeklyCapShortfallM == nil)
    }

    /// The race has a date: a short runway steepens the ramp (to a 15%/wk ceiling) instead of
    /// leaving the athlete short of the peak. Injury history keeps the gentle ramp.
    @Test func shortRunwayFitsTheRampInsteadOfShrinkingTheGoal() {
        let mi = 1609.344
        func peakMi(weeks: Int, injured: Bool = false) -> (peak: Double, maxStep: Double) {
            var inputs = PlanInputs(disciplines: [.running], goal: .raceDistance, daysPerWeek: 5,
                                    equipment: .fullGym, sessionMinutes: 60,
                                    raceDate: race(weeksOut: weeks), runningExperience: .some,
                                    liftingExperience: .some, raceDistanceM: 42_195,
                                    currentWeeklyVolumeM: 25 * mi, longestRunM: 10 * mi, intensity: .aggressive)
            inputs.goalFinishTimeS = 3.5 * 3600
            if injured { inputs.injuryHistory = [.knee] }
            let plan = PlanEngine.generate(profile: inputs, catalog: [], startDate: start, calendar: cal)
            let build = plan.weeks.filter { !$0.isTaper && !$0.isDeload }
            var maxStep = 1.0
            for (a, b) in zip(build, build.dropFirst()) where a.runVolumeM > 0 {
                maxStep = max(maxStep, b.runVolumeM / a.runVolumeM)
            }
            return ((build.map(\.runVolumeM).max() ?? 0) / mi, maxStep)
        }
        let long = peakMi(weeks: 20), short = peakMi(weeks: 12)
        // 0.85: the 15%/wk ceiling and the deload cadence are physiology, not a bug.
        #expect(short.peak >= long.peak * 0.85, "12 weeks peaked at \(Int(short.peak)) vs \(Int(long.peak)) with 20")
        #expect(short.maxStep <= 1.33, "a build step of \(short.maxStep)× is past the governor")
        let hurt = peakMi(weeks: 12, injured: true)
        #expect(hurt.peak < short.peak, "injury history should not be rushed to the same peak")
    }

    /// Train to the TIME: goal-pace sessions are set at the goal (honesty-capped), approached from
    /// today's fitness week by week, and the specific block carries a growing dose of it.
    @Test func goalPaceSessionsApproachAndHoldTheGoal() {
        let mi = 1609.344
        var inputs = PlanInputs(disciplines: [.running], goal: .raceDistance, daysPerWeek: 5,
                                equipment: .fullGym, sessionMinutes: 60,
                                raceDate: race(weeksOut: 18), runningExperience: .some,
                                liftingExperience: .some, raceDistanceM: 42_195,
                                currentWeeklyVolumeM: 30 * mi, longestRunM: 12 * mi, intensity: .aggressive)
        inputs.goalFinishTimeS = 3.75 * 3600                       // 3:45 → 320 s/km
        // A 27:30 5K runner today: the marathon prediction is well slower than 3:45.
        let plan = PlanEngine.generate(profile: inputs, catalog: [], calibration: CalibrationSeed(estimatedP5kSPerKm: 330),
                                       startDate: start, calendar: cal)
        let predicted = DanielsPaces.racePaceSPerKm(distanceM: 42_195, p5kSPerKm: 330) ?? 0
        let goal = plan.goalRacePaceSPerKm ?? 0
        #expect(goal > 0 && goal < predicted, "goal pace \(goal) should be faster than predicted \(predicted)")
        #expect(goal >= 320 - 0.5, "the goal pace is never faster than the goal itself")
        let racePaceSessions = plan.weeks.flatMap(\.sessions).filter {
            $0.runType == .intervals && ($0.intervals?.contains("race pace") ?? false)
        }
        #expect(racePaceSessions.count >= 4, "the specific block should carry several goal-pace sessions")
        let paces = racePaceSessions.compactMap(\.targetPaceSPerKm)
        // Approached, then held: the last goal-pace session sits at the goal (snapping slack), the
        // first sits no faster than it, and nothing is ever faster than the goal.
        #expect(abs((paces.last ?? 0) - goal) <= 6, "last goal-pace session \(paces.last ?? 0) vs goal \(goal)")
        #expect((paces.first ?? 0) >= (paces.last ?? 0) - 0.5)
        #expect(paces.allSatisfy { $0 >= goal - 6 })
        // The dose grows: the last session's total goal-pace meters exceed the first's.
        let doses = racePaceSessions.compactMap { $0.intervals.map { PlanEngine.goalPaceDoseM(String($0.split(separator: "@")[0]).trimmingCharacters(in: .whitespaces)) } }
        #expect((doses.max() ?? 0) > (doses.first ?? 0), "the goal-pace dose never grew: \(doses)")
        // The coach's card: one line per week for eyeball review.
        var card = "\n════ GOAL 3:45 marathon · 27:30 5K today · 18w aggressive (paces s/km; goal \(Int(goal)), predicted \(Int(predicted))) ════\n"
        for w in plan.weeks {
            let km = w.runVolumeM / 1000
            let long = w.sessions.filter { $0.runType == .long || $0.runType == .progression }.first
            let q = w.sessions.filter { $0.isHardRun && $0.runType != .long && $0.runType != .race }
            let qs = q.map { "\($0.intervals ?? $0.runType.map { "\($0)" } ?? "?") @\(Int($0.targetPaceSPerKm ?? 0))" }.joined(separator: " · ")
            card += String(format: "w%02d %-8@ %5.1fkm  long %4.1f %@ | %@\n", w.index, "\(w.phase)", km,
                           (long?.targetDistanceM ?? 0) / 1000, long?.intervals ?? "", qs)
        }
        print(card)
        // And the marathon long runs finish at goal pace with a real block (≥ 8 km) late in the build.
        let finishes = plan.weeks.flatMap(\.sessions).compactMap { StructuredWorkoutBuilder.parseRaceFinish($0.intervals) }
        #expect((finishes.max() ?? 0) >= 8_000, "biggest goal-pace finish was \(finishes.max() ?? 0) m")
        // Race day itself is set at the goal pace.
        let raceDay = plan.weeks.flatMap(\.sessions).first { $0.runType == .race }
        #expect(abs((raceDay?.targetPaceSPerKm ?? 0) - goal) <= 6)
    }
}
