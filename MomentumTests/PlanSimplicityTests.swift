import Testing
import Foundation
@testable import Momentum

/// The plan's vocabulary (owner call 2026-08-28): a plan is a SIMPLE thing to follow — easy runs,
/// a long run, steady runs, and plain repeats that grow. Fartleks, hill reps, strides and track
/// jargon live in the WORKOUT LIBRARY for athletes who go looking for them; an auto-generated plan
/// never prescribes them and never says them. This is the tripwire.
struct PlanSimplicityTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)
    private let cal = Calendar.current
    private func race(weeksOut: Int) -> Date { cal.date(byAdding: .day, value: (weeksOut - 1) * 7 + 6, to: start)! }

    private func plan(_ raceM: Double?, weeks: Int, level: ExperienceLevel, tier: PlanIntensity,
                      days: Int, injuries: [InjuryArea] = []) -> GeneratedPlan {
        var inputs = PlanInputs(disciplines: [.running], goal: raceM == nil ? .endurance : .raceDistance,
                                daysPerWeek: days, equipment: .fullGym, sessionMinutes: 60,
                                raceDate: raceM == nil ? nil : race(weeksOut: weeks),
                                runningExperience: level, liftingExperience: .some,
                                raceDistanceM: raceM, currentWeeklyVolumeM: 40_000,
                                longestRunM: 14_000, intensity: tier)
        inputs.injuryHistory = injuries
        return PlanEngine.generate(profile: inputs, catalog: [], startDate: start, calendar: cal)
    }

    /// Every plan we can generate, checked against the banned vocabulary.
    @Test func noPlanEverPrescribesLibraryJargon() {
        let banned = ["fartlek", "surge", "float", "hill", "stride", "vo2", "vo₂"]
        for raceM in [nil, 5_000.0, 10_000.0, 21_097.0, 42_195.0] as [Double?] {
            for level in [ExperienceLevel.new, .some, .experienced] {
                for tier in [PlanIntensity.gentle, .balanced, .aggressive, .podium] {
                    for days in [3, 5, 6] {
                        let p = plan(raceM, weeks: 16, level: level, tier: tier, days: days)
                        let label = "\(raceM.map { Int($0) } ?? 0)m \(level) \(tier.rawValue) \(days)d"
                        for s in p.weeks.flatMap(\.sessions) where s.discipline == .running {
                            #expect(s.runType != .fartlek, "\(label): a plan prescribed a fartlek")
                            #expect(s.runType != .hills, "\(label): a plan prescribed hill reps")
                            #expect(s.runType != .strides, "\(label): a plan prescribed strides")
                            let words = "\((s.intervals ?? "")) \((s.rationale ?? ""))".lowercased()
                            for term in banned {
                                #expect(!words.contains(term), "\(label): plan says \"\(term)\" — \(words)")
                            }
                        }
                    }
                }
            }
        }
    }

    /// What a plan DOES prescribe: easy running, a long run, and — for anyone past beginner —
    /// steady runs and repeats that grow across the block.
    @Test func plansAreEasyVolumePlusTwoPlainHardSessions() {
        let p = plan(21_097, weeks: 16, level: .some, tier: .balanced, days: 5)
        let runs = p.weeks.flatMap(\.sessions).filter { $0.discipline == .running }
        let types = Set(runs.compactMap(\.runType))
        #expect(types.contains(.easy) && types.contains(.long))
        #expect(types.isSubset(of: [.easy, .long, .recovery, .tempo, .intervals, .progression, .race]),
                "unexpected session types: \(types)")
        // Every hard session says, in plain words, what it should feel like.
        for s in runs where s.isHardRun {
            #expect(!(s.rationale ?? "").isEmpty, "a hard session with no explanation")
        }
        // A beginner's plan is simpler still: no repeats at all.
        let beginner = plan(5_000, weeks: 12, level: .new, tier: .balanced, days: 3)
        let bTypes = Set(beginner.weeks.flatMap(\.sessions).filter { $0.discipline == .running }.compactMap(\.runType))
        #expect(!bTypes.contains(.intervals), "a beginner plan prescribed repeats: \(bTypes)")
    }

    /// The tier is the dial: how hard, how often, how much — never a different vocabulary.
    @Test func tiersDifferInDoseNotInJargon() {
        func hardDays(_ tier: PlanIntensity) -> Int {
            plan(21_097, weeks: 16, level: .experienced, tier: tier, days: tier == .podium ? 6 : 5)
                .weeks.filter { !$0.isDeload && !$0.isTaper }
                .map { $0.sessions.filter(\.isHardRun).count }.max() ?? 0
        }
        #expect(hardDays(.gentle) <= hardDays(.balanced))
        #expect(hardDays(.podium) >= hardDays(.balanced))
        #expect(hardDays(.gentle) >= 1)                  // every tier still trains quality
    }

    /// Sessions carry round, followable numbers — never "7×1.37km".
    @Test func repeatsAreRoundNumbers() {
        let p = plan(10_000, weeks: 14, level: .experienced, tier: .aggressive, days: 6)
        for s in p.weeks.flatMap(\.sessions) where s.runType == .intervals {
            guard let iv = s.intervals else { continue }
            if let d = StructuredWorkoutBuilder.parseIntervals(iv) {
                #expect(d.reps >= 2 && d.reps <= 10, "\(iv): odd rep count")
                #expect([200.0, 400, 600, 800, 1_000, 1_200, 1_600, 2_000, 3_000, 4_000, 5_000, 6_000, 8_000]
                            .contains(d.distanceM), "\(iv): not a round rep distance")
            } else if let t = StructuredWorkoutBuilder.parseTimeReps(iv) {
                #expect(t.reps >= 2 && t.reps <= 10, "\(iv): odd rep count")
                #expect(t.seconds.truncatingRemainder(dividingBy: 60) == 0, "\(iv): not a round number of minutes")
            }
        }
    }

    /// The coach's card: exactly what the athlete reads, week by week. Printed for review.
    @Test func printWhatTheAthleteReads() {
        for (name, raceM, tier) in [("HALF · balanced", 21_097.0, PlanIntensity.balanced),
                                    ("5K · podium", 5_000.0, PlanIntensity.podium)] {
            let p = plan(raceM, weeks: 14, level: .some, tier: tier, days: tier == .podium ? 6 : 5)
            var out = "\n════ \(name) — what the athlete reads ════\n"
            for w in p.weeks.prefix(12) {
                let lines = w.sessions.filter { $0.discipline == .running }.map { s -> String in
                    let title = s.runType?.planTitle ?? "Run"
                    let dist = (s.targetDistanceM ?? 0) / 1000
                    let shape = s.intervals.map { " (\($0))" } ?? ""
                    return String(format: "%@ %.1fkm%@", title, dist, shape)
                }
                out += "w\(String(format: "%02d", w.index)) \(w.phase): " + lines.joined(separator: " · ") + "\n"
            }
            print(out)
        }
    }
}
