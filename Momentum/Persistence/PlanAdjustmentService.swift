import Foundation
import SwiftData

/// The one action layer behind Manage plan (2026-09-07, docs/PLAN-AND-FUEL-UPGRADE.md §2.3). Every
/// adjustment is a `CoachIntent` applied through `CoachActions`, exactly as the coach chat applies
/// it, so there is one adaptation engine and one throttle. What this adds is the proposal the
/// athlete decides on: what was asked, which sessions and dates it touches, the before and after,
/// one explanation, the outlook effect, whether it is available right now and why not, and a
/// signature of the plan so a proposal computed against last week's plan is recomputed rather
/// than applied.
@MainActor
enum PlanAdjustmentService {

    struct Affected: Equatable, Sendable {
        var sessions: Int
        var from: Date
        var to: Date
    }

    struct Proposal: Identifiable, Equatable {
        let id: UUID
        let intent: CoachIntent
        /// "Train 5 days a week"
        let title: String
        /// What the athlete asked for, in their words.
        let request: String
        /// Before → after lines, computed.
        let lines: [String]
        let affected: Affected?
        let explanation: String
        /// "On track → Tight" when a race outlook moves; nil otherwise.
        let outlookChange: String?
        /// Why it cannot be applied right now; nil when available.
        let blocked: String?
        let signature: Int
        var isAvailable: Bool { blocked == nil }
    }

    enum ApplyResult {
        case applied(CoachActions.Receipt, undo: String?)
        case declined(String)
        /// The plan changed since the proposal was computed; here is the fresh one.
        case stale(Proposal)
    }

    // MARK: - Signature

