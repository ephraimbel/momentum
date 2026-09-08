import Foundation
import SwiftData

/// A synchronous transaction on the caller's SwiftData executor. Nested engine saves are staged;
/// the plan, evidence ledger and inbox receipt commit together. Live surfaces run only afterward.
enum PlanMutation {
    private final class Scope: @unchecked Sendable {
        let contextID: ObjectIdentifier
        var effects: [() -> Void] = []
        init(_ context: ModelContext) { contextID = ObjectIdentifier(context) }
    }
    @TaskLocal private static var scope: Scope?
    static let failureNotification = Notification.Name("Momentum.planMutationFailed")

    static func isStaging(_ context: ModelContext) -> Bool {
        scope?.contextID == ObjectIdentifier(context)
    }

    static func save(_ context: ModelContext) throws {
        if !isStaging(context) { try context.save() }
    }

    static func afterCommit(in context: ModelContext, _ effect: @escaping () -> Void) {
        if isStaging(context), let scope { scope.effects.append(effect) }
        else { effect() }
    }

    @MainActor
    static func perform<T>(in context: ModelContext,
                           commit: (ModelContext) throws -> Void = { try $0.save() },
                           _ changes: () throws -> T) throws -> T {
        if isStaging(context) { return try changes() }
        // Preserve already-pending workout samples/other edits before creating a rollback boundary.
        if context.hasChanges { try context.save() }
        let autosave = context.autosaveEnabled
        let previousUndo = context.undoManager
        let undo = UndoManager()
        undo.groupsByEvent = false
        context.autosaveEnabled = false
        context.undoManager = undo
        undo.beginUndoGrouping()
        defer {
            undo.removeAllActions()
            context.undoManager = previousUndo
            context.autosaveEnabled = autosave
        }
        let transaction = Scope(context)
        do {
            let result = try $scope.withValue(transaction) {
                let result = try changes()
                try RunPrescriptionBudget.enforcePreferences(in: context)
                try InjuryResponse.enforce(in: context)
                try IllnessResponse.enforce(in: context)
                context.processPendingChanges()
                if undo.groupingLevel > 0 { undo.endUndoGrouping() }
                try commit(context)
                return result
            }
            transaction.effects.forEach { $0() }
            return result
        } catch {
            context.processPendingChanges()
            if undo.groupingLevel > 0 { undo.endUndoGrouping() }
            // SwiftData rollback discards inserts, but may leave already-observed model values
            // cached. Undo restores those values on the same instances before discarding storage edits.
            if undo.canUndo { undo.undo() }
            context.rollback()
            throw error
        }
    }

    @MainActor
    static func edit(in context: ModelContext, _ changes: () -> Void) -> Bool {
        attempt(in: context, fallback: false) { changes(); return true }
    }

    @MainActor
    static func attempt<T>(in context: ModelContext, fallback: T, _ changes: () throws -> T) -> T {
        do { return try perform(in: context, changes) }
        catch {
            NotificationCenter.default.post(name: failureNotification, object: nil)
            return fallback
        }
    }
}

/// The one action layer behind Manage plan (2026-09-07, docs/PLAN-AND-FUEL-UPGRADE.md §2.3). Every
/// adjustment is a `CoachIntent` applied through `CoachActions`, exactly as the coach chat applies
/// it, so there is one adaptation engine and one throttle. What this adds is the proposal the
/// athlete decides on: what was asked, which sessions and dates it touches, the before and after,
/// one explanation, the outlook effect, whether it is available right now and why not, and a
/// signature of the plan so a proposal computed against last week's plan is recomputed rather
/// than applied.
@MainActor
enum PlanAdjustmentService {

