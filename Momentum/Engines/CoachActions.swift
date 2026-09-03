import Foundation
import SwiftData

/// Executes validated `CoachIntent`s — the single bridge from the coach chat to the deterministic
/// engines (PRD §4.7, §9). Chat UI, offline responder, and proactive nudges all funnel here; nothing
/// in this file computes a training number itself. Every mutation is consent-gated upstream (the
/// athlete tapped Apply) and re-checked here at apply time (throttle, feasibility, staleness), so a
/// card can never execute against a plan that changed underneath it.
@MainActor
enum CoachActions {

    /// What the coach says after a change lands — headline for the card, detail as the chat line.
    struct Receipt: Sendable, Equatable {
        let headline: String
        let detail: String
    }

    enum Outcome: Sendable, Equatable {
        case applied(Receipt)
        case declined(reason: String)       // honest, no-shame refusal (throttle, feasibility, stale)
        case navigate(CoachDestination)
    }

    /// The ≤1-structural-change/week transaction gate (shares `plan.lastAdaptedAt` with autoAdapt /
    /// adaptToEffort / proposeAdjustment, so coach-chat changes can never stack on an auto-ease).
    static func canAdaptLoad(_ plan: TrainingPlan?, today: Date, calendar: Calendar = .current) -> Bool {
        guard let last = plan?.lastAdaptedAt else { return true }
        return (calendar.dateComponents([.day], from: last, to: today).day ?? .max) >= 7
    }

    /// Feasibility snapshot for a proposed (or current) race setup — the honesty check shown BEFORE
    /// a changeRace/changeGoal card can be applied. Overrides fall back to the profile's values.
    static func feasibility(for profile: UserProfile, distanceM: Double? = nil, date: Date? = nil,
                            goalFinishTimeS: Double? = nil, today: Date = Date(),
                            calendar: Calendar = .current) -> PlanFeasibility {
        let raceDate = date ?? profile.raceDate
        let weeks = raceDate.map {
            max(0, calendar.dateComponents([.weekOfYear], from: today, to: $0).weekOfYear ?? 0)
        } ?? 0
        let experience = (profile.experience[Discipline.running.rawValue])
            .flatMap(ExperienceLevel.init(rawValue:)) ?? .new
        return PlanFeasibility.assess(
            raceDistanceM: distanceM ?? profile.raceDistanceM,
            goalFinishTimeS: goalFinishTimeS ?? profile.goalFinishTimeS,
            currentP5kSPerKm: profile.plan?.p5kSPerKm,
            currentWeeklyVolumeM: profile.weeklyRunVolumeM ?? 0,
            weeksAvailable: weeks,
            experience: experience,
            injuryProne: !profile.injuryHistory.isEmpty,
            daysPerWeek: profile.daysPerWeek)
    }

    // MARK: - Preview (the card's diff lines — shown before Apply, computed not narrated)

