import Foundation

/// One local notification, fully decided: what it says, when it fires, where a tap lands.
/// Pure data so the whole schedule can be unit-tested without a notification center.
struct LocalNotificationPayload: Equatable, Sendable {
    let id: String
    let family: NotificationFamily
    let title: String
    let body: String
    /// Local calendar fire time (year, month, day, hour, minute).
    let fire: DateComponents
    let route: NotificationRoute?
    /// False for the quiet families (a morning catch-up, the win-back): they sit on the lock
    /// screen without a chime.
    let sound: Bool
    /// Notification Summary ordering: race day outranks a weekly review.
    let relevance: Double
}

/// Everything the PLAN schedules, decided in one pure pass (notification pass 2026-09-06). The
/// service calls this on every resync and replaces every `momentum.plan.` request with the result,
/// so a moved, eased, completed or deleted session can never leave a stale reminder behind.
///
/// The families and their frequency contract:
///  • **Session reminder**: one per training day (a run and a lift on the same day share one
///    line), at the athlete's learned or chosen time, seven days ahead. Opens that session.
///  • **Catch-up**: the morning after the next session, only if that morning has no reminder of
///    its own, and at most ONE per resync. It exists for the athlete who went quiet: a missed
///    session moves forward, nothing is lost, and the plan says so before they have to. Quiet
///    (no sound). Cancelled by the resync the moment the session is logged.
///  • **Win-back**: one line ten days out, replaced on every resync so it only ever fires after
///    ten days without the app. One per absence, never a drip.
///  • **Weekly review**: the coming Sunday at 18:00, previewing the seven days ahead from the plan
///    itself (runs, distance, the long run's day). Opens Progress · Trends.
///  • **Race**: the evening before a race and race morning (quiet), from the plan's own race
///    sessions, goal race and tune-ups alike. Opens the race session.
/// Worst case on a training day is one reminder plus the evening streak line; a rest day is
/// silent unless a catch-up is owed.
/// Main-actor because the session brief it speaks (`PlanCoaching.brief`) is; every caller (the
/// service's resync, Today's bootstrap) already is too.
@MainActor
enum NotificationPlanner {

    static let prefix = "momentum.plan."
    static let catchUpID = prefix + "catchup"
    static let winbackID = prefix + "winback"
    static let weeklyID = prefix + "weekly"
    /// Seven days of reminders: far enough that a quiet week still hears its plan, short enough
    /// that a reshaped block never leaves a week of stale requests.
    static let horizonDays = 7
    static let winbackDays = 10

    struct Options: Sendable {
        var sessionReminders = true
        var weekly = true
        var distanceUnit: DistanceUnit = .auto
    }

    /// The full plan-derived schedule. Empty when the athlete has no plan.
    static func payloads(for plan: TrainingPlan?, now: Date = Date(), hour: Int, minute: Int,
                         options: Options = Options(), calendar: Calendar = .current) -> [LocalNotificationPayload] {
        guard let plan else { return [] }
        // A dated notification cannot know tomorrow's symptoms. Clear the ordinary training,
        // race and catch-up schedule until the athlete completes their recovery check-in.
        guard IllnessResponse.state(for: plan) == nil, plan.adaptiveState?.requiresRecoveryCheckin != true else { return [] }
        var out: [LocalNotificationPayload] = []
        if options.sessionReminders {
            out += sessionReminders(for: plan, now: now, hour: hour, minute: minute,
                                    unit: options.distanceUnit, calendar: calendar)
            if let catchUp = catchUp(for: plan, now: now, hour: hour, minute: minute, calendar: calendar) {
                out.append(catchUp)
            }
            if let winback = winback(for: plan, now: now, hour: hour, minute: minute, calendar: calendar) {
                out.append(winback)
            }
            out += raceNotes(for: plan, now: now, unit: options.distanceUnit, calendar: calendar)
        }
        if options.weekly, let weekly = weekly(for: plan, now: now, unit: options.distanceUnit, calendar: calendar) {
            out.append(weekly)
        }
        return out
    }

    // MARK: Session reminders (one per training day)

    static func sessionReminders(for plan: TrainingPlan, now: Date, hour: Int, minute: Int,
                                 unit: DistanceUnit, calendar: Calendar) -> [LocalNotificationPayload] {
        let days = upcomingByDay(plan, now: now, calendar: calendar)
        return days.compactMap { day, sessions in
            var comps = calendar.dateComponents([.year, .month, .day], from: day)
            comps.hour = hour; comps.minute = minute
            // Never a fire time already behind us (today, after the reminder hour).
            guard let fire = calendar.date(from: comps), fire > now, let lead = sessions.first else { return nil }
            let body = sessions.map { NotificationCopy.clean(PlanCoaching.brief(for: $0, distanceUnit: unit)) }
                .joined(separator: ". ")
            return LocalNotificationPayload(
                id: prefix + "session." + lead.id.uuidString,
                family: .session,
                title: dayTitle(sessions),
                body: body,
                fire: comps,
                route: .planSession(lead.id),
                sound: true,
                relevance: 0.8)
        }
    }

