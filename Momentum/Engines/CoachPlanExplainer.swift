import Foundation

/// One row of a coach info card (explain plan, week recap, race plan) — icon + title + a line
/// computed from the athlete's own data.
struct CoachSection: Identifiable, Equatable, Sendable {
    let icon: String       // SF Symbol
    let title: String
    let detail: String
    var id: String { title }
}

/// The "why your plan looks like this" breakdown — every line computed from the athlete's own data
/// (goal, race runway, calibrated pace, completed load, phases), so the explanation is personal and
/// provably true. Deterministic: the engines explain themselves; the AI never invents rationale.
@MainActor
enum CoachPlanExplainer {

    typealias Section = CoachSection

    static func sections(profile: UserProfile, workouts: [Workout], today: Date = Date(),
                         calendar: Calendar = .current) -> [Section] {
        guard let plan = profile.plan else { return [] }
        var out: [Section] = []
        let unit = DistanceUnit(rawValue: profile.distanceUnit) ?? .auto

        // 1. The destination — what all of this points at.
        if let raceDate = profile.raceDate, let distanceM = profile.raceDistanceM {
            let weeks = max(0, calendar.dateComponents([.weekOfYear], from: today, to: raceDate).weekOfYear ?? 0)
            let race = RaceDistance.nearest(toMeters: distanceM).label
            var line = "Everything points at your \(race) on \(raceDate.formatted(.dateTime.month(.wide).day())) — \(weeks) week\(weeks == 1 ? "" : "s") out."
            if let goalS = profile.goalFinishTimeS {
                line += " Target: \(PlanFeasibility.hms(goalS))."
            }
            out.append(Section(icon: "flag.checkered", title: "Your goal", detail: line))
        } else {
            out.append(Section(icon: "target", title: "Your goal",
                               detail: "No race on the calendar, so this is a rolling block: build fitness safely, week over week. Point it at a race anytime."))
        }

        // 2. The shape — phases, and the intensity the athlete chose.
        if !plan.weekPhases.isEmpty {
            let phases = plan.weekPhases.compactMap(PlanPhase.init(rawValue:))
            let build = phases.filter { $0 == .build }.count
            let peak = phases.filter { $0 == .peak }.count
            let recovery = phases.filter { $0 == .recovery }.count
            let taper = phases.filter { $0 == .taper }.count
            var line = "\(plan.weekPhases.count) weeks: base first, \(build) build week\(build == 1 ? "" : "s") where fitness is made"
            if recovery > 0 { line += ", \(recovery) planned down week\(recovery == 1 ? "" : "s") so the work absorbs" }
            if peak > 0 { line += ", \(peak) peak week\(peak == 1 ? "" : "s") of race-specific work at full flight" }
            if taper > 0 { line += ", then a \(taper)-week taper to arrive fresh" }
            line += "."
            if let intensity = profile.planIntensity.flatMap(PlanIntensity.init(rawValue:)) {
                line += " Ramp: \(intensity.label.lowercased()) — your choice."
            }
            out.append(Section(icon: "chart.bar", title: "The shape of your weeks", detail: line))
        }

        // 3. Paces — where the numbers come from.
        if plan.p5kSPerKm > 0, plan.sessions.contains(where: { ($0.targetPaceSPerKm ?? 0) > 0 }) {
            out.append(Section(icon: "speedometer", title: "Your paces",
                               detail: "Every pace derives from your calibrated 5K fitness (\(Formatters.pace(secPerKm: plan.p5kSPerKm, unit: unit))). Show real fitness on a hard run and they sharpen automatically — a bad day never slows them down."))
        }

        // 4. The schedule — their days, their say.
        var days = "\(profile.daysPerWeek) training days a week"
        if !profile.preferredDays.isEmpty {
            let symbols = calendar.shortWeekdaySymbols
            let names = profile.preferredDays.sorted().compactMap { (1...7).contains($0) ? symbols[$0 - 1] : nil }
            days += ", on your days (\(names.joined(separator: " · ")))"
        }
        out.append(Section(icon: "calendar", title: "Your schedule",
                           detail: days + ". Miss one and it moves — never a failure state."))

        // 5. Load right now — the adaptive half, in their numbers.
        let insights = ProgressInsights(workouts: workouts, now: today, calendar: calendar)
        if insights.hasData, insights.acwr > 0 {
            out.append(Section(icon: "waveform.path.ecg", title: "Your load right now",
                               detail: TrainingLoadContext.summary(ratio: insights.acwr)
                                   + " Momentum may propose a bounded ease when load and your response agree — at most one normal structural change a week."))
        }

        // 6. The long run — capped progression toward the race.
        let longs = plan.sessions.filter { $0.runType == .long }.compactMap(\.targetDistanceM)
        if let peak = longs.max(), peak > 0 {
            out.append(Section(icon: "arrow.up.right", title: "The long run",
                               detail: "Builds gradually to \(Formatters.distance(meters: peak, unit: unit)) at peak — far enough to be ready, capped so it never outruns your recovery."))
        }

        // 7. Strength's role, when it's on the menu.
        if profile.disciplines.contains(Discipline.strength.rawValue),
           plan.sessions.contains(where: { $0.discipline == .strength }) {
            out.append(Section(icon: "dumbbell.fill", title: "Strength's role",
                               detail: "Strength days support the running: stronger legs hold form late, and the schedule keeps hard days from stacking."))
        }

        // 8. Protection — only when there's history to protect.
        if profile.activeInjuryArea != nil {
            let area = profile.activeInjuryArea.flatMap(InjuryArea.init(rawValue:))?.label.lowercased() ?? "injury"
            out.append(Section(icon: "bandage.fill", title: "Protecting you",
                               detail: "The plan is training around your \(area) right now — reduced stress, fitness preserved, and a gated return when you're ready."))
        } else if !profile.injuryHistory.isEmpty {
            out.append(Section(icon: "shield", title: "Protecting you",
                               detail: "You've reported injuries before, so the ramp starts protective and the recovery leash stays tighter."))
        }

        return out
    }
}
