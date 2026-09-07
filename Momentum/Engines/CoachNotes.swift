import Foundation

/// The coach's words on a session and on a week. Deterministic (no model), so every line is
/// testable and the register never drifts; unit free, because the brief above the note already
/// carries the distance and the pace and a coach does not read the number back at you; and written
/// as a coach talks: short sentences, one idea each, the feel of the run, why it is in the week,
/// and at most one thing to actually do.
///
/// Before this, every session of a given type carried the same sentence for the life of the plan
/// ("Long run. Steady and unhurried." in week 1 and in week 14, for a 5K novice and a marathoner).
/// A plan that never says anything specific reads as a spreadsheet, which is exactly the day one
/// judgement a trialist makes. These notes know the week's phase, how big the session is within
/// the week, what it sits next to, how the long run compares with last week's, and how far the
/// race is. Nothing here is a number the athlete has to convert; nothing here is praise.
///
/// Voice rules (pinned by `CoachVoiceTests` and `CoachNotesTests`): no dash of any kind, no
/// exclamation marks, no filler, no conclusion hung off a comma. Variation comes from a seed per
/// session, so the same run type does not repeat itself week to week, and the same session always
/// gets the same words (the note is persisted at generation and must be stable).
enum CoachNotes {

    /// What the notes know about the week the session belongs to. Built by `annotate` from the
    /// FINAL generated week, after every volume pass, so a share of the week is a true share.
    struct Week: Sendable, Equatable {
        var index: Int                 // 0 based within the block
        var total: Int
        var phase: PlanPhase
        var isDeload: Bool
        var isTaper: Bool
        var runDays: Int
        var runVolumeM: Double
        var longRunDay: Int?
        var hardRunDay: Int?
        var previousLongRunM: Double?
        var weeksToRace: Int?
        var raceDistanceM: Double?
        var liftDays: Int
        /// The day of the block's checkpoint time trial, when this week carries one.
        var checkpointDay: Int? = nil
    }

    // MARK: - The note on a session

    static func session(_ s: GeneratedSession, week: Week) -> String {
        let seed = week.index * 7 + max(0, s.dayOffset)
        switch s.discipline {
        case .strength: return strength(s, week: week, seed: seed)
        case .running:  return run(s, week: week, seed: seed)
        case .walking, .cycling: return otherCardio(s, week: week, seed: seed)
        }
    }

    private static func run(_ s: GeneratedSession, week: Week, seed: Int) -> String {
        let type = s.runType ?? .easy
        var lines: [String] = []
        switch type {
        case .easy, .freeRun:
            lines.append(pick(easyFeel, seed))
            lines.append(easyWhy(s, week: week, seed: seed))
        case .recovery:
            lines.append(pick(["Slow on purpose. This is the easiest run of your week.",
                               "Slower than easy. If it feels too slow, it is right."], seed))
            lines.append(week.hardRunDay.map { $0 == s.dayOffset - 1 }
                         == true ? "Its only job is to help you recover from yesterday."
                                 : "Its only job is to help you recover, not to add fitness.")
        case .long:
            lines.append(pick(longFeel, seed))
            lines.append(longWhy(s, week: week, seed: seed))
            if let cue = longCue(s, week: week, seed: seed) { lines.append(cue) }
        case .tempo:
            lines.append(pick(["Comfortably hard. You could say a few words but not hold a conversation.",
                               "Controlled from start to finish. End it knowing you had a little left.",
                               "Steady means steady. Settle into the effort and hold it."], seed))
            lines.append(pick(["This is the pace you could hold for about an hour. It teaches your body to clear fatigue faster.",
                               "The steady days are where race fitness is made. One of them a week is enough.",
                               "Ten easy minutes first, then settle into it. The last third should feel like work."], seed))
        case .intervals:
            lines.append(pick(["Quick but controlled. The last rep should feel like the first.",
                               "Run the reps at the target and jog the recoveries slower than feels natural.",
                               "Hit the pace, then let the recovery be a real recovery."], seed))
            lines.append(intervalsWhy(week: week, seed: seed))
            lines.append("If the reps fall apart, call it there. Quality over quantity.")
        case .progression:
            lines.append(pick(["Start easy and finish a little quicker. Never a sprint.",
                               "The first half is a warm up. Let the pace come to you in the second."], seed))
            lines.append("It teaches you to hold pace on tired legs, which is what a race asks of you.")
        case .fartlek:
            lines.append("Easy running with a few quicker stretches whenever you feel like it.")
            lines.append("Play with the pace. Nothing here is measured.")
        case .hills:
            lines.append("Strong and controlled going up, easy coming down.")
            lines.append("Strength for your legs without the pounding of flat speed.")
        case .strides:
            lines.append("A few relaxed pick ups to wake the legs up.")
            lines.append("Quick feet and tall posture. No straining.")
        case .race:
            lines.append("Race day. Everything pointed here.")
            lines.append("Trust the taper and run your plan.")
        }
        return join(lines)
    }

