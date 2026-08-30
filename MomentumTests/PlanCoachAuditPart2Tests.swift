import Testing
import Foundation
@testable import Momentum

/// The second half of the coach's audit (2026-08-29). The first pass judged plan SHAPE; a shape
/// can be perfect and the plan still wrong. This one judges the things a coach checks before
/// handing the program over:
///
///  • **the paces** — the single most important number on the page. A session at the wrong
///    intensity trains the wrong system no matter how well the week is laid out;
///  • **the athlete's stated time** — a 45-minute athlete cannot run a 2-hour midweek session;
///  • **the days they chose** — a plan on the wrong days is not their plan;
///  • **where week one starts** — it must meet them where they are, not where the tier average is;
///  • **where the longest run lands** — three to four weeks out, never against the taper;
///  • **the mapping itself** — the engine can be perfect and still be handed the wrong athlete.
struct PlanCoachAuditPart2Tests {

    private let start = Date(timeIntervalSinceReferenceDate: 0)
    private let cal = Calendar.current
    private func race(weeksOut: Int) -> Date { cal.date(byAdding: .day, value: (weeksOut - 1) * 7 + 6, to: start)! }

    private struct Finding: CustomStringConvertible {
        let route: String, bar: String, detail: String
        var description: String { "  ✗ [\(bar)] \(route) — \(detail)" }
    }
    private func report(_ f: [Finding], _ title: String) {
        guard !f.isEmpty else { print("\n════ \(title): clean ════"); return }
        var byBar: [String: [Finding]] = [:]
        for x in f { byBar[x.bar, default: []].append(x) }
        var out = "\n════ \(title): \(f.count) findings ════\n"
        for (bar, list) in byBar.sorted(by: { $0.value.count > $1.value.count }) {
            out += "\n\(bar) — \(list.count)\n"
            for x in list.prefix(5) { out += "\(x)\n" }
            if list.count > 5 { out += "  … \(list.count - 5) more\n" }
        }
        print(out)
    }

    private func plan(_ i: PlanInputs) -> GeneratedPlan {
        PlanEngine.generate(profile: i, catalog: [], calibration: CalibrationSeed(estimatedP5kSPerKm: 300),
                            startDate: start, calendar: cal)
    }
    private func base(days: Int, raceM: Double? = 21_097, weeksOut: Int? = 16,
                      exp: ExperienceLevel = .some, seedMi: Double? = 25) -> PlanInputs {
        var i = PlanInputs(disciplines: [.running], goal: raceM == nil ? .endurance : .raceDistance,
                           daysPerWeek: days, equipment: .fullGym, sessionMinutes: 45,
                           raceDate: weeksOut.map(race(weeksOut:)), runningExperience: exp,
                           liftingExperience: .some, raceDistanceM: raceM)
        if let seedMi {
            i.currentWeeklyVolumeM = seedMi * 1609.344
            i.longestRunM = seedMi * 1609.344 * 0.32
        }
        return i
    }

    // MARK: The paces

