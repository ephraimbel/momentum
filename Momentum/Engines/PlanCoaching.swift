import Foundation
import SwiftData

/// Plan queries + deterministic, no-shame adaptation (PRD §4.7, §9.4). Missed sessions **move**;
/// there is never a red "failed" state.
@MainActor
enum PlanCoaching {

    static func todaySessions(_ plan: TrainingPlan?, on date: Date, calendar: Calendar = .current) -> [PlannedSession] {
        guard let plan else { return [] }
        let day = calendar.startOfDay(for: date)
        return plan.sessions
            .filter { calendar.isDate($0.date, inSameDayAs: day) }
            .sorted { $0.date < $1.date }
    }

    static func weekSessions(_ plan: TrainingPlan?, containing date: Date, calendar: Calendar = .current) -> [PlannedSession] {
        guard let plan, let interval = calendar.dateInterval(of: .weekOfYear, for: date) else { return [] }
        return plan.sessions
            .filter { interval.contains($0.date) }
            .sorted { $0.date < $1.date }
    }

    /// Link a finished workout to its planned session.
    static func markComplete(_ session: PlannedSession, with workout: Workout, in context: ModelContext) {
        session.completedWorkout = workout
        session.status = .completed
        workout.plannedSession = session
        try? context.save()
    }

    /// Manual check-off from the Plan page (no workout attached). Toggling off unlinks any credited
    /// workout so the session reads as open again. No-shame: this never creates a "failed" state.
    static func setCompletion(_ session: PlannedSession, done: Bool, in context: ModelContext) {
        session.status = done ? .completed : .planned
        if done {
            session.rationale = nil          // clear any "moved" note — it's done now
        } else {
            session.completedWorkout?.plannedSession = nil
            session.completedWorkout = nil
        }
        try? context.save()
    }

    /// Move a session to another day from the Plan page. A manual move clears the auto-"moved" note so
    /// it reads as a deliberate plan, not a slipped one.
    static func reschedule(_ session: PlannedSession, to date: Date, in context: ModelContext,
                           calendar: Calendar = .current) {
        session.date = calendar.startOfDay(for: date)
        if session.status == .moved { session.status = .planned }
        session.rationale = nil
        try? context.save()
    }

    /// Credit a free workout toward today's matching planned session, if still open. Magnitude-aware
    /// (`PlanCredit`): the workout must plausibly *fulfill* the prescription — a short recovery jog
    /// leaves the day's long run open instead of silently completing it.
    @discardableResult
    static func creditWorkout(_ workout: Workout, to plan: TrainingPlan?, in context: ModelContext,
                              calendar: Calendar = .current) -> PlannedSession? {
        guard let plan else { return nil }
        let open = todaySessions(plan, on: workout.startedAt, calendar: calendar).filter {
            $0.status == .planned && $0.completedWorkout == nil && $0.discipline == workout.type.discipline
        }
        guard !open.isEmpty else { return nil }
        let candidates = open.map {
            PlanCredit.Candidate(targetDistanceM: $0.targetDistanceM, targetDurationS: $0.targetDurationS)
        }
        guard let idx = PlanCredit.bestMatch(distanceM: workout.gps?.distanceM ?? 0,
                                             durationS: workout.durationS,
                                             candidates: candidates) else { return nil }
        markComplete(open[idx], with: workout, in: context)
        return open[idx]
    }

    /// Move past, still-planned sessions onto the next open day — never a red miss (§9.4).
    static func reconcileMissed(_ plan: TrainingPlan?, today: Date, in context: ModelContext,
                                calendar: Calendar = .current) {
        guard let plan else { return }
        let todayStart = calendar.startOfDay(for: today)
        var occupied = Set(plan.sessions.map { calendar.startOfDay(for: $0.date) })
        var changed = false

        for session in plan.sessions
            where session.status == .planned
            && session.completedWorkout == nil
            && calendar.startOfDay(for: session.date) < todayStart {

            var moved = false
            for delta in 0..<7 {
                guard let cand = calendar.date(byAdding: .day, value: delta, to: todayStart) else { continue }
                if !occupied.contains(cand) {
                    occupied.remove(calendar.startOfDay(for: session.date))
                    session.date = cand
                    session.status = .moved
                    session.rationale = "Shifted to \(cand.formatted(.dateTime.weekday(.wide))) — still on track."
                    occupied.insert(cand)
                    moved = true
                    changed = true
                    break
                }
            }
            if !moved {
                session.status = .moved
                session.rationale = "Rolled forward — no streak lost."
                changed = true
            }
        }
        if changed { try? context.save() }
    }