    // MARK: Easy

    private static let easyFeel = [
        "Conversational the whole way. If you could not chat, it is too quick.",
        "Relaxed and unhurried. The pace should feel almost too easy.",
        "Easy means easy. Finish feeling like you could go again.",
        "Keep it gentle. Easy days only work when they stay easy.",
    ]

    private static func easyWhy(_ s: GeneratedSession, week: Week, seed: Int) -> String {
        if week.index == 0 {
            return "Your first week is about showing up, not proving anything."
        }
        if let test = week.checkpointDay, test == s.dayOffset + 1 {
            return "Keep it truly easy. The checkpoint is tomorrow, and fresh legs are the point."
        }
        if let test = week.checkpointDay, test == s.dayOffset - 1 {
            return "Easy after yesterday's checkpoint. Let the work soak in."
        }
        if let hard = week.hardRunDay, hard == s.dayOffset + 1 {
            return "It keeps your legs fresh for tomorrow's \(hardNoun(week))."
        }
        if let hard = week.hardRunDay, hard == s.dayOffset - 1 {
            return "Yesterday was the hard day. Today is where that work sinks in."
        }
        if let long = week.longRunDay, long == s.dayOffset + 1 {
            return "It keeps you fresh for the long run tomorrow."
        }
        if let long = week.longRunDay, long == s.dayOffset - 1 {
            return "The day after a long run should feel slow, and that is right."
        }
        if week.isDeload || week.phase == .recovery {
            return "Cutback week. The point is to absorb the last few weeks, not add to them."
        }
        if week.isTaper || week.phase == .taper {
            return "Nothing to gain by pushing in the taper. Fresh legs win."
        }
        if let share = shareWords(s, week: week), seed % 2 == 0 {
            return "\(share) of this week's running."
        }
        switch week.phase {
        case .base:     return pick(["Base weeks are made of runs like this one.",
                                     "The aerobic base you build now carries everything later."], seed)
        case .build:    return pick(["The easy days are what let the hard days count.",
                                     "Volume is climbing. The easy runs are where it settles in."], seed)
        case .peak:     return "Sharpening now. Keep the easy days honest and easy."
        case .taper:    return "Nothing to gain by pushing in the taper. Fresh legs win."
        case .recovery: return "Cutback week. The point is to absorb the last few weeks, not add to them."
        }
    }

    // MARK: Long

    private static let longFeel = [
        "Steady from the first step to the last. Settle in and let the distance do the work.",
        "Start slower than feels necessary. The last third is where the run is.",
        "Unhurried the whole way. This is time on your feet, not a time trial.",
    ]

    private static func longWhy(_ s: GeneratedSession, week: Week, seed: Int) -> String {
        if week.isTaper || week.phase == .taper {
            return "Shorter than the build. The work is done and this keeps the rhythm."
        }
        if let prev = week.previousLongRunM, prev > 0, let dist = s.targetDistanceM {
            let ratio = dist / prev
            if ratio > 1.03 { return "A little longer than last week. That is the whole idea." }
            if ratio < 0.97 {
                return week.isDeload || week.phase == .recovery
                    ? "Shorter than last week on purpose. Recovery is part of the plan."
                    : "A shorter long run this week to let the last one settle."
            }
            return "The same distance as last week. Let it feel easier than it did."
        }
        if week.index == 0 {
            return "The biggest run of your first week. Comfortable is the goal."
        }
        if let share = shareWords(s, week: week) {
            return "The biggest run of your week, \(share.lowercased()) of it."
        }
        return "Long runs are how endurance is built, one week at a time."
    }

    private static func longCue(_ s: GeneratedSession, week: Week, seed: Int) -> String? {
        guard let dist = s.targetDistanceM, let pace = s.targetPaceSPerKm, pace > 0 else { return nil }
        let minutes = dist / 1000 * pace / 60
        if let toRace = week.weeksToRace, toRace <= 8, (week.raceDistanceM ?? 0) >= 21_000, seed % 2 == 1 {
            return "Practice your race day breakfast and fueling on this one."
        }
        if minutes >= 75 { return "Take something to eat if you are out past an hour." }
        return nil
    }

