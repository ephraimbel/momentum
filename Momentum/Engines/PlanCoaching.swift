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
        // `.moved` counts as open: reconcileMissed rolls every past-due session forward as .moved
        // (routine after any slipped day), and the athlete who then does the work must get the
        // credit — markComplete already accepts moved sessions.
        let open = todaySessions(plan, on: workout.startedAt, calendar: calendar).filter {
            ($0.status == .planned || $0.status == .moved)
                && $0.completedWorkout == nil && $0.discipline == workout.type.discipline
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
    /// A real absence (≥3 past-due sessions at once) additionally triggers the **rebuild week**:
    /// the coming week's sessions are scaled to ~70% and hard work softens to easy, because the
    /// evidence on returning from time away says restore 50–75% of lost volume — never cram it back.
    /// Naturally idempotent: once reconciled, nothing is past-due, so a second pass can't re-shrink.
    static func reconcileMissed(_ plan: TrainingPlan?, today: Date, in context: ModelContext,
                                calendar: Calendar = .current) {
        guard let plan else { return }
        // While paused, sessions were deliberately shifted out — rolling them "forward" again would
        // undo the pause. Stand down until the window passes (resume clears it early).
        if let paused = plan.pausedUntil, calendar.startOfDay(for: today) < calendar.startOfDay(for: paused) { return }
        let todayStart = calendar.startOfDay(for: today)
        var occupied = Set(plan.sessions.map { calendar.startOfDay(for: $0.date) })
        var changed = false
        var movedCount = 0

        for session in plan.sessions
            where session.status == .planned
            && session.completedWorkout == nil
            && session.runType != .race        // a missed race never auto-reschedules — that's the athlete's call
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
            movedCount += 1
        }

        // Rebuild week after a real absence (PRD §9.4: ≥3 misses → the week restarts at ~70%).
        // Shrinking load is a structural change, so it shares the ≤1-change/week `lastAdaptedAt` gate
        // — never stack a rebuild-week on top of another ease/bump (or vice-versa) in the same week.
        let recentlyAdapted = plan.lastAdaptedAt.map {
            (calendar.dateComponents([.day], from: $0, to: today).day ?? .max) < 7
        } ?? false
        if movedCount >= 3, !recentlyAdapted, let horizon = calendar.date(byAdding: .day, value: 7, to: todayStart) {
            let unit = displayUnit(in: context)
            // Comeback paces: time away costs fitness, so the assumed 5k eases ~2% BEFORE the week
            // is softened (the converted easy sessions then price at the eased fitness). Recalibration
            // earns it back the first time a quality run proves the old level — paces only ever
            // tighten from evidence, so this can't spiral downward.
            if plan.p5kSPerKm > 0 { plan.p5kSPerKm *= 1.02 }
            for s in plan.sessions
                where s.status != .completed && s.completedWorkout == nil && s.runType != .race
                      && calendar.startOfDay(for: s.date) >= todayStart && s.date < horizon {
                if let d = s.targetDistanceM { s.targetDistanceM = RunRounding.snap(meters: d * 0.7, unit: unit) }
                if let dur = s.targetDurationS { s.targetDurationS = (dur * 0.7).rounded() }
                if let rt = s.runType, rt.isQuality {
                    s.runType = .easy
                    s.intervals = nil
                }
                for pe in s.strengthTargets { pe.targetSets = max(1, Int((Double(pe.targetSets) * 0.7).rounded())) }
                s.rationale = "Rebuild week — easing back in at ~70% after time away. The plan meets you here."
            }
            // Re-derive every future planned pace at the eased fitness (this week's converted easies
            // AND the weeks beyond — a comeback's interval day shouldn't demand last month's legs).
            for s in plan.sessions
                where s.status != .completed && s.completedWorkout == nil
                      && calendar.startOfDay(for: s.date) >= todayStart {
                guard let rt = s.runType, (s.targetPaceSPerKm ?? 0) > 0 else { continue }
                s.targetPaceSPerKm = PlanEngine.sessionPace(rt, p5k: plan.p5kSPerKm, intervals: s.intervals,
                                                            raceDistanceM: goalRaceDistanceM(in: context))
            }
            plan.lastAdaptedAt = today   // arm the weekly gate so no other ease/bump stacks on this
            CoachingEvent.record(kind: .ease, headline: "Welcome back — rebuild week",
                                 detail: "You were away a bit, so this week restarts at about 70% and your paces ease a touch. One good session earns them right back.",
                                 on: today, in: context, calendar: calendar)
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
        // Race day is untouchable too — you don't run 110% (or 85%) of a marathon; adaptations
        // shape the training around it, never the race itself.
        let future = plan.sessions
            .filter { $0.status == .planned && $0.completedWorkout == nil
                      && calendar.startOfDay(for: $0.date) >= todayStart
                      && $0.runType != .race
                      && !($0.rationale?.hasPrefix(InjuryResponse.marker) ?? false) }
            .sorted { $0.date < $1.date }
        guard !future.isEmpty else { return 0 }
        let p5k = plan.p5kSPerKm
        let unit = displayUnit(in: context)   // keep rescaled prescriptions clean

        // Scale a cardio session's targets and soften any hard quality work to easy.
        func soften(_ s: PlannedSession, factor: Double, note: String) {
            if let d = s.targetDistanceM { s.targetDistanceM = RunRounding.snap(meters: d * factor, unit: unit) }
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
                if let d = s.targetDistanceM { s.targetDistanceM = RunRounding.snap(meters: d * 1.1, unit: unit) }
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
                next.targetDistanceM = RunRounding.snap(meters: min(next.targetDistanceM ?? 3200, 3200), unit: unit)
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

    /// The goal race distance for "@ race pace" re-derivation — lives on the profile, not the plan.
    private static func goalRaceDistanceM(in context: ModelContext) -> Double? {
        (try? context.fetch(FetchDescriptor<UserProfile>()))?.first?.raceDistanceM
    }

    /// The athlete's resolved display unit — so adaptations keep prescriptions clean (`RunRounding`)
    /// after scaling. Internal so the sibling recovery/injury engines reuse it.
    static func displayUnit(in context: ModelContext) -> DistanceUnit {
        ((try? context.fetch(FetchDescriptor<UserProfile>()))?.first?.distanceUnit)
            .flatMap(DistanceUnit.init(rawValue:))?.resolved() ?? .metric
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
            s.targetPaceSPerKm = PlanEngine.sessionPace(runType, p5k: bounded, intervals: s.intervals,
                                                        raceDistanceM: goalRaceDistanceM(in: context))
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
            s.targetPaceSPerKm = PlanEngine.sessionPace(runType, p5k: newP5k, intervals: s.intervals,
                                                        raceDistanceM: goalRaceDistanceM(in: context))
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

    /// Autoregulated strength deload (PRD §9.2's plan-level half): when the last two strength
    /// sessions were sustained near-max effort (`StrengthSessionEngine.rpeCreep`), cut the coming
    /// week's still-open strength prescriptions ~40% in sets so the work absorbs. Shares the
    /// ≤1-change/week `lastAdaptedAt` gate with every other structural adaptation; no-shame, never
    /// touches history or running sessions. Returns the note when it changed the plan.
    @discardableResult
    static func easeStrengthOnRPECreep(_ plan: TrainingPlan?, workouts: [Workout], today: Date = Date(),
                                       in context: ModelContext, calendar: Calendar = .current)
        -> (headline: String, detail: String)? {
        guard let plan else { return nil }
        if let last = plan.lastAdaptedAt,
           (calendar.dateComponents([.day], from: last, to: today).day ?? .max) < 7 { return nil }

        // The two most recent strength sessions' rated working-set RPEs, newest first.
        let sessionRPEs: [[Double]] = workouts
            .filter { $0.type.isStrengthStyle && $0.strength != nil }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(2)
            .map { w in
                (w.strength?.exercises ?? []).flatMap(\.sets)
                    .filter { $0.isComplete && $0.type == .working }
                    .compactMap(\.rpe)
            }
        guard StrengthSessionEngine.rpeCreep(recentSessionRPEs: sessionRPEs) else { return nil }

        // ~40% fewer sets on the coming week's open strength days (PRD §9.2 deload).
        let todayStart = calendar.startOfDay(for: today)
        guard let horizon = calendar.date(byAdding: .day, value: 7, to: todayStart) else { return nil }
        var changed = 0
        for s in plan.sessions
            where s.status == .planned && s.completedWorkout == nil && !s.strengthTargets.isEmpty
                  && calendar.startOfDay(for: s.date) >= todayStart && s.date < horizon {
            for pe in s.strengthTargets { pe.targetSets = max(1, Int((Double(pe.targetSets) * 0.6).rounded())) }
            s.rationale = "Deload — your last sessions read near-max effort, so this week absorbs instead of adds."
            changed += 1
        }
        guard changed > 0 else { return nil }
        plan.lastAdaptedAt = today
        try? context.save()
        let note = (headline: "Strength deload week",
                    detail: "Your effort's been pinned near max for two sessions, so I cut this week's sets about 40%. Strength is built in the recovery.")
        CoachingEvent.record(kind: .ease, headline: note.headline, detail: note.detail,
                             on: today, in: context, calendar: calendar)
        return note
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

    /// Pause the plan (travel, illness, life): shift every future, still-planned session forward by
    /// `days` and stamp `pausedUntil`. Scheduling only — never load adaptation, so `lastAdaptedAt` is
    /// untouched. The race date is NEVER moved; the caller is honest about compressed runway instead.
    /// Returns the number of sessions shifted.
    @discardableResult
    static func pause(_ plan: TrainingPlan?, days: Int, from today: Date,
                      in context: ModelContext, calendar: Calendar = .current) -> Int {
        guard let plan, days > 0 else { return 0 }
        let todayStart = calendar.startOfDay(for: today)
        guard let until = calendar.date(byAdding: .day, value: days, to: todayStart) else { return 0 }
        var shifted = 0
        for s in plan.sessions
            where s.status != .completed && s.completedWorkout == nil
                  && calendar.startOfDay(for: s.date) >= todayStart {
            guard let moved = calendar.date(byAdding: .day, value: days, to: s.date) else { continue }
            s.date = moved
            shifted += 1
        }
        plan.pausedUntil = until
        try? context.save()
        return shifted
    }

    /// End a pause early: pull the shifted sessions back by the *unused* remainder of the window and
    /// clear `pausedUntil`. Resuming on/after the window's end just clears the flag (nothing to pull).
    /// Returns the number of sessions moved back.
    @discardableResult
    static func resume(_ plan: TrainingPlan?, from today: Date,
                       in context: ModelContext, calendar: Calendar = .current) -> Int {
        guard let plan, let until = plan.pausedUntil else { return 0 }
        let todayStart = calendar.startOfDay(for: today)
        let remaining = calendar.dateComponents([.day], from: todayStart,
                                                to: calendar.startOfDay(for: until)).day ?? 0
        plan.pausedUntil = nil
        guard remaining > 0 else { try? context.save(); return 0 }
        var moved = 0
        for s in plan.sessions
            where s.status != .completed && s.completedWorkout == nil
                  && calendar.startOfDay(for: s.date) >= todayStart {
            guard let back = calendar.date(byAdding: .day, value: -remaining, to: s.date),
                  calendar.startOfDay(for: back) >= todayStart else { continue }
            s.date = back
            moved += 1
        }
        try? context.save()
        return moved
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