    /// Apply the Progress coach's recommendation to **future** planned sessions (PRD §4.7, §9).
    /// Adjusts only sessions dated today-or-later and still `.planned` — completed work and history
    /// are never touched. Deterministic: rules reshape the plan, the coach only narrates it.
    /// Returns the number of sessions changed (0 ⇒ nothing upcoming, or an advisory-only rec).
    ///
    /// Note: the recommendation is derived from *completed* load, not from the plan, so applying
    /// the same rec repeatedly compounds. The UI confirms once and disables re-tapping per render.
    @discardableResult
    static func apply(_ rec: ProgressInsights.Recommendation, to plan: TrainingPlan?,
                      from date: Date = Date(), in context: ModelContext,
                      calendar: Calendar = .current) -> Int {
        guard let plan else { return 0 }
        let todayStart = calendar.startOfDay(for: date)
        // Injury-converted sessions are off-limits: softening one would corrupt the swap (easy-run
        // fields on a cycling session) and overwrite the marker `resume` needs to restore it.
        let future = plan.sessions
            .filter { $0.status == .planned && $0.completedWorkout == nil
                      && calendar.startOfDay(for: $0.date) >= todayStart
                      && !($0.rationale?.hasPrefix(InjuryResponse.marker) ?? false) }
            .sorted { $0.date < $1.date }
        guard !future.isEmpty else { return 0 }
        let p5k = plan.p5kSPerKm

        // Scale a cardio session's targets and soften any hard quality work to easy.
        func soften(_ s: PlannedSession, factor: Double, note: String) {
            if let d = s.targetDistanceM { s.targetDistanceM = (d * factor).rounded() }
            if let dur = s.targetDurationS { s.targetDurationS = (dur * factor).rounded() }
            if let rt = s.runType, rt.isQuality || rt == .long {
                s.runType = .easy
                s.intervals = nil
                s.targetPaceSPerKm = PlanEngine.pace(.easy, p5k: p5k)
            }
            s.rationale = note
        }

        switch rec {
        case .increase:
            for s in future {
                if let d = s.targetDistanceM { s.targetDistanceM = (d * 1.1).rounded() }
                if let dur = s.targetDurationS { s.targetDurationS = (dur * 1.1).rounded() }
                for pe in s.strengthTargets { pe.targetSets = min(6, pe.targetSets + 1) }
                s.rationale = "Nudged up ~10% — your load says you've earned more."
            }
        case .ease:
            for s in future {
                soften(s, factor: 0.85, note: "Eased ~15% to absorb your recent load.")
                for pe in s.strengthTargets { pe.targetSets = max(2, pe.targetSets - 1) }
            }
        case .rest:
            for s in future {
                soften(s, factor: 0.8, note: "Pulled back to bank recovery.")
                for pe in s.strengthTargets { pe.targetSets = max(2, pe.targetSets - 1) }
            }
            // Make the very next session a true recovery day.
            let next = future[0]
            if next.strengthTargets.isEmpty {
                next.runType = .recovery
                next.intervals = nil
                next.targetDistanceM = min(next.targetDistanceM ?? 3200, 3200)
                next.targetPaceSPerKm = PlanEngine.pace(.recovery, p5k: p5k)
            } else {
                for pe in next.strengthTargets { pe.targetSets = 2 }
            }
            next.rationale = "Recovery day — rest is where the gains land."
        case .hold, .start:
            return 0   // advisory only — nothing to change
        }
        plan.lastAdaptedAt = date   // record any adaptation so auto-adapt can't stack on it (≤1/week)
        try? context.save()
        return future.count
    }

    /// The outcome of a pace recalibration, so the caller can narrate/notify it ("you're getting faster").
    struct Recalibration: Sendable, Equatable {
        let oldP5kSPerKm: Double
        let newP5kSPerKm: Double
        let sessionsUpdated: Int
    }