    // MARK: Repeats

    private static func intervalsWhy(week: Week, seed: Int) -> String {
        if let toRace = week.weeksToRace, toRace <= 6 {
            return "This is the speed you want on race day, in pieces you can hold."
        }
        return pick(["Short doses of faster running that lift your ceiling.",
                     "The reps teach your legs a faster rhythm. The recoveries make it stick."], seed)
    }

    // MARK: Strength and other cardio

    private static func strength(_ s: GeneratedSession, week: Week, seed: Int) -> String {
        let label = s.strengthLabel.map { "\($0) day." } ?? "Strength day."
        let count = s.strengthTargets.count
        var lines = [label]
        if count > 0 { lines.append("\(numberWord(count).capitalized) lift\(count == 1 ? "" : "s"). Leave a rep or two in the tank on every set.") }
        else { lines.append("Leave a rep or two in the tank on every set.") }
        if let hard = week.hardRunDay, hard == s.dayOffset + 1 {
            lines.append("Keep the legs light with a hard run tomorrow.")
        } else if week.index == 0 {
            lines.append("Move well before you move heavy.")
        }
        return join(lines)
    }

    private static func otherCardio(_ s: GeneratedSession, week: Week, seed: Int) -> String {
        let noun = s.discipline == .cycling ? "ride" : "walk"
        switch s.runType {
        case .long:
            return join(["The long \(noun) of the week. Unhurried, and let the time on your feet do the work.",
                         week.index == 0 ? "Comfortable is the goal in your first week." : "It is the session your endurance grows from."])
        case .tempo, .intervals, .progression:
            return join(["A quicker \(noun) today. Controlled effort, not all out.",
                         "One quality session a week is enough to move the needle."])
        default:
            return join([s.discipline == .cycling ? "An easy spin. Conversational effort the whole way."
                                                  : "A steady walk at a pace you could hold all day.",
                         week.index == 0 ? "Your first week is about showing up, not proving anything."
                                         : "Easy sessions are what let the harder ones count."])
        }
    }

    // MARK: - The week ahead (the coach's Sunday message)

    /// "Week 3 of 12. Build. Four runs this week, one of them quick, and the long run to close it
    /// out. Two lifts around them. The easy days matter as much as the hard one."
    static func weekAhead(index: Int, total: Int, phase: PlanPhase, isDeload: Bool, isTaper: Bool,
                          runs: Int, lifts: Int, hasLong: Bool, hasHard: Bool,
                          weeksToRace: Int?, raceName: String?,
                          checkpointDay: String? = nil) -> String {
        var lines: [String] = []
        lines.append("Week \(index + 1) of \(total).")
        if isTaper || phase == .taper {
            lines.append("Taper.")
        } else if isDeload || phase == .recovery {
            lines.append("Cutback week.")
        } else {
            lines.append(phase == .base ? "Base." : phase == .peak ? "Peak." : "Build.")
        }
        var shape = "\(numberWord(runs).capitalized) run\(runs == 1 ? "" : "s") this week"
        if hasHard && hasLong { shape += ", one of them quick, and the long run to close it out." }
        else if hasLong { shape += ", with the long run to close it out." }
        else if hasHard { shape += ", one of them quick." }
        else { shape += "." }
        if runs > 0 { lines.append(shape) }
        if lifts > 0 { lines.append("\(numberWord(lifts).capitalized) lift\(lifts == 1 ? "" : "s") around \(runs > 0 ? "them" : "the week").") }
        if let checkpointDay {
            lines.append("The block ends with your checkpoint on \(checkpointDay). Everything else this week stays easy on purpose.")
        }
        if let toRace = weeksToRace, toRace >= 0 {
            let name = raceName ?? "race day"
            switch toRace {
            case 0: lines.append("\(name.prefix(1).uppercased() + String(name.dropFirst())) is this week. Everything pointed there.")
            case 1: lines.append("One week to \(name). Nothing new now, just fresh legs.")
            case 2...4: lines.append("\(numberWord(toRace).capitalized) weeks to \(name). Every session has a job.")
            default: break
            }
        } else if index == 0 {
            lines.append("First week. Show up, keep the easy days easy, and let the plan do the rest.")
        } else if isDeload || phase == .recovery {
            lines.append("Less this week on purpose. This is where the last few weeks turn into fitness.")
        } else if checkpointDay != nil {
            lines.append("Run the test honest and let the block report do the talking.")
        } else if hasHard {
            lines.append("The easy days matter as much as the hard one. Keep them easy.")
        } else {
            lines.append("Nothing fancy. Consistency is the whole plan this week.")
        }
        return join(lines)
    }