    /// "Run day", "Lift day", or "Run and lift day" when both are planned.
    static func dayTitle(_ sessions: [PlannedSession]) -> String {
        var words: [String] = []
        for s in sessions {
            let word = disciplineWord(s.discipline)
            if !words.contains(word) { words.append(word) }
        }
        guard let first = words.first else { return "Session day" }
        if words.count == 1 { return "\(first.capitalized) day" }
        return "\(first.capitalized) and \(words.dropFirst().joined(separator: " and ")) day"
    }

    static func disciplineWord(_ d: Discipline) -> String {
        switch d {
        case .running: "run"
        case .cycling: "ride"
        case .walking: "walk"
        case .strength: "lift"
        }
    }

    // MARK: Catch-up (the morning after, only when that morning is otherwise silent)

    static func catchUp(for plan: TrainingPlan, now: Date, hour: Int, minute: Int,
                        calendar: Calendar) -> LocalNotificationPayload? {
        let days = upcomingByDay(plan, now: now, calendar: calendar)
        let sessionDays = Set(days.map(\.day))
        for (day, sessions) in days {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day),
                  !sessionDays.contains(next),          // that day's own reminder is the knock
                  let lead = sessions.first else { continue }
            var comps = calendar.dateComponents([.year, .month, .day], from: next)
            comps.hour = hour; comps.minute = minute
            guard let fire = calendar.date(from: comps), fire > now else { continue }
            return LocalNotificationPayload(
                id: catchUpID,
                family: .catchUp,
                title: "Check in on yesterday's \(disciplineWord(lead.discipline))",
                body: "See what is recorded and whether your schedule needs an adjustment.",
                fire: comps,
                route: .plan,
                sound: false,
                relevance: 0.6)
        }
        return nil
    }

    // MARK: Win-back (one line, ten quiet days out)

    static func winback(for plan: TrainingPlan, now: Date, hour: Int, minute: Int,
                        calendar: Calendar) -> LocalNotificationPayload? {
        // Only a plan with something ahead of it has a place to keep.
        let todayStart = calendar.startOfDay(for: now)
        guard plan.sessions.contains(where: {
            $0.status != .completed && $0.status != .missed && $0.completedWorkout == nil && $0.date >= todayStart
        }) else { return nil }
        guard let day = calendar.date(byAdding: .day, value: winbackDays, to: todayStart) else { return nil }
        var comps = calendar.dateComponents([.year, .month, .day], from: day)
        comps.hour = hour; comps.minute = minute
        return LocalNotificationPayload(
            id: winbackID,
            family: .winback,
            title: "Your plan kept your place",
            body: "Ten days is a pause, not a reset. Open your plan and pick this week up from where you are.",
            fire: comps,
            route: .plan,
            sound: false,
            relevance: 0.4)
    }

    // MARK: Weekly review (09:00 at the plan's anchored week boundary)

    static func weekly(for plan: TrainingPlan, now: Date, unit: DistanceUnit,
                       calendar: Calendar) -> LocalNotificationPayload? {
        let cal = plan.adaptiveState?.calendar ?? calendar
        let boundary = AdaptiveTrainingWeek.week(containing: now, calendar: cal).end
        guard let fire = cal.date(bySettingHour: 9, minute: 0, second: 0, of: boundary) else { return nil }
        var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        comps.timeZone = cal.timeZone
        let body = "Review your recent training and recovery to shape the week ahead. Open Momentum to finalize it."
        return LocalNotificationPayload(
            id: weeklyID,
            family: .weekly,
            title: "Time to review your week",
            body: body,
            fire: comps,
            route: .plan,
            sound: true,
            relevance: 0.5)
    }

    /// The coming Sunday's 18:00, or the one after if this Sunday's has passed.
    static func nextSundayEvening(after now: Date, calendar: Calendar) -> Date? {
        let todayStart = calendar.startOfDay(for: now)
        for delta in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: delta, to: todayStart),
                  calendar.component(.weekday, from: day) == 1,
                  let fire = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day) else { continue }
            if fire > now { return fire }
        }
        return nil
    }

    /// "Next week: 4 runs, 38 km, and 2 lifts. Long run Saturday." from the seven days after the
    /// Sunday it fires on. nil when nothing is planned (a self-coached blank week, a finished block).
    static func weekPreview(_ plan: TrainingPlan, from sunday: Date, unit: DistanceUnit,
                            calendar: Calendar) -> String? {
        let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: sunday) ?? sunday)
        guard let end = calendar.date(byAdding: .day, value: 7, to: start) else { return nil }
        let week = plan.sessions.filter {
            $0.status != .completed && $0.status != .missed && $0.completedWorkout == nil && $0.date >= start && $0.date < end
        }
        guard !week.isEmpty else { return nil }
        let runs = week.filter { $0.discipline == .running }
        let lifts = week.filter { $0.discipline == .strength }
        let others = week.count - runs.count - lifts.count
        var parts: [String] = []
        if !runs.isEmpty { parts.append("\(runs.count) run\(runs.count == 1 ? "" : "s")") }
        if !lifts.isEmpty { parts.append("\(lifts.count) lift\(lifts.count == 1 ? "" : "s")") }
        if others > 0 { parts.append("\(others) other session\(others == 1 ? "" : "s")") }
        var line = "Next week: " + joinedList(parts)
        // The distance is its own clause, so "3 runs and 1 lift, 30 km of running" never reads as
        // a list of three.
        let meters = runs.reduce(0.0) { $0 + ($1.targetDistanceM ?? 0) }
        if meters > 0 {
            let distance = Formatters.distance(meters: meters, unit: unit)
            line += parts.count > 1 ? ", \(distance) of running" : ", \(distance) in total"
        }
        line += "."
        if let long = runs.first(where: { $0.runType == .long }) {
            line += " Long run \(long.date.formatted(.dateTime.weekday(.wide)))."
        }
        return NotificationCopy.clean(line)
    }

    private static func joinedList(_ parts: [String]) -> String {
        switch parts.count {
        case 0: ""
        case 1: parts[0]
        case 2: "\(parts[0]) and \(parts[1])"
        default: parts.dropLast().joined(separator: ", ") + ", and " + parts[parts.count - 1]
        }
    }

    // MARK: Race eve + race morning (from the plan's own race sessions)

    static func raceNotes(for plan: TrainingPlan, now: Date, unit: DistanceUnit,
                          calendar: Calendar) -> [LocalNotificationPayload] {
        let todayStart = calendar.startOfDay(for: now)
        let disclosure = AdaptivePlanService.Disclosure(plan: plan, now: now, calendar: calendar)
        let races = plan.sessions
            .filter { disclosure.showsDetails($0) }
            .filter { $0.runType == .race && $0.status != .completed && $0.status != .missed && $0.completedWorkout == nil
                      && calendar.startOfDay(for: $0.date) >= todayStart }
            .sorted { $0.date < $1.date }
        var out: [LocalNotificationPayload] = []
        for race in races {
            let raceDay = calendar.startOfDay(for: race.date)
            let distance = race.targetDistanceM.map { Formatters.distance(meters: $0, unit: unit) }
            if let eve = calendar.date(byAdding: .day, value: -1, to: raceDay) {
                var comps = calendar.dateComponents([.year, .month, .day], from: eve)
                comps.hour = 19; comps.minute = 0
                if let fire = calendar.date(from: comps), fire > now {
                    let lead = distance.map { "\($0) tomorrow." } ?? "Tomorrow is the day."
                    out.append(LocalNotificationPayload(
                        id: prefix + "race.eve." + race.id.uuidString,
                        family: .race,
                        title: "Race day tomorrow",
                        body: "\(lead) Lay out your kit, eat what you know, and get to bed early.",
                        fire: comps,
                        route: .planSession(race.id),
                        sound: true,
                        relevance: 1.0))
                }
            }
            var morning = calendar.dateComponents([.year, .month, .day], from: raceDay)
            morning.hour = 6; morning.minute = 0
            if let fire = calendar.date(from: morning), fire > now {
                out.append(LocalNotificationPayload(
                    id: prefix + "race.day." + race.id.uuidString,
                    family: .race,
                    title: "Race day",
                    body: "Trust the training. Start easy, finish strong, and enjoy it.",
                    fire: morning,
                    route: .planSession(race.id),
                    sound: false,
                    relevance: 1.0))
            }
        }
        return out
    }

    // MARK: Shared

    /// Upcoming, undone sessions inside the horizon, grouped by local day, both ascending. Inside
    /// a day the order is deterministic (the store hands relationships back in any order): the
    /// run leads the lift, as the coach's week does, then ids break ties, so a run+lift day is
    /// always "Run and lift day" and always opens the run.
    static func upcomingByDay(_ plan: TrainingPlan, now: Date,
                              calendar: Calendar) -> [(day: Date, sessions: [PlannedSession])] {
        let today = calendar.startOfDay(for: now)
        let horizon = calendar.date(byAdding: .day, value: horizonDays, to: today) ?? today
        let disclosure = AdaptivePlanService.Disclosure(plan: plan, now: now, calendar: calendar)
        let upcoming = plan.sessions
            .filter { disclosure.showsDetails($0) }
            .filter { $0.status != .completed && $0.status != .missed && $0.completedWorkout == nil
                      && $0.date >= today && $0.date <= horizon }
            .sorted { a, b in
                if a.date != b.date { return a.date < b.date }
                let ra = disciplineRank(a.discipline), rb = disciplineRank(b.discipline)
                if ra != rb { return ra < rb }
                return a.id.uuidString < b.id.uuidString
            }
        var buckets: [Date: [PlannedSession]] = [:]
        for s in upcoming { buckets[calendar.startOfDay(for: s.date), default: []].append(s) }
        return buckets.keys.sorted().map { (day: $0, sessions: buckets[$0] ?? []) }
    }

    /// Runs before rides before walks before lifts: the endurance session is the day's headline.
    static func disciplineRank(_ d: Discipline) -> Int {
        switch d {
        case .running: 0
        case .cycling: 1
        case .walking: 2
        case .strength: 3
        }
    }
}