    /// Learn from a finished run (PRD §9, the adaptive half): if a genuine effort implies a faster 5k
    /// than the plan currently assumes, lower the athlete's `p5kSPerKm` and re-derive **future**
    /// running paces. Conservative on purpose:
    ///  • only quality/hard efforts count (never recalibrate off an easy/long run, which is slow by design),
    ///  • paces only ever get *faster* from a single run (a bad day never slows you down — no-shame),
    ///  • a single run moves p5k at most ~3%, with a sane floor.
    /// Returns the change if one was made (else `nil`). Deterministic + bounded; the AI only narrates it.
    @discardableResult
    static func recalibratePaces(from workout: Workout, plan: TrainingPlan?, today: Date = Date(),
                                 in context: ModelContext, calendar: Calendar = .current) -> Recalibration? {
        guard let plan, workout.type.discipline == .running, let gps = workout.gps else { return nil }
        let dist = gps.distanceM, time = workout.durationS, current = plan.p5kSPerKm
        // Need a meaningful distance to extrapolate a 5k from — Riegel off a 400 m rep is noise.
        guard dist >= 2000, time > 0, current > 0 else { return nil }

        // Fitness signal only: a planned quality session, a hard reported effort, or a pace sustained
        // at roughly 5k effort or faster. An easy/long run (run deliberately slow) never qualifies.
        let avgPaceSPerKm = time / (dist / 1000)
        let isQualityPlanned = (workout.plannedSession?.runType).map { [.tempo, .intervals, .race].contains($0) } ?? false
        let isHardEffort = (workout.perceivedEffort ?? 0) >= 7
        let ranNearThreshold = avgPaceSPerKm <= current + 15
        guard isQualityPlanned || isHardEffort || ranNearThreshold else { return nil }

        // Treat the run as a 5k-equivalent (Riegel). Most efforts aren't maximal, so this *under*-states
        // true fitness — beating the stored p5k is therefore a strong, conservative signal.
        let equivalent = PlanEngine.riegelP5k(distanceM: dist, timeS: time)
        guard equivalent < current else { return nil }       // only get faster from a single run
        let bounded = max(equivalent, current * 0.97, 150)   // ≤3%/update; sane floor
        guard current - bounded >= 0.5 else { return nil }   // ignore sub-second-per-km noise

        plan.p5kSPerKm = bounded

        // Re-derive paces on future, still-planned running sessions (today's history is never touched).
        let todayStart = calendar.startOfDay(for: today)
        var updated = 0
        for s in plan.sessions
            where s.status == .planned && s.completedWorkout == nil
                  && calendar.startOfDay(for: s.date) >= todayStart {
            guard let runType = s.runType, (s.targetPaceSPerKm ?? 0) > 0 else { continue }
            s.targetPaceSPerKm = PlanEngine.pace(runType, p5k: bounded)
            updated += 1
        }
        try? context.save()
        if updated > 0 {
            let delta = Int((current - bounded).rounded())
            CoachingEvent.record(kind: .recalibrate, headline: "Your paces got faster",
                                 detail: "That run showed real fitness, so I sharpened your target paces by about \(delta) s/km. You've earned it.",
                                 on: today, in: context, calendar: calendar)
        }
        return Recalibration(oldP5kSPerKm: current, newP5kSPerKm: bounded, sessionsUpdated: updated)
    }