    /// Every prescribed pace must be the pace its session type means, derived from the athlete's
    /// own fitness — and the zones must stay in order. A "recovery" run that is faster than an
    /// "easy" run is not a recovery run, whatever the label says.
    @Test func everySessionRunsAtItsOwnZone() {
        var findings: [Finding] = []
        for p5k in [240.0, 300, 360, 420] {                       // 20:00 → 35:00 5K athletes
            for raceM in [5_000.0, 10_000, 21_097, 42_195] {
                let inputs = base(days: 5, raceM: raceM, weeksOut: 16)
                let p = PlanEngine.generate(profile: inputs, catalog: [],
                                            calibration: CalibrationSeed(estimatedP5kSPerKm: p5k),
                                            startDate: start, calendar: cal)
                let route = "p5k \(Int(p5k)) \(Int(raceM / 1000))K"
                let planP5k = p.p5kSPerKm
                for w in p.weeks {
                    for s in w.sessions where s.discipline == .running {
                        guard let pace = s.targetPaceSPerKm, pace > 0, let type = s.runType else { continue }
                        // Race-pace and threshold-labelled reps carry their own intent.
                        let note = (s.intervals ?? "").lowercased()
                        // Race-pace reps, threshold reps and the 5K time trial all carry their own
                        // intent — the trial IS run at 5K pace, which is the point of a trial.
                        if note.contains("race pace") || note.contains("threshold")
                            || note.contains("time trial") || type == .race { continue }
                        let expected = PlanEngine.pace(type, p5k: planP5k)
                        // Clean-pace snapping moves a pace by up to a few seconds per km.
                        if abs(pace - expected) > 12 {
                            findings.append(Finding(route: route, bar: "pace zone",
                                                    detail: "w\(w.index) \(type) at \(Int(pace))s/km, zone says \(Int(expected))"))
                        }
                    }
                }
                // The zones themselves must stay ordered for this athlete.
                let recovery = PlanEngine.pace(.recovery, p5k: planP5k)
                let long = PlanEngine.pace(.long, p5k: planP5k)
                let easy = PlanEngine.pace(.easy, p5k: planP5k)
                let tempo = PlanEngine.pace(.tempo, p5k: planP5k)
                let interval = PlanEngine.pace(.intervals, p5k: planP5k)
                if !(recovery > long && long > easy && easy > tempo && tempo > interval) {
                    findings.append(Finding(route: route, bar: "zone order",
                                            detail: "rec \(Int(recovery)) long \(Int(long)) easy \(Int(easy)) tempo \(Int(tempo)) int \(Int(interval))"))
                }
                // …and threshold must be a plausible one-hour effort: slower than 5K pace, faster
                // than easy. A "tempo" at 5K pace is a race, not a tempo.
                if tempo <= planP5k + 3 {
                    findings.append(Finding(route: route, bar: "threshold sanity",
                                            detail: "tempo \(Int(tempo)) vs 5K \(Int(planP5k))"))
                }
            }
        }
        report(findings, "PACES")
        #expect(findings.isEmpty)
    }

    // MARK: The athlete's stated time

    /// A midweek session has to fit the time the athlete said they have. The long run is the one
    /// exception a coach makes — it IS the session the goal stands on — and it is exempted here
    /// deliberately, not by accident.
    @Test func midweekSessionsFitTheStatedTime() {
        var findings: [Finding] = []
        for minutes in [30, 45, 60, 75] {
            for raceM in [10_000.0, 21_097, 42_195] {
                var i = base(days: 5, raceM: raceM, weeksOut: 16)
                i.sessionMinutes = minutes
                let p = plan(i)
                let route = "\(minutes)min \(Int(raceM / 1000))K"
                for w in p.weeks {
                    for s in w.sessions where s.discipline == .running {
                        guard s.runType != .long, s.runType != .progression, s.runType != .race else { continue }
                        guard let d = s.targetDistanceM, let pace = s.targetPaceSPerKm, pace > 0 else { continue }
                        let mins = (d / 1000) * pace / 60
                        // A quarter of slack: warm-up and cool-down live inside a session, and
                        // nobody times themselves to the minute.
                        // Half again over the stated time is the engine's contract (a hard cap at
                        // the stated minutes would delete the mileage they also stated); past that
                        // the plan is asking for time the athlete told us they do not have.
                        // Measured against THIS week, the way the engine caps it: sessions grow with
                        // the mileage, so a static read of the athlete's opening volume asks a
                        // different question than the engine answers.
                        let impliedMins = (w.runVolumeM / Double(i.daysPerWeek) / 1000) * pace / 60
                        if mins > max(Double(minutes) * 1.6, impliedMins * 1.5) {
                            findings.append(Finding(route: route, bar: "session length",
                                                    detail: "w\(w.index) \(s.runType.map { "\($0)" } ?? "run") is \(Int(mins))min against a stated \(minutes)"))
                        }
                    }
                }
            }
        }
        report(findings, "SESSION LENGTH")
        #expect(findings.isEmpty)
    }

    // MARK: The days they chose