    static func preview(_ intent: CoachIntent, profile: UserProfile, today: Date = Date(),
                        calendar: Calendar = .current) -> [String] {
        let unit = DistanceUnit.auto
        switch intent {
        case .navigate:
            return []
        case .changeGoal(let goal):
            return ["Goal: \(label(profile.goal)) → \(label(goal))", rebuildLine]
        case .changeRace(let distanceM, let date, let goalTime):
            var lines = ["Race: \(RaceDistance.nearest(toMeters: distanceM).label) on \(day(date))"]
            if let t = goalTime { lines.append("Goal time: \(PlanFeasibility.hms(t))") }
            lines.append(rebuildLine)
            return lines
        case .addTuneUp(let name, let distanceM, let date, let racesIt, let goalTime):
            let label = RaceDistance.nearest(toMeters: distanceM).label
            var lines = ["Tune-up: \(name.isEmpty ? label : "\(name) · \(label)") on \(day(date))",
                         racesIt ? "Race it: two easy days in, easy days out" : "Train through it: a hard day with a bib on"]
            if let t = goalTime { lines.append("Target: \(PlanFeasibility.hms(t))") }
            lines.append("The block toward your goal race stays as it is")
            return lines
        case .changeDays(let days, let preferred):
            var lines: [String] = []
            if let days { lines.append("Training days: \(profile.daysPerWeek) → \(days) per week") }
            if let preferred { lines.append("Preferred days: \(weekdayList(preferred, calendar: calendar))") }
            lines.append(rebuildLine)
            return lines
        case .changeSessionLength(let minutes):
            return ["Session length: \(profile.sessionMinutes)m → \(minutes)m", rebuildLine]
        case .moveSession(let id, let to):
            guard let s = session(id, of: profile) else { return [] }
            return ["\(PlanCoaching.brief(for: s, distanceUnit: unit))",
                    "\(day(s.date)) → \(day(to))"]
        case .skipSession(let id):
            guard let s = session(id, of: profile) else { return [] }
            return ["Clears \(PlanCoaching.brief(for: s, distanceUnit: unit)) on \(day(s.date))",
                    "No streak lost — rest days count"]
        case .easeWeek:
            return ["Upcoming sessions ease ~15%", "Hard sessions soften to easy"]
        case .bumpLoad:
            return ["Upcoming sessions nudge up ~10%", "Your completed load says you've earned it"]
        case .easePaces:
            return ["Target paces ease ~2%", "Future runs only — history untouched"]
        case .changeEquipment(let equipment):
            return ["Equipment: \(label(profile.equipment)) → \(label(equipment))", rebuildLine]
        case .injuryReport(let area, let severity):
            return ["Protects your \(area.label.lowercased()) for \(severity.windowDays) days",
                    "Gated return when you're ready — never a diagnosis"]
        case .pausePlan(let days):
            var lines = ["Everything upcoming shifts \(days) day\(days == 1 ? "" : "s") later"]
            if profile.raceDate != nil { lines.append("Race day stays fixed") }
            return lines
        case .resumePlan:
            return ["Pulls your plan back to today", "Picks up where you left off"]
        case .renewBlock:
            if profile.plan?.raceDate == nil {
                return ["Reassesses your last 4 weeks of real running",
                        "Builds your next block fresh from today"]
            }
            return ["Rebuilds from today, still pointed at your race", rebuildLine]
        case .rememberNote(let text, _):
            return ["“\(text)”", "Kept in your coach's memory — forget it anytime"]
        case .explainPlan, .weekRecap, .racePlan, .showMemory, .racePredictor, .todayBriefing, .showZones:
            return []   // informational — these render their own sections
        }
    }

    // MARK: - Apply