    /// The consent-required inverse of `recalibratePaces`, offered by the session pace review when a
    /// guided run's targets consistently ran hot ("Review"): ease the plan's assumed 5k a small
    /// bounded step and re-derive **future** planned running paces so the prescription stays honest.
    /// Never touches history; bounded to +2% per approval (mirrors recalibrate's ≤3% in the other
    /// direction) so a tap can't lurch the plan. No-shame: this is "make the targets fit", never a
    /// demotion. Returns the number of future sessions updated (0 ⇒ nothing upcoming to change).
    @discardableResult
    static func easeQualityPaces(_ plan: TrainingPlan?, from date: Date = Date(),
                                 in context: ModelContext, calendar: Calendar = .current) -> Int {
        guard let plan, plan.p5kSPerKm > 0 else { return 0 }
        let newP5k = plan.p5kSPerKm * 1.02
        let todayStart = calendar.startOfDay(for: date)
        var updated = 0
        for s in plan.sessions
            where s.status == .planned && s.completedWorkout == nil
                  && calendar.startOfDay(for: s.date) >= todayStart {
            guard let runType = s.runType, (s.targetPaceSPerKm ?? 0) > 0 else { continue }
            s.targetPaceSPerKm = PlanEngine.pace(runType, p5k: newP5k)
            updated += 1
        }
        guard updated > 0 else { return 0 }   // nothing to change → don't move p5k either
        let delta = Int((newP5k - plan.p5kSPerKm).rounded())
        plan.p5kSPerKm = newP5k
        try? context.save()
        CoachingEvent.record(kind: .recalibrate, headline: "Eased your target paces",
                             detail: "You asked for honest targets, so I eased your paces by about \(max(1, delta)) s/km. The reps will land the way they should.",
                             on: date, in: context, calendar: calendar)
        return updated
    }

    /// Automatically protect the athlete from overreaching (PRD §9.4) — the closed-loop half of
    /// `apply`. Reads the ACWR recommendation from *completed* load and, **only when it says ease or
    /// rest**, applies it to upcoming sessions. Deliberately never auto-*increases* load (raising
    /// volume without consent is the unsafe direction — that stays a manual/coach-proposed action).
    ///
    /// Gated to **at most once per 7 days** via `plan.lastAdaptedAt`, which is the safeguard against
    /// the compounding that `apply`'s doc warns about (the rec is from completed load, so re-applying
    /// it back-to-back would spiral). Returns the rec it applied, or `nil` if nothing changed.
    @discardableResult
    static func autoAdapt(_ plan: TrainingPlan?, workouts: [Workout], today: Date = Date(),
                          in context: ModelContext, calendar: Calendar = .current) -> ProgressInsights.Recommendation? {
        guard let plan else { return nil }
        if let last = plan.lastAdaptedAt,
           (calendar.dateComponents([.day], from: last, to: today).day ?? .max) < 7 { return nil }

        let rec = ProgressInsights(workouts: workouts, now: today, calendar: calendar).recommendation
        guard rec == .ease || rec == .rest else { return nil }   // protective directions only
        guard apply(rec, to: plan, from: today, in: context, calendar: calendar) > 0 else { return nil }
        let (headline, detail): (String, String) = rec == .rest
            ? ("Recovery inserted", "Your training load's been climbing, so your next session is now a recovery day. Rest is where it sticks.")
            : ("Eased your week", "Your recent load spiked, so I trimmed this week's volume to keep you fresh and healthy.")
        CoachingEvent.record(kind: rec == .rest ? .recover : .ease, headline: headline, detail: detail,
                             on: today, in: context, calendar: calendar)
        return rec   // `apply` already recorded `lastAdaptedAt` + saved
    }

    /// Post-run RPE → adaptation — the *subjective* half of the closed loop (Runna's RPE prompt, but
    /// automatic). Called once the athlete rates a run: if it felt far harder than prescribed, ease the
    /// block; if an easy day felt brutal, insert recovery. Never auto-*raises* load (headroom is
    /// informational). Shares `autoAdapt`'s ≤1/week gate so subjective + objective easing never stack.
    /// Returns a no-shame note when it changed the plan.
    @discardableResult
    static func adaptToEffort(_ workout: Workout, plan: TrainingPlan?, today: Date = Date(),
                              in context: ModelContext, calendar: Calendar = .current) -> (headline: String, detail: String)? {
        guard let plan, workout.type.discipline == .running else { return nil }
        let outcome = EffortAdaptation.judge(rpe: workout.perceivedEffort, runType: workout.plannedSession?.runType)
        let rec: ProgressInsights.Recommendation
        switch outcome {
        case .ease: rec = .ease
        case .recover: rec = .rest
        case .none, .headroom: return nil
        }
        if let last = plan.lastAdaptedAt,
           (calendar.dateComponents([.day], from: last, to: today).day ?? .max) < 7 { return nil }
        guard apply(rec, to: plan, from: today, in: context, calendar: calendar) > 0 else { return nil }
        let note = EffortAdaptation.note(for: outcome, runType: workout.plannedSession?.runType,
                                         rpe: workout.perceivedEffort)
        if let note { CoachingEvent.record(kind: outcome == .recover ? .recover : .ease,
                                           headline: note.headline, detail: note.detail, on: today, in: context) }
        return note
    }