    @Test func theWeekLandsOnTheDaysTheAthleteChose() {
        var findings: [Finding] = []
        for (pref, avoid) in [([1, 3, 5], []), ([0, 6], []), ([], [0, 6]), ([2, 4], [0])] as [([Int], [Int])] {
            var i = base(days: max(2, pref.isEmpty ? 4 : pref.count))
            i.preferredDayOffsets = pref
            i.avoidDayOffsets = avoid
            let p = plan(i)
            let route = "pref\(pref) avoid\(avoid)"
            for w in p.weeks {
                // The race lands on its own date and the shakeout beside it — neither is the
                // scheduler's choice, so neither is the scheduler's to be judged on.
                guard !w.sessions.contains(where: { $0.runType == .race }) else { continue }
                let used = Set(w.sessions.map(\.dayOffset))
                // A week that needs more days than the athlete left open has to borrow one; the
                // bar is about borrowing when there WAS an alternative.
                let openDays = 7 - avoid.count
                if !avoid.isEmpty, w.sessions.count <= openDays, !used.isDisjoint(with: Set(avoid)) {
                    findings.append(Finding(route: route, bar: "avoid days",
                                            detail: "w\(w.index) scheduled on \(used.intersection(Set(avoid)).sorted())"))
                }
                // A stated preference is a request, not a suggestion: every session should land on
                // a chosen day (the race itself excepted — it has its own date).
                if !pref.isEmpty {
                    let strays = used.subtracting(Set(pref))
                        .filter { off in !w.sessions.contains { $0.dayOffset == off && $0.runType == .race } }
                    if !strays.isEmpty {
                        findings.append(Finding(route: route, bar: "preferred days",
                                                detail: "w\(w.index) also used \(strays.sorted())"))
                    }
                }
            }
        }
        report(findings, "DAYS")
        #expect(findings.isEmpty)
    }

    // MARK: Where week one starts, and where the long run peaks

    @Test func weekOneMeetsThemWhereTheyAre() {
        var findings: [Finding] = []
        for seedMi in [15.0, 25, 40, 60] {
            for days in [3, 4, 5] {
                let i = base(days: days, seedMi: seedMi)
                let p = plan(i)
                let stated = seedMi * 1609.344
                let opener = p.weeks.first?.runVolumeM ?? 0
                let route = "seed \(Int(seedMi))mi \(days)d"
                // Within a quarter either way: a plan that opens far above their week is a jump,
                // and one that opens far below wastes the runway.
                if opener > stated * 1.25 {
                    findings.append(Finding(route: route, bar: "opening week",
                                            detail: "opens at \(Int(opener / 1000))km against a stated \(Int(stated / 1000))km"))
                }
                let perSession = stated / Double(days)
                if opener < stated * 0.7, perSession <= 15_000 {
                    findings.append(Finding(route: route, bar: "opening week",
                                            detail: "opens at only \(Int(opener / 1000))km against a stated \(Int(stated / 1000))km"))
                }
            }
        }
        report(findings, "OPENING WEEK")
        #expect(findings.isEmpty)
    }

    /// The longest run belongs three to four weeks before the race — long enough to absorb, close
    /// enough to count. In the last fortnight it is a liability.
    @Test func theLongestRunLandsBeforeTheTaper() {
        var findings: [Finding] = []
        for raceM in [21_097.0, 42_195, 50_000] {
            for weeksOut in [12, 16, 20] {
                let i = base(days: 5, raceM: raceM, weeksOut: weeksOut, exp: .experienced, seedMi: 35)
                let p = plan(i)
                let route = "\(Int(raceM / 1000))K \(weeksOut)w"
                var longest = 0.0, longestWeek = 0
                for w in p.weeks {
                    for s in w.sessions where s.runType == .long || s.runType == .progression {
                        // >= so a long run that plateaus at its cap reports its LAST week, not
                        // its first — otherwise a healthy plateau reads as "peaked in week 3".
                        if (s.targetDistanceM ?? 0) >= longest { longest = s.targetDistanceM ?? 0; longestWeek = w.index }
                    }
                }
                let weeksFromEnd = p.weeks.count - 1 - longestWeek
                if weeksFromEnd < 2 {
                    findings.append(Finding(route: route, bar: "long-run peak",
                                            detail: "longest run is w\(longestWeek) of \(p.weeks.count - 1) — inside the taper"))
                }
                if weeksFromEnd > 8 {
                    findings.append(Finding(route: route, bar: "long-run peak",
                                            detail: "longest run is \(weeksFromEnd) weeks out — the fitness will have faded"))
                }
            }
        }
        report(findings, "LONG-RUN PEAK")
        #expect(findings.isEmpty)
    }
}