    @discardableResult
    static func apply(_ intent: CoachIntent, profile: UserProfile, workouts: [Workout],
                      today: Date = Date(), in context: ModelContext,
                      calendar: Calendar = .current) -> Outcome {
        switch intent {
        case .navigate(let dest):
            return .navigate(dest)

        case .changeGoal(let goal):
            let old = profile.goal
            guard goal != old else { return .declined(reason: "That's already your goal — you're set.") }
            profile.goal = goal
            rebuild(profile, in: context)
            return notify(Receipt(
                headline: "Goal updated",
                detail: "Your goal is now \(label(goal).lowercased()). I rebuilt your upcoming weeks around it — completed work and your calibrated paces are kept."),
                today: today, in: context)

        case .changeRace(let distanceM, let date, let goalTime):
            // The card already showed the honest feasibility read + the alternatives before Apply, so
            // tapping Apply is the athlete's informed choice — build the best block the timeline allows
            // (the engine handles any runway; a too-short race becomes an honest freshness block) and
            // stay truthful in the receipt. The user chose; we don't refuse.
            let check = feasibility(for: profile, distanceM: distanceM, date: date,
                                    goalFinishTimeS: goalTime, today: today, calendar: calendar)
            profile.raceDate = date
            profile.raceDistanceM = distanceM
            if let goalTime { profile.goalFinishTimeS = goalTime }
            if profile.goal != .raceDistance { profile.goal = .raceDistance }
            rebuild(profile, in: context)
            let label = RaceDistance.nearest(toMeters: distanceM).label
            let detail: String
            if check.verdict == .tooShort {
                let alt = check.options.first.map { " If you can, \(lowerFirst($0))." } ?? ""
                detail = "\(label) on \(day(date)) — that's a very short runway, so I built the most we safely can to get you to the line healthy.\(alt) Your upcoming weeks are rebuilt to point at it."
            } else {
                detail = "\(label) on \(day(date)) — \(check.headline.lowercased()). I rebuilt your upcoming weeks to point at it."
            }
            return notify(Receipt(headline: "Race locked in", detail: detail), today: today, in: context)

        case .addTuneUp(let name, let distanceM, let date, let racesIt, let goalTime):
            guard profile.goal == .raceDistance, let goalDate = profile.raceDate, date < goalDate else {
                return .declined(reason: "A tune-up needs a goal race to sit in front of. Point the plan at your race first, then add the tune-up.")
            }
            let existing = PlanService.tuneUpRaces(for: profile, in: context)
            guard existing.count < 4 else {
                return .declined(reason: "Four tune-ups is the most a season carries. Remove one in Plan settings to make room.")
            }
            var tuneUps = existing.map {
                TuneUpEvent(id: $0.id, name: "", date: $0.date, distanceM: $0.distanceM,
                            priority: $0.priority, goalTimeS: $0.goalTimeS)
            }
            tuneUps.append(TuneUpEvent(name: name, date: calendar.startOfDay(for: date), distanceM: distanceM,
                                       priority: racesIt ? .b : .c, goalTimeS: goalTime))
            let label = RaceDistance.nearest(toMeters: distanceM).label
            do {
                let command = try PlanConfigurationCommand.legacyUICommand(
                    id: UUID(), profile: profile, startsNewSeason: false,
                    planName: profile.plan?.name ?? "", goal: profile.goal,
                    raceDate: profile.raceDate, raceDistanceM: profile.raceDistanceM,
                    goalFinishTimeS: profile.goalFinishTimeS, tuneUps: tuneUps, now: today, in: context)
                try command.preflightValidation()
                let previousAutosave = context.autosaveEnabled
                context.autosaveEnabled = false
                defer { context.autosaveEnabled = previousAutosave }
                do {
                    let events = tuneUps.map {
                        PlanRaceEvent(id: $0.id, date: $0.date, distanceM: $0.distanceM,
                                      priority: $0.priority, goalTimeS: $0.goalTimeS)
                    }
                    _ = try PlanService.stageRebuild(for: profile, tuneUps: events, in: context)
                    _ = try command.apply(in: context, now: today)
                    _ = try RunningPlanBackfill.prepareAfterLegacyPlanMutation(in: context)
                    try context.save()
                } catch {
                    context.rollback()
                    throw error
                }
            } catch let error as PlanConfigurationCommandError {
                switch error {
                case .tuneUpTooClose:
                    return .declined(reason: "That \(label) sits too close to another race. A raced tune-up keeps a week from the goal race and from another tune-up; anything keeps three days.")
                case .tuneUpTooSoon:
                    return .declined(reason: "That is inside the next week, and a week can only bend around a race when there is a week to bend. Pick a date at least seven days out.")
                default:
                    return .declined(reason: "I could not add that tune-up. Try it from Plan settings.")
                }
            } catch {
                return .declined(reason: "I could not add that tune-up. Try it from Plan settings.")
            }
            let detail = racesIt
                ? "\(label) on \(day(date)), raced. That week bends around it: easy days in, an honest effort, easy days out. The block toward your goal race is untouched."
                : "\(label) on \(day(date)), trained through. It stands in for that week's hard session and nothing else moves."
            return notify(Receipt(headline: "Tune-up added", detail: detail), today: today, in: context)

        case .changeDays(let days, let preferred):
            if let days { profile.daysPerWeek = days }
            if let preferred { profile.preferredDays = preferred }
            rebuild(profile, in: context)
            let what = days.map { "\($0) days a week" } ?? "your preferred days"
            return notify(Receipt(
                headline: "Schedule updated",
                detail: "Your plan now fits \(what). I rebuilt the upcoming weeks — nothing you've done is lost."),
                today: today, in: context)

        case .changeSessionLength(let minutes):
            profile.sessionMinutes = minutes
            rebuild(profile, in: context)
            return notify(Receipt(
                headline: "Session length updated",
                detail: "Sessions now target about \(minutes) minutes. Upcoming weeks are rebuilt to fit."),
                today: today, in: context)

        case .changeEquipment(let equipment):
            profile.equipment = equipment
            rebuild(profile, in: context)
            return notify(Receipt(
                headline: "Equipment updated",
                detail: "Strength work now assumes \(label(equipment).lowercased()). Upcoming sessions are rebuilt around it."),
                today: today, in: context)

        case .moveSession(let id, let to):
            guard let s = session(id, of: profile), s.status != .completed else {
                return .declined(reason: "That session isn't on your plan anymore, so there's nothing to move.")
            }
            let from = day(s.date)
            PlanCoaching.reschedule(s, to: to, in: context, calendar: calendar)
            return notify(Receipt(
                headline: "Session moved",
                detail: "Moved \(PlanCoaching.brief(for: s, distanceUnit: .auto)) from \(from) to \(day(to)). The rest of your week stands."),
                today: today, in: context)

        case .skipSession(let id):
            guard let s = session(id, of: profile), s.status != .completed else {
                return .declined(reason: "That session isn't on your plan anymore — nothing to clear.")
            }
            let what = PlanCoaching.brief(for: s, distanceUnit: .auto), when = day(s.date)
            // Drop it from the relationship first — a deleted model can linger in the to-many array
            // until refetch, which would let a stale card "clear" the same session twice.
            profile.plan?.sessions.removeAll { $0.id == s.id }
            context.delete(s)
            try? context.save()
            return notify(Receipt(
                headline: "Session cleared",
                detail: "Cleared \(what) on \(when). No streak lost — rest days count too."),
                today: today, in: context)

        case .easeWeek:
            guard let plan = profile.plan else { return .declined(reason: noPlan) }
            guard canAdaptLoad(plan, today: today, calendar: calendar) else {
                return .declined(reason: throttleReason(plan, today: today))
            }
            guard PlanCoaching.apply(.ease, to: plan, from: today, in: context, calendar: calendar) > 0 else {
                return .declined(reason: "There's nothing upcoming to ease — your slate is clear.")
            }
            return notify(Receipt(
                headline: "Week eased",
                detail: "I trimmed your upcoming sessions about 15% and softened the hard work to easy. Absorb this block; we ramp again when you're fresh."),
                today: today, in: context)

        case .bumpLoad:
            guard let plan = profile.plan else { return .declined(reason: noPlan) }
            guard canAdaptLoad(plan, today: today, calendar: calendar) else {
                return .declined(reason: throttleReason(plan, today: today))
            }
            let insights = ProgressInsights(workouts: workouts, now: today, calendar: calendar)
            guard insights.recommendation == .increase else {
                return .declined(reason: "Your recent training pattern doesn't support reviewing a bump right now. Keep following the plan and use your recovery and session feedback as the deciding context.")
            }
            guard PlanCoaching.apply(.increase, to: plan, from: today, in: context, calendar: calendar) > 0 else {
                return .declined(reason: "There's nothing upcoming to raise — your slate is clear.")
            }
            return notify(Receipt(
                headline: "Load raised",
                detail: "Upcoming sessions are up about 10%. You chose the bounded progression after reviewing a lighter-than-recent week."),
                today: today, in: context)

        case .easePaces:
            guard let plan = profile.plan else { return .declined(reason: noPlan) }
            guard PlanCoaching.canEasePaces(plan, today: today, calendar: calendar) else {
                return .declined(reason: "I eased your paces less than a week ago — let a few sessions land at the new targets first, then we'll look again.")
            }
            guard PlanCoaching.easeQualityPaces(plan, from: today, in: context, calendar: calendar) > 0 else {
                return .declined(reason: "There are no upcoming paced runs to ease right now.")
            }
            return notify(Receipt(
                headline: "Paces eased",
                detail: "I eased your target paces about 2% so the prescriptions land the way they should. Honest targets beat heroic ones."),
                today: today, in: context)

        case .injuryReport(let area, let severity):
            let outcome = InjuryResponse.report(area: area, severity: severity, profile: profile,
                                                today: today, in: context, calendar: calendar)
            return .applied(Receipt(headline: outcome.headline, detail: outcome.detail))

        case .pausePlan(let days):
            guard let plan = profile.plan else { return .declined(reason: noPlan) }
            guard plan.pausedUntil == nil else {
                return .declined(reason: "Your plan is already paused — tell me when you're back and I'll pick it up.")
            }
            let shifted = PlanCoaching.pause(plan, days: days, from: today, in: context, calendar: calendar)
            guard shifted > 0 else { return .declined(reason: "There's nothing upcoming to pause.") }
            var detail = "Everything upcoming moved \(days) day\(days == 1 ? "" : "s") later. Life happens; the plan bends."
            if profile.raceDate != nil {
                detail += " Race day stays fixed, so the runway is a little tighter — I'll be honest about it when you're back."
            }
            return notify(Receipt(headline: "Plan paused", detail: detail), today: today, in: context)

        case .resumePlan:
            guard let plan = profile.plan, plan.pausedUntil != nil else {
                return .declined(reason: "Your plan isn't paused — you're already rolling.")
            }
            PlanCoaching.resume(plan, from: today, in: context, calendar: calendar)
            return notify(Receipt(
                headline: "Welcome back",
                detail: "Your plan picks up from today. First session back stays easy; we rebuild rhythm before intensity."),
                today: today, in: context)

        case .renewBlock:
            guard let plan = profile.plan else { return .declined(reason: noPlan) }
            // Rolling plan → a true renewal: reassess what they actually ran, next block, counter up.
            if plan.raceDate == nil {
                PlanService.renewBlock(for: profile, startDate: today, in: context)
                let block = (profile.plan?.blockIndex ?? 0) + 1
                return notify(Receipt(
                    headline: "Block \(block) is built",
                    detail: "I looked at what you've actually been running these past few weeks and built your next block from there — six fresh weeks starting today. Nothing you've done is lost."),
                    today: today, in: context)
            }
            // Race plan → rebuild from today, still pointed at the race (races don't run in blocks).
            // Capture the date first: rebuild cascade-deletes the old plan out from under `plan`.
            let raceDay = plan.raceDate ?? today
            rebuild(profile, in: context)
            return notify(Receipt(
                headline: "Plan rebuilt",
                detail: "Rebuilt from today, still pointed at your race on \(day(raceDay)). Completed work and your calibrated paces are kept."),
                today: today, in: context)

        case .rememberNote(let rawText, let category):
            // Same hygiene gate as every other memory write (no medical language, no shame).
            guard let text = MemoryConsolidation.clean(rawText) else {
                return .declined(reason: "I can't keep medical notes, that's a professional's job. Anything about how you like to train, I'm all ears.")
            }
            let model = athleteModel(for: profile, in: context)
            let active = model.notes.filter { $0.isActive && $0.source == MemorySource.user.rawValue }
            if active.contains(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) {
                return .declined(reason: "Already got it. That one's been in my notes for a while.")
            }
            guard active.count < 12 else {
                return .declined(reason: "My notes on you are full (12). Ask me what I know about you and forget one first, then I'll keep this.")
            }
            // Append-only (unlike per-category corrections): each remembered fact stands alone.
            let note = MemoryNote()
            note.category = category.rawValue
            note.text = text
            note.source = MemorySource.user.rawValue
            note.confidence = Confidence.confident.rawValue
            note.pinned = true
            note.isActive = true
            context.insert(note)
            model.notes.append(note)
            try? context.save()
            return .applied(Receipt(
                headline: "Noted",
                detail: "Kept: \"\(text)\". I'll coach with that in mind. Ask me what I know about you anytime, and tell me to forget anything."))

        case .explainPlan, .weekRecap, .racePlan, .showMemory, .racePredictor, .todayBriefing, .showZones:
            // Informational cards — nothing to apply; their only tap-through navigates.
            switch intent {
            case .weekRecap, .racePredictor, .showZones: return .navigate(.viewProgress)
            case .todayBriefing: return .navigate(.startToday)
            default: return .navigate(.viewPlanWeek)
            }
        }
    }