    /// A bounded plan change the athlete can opt into on confirm — the consent-required half of the
    /// adaptive loop (PRD §9.4). `autoAdapt` applies the *protective* directions (ease/rest) on its
    /// own; raising load is the one direction that must never happen without a tap, so it's surfaced
    /// here for "Apply." The numbers are always the engine's; the AI (when present) only narrates the
    /// same decision in the read card.
    struct Proposal: Sendable, Equatable {
        let rec: ProgressInsights.Recommendation
        let headline: String
        let detail: String
        let sessionsAffected: Int
    }

    /// Offer an opt-in load increase when *completed* load (ACWR) says the athlete is under-loaded and
    /// has earned more — but only if nothing was adapted in the last 7 days (mirrors `autoAdapt`'s
    /// safeguard, so a proposal can't stack on an auto-ease) and there are future sessions to change.
    /// Returns `nil` when there's nothing to offer. Deterministic — this is what `apply` would do.
    static func proposeAdjustment(_ plan: TrainingPlan?, workouts: [Workout], today: Date = Date(),
                                  calendar: Calendar = .current) -> Proposal? {
        guard let plan else { return nil }
        if let last = plan.lastAdaptedAt,
           (calendar.dateComponents([.day], from: last, to: today).day ?? .max) < 7 { return nil }
        // Only the consent-required direction. ease/rest are auto-applied; hold/start are advisory.
        guard ProgressInsights(workouts: workouts, now: today, calendar: calendar).recommendation == .increase
        else { return nil }
        let todayStart = calendar.startOfDay(for: today)
        let future = plan.sessions.filter {
            $0.status == .planned && $0.completedWorkout == nil
            && calendar.startOfDay(for: $0.date) >= todayStart
        }
        guard !future.isEmpty else { return nil }
        return Proposal(rec: .increase,
                        headline: "You've earned more",
                        detail: "Your load's been light and well-absorbed — bump next week about 10%?",
                        sessionsAffected: future.count)
    }

    /// Human pre-session brief (PRD §4.7), deterministic; the AI may rewrite it later.
    static func brief(for session: PlannedSession, distanceUnit: DistanceUnit = .auto) -> String {
        if session.discipline == .strength {
            let label = session.strengthTargets.count >= 5 ? "Full body" : "Strength"
            let n = session.strengthTargets.count
            return n > 0 ? "\(label) — \(n) exercise\(n == 1 ? "" : "s")" : "Strength session"
        }
        // Timed sports (swim, row, yoga, tennis…) — no distance/pace; show the sport + any duration.
        if let wt = session.workoutType, wt.isTimed {
            if let dur = session.targetDurationS, dur > 0 { return "\(wt.title) \(Formatters.duration(s: dur))" }
            return wt.title
        }
        // GPS: a run keeps its quality label (Easy/Tempo/Long); ride/walk/etc. use the sport name.
        let label: String = {
            if let wt = session.workoutType, wt != .run { return wt.title }
            return session.runType?.rawValue.capitalized ?? "Session"
        }()
        let dist = session.targetDistanceM.map { Formatters.distance(meters: $0, unit: distanceUnit) } ?? ""
        let base = "\(label) \(dist)".trimmingCharacters(in: .whitespaces)
        if let pace = session.targetPaceSPerKm, pace > 0 {
            return "\(base) ~\(Formatters.pace(secPerKm: pace, unit: distanceUnit))"
        }
        return base
    }

    /// The SF Symbol for a session — the precise sport when chosen, else the discipline glyph.
    static func icon(for session: PlannedSession) -> String {
        if let wt = session.workoutType { return wt.systemImage }
        switch session.discipline {
        case .running: return "figure.run"
        case .cycling: return "bicycle"
        case .walking: return "figure.walk"
        case .strength: return "dumbbell.fill"
        }
    }
}