    /// Everything an adjustment reads or writes: the sessions (id, day, status, targets), the
    /// adaptation latches, the pause. Two plans with equal signatures produce equal proposals.
    static func signature(of plan: TrainingPlan?, calendar: Calendar = .current) -> Int {
        var h = Hasher()
        guard let plan else { h.combine(0); return h.finalize() }
        h.combine(plan.id)
        h.combine(plan.lastAdaptedAt)
        h.combine(plan.lastPaceEasedAt)
        h.combine(plan.pausedUntil)
        h.combine(plan.isSelfCoached)
        for s in plan.sessions.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            h.combine(s.id)
            h.combine(calendar.startOfDay(for: s.date))
            h.combine(s.status.rawValue)
            h.combine(s.targetDistanceM)
            h.combine(s.targetDurationS)
            h.combine(s.runType?.rawValue)
        }
        return h.finalize()
    }

    // MARK: - Proposal

    static func proposal(_ intent: CoachIntent, title: String, request: String,
                         profile: UserProfile, workouts: [Workout], today: Date = Date(),
                         distanceUnit: DistanceUnit = .metric,
                         in context: ModelContext, calendar: Calendar = .current) -> Proposal {
        let plan = profile.plan
        var lines = CoachActions.preview(intent, profile: profile, today: today, calendar: calendar)
        lines.append(contentsOf: computedLines(intent, profile: profile, today: today,
                                               distanceUnit: distanceUnit, in: context, calendar: calendar))
        return Proposal(
            id: UUID(), intent: intent, title: title, request: request, lines: lines,
            affected: affected(intent, plan: plan, today: today, calendar: calendar),
            explanation: explanation(intent, profile: profile),
            outlookChange: outlookChange(intent, profile: profile, today: today, calendar: calendar),
            blocked: blocked(intent, profile: profile, workouts: workouts, today: today, calendar: calendar),
            signature: signature(of: plan, calendar: calendar))
    }

    /// Which open sessions the change touches, and the span of dates.
    static func affected(_ intent: CoachIntent, plan: TrainingPlan?, today: Date,
                         calendar: Calendar = .current) -> Affected? {
        guard let plan else { return nil }
        let todayStart = calendar.startOfDay(for: today)
        let open = plan.sessions.filter {
            ($0.status == .planned || $0.status == .moved) && $0.completedWorkout == nil
                && calendar.startOfDay(for: $0.date) >= todayStart
        }
        func span(_ sessions: [PlannedSession]) -> Affected? {
            guard let from = sessions.map(\.date).min(), let to = sessions.map(\.date).max() else { return nil }
            return Affected(sessions: sessions.count, from: from, to: to)
        }
        switch intent {
        case .moveSession(let id, let to):
            guard let s = plan.sessions.first(where: { $0.id == id }) else { return nil }
            return Affected(sessions: 1, from: min(s.date, to), to: max(s.date, to))
        case .skipSession(let id):
            guard let s = plan.sessions.first(where: { $0.id == id }) else { return nil }
            return Affected(sessions: 1, from: s.date, to: s.date)
        case .easeWeek, .bumpLoad:
            return span(open.filter { $0.runType != .race })
        case .easePaces:
            return span(open.filter { $0.discipline != .strength && $0.targetPaceSPerKm != nil && $0.runType != .race })
        case .injuryReport(_, let severity):
            let until = calendar.date(byAdding: .day, value: severity.windowDays, to: todayStart) ?? todayStart
            return span(open.filter { $0.date <= until })
        case .pausePlan, .resumePlan:
            return span(open)
        case .changeGoal, .changeRace, .changeDays, .changeSessionLength, .changeEquipment, .renewBlock, .addTuneUp:
            return span(open)
        case .navigate, .explainPlan, .weekRecap, .racePlan, .showMemory, .racePredictor, .todayBriefing,
             .showZones, .rememberNote:
            return nil
        }
    }

    /// Before → after in numbers, from the same generator the change will run. Rebuild-type
    /// changes compare the current plan's typical week with a preview of the rebuilt one; the
    /// bounded adaptations show the next open session scaled by their factor.
    static func computedLines(_ intent: CoachIntent, profile: UserProfile, today: Date,
                              distanceUnit: DistanceUnit, in context: ModelContext,
                              calendar: Calendar = .current) -> [String] {
        guard let plan = profile.plan, !plan.isSelfCoached else { return [] }
        func km(_ m: Double) -> String { Formatters.distance(meters: m, unit: distanceUnit) }
        switch intent {
        case .changeDays, .changeSessionLength, .changeEquipment, .changeGoal, .changeRace:
            var after = PlanBlueprint(profile: profile)
            switch intent {
            case .changeDays(let days, let preferred):
                if let days { after.daysPerWeek = days }
                if let preferred { after.preferredDays = preferred }
            case .changeSessionLength(let minutes): after.sessionMinutes = minutes
            case .changeEquipment(let equipment): after.equipment = equipment
            case .changeGoal(let goal): after.goal = goal
            case .changeRace(let distanceM, let date, let goalTime):
                after.goal = .raceDistance; after.raceDistanceM = distanceM; after.raceDate = date
                if let goalTime { after.goalFinishTimeS = goalTime }
            default: break
            }
            let before = PlanPreview.build(snapshot: CoachUndo.planState(of: plan),
                                           blueprint: PlanBlueprint(profile: profile), distanceUnit: distanceUnit,
                                           calendar: calendar)
            let preview = PlanLifecycleService.preview(for: after, profile: profile, startDate: today,
                                                       today: today, in: context, calendar: calendar)
            var lines: [String] = []
            if before.runsPerWeek != preview.runsPerWeek {
                lines.append("Runs a week: \(before.runsPerWeek) → \(preview.runsPerWeek)")
            }
            if before.liftsPerWeek != preview.liftsPerWeek {
                lines.append("Strength a week: \(before.liftsPerWeek) → \(preview.liftsPerWeek)")
            }
            if before.peakWeekM > 0, preview.peakWeekM > 0, abs(before.peakWeekM - preview.peakWeekM) >= 500 {
                lines.append("Peak week: \(km(before.peakWeekM)) → \(km(preview.peakWeekM))")
            }
            if before.longestRunM > 0, preview.longestRunM > 0, abs(before.longestRunM - preview.longestRunM) >= 500 {
                lines.append("Longest run: \(km(before.longestRunM)) → \(km(preview.longestRunM))")
            }
            if preview.weeklyTimeS > 0 {
                lines.append("A typical week asks about \(Formatters.compactDuration(s: preview.weeklyTimeS))")
            }
            return lines
        case .easeWeek, .bumpLoad:
            let factor = intent == .easeWeek ? 0.85 : 1.1
            let next = plan.sessions
                .filter { ($0.status == .planned || $0.status == .moved) && $0.completedWorkout == nil
                          && calendar.startOfDay(for: $0.date) >= calendar.startOfDay(for: today)
                          && $0.discipline != .strength && $0.runType != .race && ($0.targetDistanceM ?? 0) > 0 }
                .sorted { $0.date < $1.date }
                .prefix(3)
            return next.map { s in
                let title = s.runType?.planTitle ?? "Run"
                let day = s.date.formatted(.dateTime.weekday(.abbreviated))
                return "\(day) \(title): \(km(s.targetDistanceM ?? 0)) → \(km((s.targetDistanceM ?? 0) * factor))"
            }
        case .pausePlan(let days):
            let next = plan.sessions
                .filter { ($0.status == .planned || $0.status == .moved) && $0.completedWorkout == nil
                          && calendar.startOfDay(for: $0.date) >= calendar.startOfDay(for: today) }
                .sorted { $0.date < $1.date }
                .prefix(2)
            return next.compactMap { s in
                guard let moved = calendar.date(byAdding: .day, value: days, to: s.date) else { return nil }
                let title = s.discipline == .strength ? (s.strengthLabel ?? "Strength") : (s.runType?.planTitle ?? "Run")
                return "\(title): \(s.date.formatted(.dateTime.weekday(.abbreviated).day())) → \(moved.formatted(.dateTime.weekday(.abbreviated).day()))"
            }
        default:
            return []
        }
    }

    static func explanation(_ intent: CoachIntent, profile: UserProfile) -> String {
        switch intent {
        case .changeDays:
            return "The week is rebuilt from today around the days you can train. Completed sessions and your paces stay; the weekly ramp is still governed, so more days never means a jump in load."
        case .changeSessionLength:
            return "Sessions are re-sized to the time you have. Long runs keep their place in the week; what does not fit moves to the days that can hold it."
        case .changeEquipment:
            return "Strength days are rebuilt with exercises you can actually do. Running is untouched."
        case .changeGoal:
            return "The upcoming weeks are rebuilt toward the new goal from today. Nothing you have done is lost."
        case .changeRace:
            return "The block is re-pointed at the race: build, peak and taper land on the new date. The outlook above is the honest read of that runway."
        case .moveSession:
            return "One session moves; the rest of the week stands. A hard day never lands next to the long run."
        case .skipSession:
            return "The session is cleared, not marked missed. Rest days count; your streak holds."
        case .easeWeek:
            return "Every upcoming session trims about 15% and hard work softens to easy. This uses the one structural change the week allows, so the coach will not stack another on top."
        case .bumpLoad:
            return "Upcoming sessions rise about 10%. The coach only offers this when your completed load has earned it, and it counts as the week's structural change."
        case .easePaces:
            return "Target paces ease about 2% on future runs. Past runs and your fitness estimate are untouched; sharpening evidence starts fresh."
        case .injuryReport:
            return "Training around a sore spot removes what aggravates it and gates the way back. Never a diagnosis; anything sharp, swollen or worsening is a question for a professional."
        case .pausePlan:
            return "Everything upcoming shifts later by the same number of days. Race day never moves, so a pause inside a race build tightens the runway; the coach says so when you are back."
        case .resumePlan:
            return "Sessions pull back to meet you today. The first one back stays easy."
        case .renewBlock:
            return profile.plan?.raceDate == nil
                ? "The next block is built from what you actually ran in the last four weeks, not from what was planned."
                : "The block is rebuilt from today, still pointed at your race."
        case .addTuneUp:
            return "Only the week the race lands in bends. The block toward your goal race is untouched."
        case .navigate, .explainPlan, .weekRecap, .racePlan, .showMemory, .racePredictor, .todayBriefing,
             .showZones, .rememberNote:
            return ""
        }
    }

    /// How the race outlook moves, when it moves.
    static func outlookChange(_ intent: CoachIntent, profile: UserProfile, today: Date,
                              calendar: Calendar = .current) -> String? {
        let before = PlanBlueprint(profile: profile)
        var after = before
        switch intent {
        case .changeDays(let days, _): if let days { after.daysPerWeek = days }
        case .changeRace(let distanceM, let date, let goalTime):
            after.goal = .raceDistance; after.raceDistanceM = distanceM; after.raceDate = date
            if let goalTime { after.goalFinishTimeS = goalTime }
        case .changeGoal(let goal): after.goal = goal
        case .pausePlan(let days):
            // A pause shortens the runway by exactly its days.
            guard before.isRace, let date = before.raceDate else { return nil }
            after.raceDate = calendar.date(byAdding: .day, value: -days, to: date)
        default: return nil
        }
        guard before.isRace || after.isRace else { return nil }
        let a = PlanLifecycleService.feasibility(for: before, profile: profile, today: today, calendar: calendar)
        let b = PlanLifecycleService.feasibility(for: after, profile: profile, today: today, calendar: calendar)
        guard a.verdict != b.verdict else { return nil }
        return "Outlook: \(word(a.verdict)) → \(word(b.verdict))"
    }

    private static func word(_ v: PlanFeasibility.Verdict) -> String {
        switch v {
        case .onTrack: "On track"
        case .tight: "Tight"
        case .tooShort: "Too short"
        case .noRace: "No race"
        }
    }

    /// The honest "not right now": the same gates `CoachActions.apply` enforces, said before the
    /// athlete taps, in plain words.
    static func blocked(_ intent: CoachIntent, profile: UserProfile, workouts: [Workout], today: Date,
                        calendar: Calendar = .current) -> String? {
        guard let plan = profile.plan else { return "There is no current plan to adjust. Create one from Your plans." }
        if plan.isSelfCoached {
            switch intent {
            case .moveSession, .skipSession, .pausePlan, .resumePlan: break
            default: return "You are coaching this plan yourself, so the coach does not reshape it. Edit the week on the board, or ask for a coached plan from Your plans."
            }
        }
        func nextAllowed() -> String {
            guard let last = plan.lastAdaptedAt,
                  let next = calendar.date(byAdding: .day, value: 7, to: last) else { return "in a few days" }
            return "from \(next.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))"
        }
        switch intent {
        case .easeWeek:
            guard CoachActions.canAdaptLoad(plan, today: today, calendar: calendar) else {
                return "The plan was already reshaped this week. One structural change a week keeps adaptation honest; this is available again \(nextAllowed())."
            }
        case .bumpLoad:
            guard CoachActions.canAdaptLoad(plan, today: today, calendar: calendar) else {
                return "The plan was already reshaped this week. One structural change a week keeps adaptation honest; this is available again \(nextAllowed())."
            }
            let insights = ProgressInsights(workouts: workouts, now: today, calendar: calendar)
            guard insights.recommendation == .increase else {
                return "Your recent completed training does not support a load increase yet. Keep following the plan; the coach offers the bump when your finished sessions have earned it."
            }
        case .easePaces:
            guard PlanCoaching.canEasePaces(plan, today: today, calendar: calendar) else {
                return "Paces were eased less than a week ago. Let a few sessions land at the new targets first."
            }
        case .pausePlan:
            if let until = plan.pausedUntil, calendar.startOfDay(for: until) > calendar.startOfDay(for: today) {
                return "The plan is already paused until \(until.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))). Resume it first."
            }
        case .resumePlan:
            guard plan.pausedUntil != nil else { return "The plan is not paused." }
        case .moveSession(let id, _), .skipSession(let id):
            guard let s = plan.sessions.first(where: { $0.id == id }), s.status != .completed else {
                return "That session is no longer open on your plan."
            }
        default:
            break
        }
        return nil
    }

    // MARK: - Apply and undo

    /// Apply through the one engine, with the plan's signature checked first: a proposal computed
    /// against a plan that has since changed is recomputed and returned instead of applied.
    static func apply(_ proposal: Proposal, profile: UserProfile, workouts: [Workout],
                      notifications: NotificationServing, today: Date = Date(),
                      distanceUnit: DistanceUnit = .metric, in context: ModelContext,
                      calendar: Calendar = .current) -> ApplyResult {
        let current = signature(of: profile.plan, calendar: calendar)
        guard current == proposal.signature else {
            return .stale(self.proposal(proposal.intent, title: proposal.title, request: proposal.request,
                                        profile: profile, workouts: workouts, today: today,
                                        distanceUnit: distanceUnit, in: context, calendar: calendar))
        }
        if let blocked = blocked(proposal.intent, profile: profile, workouts: workouts, today: today, calendar: calendar) {
            return .declined(blocked)
        }
        let undo = CoachUndo.capture(profile)
        switch CoachActions.apply(proposal.intent, profile: profile, workouts: workouts, today: today,
                                  in: context, calendar: calendar) {
        case .applied(let receipt):
            try? context.save()
            propagate(profile: profile, workouts: workouts, notifications: notifications, calendar: calendar)
            return .applied(receipt, undo: undo)
        case .declined(let reason):
            return .declined(reason)
        case .navigate:
            return .declined("That one opens a page rather than changing the plan.")
        }
    }

    /// Roll the plan back to the state captured before an apply. The same restore the coach chat
    /// trusts; it also returns the week's adaptation budget.
    @discardableResult
    static func undo(_ json: String, profile: UserProfile, workouts: [Workout],
                     notifications: NotificationServing, in context: ModelContext,
                     calendar: Calendar = .current) -> Bool {
        guard CoachUndo.restore(json, profile: profile, in: context) else { return false }
        propagate(profile: profile, workouts: workouts, notifications: notifications, calendar: calendar)
        return true
    }

    /// Reminders, the widget and the wrist follow the plan (the existing hooks, nothing new).
    static func propagate(profile: UserProfile, workouts: [Workout], notifications: NotificationServing,
                          calendar: Calendar = .current) {
        notifications.schedulePlannedReminders(profile.plan)
        WidgetBridge.publish(profile: profile, workouts: workouts,
                             stats: ProfileStats(workouts: workouts, plan: profile.plan, calendar: calendar))
        PhoneWatchSync.shared.scheduleRefresh()
    }
}