    // MARK: - Looking back (yesterday's run, on today's card)

    /// One line about the last run, spoken on today's card. `distanceText` and `paceText` arrive
    /// already formatted in the athlete's unit ("4.1 mi", "10:12 /mi"). `daysAgo` is 1 for
    /// yesterday; older than two days the coach lets it go.
    static func lookBack(distanceText: String, paceText: String, actualPaceSPerKm: Double,
                         targetPaceSPerKm: Double?, runType: RunType?, daysAgo: Int,
                         weekday: String? = nil) -> String? {
        guard daysAgo >= 1, daysAgo <= 2, actualPaceSPerKm > 0 else { return nil }
        // "Yesterday's 4 mi at 9:40 /mi" or "Thursday's 4 mi at 9:40 /mi": the day owns the run,
        // the way a coach talks about it. The comma-wrapped fallback only fires with no weekday.
        let lead: String
        if daysAgo == 1 { lead = "Yesterday's \(distanceText) at \(paceText)" }
        else if let weekday, !weekday.isEmpty { lead = "\(weekday)'s \(distanceText) at \(paceText)" }
        else { lead = "Your last run, \(distanceText) at \(paceText)," }
        guard let target = targetPaceSPerKm, target > 0 else {
            return "\(lead) is in the book."
        }
        let hard = runType == .tempo || runType == .intervals || runType == .progression || runType == .race
        let diff = actualPaceSPerKm - target          // positive = slower than target
        if abs(diff) <= 10 { return "\(lead) held right where I want it." }
        if diff < 0 {
            return hard ? "\(lead) was quicker than the target. Good, as long as it felt controlled."
                        : "\(lead) was a touch quick for an easy day. Slower today is the plan, not laziness."
        }
        return hard ? "\(lead) came in under the target. Fitness shows up on its own schedule."
                    : "\(lead) came in a little under the target. That is fine on an easy day."
    }

    // MARK: - Writing the notes onto a generated plan

    /// Fill every generic rationale (nil, or one of `PlanEngine`'s old fixed sentences) with a
    /// note from the FINAL week. Special rationales written by the engine (shakeouts, tune ups,
    /// eased or protected sessions, the medium long run) are kept: they already say something.
    static func annotate(_ weeks: inout [GeneratedWeek], inputs: PlanInputs, startDate: Date,
                         calendar: Calendar) {
        annotate(&weeks, raceDate: inputs.raceDate, raceDistanceM: inputs.raceDistanceM,
                 startDate: startDate, calendar: calendar)
    }

    static func annotate(_ weeks: inout [GeneratedWeek], raceDate: Date?, raceDistanceM: Double?,
                         startDate: Date, calendar: Calendar) {
        let total = weeks.count
        for w in weeks.indices {
            let week = weeks[w]
            let cardio = week.sessions.filter { $0.discipline != .strength }
            let weekStart = calendar.date(byAdding: .weekOfYear, value: w, to: startDate) ?? startDate
            let ctx = Week(
                index: week.index, total: total, phase: week.phase,
                isDeload: week.isDeload, isTaper: week.isTaper,
                runDays: cardio.count, runVolumeM: week.runVolumeM,
                longRunDay: cardio.first { $0.runType == .long }?.dayOffset,
                hardRunDay: cardio.first { $0.isHardRun && $0.runType != .race }?.dayOffset,
                previousLongRunM: w > 0
                    ? weeks[w - 1].sessions.first { $0.discipline != .strength && $0.runType == .long }?.targetDistanceM
                    : nil,
                weeksToRace: PlanEngine.weeksToRace(startDate: weekStart, raceDate: raceDate, calendar: calendar),
                raceDistanceM: raceDistanceM,
                liftDays: week.sessions.count - cardio.count,
                checkpointDay: cardio.first { $0.intervals?.contains("Time trial") == true }?.dayOffset)
            for i in weeks[w].sessions.indices
            where PlanEngine.isGenericRationale(weeks[w].sessions[i].rationale, for: weeks[w].sessions[i]) {
                weeks[w].sessions[i].rationale = session(weeks[w].sessions[i], week: ctx)
            }
        }
    }