    // MARK: - Helpers

    private static let rebuildLine = "Rebuilds your upcoming weeks (completed work + paces kept)"
    private static let noPlan = "You don't have an active plan yet — set one up and I can tune it."

    /// Lowercase only the first character (so a feasibility option reads mid-sentence).
    private static func lowerFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.lowercased() + s.dropFirst()
    }

    private static func rebuild(_ profile: UserProfile, in context: ModelContext) {
        PlanService.rebuild(for: profile, in: context)
        try? context.save()
    }

    private static func notify(_ receipt: Receipt, today: Date, in context: ModelContext) -> Outcome {
        AppNotification.post(kind: .coaching, title: receipt.headline, body: receipt.detail,
                             on: today, in: context)
        return .applied(receipt)
    }

    private static func throttleReason(_ plan: TrainingPlan, today: Date) -> String {
        let when = plan.lastAdaptedAt.map { day($0) } ?? "recently"
        return "I already adjusted your plan \(when). One structural change a week keeps adaptation honest — ask me again in a few days and I'll take another look."
    }

    private static func session(_ id: UUID, of profile: UserProfile) -> PlannedSession? {
        profile.plan?.sessions.first { $0.id == id }
    }

    /// The athlete's memory model, created on first use (mirrors AthleteModelService.model(for:in:)).
    private static func athleteModel(for profile: UserProfile, in context: ModelContext) -> AthleteModel {
        if let existing = profile.athlete { return existing }
        let model = AthleteModel()
        context.insert(model)
        profile.athlete = model
        return model
    }

    private static func day(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private static func weekdayList(_ days: [Int], calendar: Calendar) -> String {
        let symbols = calendar.shortWeekdaySymbols
        return days.compactMap { (1...7).contains($0) ? symbols[$0 - 1] : nil }.joined(separator: " · ")
    }

    private static func label(_ goal: Goal) -> String {
        goal.planLabel
    }

    private static func label(_ equipment: Equipment) -> String {
        switch equipment {
        case .fullGym: "Full gym"
        case .dumbbellsOnly: "Dumbbells only"
        case .homeMinimal: "Home minimal"
        case .bodyweight: "Bodyweight"
        }
    }
}