    /// What the athlete asked for: the intent plus the words the proposal is headed with. The
    /// proposal itself is computed from this when the sheet opens, never inside the tap.
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let intent: CoachIntent
        let title: String
        let request: String
    }

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
        /// Before → after lines, computed from the same engine the change will run.
        let lines: [String]
        let affected: Affected?
        let explanation: String
        /// "Outlook: On track → Tight" when a race outlook moves; nil otherwise.
        let outlookChange: String?
        /// Why it cannot be applied right now; nil when available.
        let blocked: String?
        let signature: Int
        /// The date, athlete settings and completed training can change independently of the plan.
        let contextSignature: Int
        var isAvailable: Bool { blocked == nil }
    }

    enum ApplyResult {
        case applied(CoachActions.Receipt, undo: String?)
        case declined(String)
        /// The plan changed since the proposal was computed; here is the fresh one.
        case stale(Proposal)
    }

    // MARK: - Signature

    /// Everything an adjustment reads or writes: the sessions (id, day, status, discipline, targets,
    /// paces, the injury marker), the calibrated pace, the adaptation latches, the pause. Two plans
    /// with equal signatures produce equal proposals. Compared within one process only.
    static func signature(of plan: TrainingPlan?, calendar: Calendar = .current) -> Int {
        var h = Hasher()
        guard let plan else { h.combine(0); return h.finalize() }
        h.combine(plan.id)
        h.combine(plan.goal.rawValue)
        h.combine(plan.raceDate)
        h.combine(plan.goalRacePaceSPerKm)
        h.combine(plan.blockStart)
        h.combine(plan.weekPhases)
        h.combine(plan.pendingP5kSPerKm)
        h.combine(plan.pendingP5kAt)
        let coachingState = plan.coachingState
        h.combine(coachingState?.pendingP5kWorkoutID)
        for (key, value) in (coachingState?.paceEvidenceDates ?? [:]).sorted(by: { $0.key < $1.key }) { h.combine(key); h.combine(value) }
        h.combine(plan.p5kSPerKm)
        h.combine(plan.lastAdaptedAt)
        h.combine(plan.lastPaceEasedAt)
        h.combine(plan.lastRecalibratedAt)
        h.combine(plan.pausedUntil)
        for (key, value) in (coachingState?.pauseShiftedDates ?? [:]).sorted(by: { $0.key < $1.key }) { h.combine(key); h.combine(value) }
        h.combine(plan.isSelfCoached)
        // Read each persistent identifier once instead of faulting it in every sort comparison.
        let orderedSessions = plan.sessions.map { (key: $0.id.uuidString, session: $0) }
            .sorted { $0.key < $1.key }
        for (_, s) in orderedSessions {
            h.combine(s.id)
            h.combine(calendar.startOfDay(for: s.date))
            h.combine(s.status.rawValue)
            h.combine(s.discipline.rawValue)
            h.combine(s.sportType)
            h.combine(s.completedWorkout?.id)
            h.combine(s.targetDistanceM)
            h.combine(s.targetDurationS)
            h.combine(s.targetPaceSPerKm)
            h.combine(s.runType?.rawValue)
            h.combine(s.intervals)
            h.combine(s.rationale?.hasPrefix(InjuryResponse.marker) ?? false)
            // A to-many relationship has no stable order between fetches; sort before hashing or
            // the signature moves on its own the moment the sheet closes and the undo dies.
            // Only a strength session carries targets; reading the relationship on a run is a
            // fault for nothing.
            if s.discipline == .strength {
                h.combine(s.strengthTargets.map {
                    "\($0.order)|\($0.exercise?.name ?? "")|\($0.targetSets)|\($0.targetRepLow)|\($0.targetRepHigh)|\($0.targetRPE ?? -1)|\($0.targetPctRM ?? -1)|\($0.progression)"
                }.sorted())
            }
        }
        return h.finalize()
    }

    private static func contextSignature(profile: UserProfile, workouts: [Workout], today: Date,
                                         distanceUnit: DistanceUnit, calendar: Calendar) -> Int {
        var h = Hasher()
        h.combine(profile.id)
        h.combine(calendar.startOfDay(for: today))
        h.combine(calendar.timeZone.identifier)
        h.combine(calendar.firstWeekday)
        h.combine(distanceUnit.rawValue)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // Data's Hashable implementation may sample bytes. Hash every byte so fields in the
        // middle of the blueprint (such as availability) participate in this fingerprint.
        if let encoded = try? encoder.encode(PlanBlueprint(profile: profile).sanitized()) {
            h.combine(encoded.count)
            for byte in encoded { h.combine(byte) }
        }
        h.combine(profile.injuryHistory.sorted())
        h.combine(profile.activeInjuryArea)
        h.combine(profile.activeInjurySeverity)
        h.combine(profile.activeInjuryUntil)
        // Athlete-wide recovery belongs to the context fingerprint. Looking up the profile
        // from every plan signature forced unrelated relationship work during view refreshes.
        let continuity = profile.continuity
        h.combine(continuity?.illnessData)
        h.combine(continuity?.trainingEvidenceFrom)
        h.combine(profile.crossTraining.sorted())
        for workout in workouts.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            h.combine(workout.id)
            h.combine(workout.type.rawValue)
            h.combine(workout.startedAt)
            h.combine(workout.durationS)
            h.combine(workout.gps?.distanceM)
            h.combine(workout.perceivedEffort)
            h.combine(workout.planFitRaw)
        }
        return h.finalize()
    }

    // MARK: - Proposal

    static func proposal(for request: Request, profile: UserProfile, workouts: [Workout], today: Date = Date(),
                         distanceUnit: DistanceUnit = .metric, in context: ModelContext,
                         calendar: Calendar = .current) -> Proposal {
        proposal(request.intent, title: request.title, request: request.request, profile: profile,
                 workouts: workouts, today: today, distanceUnit: distanceUnit, in: context, calendar: calendar)
    }

    static func proposal(_ intent: CoachIntent, title: String, request: String,
                         profile: UserProfile, workouts: [Workout], today: Date = Date(),
                         distanceUnit: DistanceUnit = .metric,
                         in context: ModelContext, calendar: Calendar = .current) -> Proposal {
        let plan = profile.plan
        let blocked = blocked(intent, profile: profile, workouts: workouts, today: today, calendar: calendar)
        // A blocked proposal carries no before/after: "your completed load says you've earned it"
        // under a card that says the opposite is a contradiction, not a preview.
        var lines: [String] = []
        if blocked == nil {
            lines = CoachActions.preview(intent, profile: profile, today: today, calendar: calendar)
            lines.append(contentsOf: computedLines(intent, profile: profile, today: today,
                                                   distanceUnit: distanceUnit, in: context, calendar: calendar))
        }
        return Proposal(
            id: UUID(), intent: intent, title: title, request: request, lines: lines,
            affected: affected(intent, plan: plan, today: today, calendar: calendar),
            explanation: explanation(intent, profile: profile),
            outlookChange: outlookChange(intent, profile: profile, today: today, calendar: calendar),
            blocked: blocked,
            signature: signature(of: plan, calendar: calendar),
            contextSignature: contextSignature(profile: profile, workouts: workouts, today: today,
                                               distanceUnit: distanceUnit, calendar: calendar))
    }

    /// The sessions an intent can touch, the way the engine selects them.
    private static func openSessions(_ plan: TrainingPlan, from today: Date, calendar: Calendar) -> [PlannedSession] {
        let todayStart = calendar.startOfDay(for: today)
        return plan.sessions.filter {
            ($0.status == .planned || $0.status == .moved) && $0.completedWorkout == nil
                && calendar.startOfDay(for: $0.date) >= todayStart
        }
    }

    private static func isInjuryMarked(_ s: PlannedSession) -> Bool {
        s.rationale?.hasPrefix(InjuryResponse.marker) ?? false
    }

    /// Which open sessions the change touches, and the span of dates.
    static func affected(_ intent: CoachIntent, plan: TrainingPlan?, today: Date,
                         calendar: Calendar = .current) -> Affected? {
        guard let plan else { return nil }
        let todayStart = calendar.startOfDay(for: today)
        let open = openSessions(plan, from: today, calendar: calendar)
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
            // Exactly `PlanCoaching.apply`'s selection: open, future, never race day, never a
            // session the injury loop already converted.
            return span(open.filter { $0.runType != .race && !isInjuryMarked($0) })
        case .easeThisWeek:
            let horizon = calendar.date(byAdding: .day, value: 7, to: todayStart) ?? todayStart
            return span(open.filter { $0.runType != .race && !isInjuryMarked($0) && $0.date < horizon })
        case .easePaces:
            // Exactly `easeQualityPaces`'s selection: every open session with a pace, race day too.
            return span(open.filter { $0.discipline != .strength && $0.targetPaceSPerKm != nil })
        case .injuryReport(_, let severity):
            let until = calendar.date(byAdding: .day, value: severity.windowDays, to: todayStart) ?? todayStart
            return span(open.filter { $0.date <= until })
        case .pausePlan(let days):
            return span(PlanCoaching.pausePlacements(plan, days: days, from: today, calendar: calendar).map(\.session))
        case .resumePlan:
            return span(PlanCoaching.resumePlacements(plan, from: today, calendar: calendar).map(\.session))
        case .changeGoal, .changeRace, .changeDays, .changeSessionLength, .changeEquipment, .renewBlock, .addTuneUp:
            return span(open)
        case .navigate, .explainPlan, .weekRecap, .racePlan, .showMemory, .racePredictor, .todayBriefing,
             .showZones, .rememberNote:
            return nil
        }
    }

    /// Before → after in numbers, from the same generator the change will run. Rebuild-type
    /// changes compare the current plan's typical week with a preview of the rebuilt one; the
    /// bounded adaptations show the next open sessions the way the engine will write them (snapped
    /// to clean values, with the run type that lands).
    static func computedLines(_ intent: CoachIntent, profile: UserProfile, today: Date,
                              distanceUnit: DistanceUnit, in context: ModelContext,
                              calendar: Calendar = .current) -> [String] {
        guard let plan = profile.plan, !plan.isSelfCoached else { return [] }
        let unit = distanceUnit.resolved()
        func km(_ m: Double) -> String { Formatters.distance(meters: m, unit: unit) }
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
                                           blueprint: PlanBlueprint(profile: profile), distanceUnit: unit,
                                           anchor: PlanLifecycleService.span(of: plan).start, calendar: calendar)
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
        case .easeWeek, .easeThisWeek, .bumpLoad:
            let factor = intent == .bumpLoad ? 1.1 : 0.85
            let todayStart = calendar.startOfDay(for: today)
            let horizon = intent == .easeThisWeek
                ? (calendar.date(byAdding: .day, value: 7, to: todayStart) ?? todayStart) : Date.distantFuture
            let next = openSessions(plan, from: today, calendar: calendar)
                .filter { $0.discipline != .strength && $0.runType != .race && !isInjuryMarked($0)
                          && ($0.targetDistanceM ?? 0) > 0 && $0.date < horizon }
                .sorted { $0.date < $1.date }
                .prefix(3)
            return next.map { s in
                let before = s.runType?.planTitle ?? "Run"
                // `PlanCoaching.apply(.ease)` softens quality AND long runs to easy; `easeWeek`
                // (the seven-day ease) softens quality only and keeps the long run.
                let softens: Bool = {
                    guard intent != .bumpLoad, let rt = s.runType else { return false }
                    return intent == .easeWeek ? (rt.isQuality || rt == .long) : rt.isQuality
                }()
                let after = softens ? RunType.easy.planTitle : before
                let day = s.date.formatted(.dateTime.weekday(.abbreviated))
                let landed = RunRounding.snap(meters: (s.targetDistanceM ?? 0) * factor, unit: unit)
                return "\(day) \(before) \(km(s.targetDistanceM ?? 0)) → \(after) \(km(landed))"
            }
        case .pausePlan(let days):
            let moves = PlanCoaching.pausePlacements(plan, days: days, from: today, calendar: calendar)
            var lines = moves.sorted { $0.date < $1.date }.prefix(2).map { move in
                let s = move.session
                let title = s.discipline == .strength ? (s.strengthLabel ?? "Strength") : (s.runType?.planTitle ?? "Run")
                return "\(title): \(s.date.formatted(.dateTime.weekday(.abbreviated).day())) → \(move.date.formatted(.dateTime.weekday(.abbreviated).day()))"
            }
            let unchanged = openSessions(plan, from: today, calendar: calendar)
                .filter { !PlanCoaching.isFixedDate($0) }.count - moves.count
            if unchanged > 0 { lines.append("\(unchanged) sessions have no room to move and stay on their dates") }
            return lines
        case .resumePlan:
            return PlanCoaching.resumePlacements(plan, from: today, calendar: calendar).prefix(2).map { move in
                let title = move.session.discipline == .strength ? (move.session.strengthLabel ?? "Strength") : (move.session.runType?.planTitle ?? "Run")
                return "\(title): \(move.session.date.formatted(.dateTime.weekday(.abbreviated).day())) → \(move.date.formatted(.dateTime.weekday(.abbreviated).day()))"
            }
        case .moveSession(let id, let to):
            // The day it lands on may already hold a session: say so, since a move stacks rather
            // than swaps (the board's drag onto a session is the swap).
            guard let moving = plan.sessions.first(where: { $0.id == id }) else { return [] }
            let sitting = plan.sessions.filter {
                $0.id != moving.id && $0.status != .completed && calendar.isDate($0.date, inSameDayAs: to)
            }
            guard let other = sitting.first else { return [] }
            let what = other.discipline == .strength ? (other.strengthLabel ?? "Strength") : (other.runType?.planTitle ?? "Run")
            return ["\(to.formatted(.dateTime.weekday(.wide))) already holds \(what.lowercased()); both would sit on that day"]
        default:
            return []
        }
    }

    static func explanation(_ intent: CoachIntent, profile: UserProfile) -> String {
        switch intent {
        case .changeDays:
            return "The week is rebuilt from today around the days you can train. Completed sessions and your paces stay; the weekly ramp is still governed, so more days never means a jump in load. This week's adjustments are not carried into the rebuilt weeks."
        case .changeSessionLength:
            return "Your usual session time helps size the rebuilt weeks. Current mileage can call for longer sessions; check the preview, and long runs are planned separately."
        case .changeEquipment:
            return "Strength days are rebuilt with exercises you can actually do. Running days are rebuilt the same way they were."
        case .changeGoal:
            return "The upcoming weeks are rebuilt toward the new goal from today. Nothing you have done is lost."
        case .changeRace:
            return "The block is re-pointed at the race: build, peak and taper land on the new date. The outlook above is the honest read of that runway."
        case .moveSession:
            return "One session moves; the rest of the week stands."
        case .skipSession:
            return "The session is cleared, not marked missed. Rest days count; your streak holds."
        case .easeWeek:
            return "Every remaining session trims about 15%, and hard runs and long runs become easy runs for the rest of the plan. This uses the one structural change the week allows, so the coach will not stack another on top."
        case .easeThisWeek:
            return "Only the next seven days change: about 15% lighter, hard sessions become easy, the long run keeps its place. Next week picks back up as planned. Your word about your week is enough; it still counts as this week's change."
        case .bumpLoad:
            return "Upcoming sessions rise about 10%. The coach only offers this when your completed load has earned it, and it counts as the week's structural change."
        case .easePaces:
            return "Future targets ease about 2%, and the pace-based fitness estimate adjusts with them. Past runs stay unchanged; sharpening evidence starts fresh."
        case .injuryReport:
            return "Training around a sore spot removes what aggravates it and gates the way back. Never a diagnosis; anything sharp, swollen or worsening is a question for a professional."
        case .pausePlan:
            return "Sessions with room to move shift later. Fixed races, occupied dates and recovery space stay protected. The preview identifies sessions that must stay on their dates."
        case .resumePlan:
            return "Ends the pause and moves eligible sessions earlier where there is room. Fixed races, recovery space and dates you changed yourself stay protected. Check your next session before returning."
        case .renewBlock:
            return profile.plan?.raceDate == nil
                ? "This block closes and the next is built from what you actually ran in the last four weeks, not from what was planned. The block review lands in your inbox."
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
        var estimate = false
        switch intent {
        case .changeDays(let days, _): if let days { after.daysPerWeek = days }
        case .changeRace(let distanceM, let date, let goalTime):
            after.goal = .raceDistance; after.raceDistanceM = distanceM; after.raceDate = date
            if let goalTime { after.goalFinishTimeS = goalTime }
        case .changeGoal(let goal): after.goal = goal
        case .pausePlan(let days):
            // Race day stays where it is; the training runway loses the paused days. Modelled as
            // a shorter runway, which is an estimate, and said so.
            guard before.isRace, let date = before.raceDate else { return nil }
            after.raceDate = calendar.date(byAdding: .day, value: -days, to: date)
            estimate = true
        default: return nil
        }
        guard before.isRace || after.isRace else { return nil }
        let a = PlanLifecycleService.feasibility(for: before, profile: profile, today: today, calendar: calendar)
        let b = PlanLifecycleService.feasibility(for: after, profile: profile, today: today, calendar: calendar)
        guard a.verdict != b.verdict else { return nil }
        return "\(estimate ? "Outlook, roughly" : "Outlook"): \(word(a.verdict)) → \(word(b.verdict))"
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
        if let reason = IllnessResponse.blocked(intent, profile: profile) { return reason }
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
        let nothingOpen = "There is nothing upcoming for this to change."
        let paused = plan.pausedUntil.map { calendar.startOfDay(for: $0) > calendar.startOfDay(for: today) } ?? false
        switch intent {
        case .easeWeek:
            guard affected(intent, plan: plan, today: today, calendar: calendar) != nil else { return nothingOpen }
            guard CoachActions.canAdaptLoad(plan, today: today, calendar: calendar) else {
                return "The plan was already reshaped this week. One structural change a week keeps adaptation honest; this is available again \(nextAllowed())."
            }
        case .easeThisWeek:
            guard affected(intent, plan: plan, today: today, calendar: calendar) != nil else {
                return "There is nothing open in the next seven days to lighten."
            }
            if PlanCoaching.weekAlreadyEased(plan, from: today, calendar: calendar) {
                return "This week is already lighter (eased once, or a rebuild week after time away). One ease a week keeps the drop honest; move a session or pause if you need more room."
            }
        case .bumpLoad:
            guard affected(intent, plan: plan, today: today, calendar: calendar) != nil else { return nothingOpen }
            guard CoachActions.canAdaptLoad(plan, today: today, calendar: calendar) else {
                return "The plan was already reshaped this week. One structural change a week keeps adaptation honest; this is available again \(nextAllowed())."
            }
            let insights = ProgressInsights(workouts: workouts, now: today, calendar: calendar)
            guard insights.recommendation == .increase else {
                return "Your recent completed training does not support a load increase yet. Keep following the plan; the coach offers the bump when your finished sessions have earned it."
            }
        case .easePaces:
            guard affected(intent, plan: plan, today: today, calendar: calendar) != nil else {
                return "There are no upcoming paced runs to ease."
            }
            guard PlanCoaching.canEasePaces(plan, today: today, calendar: calendar) else {
                return "Paces were eased less than a week ago. Let a few sessions land at the new targets first."
            }
        case .pausePlan:
            if paused, let until = plan.pausedUntil {
                return "The plan is already paused until \(until.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))). Resume it first."
            }
            guard affected(intent, plan: plan, today: today, calendar: calendar) != nil else { return nothingOpen }
        case .resumePlan:
            guard paused else { return "The plan is not paused." }
        case .changeEquipment:
            guard profile.disciplines.contains(Discipline.strength.rawValue) else {
                return "There are no strength days on this plan, so equipment changes nothing here. Turn strength on in Plan settings first."
            }
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
    /// against a plan that has since changed is recomputed and returned instead of applied. An
    /// applied change becomes the only undo point in the app: every older chat undo is retired,
    /// because it describes a plan that no longer exists.
    static func apply(_ proposal: Proposal, profile: UserProfile, workouts: [Workout],
                      notifications: NotificationServing, today: Date = Date(),
                      distanceUnit: DistanceUnit = .metric, in context: ModelContext,
                      calendar: Calendar = .current) -> ApplyResult {
        let current = signature(of: profile.plan, calendar: calendar)
        guard current == proposal.signature,
              contextSignature(profile: profile, workouts: workouts, today: today,
                               distanceUnit: distanceUnit, calendar: calendar) == proposal.contextSignature else {
            return .stale(self.proposal(proposal.intent, title: proposal.title, request: proposal.request,
                                        profile: profile, workouts: workouts, today: today,
                                        distanceUnit: distanceUnit, in: context, calendar: calendar))
        }
        if let blocked = blocked(proposal.intent, profile: profile, workouts: workouts, today: today, calendar: calendar) {
            return .declined(blocked)
        }
        let undo = CoachUndo.capture(profile)
        do {
            let receipt: CoachActions.Receipt = try PlanMutation.perform(in: context) {
                switch CoachActions.apply(proposal.intent, profile: profile, workouts: workouts, today: today,
                                          in: context, calendar: calendar) {
                case .applied(let receipt):
                    CoachUndo.makeSoleUndoPoint(in: context)
                    return receipt
                case .declined(let reason): throw ApplyFailure.declined(reason)
                case .navigate: throw ApplyFailure.declined("That action opens a page instead of changing your plan.")
                }
            }
            propagate(profile: profile, workouts: workouts, notifications: notifications, calendar: calendar)
            return .applied(receipt, undo: undo)
        } catch ApplyFailure.declined(let reason) { return .declined(reason) }
        catch { return .declined("Your change could not be saved. Your previous plan is still here. Please try again.") }
    }

    private enum ApplyFailure: Error { case declined(String) }

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

    /// Reminders, the widget and the wrist follow the plan (the existing hooks, nothing new). The
    /// widget's full-history stats run a beat later, off the frame the athlete is looking at.
    static func propagate(profile: UserProfile, workouts: [Workout], notifications: NotificationServing,
                          calendar: Calendar = .current) {
        notifications.schedulePlannedReminders(profile.plan)
        PhoneWatchSync.shared.scheduleRefresh()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            // Half a second later the profile may be gone (an account wipe, a torn-down test
            // container): reading a relationship on it then traps inside SwiftData.
            guard !profile.isDeleted, profile.modelContext != nil else { return }
            WidgetBridge.publish(profile: profile, workouts: workouts,
                                 stats: ProfileStats(workouts: workouts, plan: profile.plan, calendar: calendar))
        }
    }
}

/// A library replacement keeps the scheduled session's identity, date and dose envelope.
/// It cannot rewrite history, replace a fixed race, or turn an easy slot into quality work.
@MainActor
enum PlanSessionReplacement {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    static func blocked(_ session: PlannedSession, by prescription: WorkoutLibrary.Prescription,
                        in plan: TrainingPlan) -> String? {
        guard plan.sessions.contains(where: { $0.id == session.id }),
              session.status == .planned || session.status == .moved,
              session.completedWorkout == nil, session.discipline == .running,
              session.runType != .race else { return "Only an upcoming training run can be replaced." }
        if session.runType == .long && prescription.runType != .long {
            return "Keep this week's long-run slot. Choose a long-run workout."
        }
        if prescription.runType == .long && session.runType != .long {
            return "Choose the existing long-run slot for this workout."
        }
        if prescription.runType.isQuality && session.runType?.isQuality != true && session.runType != .long {
            return "Keep this easy day easy. Choose a quality session to replace with this workout."
        }
        return nil
    }

    static func prescription(_ proposed: WorkoutLibrary.Prescription, replacing session: PlannedSession,
                             plan: TrainingPlan, profile: UserProfile?, unit: DistanceUnit) -> WorkoutLibrary.Prescription {
        var value = proposed
        if let distance = session.targetDistanceM { value.targetDistanceM = min(value.targetDistanceM ?? distance, distance) }
        if let duration = session.targetDurationS { value.targetDurationS = min(value.targetDurationS ?? duration, duration) }
        return value.fitting(plan: plan, profile: profile, unit: unit)
    }

    static func apply(_ proposed: WorkoutLibrary.Prescription, replacing session: PlannedSession,
                      plan: TrainingPlan, profile: UserProfile?, unit: DistanceUnit, in context: ModelContext,
                      commit: (ModelContext) throws -> Void = { try $0.save() }) throws {
        try PlanMutation.perform(in: context, commit: commit) {
            if let reason = blocked(session, by: proposed, in: plan) { throw Failure(message: reason) }
            let rx = prescription(proposed, replacing: session, plan: plan, profile: profile, unit: unit)
            session.runType = rx.runType; session.intervals = rx.intervals
            session.targetDistanceM = rx.targetDistanceM; session.targetDurationS = rx.targetDurationS
            session.targetPaceSPerKm = rx.targetPaceSPerKm
            session.rationale = "Replaced within this session's training budget. " + rx.rationale
            _ = try RunningPlanBackfill.prepareAfterLegacyPlanMutation(in: context)
        }
    }
}