    /// Plans generated before the notes existed still carry the fixed fallback sentences. Rebuild
    /// the generated weeks from the stored sessions, run the same pass, and write back only what
    /// changed. Idempotent: a note is never generic again, so a second pass writes nothing. Moved,
    /// injury and other specific rationales are untouched; self-coached plans are the athlete's own
    /// words and are skipped entirely. Returns the number of sessions rewritten.
    @discardableResult
    static func annotate(existing plan: TrainingPlan, calendar: Calendar) -> Int {
        guard !plan.isSelfCoached, !plan.sessions.isEmpty else { return 0 }
        let ordered = plan.sessions.sorted { $0.date < $1.date }
        let anchor = calendar.startOfDay(for: plan.blockStart ?? ordered.first?.date ?? plan.createdAt)
        let hardTypes: Set<RunType> = [.tempo, .intervals, .race, .progression, .fartlek, .hills, .strides]
        var weeks: [GeneratedWeek] = []
        var rows: [[PlannedSession]] = []
        for ps in ordered {
            let days = calendar.dateComponents([.day], from: anchor, to: calendar.startOfDay(for: ps.date)).day ?? -1
            guard days >= 0 else { continue }          // an earlier block's leftovers
            let w = days / 7
            while weeks.count <= w {
                let raw = plan.weekPhases.indices.contains(weeks.count) ? plan.weekPhases[weeks.count] : ""
                let phase = PlanPhase(rawValue: raw) ?? .build
                weeks.append(GeneratedWeek(index: weeks.count, isDeload: phase == .recovery,
                                           isTaper: phase == .taper, phase: phase, sessions: []))
                rows.append([])
            }
            var gen = GeneratedSession(dayOffset: days % 7, discipline: ps.discipline, runType: ps.runType,
                                       targetDistanceM: ps.targetDistanceM, targetDurationS: ps.targetDurationS,
                                       targetPaceSPerKm: ps.targetPaceSPerKm, intervals: ps.intervals,
                                       strengthLabel: ps.strengthLabel, rationale: ps.rationale)
            gen.strengthTargets = ps.strengthTargets.map {
                GeneratedExercise(exerciseName: "", targetSets: $0.targetSets, repLow: $0.targetRepLow,
                                  repHigh: $0.targetRepHigh, targetRPE: $0.targetRPE,
                                  targetPctRM: $0.targetPctRM, progression: $0.progression)
            }
            gen.isHardRun = ps.discipline != .strength && (ps.runType.map(hardTypes.contains) ?? false)
            weeks[w].sessions.append(gen)
            rows[w].append(ps)
        }
        let before = weeks.map { $0.sessions.map(\.rationale) }
        let raceDistanceM = ordered.first { $0.runType == .race }?.targetDistanceM
        annotate(&weeks, raceDate: plan.raceDate, raceDistanceM: raceDistanceM, startDate: anchor, calendar: calendar)
        var changed = 0
        for w in weeks.indices {
            for i in weeks[w].sessions.indices where weeks[w].sessions[i].rationale != before[w][i] {
                rows[w][i].rationale = weeks[w].sessions[i].rationale
                changed += 1
            }
        }
        return changed
    }

    // MARK: - Helpers

    private static func join(_ lines: [String]) -> String {
        lines.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func pick(_ pool: [String], _ seed: Int) -> String {
        pool[abs(seed) % pool.count]
    }

    /// "About a third" / "About half" / "About 40 percent", or nil when the share is not worth
    /// saying (a single run week, or a tiny slice).
    private static func shareWords(_ s: GeneratedSession, week: Week) -> String? {
        guard week.runDays >= 2, week.runVolumeM > 0, let dist = s.targetDistanceM, dist > 0 else { return nil }
        let share = dist / week.runVolumeM
        switch share {
        case 0.45...0.55: return "About half"
        case 0.30..<0.37: return "About a third"
        case 0.22..<0.28: return "About a quarter"
        case 0.10..<1.0:
            let pct = Int((share * 20).rounded()) * 5
            return "About \(pct) percent"
        default: return nil
        }
    }

    private static func hardNoun(_ week: Week) -> String { "hard run" }

    static func numberWord(_ n: Int) -> String {
        switch n {
        case 0: "no"; case 1: "one"; case 2: "two"; case 3: "three"; case 4: "four"
        case 5: "five"; case 6: "six"; case 7: "seven"; case 8: "eight"; case 9: "nine"
        default: String(n)
        }
    }
}
