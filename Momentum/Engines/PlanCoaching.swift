import Foundation
import SwiftData

/// Plan queries + deterministic, no-shame adaptation (PRD §4.7, §9.4). Missed sessions **move**;
/// there is never a red "failed" state.
@MainActor
enum PlanCoaching {

    static func canStartPlannedSession(_ session: PlannedSession, profile: UserProfile?, now: Date = Date()) -> Bool {
        session.status != .missed && (profile?.plan?.adaptiveState?.requiresRecoveryCheckin != true)
            && AdaptivePlanService.showsDetails(session, plan: profile?.plan, now: now)
            && InjuryResponse.canStart(session, profile: profile) && IllnessResponse.canStart(session, profile: profile)
    }

    static func todaySessions(_ plan: TrainingPlan?, on date: Date, calendar: Calendar = .current) -> [PlannedSession] {
        guard let plan else { return [] }
        let profile = plan.modelContext.flatMap { context in
            (try? context.fetch(FetchDescriptor<UserProfile>()))?.first { $0.plan?.id == plan.id }
        }
        let illness = IllnessResponse.state(for: profile)
        if let illness, illness.phase == .resting || (illness.phase == .firstOuting && illness.firstOutingID != nil) { return [] }
        let day = calendar.startOfDay(for: date)
        return plan.sessions
            .filter { calendar.isDate($0.date, inSameDayAs: day) && $0.status != .missed }
            .filter { session in
                if session.status == .completed { return true }
                guard InjuryResponse.canStart(session, profile: profile), profile?.plan?.adaptiveState?.requiresRecoveryCheckin != true else { return false }
                return illness.map { IllnessResponse.canStart(session, state: $0, now: date) } ?? true
            }
            .sorted { $0.date < $1.date }
    }

    /// Link a finished workout to its planned session.
    static func markComplete(_ session: PlannedSession, with workout: Workout, in context: ModelContext) {
        if !PlanMutation.isStaging(context) {
            return PlanMutation.attempt(in: context, fallback: ()) { markComplete(session, with: workout, in: context) }
        }
        session.completedWorkout = workout
        session.status = .completed
        workout.plannedSession = session
        try? PlanMutation.save(context)
    }

    /// Manual check-off from the Plan page (no workout attached). Toggling off unlinks any credited
    /// workout so the session reads as open again. No-shame: this never creates a "failed" state.
    static func setCompletion(_ session: PlannedSession, done: Bool, in context: ModelContext) {
        if !PlanMutation.isStaging(context) {
            return PlanMutation.attempt(in: context, fallback: ()) { setCompletion(session, done: done, in: context) }
        }
        session.status = done ? .completed : .planned
        if done {
            session.rationale = nil          // clear any "moved" note — it's done now
        } else {
            session.completedWorkout?.plannedSession = nil
            session.completedWorkout = nil
        }
        try? PlanMutation.save(context)
    }

    /// Move a session to another day from the Plan page. A manual move clears the auto-"moved" note so
    /// it reads as a deliberate plan, not a slipped one.
    static func reschedule(_ session: PlannedSession, to date: Date, in context: ModelContext,
                           calendar: Calendar = .current) {
        if !PlanMutation.isStaging(context) {
            return PlanMutation.attempt(in: context, fallback: ()) { reschedule(session, to: date, in: context, calendar: calendar) }
        }
        let previousDate = session.date
        session.date = calendar.startOfDay(for: date)
        if previousDate != session.date {
            PlanMutation.afterCommit(in: context) { AdaptiveAnalytics.emit("workout_rescheduled") }
        }
        clearMovedNote(session)
        try? PlanMutation.save(context)
    }

    /// Drop only the auto-"moved" note, which is what a deliberate move is meant to clear.
    ///
    /// This used to blank `rationale` outright, which also destroyed the engines' adaptation
    /// explanations — "Eased after your 8/10 day.", the injury-converted and deload notes — for no
    /// reason beyond the athlete having chosen a different day. Those reasons are still true after
    /// a move, and the board renders them precisely so the athlete can read them where they look.
    /// A `.moved` session is the only one whose rationale IS the slipped-forward note, because
    /// clearing the two together is what makes that so.
    private static func clearMovedNote(_ session: PlannedSession) {
        guard session.status == .moved else { return }
        session.status = .planned
        session.rationale = nil
    }

    /// Move several sessions at once, saving ONCE.
    ///
    /// The week-shaped edits (push the week on a day, work around days away) move up to seven
    /// sessions in one gesture. Looping over the single-session `reschedule` saved seven times, and
    /// every save posts `ModelContext.didSave`, which the Plan board listens to and answers with a
    /// full analytics rebuild — `PaceInsights`, hybrid sequencing and the intensity mix, seven times
    /// over, for one tap. One write, one notification, one rebuild.
    static func reschedule(_ moves: [(session: PlannedSession, date: Date)],
                           in context: ModelContext, calendar: Calendar = .current) {
        if !PlanMutation.isStaging(context) {
            return PlanMutation.attempt(in: context, fallback: ()) { reschedule(moves, in: context, calendar: calendar) }
        }
        guard !moves.isEmpty else { return }
        PlanMutation.afterCommit(in: context) { AdaptiveAnalytics.emit("workout_rescheduled", reason: "schedule_change") }
        for move in moves {
            move.session.date = calendar.startOfDay(for: move.date)
            clearMovedNote(move.session)
        }
        try? PlanMutation.save(context)
    }

    /// Trade two planned sessions' days — the Plan board's drop-one-session-onto-another gesture.
    ///
    /// A swap is two deliberate moves at once, so both sessions clear the auto-"moved" note for the
    /// same reason a single manual move does: the week now reads as the athlete arranged it, not as
    /// one that slipped. Same-day pairs are a no-op rather than a silent write.
    static func swapDays(_ a: PlannedSession, _ b: PlannedSession, in context: ModelContext,
                         calendar: Calendar = .current) {
        if !PlanMutation.isStaging(context) {
            return PlanMutation.attempt(in: context, fallback: ()) { swapDays(a, b, in: context, calendar: calendar) }
        }
        let dayA = calendar.startOfDay(for: a.date)
        let dayB = calendar.startOfDay(for: b.date)
        guard dayA != dayB else { return }
        a.date = dayB
        b.date = dayA
        clearMovedNote(a)
        clearMovedNote(b)
        try? PlanMutation.save(context)
    }

    /// Copy a planned session onto other days — "repeat this next week", "every Tuesday for a
    /// month". Athletes build routines, and before this every recurrence was retyped from scratch.
    ///
    /// The copy is a fresh prescription, never a record: it starts `.planned` with no completed
    /// workout attached, and carries no rationale (the original's "why" belonged to the day the
    /// engine placed it on, not to a day the athlete chose). Strength targets are deep-copied —
    /// `PlannedExercise` rows cascade from their session, so sharing them would delete the copy's
    /// lifts along with the original.
    ///
    /// Days that already hold a copy-identical session are skipped, so tapping "every week" twice
    /// does not silently double the block. Returns the number of sessions actually written.
    @discardableResult
    static func duplicate(_ session: PlannedSession, onto days: [Date], to plan: TrainingPlan?,
                          in context: ModelContext, calendar: Calendar = .current) -> Int {
        if !PlanMutation.isStaging(context) {
            return PlanMutation.attempt(in: context, fallback: 0) { duplicate(session, onto: days, to: plan, in: context, calendar: calendar) }
        }
        guard let plan else { return 0 }
        var written = 0
        for day in days {
            let target = calendar.startOfDay(for: day)
            let alreadyThere = plan.sessions.contains {
                calendar.startOfDay(for: $0.date) == target
                    && $0.discipline == session.discipline
                    && $0.runType == session.runType
                    && $0.intervals == session.intervals
                    && $0.targetDistanceM == session.targetDistanceM
                    && $0.targetDurationS == session.targetDurationS
            }
            guard !alreadyThere else { continue }

            let copy = PlannedSession()
            copy.date = target
            copy.discipline = session.discipline
            copy.sportType = session.sportType
            copy.runType = session.runType
            copy.targetDistanceM = session.targetDistanceM
            copy.targetDurationS = session.targetDurationS
            copy.targetPaceSPerKm = session.targetPaceSPerKm
            copy.intervals = session.intervals
            copy.strengthLabel = session.strengthLabel
            copy.status = .planned
            copy.strengthTargets = session.strengthTargets
                .sorted { $0.order < $1.order }
                .map { source in
                    let lift = PlannedExercise()
                    lift.order = source.order
                    lift.exercise = source.exercise     // the catalog row is shared, never copied
                    lift.targetSets = source.targetSets
                    lift.targetRepLow = source.targetRepLow
                    lift.targetRepHigh = source.targetRepHigh
                    lift.targetRPE = source.targetRPE
                    lift.targetPctRM = source.targetPctRM
                    lift.progression = source.progression
                    return lift
                }
            context.insert(copy)
            plan.sessions.append(copy)
            written += 1
        }
        if written > 0 { try? PlanMutation.save(context) }
        return written
    }

    /// Credit the session the athlete **launched from the plan** — but only if the work they did
    /// actually fulfils it.
    ///
    /// Tapping Start on today's 16 km long run and stopping at 1 km used to check that session off
    /// outright: the launched branch skipped `PlanCredit` entirely, and a completed session is
    /// skipped by missed-session reconciliation, so the week's marquee run silently disappeared from
    /// the plan — the exact failure `PlanCredit` exists to prevent ("a false credit silently deletes
    /// the athlete's key session"). Under-fulfilled now falls through to the same magnitude-aware
    /// matching a free workout gets, so the effort can still credit a smaller session it *does*
    /// cover; otherwise the prescription simply stays open and rolls forward. No shame either way —
    /// the summary says plainly how much of it the run covered.
    ///
    /// A session with no measurable target (a strength day, an open-ended session) is completed by
    /// any real workout, exactly as `PlanCredit.bestMatch` treats an untargeted candidate.
    @discardableResult
    static func creditLaunched(_ session: PlannedSession, with workout: Workout, to plan: TrainingPlan?,
                               in context: ModelContext, calendar: Calendar = .current) -> PlannedSession? {
        if !PlanMutation.isStaging(context) {
            return PlanMutation.attempt(in: context, fallback: nil) { creditLaunched(session, with: workout, to: plan, in: context, calendar: calendar) }
        }
        if context.container.schema.entities.contains(where: { $0.name == "WorkoutFeedbackRecord" }) {
            let attempt = WorkoutFeedbackRecord.fetch(workoutID: workout.id, in: context) ?? WorkoutFeedbackRecord(workoutID: workout.id, now: workout.startedAt)
            if attempt.modelContext == nil { context.insert(attempt) }
            if attempt.launchedSessionID == nil {
                attempt.launchedSessionID = session.id; attempt.plannedDistanceM = session.targetDistanceM
                attempt.plannedDurationS = session.targetDurationS
                attempt.plannedPaceSPerKm = session.targetPaceSPerKm; attempt.plannedRunType = session.runType?.rawValue
            }
        }
        let candidate = PlanCredit.Candidate(targetDistanceM: session.targetDistanceM,
                                             targetDurationS: session.targetDurationS)
        let ratio = PlanCredit.fulfillment(of: candidate, distanceM: workout.gps?.distanceM ?? 0,
                                           durationS: workout.durationS)
        if ratio == nil || ratio! >= PlanCredit.minFulfillment {
            markComplete(session, with: workout, in: context)
            return session
        }
        return creditWorkout(workout, to: plan, in: context, calendar: calendar)
    }

    /// Credit a free workout toward today's matching planned session, if still open. Magnitude-aware
    /// (`PlanCredit`): the workout must plausibly *fulfill* the prescription — a short recovery jog
    /// leaves the day's long run open instead of silently completing it.
    ///
    /// The long run gets a ±1-day grace: it's the week's marquee session and real life routinely
    /// shifts it a day (Saturday's 16 km done Friday). Same-day sessions always win; only when
    /// nothing today credits do we look one day out, and only at long runs — the fulfillment rule
    /// still applies, so a short Friday jog never swallows Saturday's prescription.
    @discardableResult
    static func creditWorkout(_ workout: Workout, to plan: TrainingPlan?, in context: ModelContext,
                              calendar: Calendar = .current) -> PlannedSession? {
        if !PlanMutation.isStaging(context) {
            return PlanMutation.attempt(in: context, fallback: nil) { creditWorkout(workout, to: plan, in: context, calendar: calendar) }
        }
        guard let plan else { return nil }
        if let hit = credit(among: todaySessions(plan, on: workout.startedAt, calendar: calendar),
                            workout: workout, in: context) {
            return hit
        }
        let adjacentLongs = [-1, 1].flatMap { delta -> [PlannedSession] in
            guard let day = calendar.date(byAdding: .day, value: delta, to: workout.startedAt) else { return [] }
            return todaySessions(plan, on: day, calendar: calendar).filter { $0.runType == .long }
        }
        return credit(among: adjacentLongs, workout: workout, in: context)
    }

    /// The log composer's receipt line: which open session WOULD this workout credit — the exact
    /// matching `creditWorkout` runs (same-day best match, then the long run's ±1-day grace), with
    /// zero mutation, so the athlete sees "checks off today's planned session" before confirming.
    static func creditCandidate(type: WorkoutType, distanceM: Double, durationS: Double, on date: Date,
                                plan: TrainingPlan?, calendar: Calendar = .current) -> PlannedSession? {
        guard let plan else { return nil }
        if let hit = match(among: todaySessions(plan, on: date, calendar: calendar),
                           type: type, distanceM: distanceM, durationS: durationS) {
            return hit
        }
        let adjacentLongs = [-1, 1].flatMap { delta -> [PlannedSession] in
            guard let day = calendar.date(byAdding: .day, value: delta, to: date) else { return [] }
            return todaySessions(plan, on: day, calendar: calendar).filter { $0.runType == .long }
        }
        return match(among: adjacentLongs, type: type, distanceM: distanceM, durationS: durationS)
    }

    /// The shared matching pass: filter to open sessions of the workout's discipline, then let
    /// `PlanCredit` pick the best fulfilled prescription. `.moved` counts as open: reconcileMissed
    /// rolls every past-due session forward as .moved (routine after any slipped day), and the
    /// athlete who then does the work must get the credit — markComplete already accepts moved.
    private static func credit(among sessions: [PlannedSession], workout: Workout,
                               in context: ModelContext) -> PlannedSession? {
        guard let hit = match(among: sessions, type: workout.type,
                              distanceM: workout.gps?.distanceM ?? 0, durationS: workout.durationS)
        else { return nil }
        markComplete(hit, with: workout, in: context)
        return hit
    }

    /// Pure selection — shared by the crediting write path and the receipt preview so the two can
    /// never disagree about which session a workout fulfills.
    private static func match(among sessions: [PlannedSession], type: WorkoutType,
                              distanceM: Double, durationS: Double) -> PlannedSession? {
        let open = sessions.filter {
            ($0.status == .planned || $0.status == .moved)
                && $0.completedWorkout == nil && $0.discipline == type.discipline
        }
        guard !open.isEmpty else { return nil }
        let candidates = open.map {
            PlanCredit.Candidate(targetDistanceM: $0.targetDistanceM, targetDurationS: $0.targetDurationS)
        }
        guard let idx = PlanCredit.bestMatch(distanceM: distanceM, durationS: durationS,
                                             candidates: candidates) else { return nil }
        return open[idx]
    }

    /// Move past, still-planned sessions onto the next open day — never a red miss (§9.4).
    /// A real absence (≥3 past-due sessions at once) additionally triggers the **rebuild week**:
    /// the coming week's sessions are scaled to ~70% and hard work softens to easy, because the
    /// evidence on returning from time away says restore 50–75% of lost volume — never cram it back.
    /// Naturally idempotent: once reconciled, nothing is past-due, so a second pass can't re-shrink.
    static func reconcileMissed(_ plan: TrainingPlan?, today: Date, in context: ModelContext,
                                calendar: Calendar = .current) {
        if !PlanMutation.isStaging(context) {
            return PlanMutation.attempt(in: context, fallback: ()) { reconcileMissed(plan, today: today, in: context, calendar: calendar) }
        }
        guard let plan else { return }
        if IllnessResponse.state(for: plan) != nil {
            IllnessResponse.retireMissed(plan, before: today)
            try? PlanMutation.save(context)
            return
        }
        // While paused, sessions were deliberately shifted out — rolling them "forward" again would
        // undo the pause. Stand down until the window passes (resume clears it early). A window
        // that has passed clears itself here, so "Pause" is never refused for a pause that ended
        // weeks ago (2026-09-07).
        if let paused = plan.pausedUntil {
            if calendar.startOfDay(for: today) < calendar.startOfDay(for: paused) { return }
            plan.pausedUntil = nil
        }
        let todayStart = calendar.startOfDay(for: today)
        var occupied = Set(plan.sessions.map { calendar.startOfDay(for: $0.date) })
        var changed = false
        var movedCount = 0
        var skippedCount = 0
        // The first landed move, kept for the coaching headline ("Tuesday's run moved to Thursday").
        var firstMove: (id: UUID, from: String, to: String, word: String)?
        // Slips are counted by ORIGINAL weekday here, at the only moment it still exists — the
        // Athlete Model's avoid-day evidence (a recompute after the move sees only the new date).
        let athlete = (try? context.fetch(FetchDescriptor<UserProfile>()))?.first?.athlete

        let overdue = plan.sessions.filter {
            isOpen($0) && !isFixedDate($0) && calendar.startOfDay(for: $0.date) < todayStart
        }.sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
        let rebuildingAfterAbsence = overdue.count >= 3 && !plan.isSelfCoached
        for session in overdue {
            if rebuildingAfterAbsence {
                // Training debt is not added to the return week. Keep the historical row,
                // while the existing upcoming week supplies the budget for the reduction.
                session.status = .missed
                session.rationale = "Time away. Start with the week ahead; no need to make this one up."
                skippedCount += 1
                changed = true
                continue
            }
            let originalWeekday = calendar.component(.weekday, from: session.date) - 1
            if let athlete, athlete.missedWeekdayHistogram.indices.contains(originalWeekday) {
                athlete.missedWeekdayHistogram[originalWeekday] += 1
            }
            var moved = false
            for delta in 0..<7 {
                guard let cand = calendar.date(byAdding: .day, value: delta, to: todayStart) else { continue }
                if let race = plan.raceDate, cand >= calendar.startOfDay(for: race) { break }
                if !occupied.contains(cand), automaticMoveFits(session, on: cand, plan: plan, calendar: calendar) {
                    occupied.remove(calendar.startOfDay(for: session.date))
                    if firstMove == nil {
                        firstMove = (id: session.id,
                                     from: session.date.formatted(.dateTime.weekday(.wide)),
                                     to: cand.formatted(.dateTime.weekday(.wide)),
                                     word: sessionWord(session.discipline))
                    }
                    session.date = cand
                    session.status = .moved
                    session.rationale = "Shifted to \(cand.formatted(.dateTime.weekday(.wide))). Still on track."
                    occupied.insert(cand)
                    moved = true
                    movedCount += 1
                    changed = true
                    break
                }
            }
            if !moved {
                session.status = .missed
                session.rationale = "No room to move this session. Continue with the week ahead."
                skippedCount += 1
                changed = true
            }
        }

        // Rebuild week after a real absence (PRD §9.4: ≥3 misses → the week restarts at ~70%).
        // Retiring overdue rows makes this safety reduction idempotent. Stamp the weekly gate
        // afterward so a discretionary load increase cannot immediately reverse the return week.
        if rebuildingAfterAbsence,
           let horizon = calendar.date(byAdding: .day, value: 7, to: todayStart) {
            let unit = displayUnit(in: context)
            let athleteState = athleteState(of: plan, in: context)
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
                s.rationale = "Rebuild week. Easing back in at about 70% after time away. The plan meets you here."
            }
            // Re-derive every future planned pace at the eased fitness (this week's converted easies
            // AND the weeks beyond — a comeback's interval day shouldn't demand last month's legs).
            for s in plan.sessions
                where s.status != .completed && s.completedWorkout == nil
                      && calendar.startOfDay(for: s.date) >= todayStart {
                guard let rt = s.runType, (s.targetPaceSPerKm ?? 0) > 0 else { continue }
                s.targetPaceSPerKm = RunRounding.snapPace(
                    sPerKm: PlanEngine.sessionPace(rt, p5k: plan.p5kSPerKm, intervals: s.intervals,
                                                   raceDistanceM: goalRaceDistanceM(in: context),
                                                   goalRacePaceSPerKm: plan.goalRacePaceSPerKm,
                                                   thresholdSPerKm: athleteState.thresholdSPerKm,
                                                   riegelExponent: athleteState.riegelExponent ?? DanielsPaces.populationRiegelExponent),
                    unit: unit, type: rt)
            }
            plan.lastAdaptedAt = today   // arm the weekly gate so no other ease/bump stacks on this
            CoachingEvent.record(kind: .ease, headline: "Welcome back, a rebuild week",
                                 detail: "You were away a bit, so this week restarts at about 70% and your paces ease a touch. Future running evidence will guide the next adjustment.",
                                 on: today, in: context, calendar: calendar)
        } else if movedCount + skippedCount > 0 {
            // No rebuild — just the quiet reflow. One receipt covers however many sessions slid,
            // so a three-day trip lands one line, not three.
            let headline: String
            if movedCount == 0 {
                headline = "Continue with the week ahead"
            } else if movedCount == 1, let move = firstMove {
                headline = "\(move.from)'s \(move.word) moved to \(move.to)"
            } else {
                headline = "\(movedCount) sessions moved forward"
            }
            // A single move carries its session, so the notification opens the session that moved.
            CoachingEvent.record(kind: .moved, headline: headline,
                                 detail: skippedCount > 0
                                    ? "Some past sessions had no free day before the race or within the next week. They stay in your history; there is no need to make them up."
                                    : "Your sessions moved into the available days ahead.",
                                 on: today, in: context, calendar: calendar,
                                 focusSessionID: movedCount == 1 ? firstMove?.id : nil)
        }
        if changed { try? PlanMutation.save(context) }
    }

    /// The session noun for coaching lines ("Tuesday's run moved to Thursday").
    private static func sessionWord(_ d: Discipline) -> String {
        switch d {
        case .running: "run"
        case .cycling: "ride"
        case .walking: "walk"
        case .strength: "lift"
        }
    }

    /// An open (adaptable) session: still ahead of the athlete, whether it sat where planned or was
    /// rolled forward by reconcileMissed. `.moved` MUST count — the paths that filtered `.planned`
    /// only left every slipped-then-rolled session immune to eases and pace updates, i.e. the
    /// athlete who misses days (exactly who needs adaptation) kept stale prescriptions.
    private static func isOpen(_ s: PlannedSession) -> Bool {
        (s.status == .planned || s.status == .moved) && s.completedWorkout == nil
    }

    /// Apply the Progress coach's recommendation to **future** open sessions (PRD §4.7, §9).
    /// Adjusts only sessions dated today-or-later and still open (`.planned` or `.moved`) —
    /// completed work and history are never touched. Deterministic: rules reshape the plan, the
    /// coach only narrates it. Returns the number of sessions changed (0 ⇒ nothing upcoming, or an
    /// advisory-only rec).
    ///
    /// Note: the recommendation is derived from *completed* load, not from the plan, so applying
    /// the same rec repeatedly compounds. The UI confirms once and disables re-tapping per render.
    @discardableResult
    static func apply(_ rec: ProgressInsights.Recommendation, to plan: TrainingPlan?,
                      from date: Date = Date(), in context: ModelContext,
                      calendar: Calendar = .current) -> Int {
        if !PlanMutation.isStaging(context) {
            return PlanMutation.attempt(in: context, fallback: 0) { apply(rec, to: plan, from: date, in: context, calendar: calendar) }
        }
        guard let plan else { return 0 }
        let todayStart = calendar.startOfDay(for: date)
        // Injury-converted sessions are off-limits: softening one would corrupt the swap (easy-run
        // fields on a cycling session) and overwrite the marker `resume` needs to restore it.
        // Race day is untouchable too — you don't run 110% (or 85%) of a marathon; adaptations
        // shape the training around it, never the race itself.
        let future = plan.sessions
            .filter { isOpen($0)
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
                s.targetPaceSPerKm = RunRounding.snapPace(
                    sPerKm: PlanEngine.pace(.easy, p5k: p5k), unit: unit, type: .easy)
            }
            s.rationale = note
        }

        switch rec {
        case .increase:
            for s in future {
                if let d = s.targetDistanceM { s.targetDistanceM = RunRounding.snap(meters: d * 1.1, unit: unit) }
                if let dur = s.targetDurationS { s.targetDurationS = (dur * 1.1).rounded() }
                for pe in s.strengthTargets { pe.targetSets = min(6, pe.targetSets + 1) }
                s.rationale = "Nudged up ~10% after your review of a lighter-than-recent week."
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
                next.targetPaceSPerKm = RunRounding.snapPace(
                    sPerKm: PlanEngine.pace(.recovery, p5k: p5k), unit: unit, type: .recovery)
            } else {
                for pe in next.strengthTargets { pe.targetSets = 2 }
            }
            next.rationale = "Recovery day. Rest is where the gains land."
        case .hold, .start:
            return 0   // advisory only — nothing to change
        }
        plan.lastAdaptedAt = date   // record any adaptation so auto-adapt can't stack on it (≤1/week)
        try? PlanMutation.save(context)
        return future.count
    }

    /// Automatic catch-up never stacks demanding days. Athletes can still choose a manual move
    /// after reading the existing recovery warning; the coach must choose conservatively itself.
    static func automaticMoveFits(_ session: PlannedSession, on date: Date, plan: TrainingPlan,
                                  calendar: Calendar = .current) -> Bool {
        guard isDemanding(session) else { return true }
        let target = calendar.startOfDay(for: date)
        return !plan.sessions.contains { other in
            guard other.id != session.id, other.status != .missed, isDemanding(other) else { return false }
            let gap = calendar.dateComponents([.day], from: target, to: calendar.startOfDay(for: other.date)).day ?? 0
            return abs(gap) <= 1
        }
    }

    private static func isDemanding(_ session: PlannedSession) -> Bool {
        if session.discipline == .running {
            return session.runType == .long || session.runType == .race || session.runType?.isQuality == true
                || isFixedDate(session)
        }
        return session.strengthTargets.contains { target in
            (target.exercise?.primaryMuscles ?? []).contains { HybridSequencing.Item.legMuscles.contains($0) }
        }
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
    ///  • paces only ever get *faster* here (a bad day never slows you down — no-shame),
    ///  • **two-run confirmation**: one strong run banks a pending candidate; a second qualifying
    ///    run within 14 days confirms and applies. The evidence standard is 2–3 confirming sessions
    ///    before raising fitness — never off one great day. A finished goal RACE is definitive and
    ///    bypasses confirmation.
    ///  • at most ~3% per applied update, applied at most once per 7 days, with a sane floor —
    ///    so a great week sharpens the plan once, not every morning.
    /// Returns the change if one was applied (`nil` for non-qualifying runs AND for the banked
    /// first-evidence run — the bank records its own coaching event). Deterministic + bounded.
    @discardableResult
    static func recalibratePaces(from workout: Workout, plan: TrainingPlan?, today: Date = Date(),
                                 in context: ModelContext, calendar: Calendar = .current) -> Recalibration? {
        guard IllnessResponse.state(for: plan) == nil else { return nil }
        if !PlanMutation.isStaging(context) {
            return PlanMutation.attempt(in: context, fallback: nil) { recalibratePaces(from: workout, plan: plan, today: today, in: context, calendar: calendar) }
        }
        guard let plan, workout.type.discipline == .running, let gps = workout.gps else { return nil }
        guard !plan.isSelfCoached else { return nil }   // their targets are theirs — never rewritten
        var dist = gps.distanceM, time = workout.durationS
        let current = plan.p5kSPerKm
        // A planned checkpoint is read as the test inside the recording (the athlete warms up
        // first), never as the whole run at a blended pace (2026-09-07).
        if let testM = PlanEngine.timeTrialDistanceM(intervals: workout.plannedSession?.intervals) {
            guard let reading = CheckpointResult.read(workout: workout, testDistanceM: testM) else { return nil }
            dist = reading.distanceM; time = reading.timeS
        }
        // Need a meaningful distance to extrapolate a 5k from — Riegel off a 400 m rep is noise.
        guard dist.isFinite, time.isFinite, current.isFinite,
              dist >= 2000, time > 0, current > 0,
              workout.startedAt <= today,
              today.timeIntervalSince(workout.startedAt) <= 14 * 86_400 else { return nil }
        if workout.plannedSession?.runType == .race,
           let expected = workout.plannedSession?.targetDistanceM, dist < expected * 0.98 { return nil }
        let coachingState = PlanCoachingStateRecord.upsert(planID: plan.id, in: context)
        guard coachingState.pendingP5kWorkoutID != workout.id, coachingState.paceEvidenceDates[workout.id.uuidString] == nil else { return nil }

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
        guard equivalent < current else { return nil }       // only ever faster from evidence
        let bounded = max(equivalent, current * 0.97, 150)   // ≤3%/update; sane floor
        guard current - bounded >= 0.5 else { return nil }   // ignore sub-second-per-km noise

        // Weekly cap on APPLIED updates: strong runs can come daily; the plan sharpens once a week.
        if let last = plan.lastRecalibratedAt,
           (calendar.dateComponents([.day], from: last, to: today).day ?? .max) < 7 { return nil }

        // Two-run confirmation. A race result is maximal, definitive evidence, and so is a planned
        // checkpoint time trial: the test exists to measure, so its result applies at once
        // (2026-09-07). Everything else banks and waits for a second strong run.
        let isRaceResult = workout.plannedSession?.runType == .race
            || (workout.plannedSession?.intervals?.contains("Time trial") ?? false)
        let hasFreshEvidence = plan.pendingP5kAt.map {
            let age = calendar.dateComponents([.day], from: $0, to: today).day ?? .max
            return (0...14).contains(age) && coachingState.pendingP5kWorkoutID != nil
        } ?? false
        coachingState.paceEvidenceDates = coachingState.paceEvidenceDates.filter { today.timeIntervalSince($0.value) <= 14 * 86_400 }
        coachingState.paceEvidenceDates[workout.id.uuidString] = workout.startedAt
        guard isRaceResult || hasFreshEvidence else {
            plan.pendingP5kSPerKm = equivalent
            plan.pendingP5kAt = today
            coachingState.pendingP5kWorkoutID = workout.id
            try? PlanMutation.save(context)
            CoachingEvent.record(kind: .recalibrate, headline: "Strong run banked",
                                 detail: "That looked faster than your current training paces. Another comparable effort will help confirm whether those targets should change.",
                                 on: today, in: context, calendar: calendar)
            return nil
        }
        plan.pendingP5kSPerKm = nil
        plan.pendingP5kAt = nil
        coachingState.pendingP5kWorkoutID = nil
        plan.lastRecalibratedAt = today
        plan.p5kSPerKm = bounded
        let athleteState = athleteState(of: plan, in: context)

        // Re-derive paces on future, still-open running sessions — `.moved` included, so the
        // athlete who slipped a day doesn't carry stale targets on exactly the sessions ahead.
        let todayStart = calendar.startOfDay(for: today)
        var updated = 0
        for s in plan.sessions
            where isOpen(s) && calendar.startOfDay(for: s.date) >= todayStart {
            guard let runType = s.runType, (s.targetPaceSPerKm ?? 0) > 0 else { continue }
            s.targetPaceSPerKm = RunRounding.snapPace(
                sPerKm: PlanEngine.sessionPace(runType, p5k: bounded, intervals: s.intervals,
                                               raceDistanceM: goalRaceDistanceM(in: context),
                                               goalRacePaceSPerKm: plan.goalRacePaceSPerKm,
                                               thresholdSPerKm: athleteState.thresholdSPerKm,
                                               riegelExponent: athleteState.riegelExponent ?? DanielsPaces.populationRiegelExponent),
                unit: displayUnit(in: context), type: runType)
            updated += 1
        }
        try? PlanMutation.save(context)
        if updated > 0 {
            let delta = Int((current - bounded).rounded())
            let why = isRaceResult
                ? "A race is the truest fitness test there is, so I sharpened your target paces by about \(delta) s/km. You've earned it."
                : "Two strong runs in two weeks. That's real fitness, so I sharpened your target paces by about \(delta) s/km. You've earned it."
            CoachingEvent.record(kind: .recalibrate, headline: "Your paces got faster",
                                 detail: why, on: today, in: context, calendar: calendar)
        }
        return Recalibration(oldP5kSPerKm: current, newP5kSPerKm: bounded, sessionsUpdated: updated)
    }

    /// The plan's athlete-state reads (threshold, exponent), nil-safe when no record was written.
    static func athleteState(of plan: TrainingPlan, in context: ModelContext)
        -> (thresholdSPerKm: Double?, riegelExponent: Double?) {
        let record = PlanAthleteStateRecord.fetch(planID: plan.id, in: context)
        return (record?.thresholdSPerKm, record?.riegelExponent)
    }

    struct ThresholdRecalibration: Sendable, Equatable {
        let oldThresholdSPerKm: Double?
        let newThresholdSPerKm: Double
        let sessionsUpdated: Int
    }

    /// Sharpen the plan's OBSERVED threshold from a run that demonstrated one: a completed steady
    /// (tempo) session at a steady effort, or a race/all-out effort of roughly an hour. Same
    /// discipline as the 5K path — only ever faster, ≤3 % per applied update, once a week — and it
    /// re-derives only the steady/threshold family, since that is all the threshold anchors.
    /// Easing stays consented (RUN-DEC-007): a slow steady run never lowers anything here.
    @discardableResult
    static func recalibrateThreshold(from workout: Workout, plan: TrainingPlan?, today: Date = Date(),
                                     in context: ModelContext, calendar: Calendar = .current) -> ThresholdRecalibration? {
        guard IllnessResponse.state(for: plan) == nil else { return nil }
        if !PlanMutation.isStaging(context) {
            return PlanMutation.attempt(in: context, fallback: nil) { recalibrateThreshold(from: workout, plan: plan, today: today, in: context, calendar: calendar) }
        }
        guard let plan, !plan.isSelfCoached, workout.type.discipline == .running,
              let gps = workout.gps, gps.distanceM >= 3_000, workout.durationS > 0 else { return nil }
        let planned = workout.plannedSession?.runType
        let rpe = workout.perceivedEffort ?? 0
        let minutes = workout.durationS / 60
        let steadySession = planned == .tempo && (workout.perceivedEffort == nil || (6...8).contains(rpe))
            && minutes >= 15
        let hourEffort = (planned == .race || rpe >= 8) && (45...75).contains(minutes)
        guard steadySession || hourEffort else { return nil }
        let observed = workout.durationS / (gps.distanceM / 1000)
        // The curve's T is the ceiling of what a threshold read may claim (+2 %), the same way the
        // 5K path never lets one great day rewrite fitness. A first read is accepted as it is.
        let curveT = DanielsPaces.trainingPace(.tempo, p5kSPerKm: plan.p5kSPerKm)
        let record = PlanAthleteStateRecord.fetch(planID: plan.id, in: context)
        let current = record?.thresholdSPerKm
        let floor = max(curveT * 0.98, 120)
        let candidate = max(observed, floor)
        let newT: Double
        if let current {
            guard candidate < current else { return nil }
            let bounded = max(candidate, current * 0.97)
            guard current - bounded >= 0.5 else { return nil }
            if let last = record?.lastThresholdRecalibratedAt,
               (calendar.dateComponents([.day], from: last, to: today).day ?? .max) < 7 { return nil }
            newT = bounded
        } else {
            guard candidate <= curveT * 1.08 else { return nil }   // slower than that was not a threshold
            newT = candidate
        }
        let state = record ?? PlanAthleteStateRecord.upsert(planID: plan.id, in: context)
        state.thresholdSPerKm = newT
        state.lastThresholdRecalibratedAt = today
        state.thresholdMethod = (planned == .race ? RunningThresholdMethod.raceResult : .workoutEstimate).rawValue
        state.thresholdConfidence = (planned == .race ? RunningEvidenceConfidence.high : .moderate).rawValue
        state.thresholdObservedAt = workout.startedAt

        let todayStart = calendar.startOfDay(for: today)
        var updated = 0
        for s in plan.sessions where isOpen(s) && calendar.startOfDay(for: s.date) >= todayStart {
            guard let runType = s.runType, (s.targetPaceSPerKm ?? 0) > 0 else { continue }
            let steadyFamily = runType == .tempo
                || (runType == .intervals && (s.intervals?.lowercased().contains("threshold") ?? false))
            guard steadyFamily else { continue }
            s.targetPaceSPerKm = RunRounding.snapPace(
                sPerKm: PlanEngine.sessionPace(runType, p5k: plan.p5kSPerKm, intervals: s.intervals,
                                               raceDistanceM: goalRaceDistanceM(in: context),
                                               goalRacePaceSPerKm: plan.goalRacePaceSPerKm,
                                               thresholdSPerKm: newT,
                                               riegelExponent: state.riegelExponent ?? DanielsPaces.populationRiegelExponent),
                unit: displayUnit(in: context), type: runType)
            updated += 1
        }
        try? PlanMutation.save(context)
        if updated > 0, let current {
            let delta = Int((current - newT).rounded())
            CoachingEvent.record(kind: .recalibrate, headline: "Your steady pace got faster",
                                 detail: "You held a faster steady effort than your plan assumed, so your steady runs come down by about \(delta) s/km. Easy days stay easy.",
                                 on: today, in: context, calendar: calendar)
        }
        return ThresholdRecalibration(oldThresholdSPerKm: current, newThresholdSPerKm: newT, sessionsUpdated: updated)
    }

    /// Whether a consented pace-ease is currently available — false inside the 7-day cooldown after
    /// the last one, so every offer surface (post-run card, coach intent) can hide/decline instead
    /// of silently no-oping. The +2% ease is honest once; tapped after every session it's a slow
    /// downward ratchet with no brake, which is exactly what the cooldown is.
    static func canEasePaces(_ plan: TrainingPlan?, today: Date = Date(),
                             calendar: Calendar = .current) -> Bool {
        guard let plan else { return false }
        guard let last = plan.lastPaceEasedAt else { return true }
        return (calendar.dateComponents([.day], from: calendar.startOfDay(for: last),
                                        to: calendar.startOfDay(for: today)).day ?? .max) >= 7
    }

    /// Whether the next seven days are already a lighter week: eased once by the athlete's own
    /// word, or the rebuild week after time away. Either is as light as a week should get, so a
    /// second ease is declined rather than stacked (0.85 × 0.85 is not "a little lighter").
    static func weekAlreadyEased(_ plan: TrainingPlan, from today: Date, calendar: Calendar = .current) -> Bool {
        let start = calendar.startOfDay(for: today)
        guard let horizon = calendar.date(byAdding: .day, value: 7, to: start) else { return false }
        return plan.sessions.contains { s in
            s.status != .completed && s.date >= start && s.date < horizon
                && (s.rationale?.hasPrefix("Eased for a busy week") == true || s.rationale?.hasPrefix("Rebuild week") == true)
        }
    }

    /// The consent-required inverse of `recalibratePaces`, offered by the session pace review when a
    /// guided run's targets consistently ran hot ("Review"): ease the plan's assumed 5k a small
    /// bounded step and re-derive **future** open running paces so the prescription stays honest.
    /// Never touches history; bounded to +2% per approval (mirrors recalibrate's ≤3% in the other
    /// direction) and at most once per 7 days (`canEasePaces`) so taps can't compound. No-shame:
    /// this is "make the targets fit", never a demotion. Returns the number of future sessions
    /// updated (0 ⇒ nothing upcoming to change, or inside the cooldown).
    @discardableResult
    static func easeQualityPaces(_ plan: TrainingPlan?, from date: Date = Date(),
                                 in context: ModelContext, calendar: Calendar = .current) -> Int {
        if !PlanMutation.isStaging(context) {
            return PlanMutation.attempt(in: context, fallback: 0) { easeQualityPaces(plan, from: date, in: context, calendar: calendar) }
        }
        guard let plan, plan.p5kSPerKm > 0 else { return 0 }
        guard canEasePaces(plan, today: date, calendar: calendar) else { return 0 }
        let newP5k = plan.p5kSPerKm * 1.02
        let todayStart = calendar.startOfDay(for: date)
        var updated = 0
        for s in plan.sessions where isOpen(s) && calendar.startOfDay(for: s.date) >= todayStart {
            guard let runType = s.runType, let old = s.targetPaceSPerKm,
                  old.isFinite, old > 0 else { continue }
            // Ease the actual prescription, preserving each week's gradual progression.
            // Re-deriving from the terminal race goal could make an early session faster.
            let eased = max(old, RunRounding.snapPace(sPerKm: old * 1.02,
                            unit: displayUnit(in: context), type: runType))
            guard eased > old else { continue }
            s.targetPaceSPerKm = eased
            updated += 1
        }
        guard updated > 0 else { return 0 }   // nothing to change → don't move p5k either
        let delta = Int((newP5k - plan.p5kSPerKm).rounded())
        plan.p5kSPerKm = newP5k
        plan.lastPaceEasedAt = date
        // An eased plan also clears any banked sharpening evidence — the athlete just told us the
        // old targets ran hot; a pre-ease "strong run" must not confirm against the new baseline.
        plan.pendingP5kSPerKm = nil
        plan.pendingP5kAt = nil
        PlanCoachingStateRecord.upsert(planID: plan.id, in: context).pendingP5kWorkoutID = nil
        try? PlanMutation.save(context)
        CoachingEvent.record(kind: .recalibrate, headline: "Eased your target paces",
                             detail: "You asked for honest targets, so I eased your paces by about \(max(1, delta)) s/km. The reps will land the way they should.",
                             on: date, in: context, calendar: calendar)
        return updated
    }

    /// Conservatively respond when a much-higher-than-recent completed load is corroborated by a
    /// recent session landing harder than prescribed (PRD §9.4). A ratio alone is descriptive and
    /// can never mutate the plan. Deliberately never auto-*increases* load; raising volume remains a
    /// reviewed, athlete-confirmed action.
    ///
    /// Gated to **at most once per 7 days** via `plan.lastAdaptedAt`, which is the safeguard against
    /// the compounding that `apply`'s doc warns about (the rec is from completed load, so re-applying
    /// it back-to-back would spiral). Returns the rec it applied, or `nil` if nothing changed.
    @discardableResult
    static func autoAdapt(_ plan: TrainingPlan?, workouts: [Workout], today: Date = Date(),
                          in context: ModelContext, calendar: Calendar = .current) -> ProgressInsights.Recommendation? {
        guard IllnessResponse.state(for: plan) == nil else { return nil }
        if !PlanMutation.isStaging(context) {
            return PlanMutation.attempt(in: context, fallback: nil) { autoAdapt(plan, workouts: workouts, today: today, in: context, calendar: calendar) }
        }
        guard let plan, !plan.isSelfCoached else { return nil }   // self-coached: we never touch it
        if let last = plan.lastAdaptedAt,
           (calendar.dateComponents([.day], from: last, to: today).day ?? .max) < 7 { return nil }

        let loadRec = ProgressInsights(workouts: workouts, now: today, calendar: calendar).recommendation
        guard loadRec == .ease || loadRec == .rest else { return nil }
        // The load ratio is not a clearance or injury model. Require the athlete's recent response
        // to agree before a structural mutation; races are excluded because high effort is expected.
        guard let response = corroboratingRunResponse(in: workouts, today: today, calendar: calendar)
        else { return nil }
        let rec: ProgressInsights.Recommendation = response == .recover ? .rest : .ease
        guard apply(rec, to: plan, from: today, in: context, calendar: calendar) > 0 else { return nil }
        let (headline, detail): (String, String) = rec == .rest
            ? ("Recovery inserted", "Your recent load is much higher than your recent pattern and a session landed much harder than planned, so your next session is now a recovery day.")
            : ("Eased your week", "Your recent load is above your recent pattern and a session landed harder than planned, so I made a conservative trim.")
        CoachingEvent.record(kind: rec == .rest ? .recover : .ease, headline: headline, detail: detail,
                             on: today, in: context, calendar: calendar)
        return rec   // `apply` already recorded `lastAdaptedAt` + saved
    }

    /// Subjective corroboration for the legacy automatic load path. Only a recent planned run with
    /// explicit plan-fit/RPE mismatch qualifies; an unplanned hard effort or race is not evidence
    /// that an ordinary prescription missed. Kept local so load math cannot quietly broaden it.
    private static func corroboratingRunResponse(in workouts: [Workout], today: Date,
                                                 calendar: Calendar) -> EffortAdaptation.Outcome? {
        guard let cutoff = calendar.date(byAdding: .day, value: -3, to: today) else { return nil }
        return workouts
            .filter { $0.startedAt >= cutoff && $0.startedAt <= today && $0.type.discipline == .running }
            .sorted { $0.startedAt > $1.startedAt }
            .compactMap { workout in
                guard let runType = workout.plannedSession?.runType, runType != .race else { return nil }
                let outcome = EffortAdaptation.judge(rpe: workout.perceivedEffort,
                                                     runType: runType,
                                                     planFit: workout.planFit)
                return outcome == .ease || outcome == .recover ? outcome : nil
            }
            .first
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
        guard IllnessResponse.state(for: plan) == nil else { return nil }
        if !PlanMutation.isStaging(context) {
            return PlanMutation.attempt(in: context, fallback: nil) { easeStrengthOnRPECreep(plan, workouts: workouts, today: today, in: context, calendar: calendar) }
        }
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
            s.rationale = "Deload week. Your last sessions read near max effort, so this week absorbs instead of adds."
            changed += 1
        }
        guard changed > 0 else { return nil }
        plan.lastAdaptedAt = today
        try? PlanMutation.save(context)
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
        guard IllnessResponse.state(for: plan) == nil else { return nil }
        if !PlanMutation.isStaging(context) {
            return PlanMutation.attempt(in: context, fallback: nil) { adaptToEffort(workout, plan: plan, today: today, in: context, calendar: calendar) }
        }
        guard let plan, !plan.isSelfCoached, workout.type.discipline == .running else { return nil }
        let outcome = EffortAdaptation.judge(rpe: workout.perceivedEffort,
                                             runType: workout.plannedSession?.runType,
                                             planFit: workout.planFit)
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

    /// Offer an opt-in review when completed load is lighter than the recent pattern. A light ratio
    /// does not prove readiness or permission to add; the athlete must confirm the week was intentional
    /// and landed well. Nothing is offered if the plan changed in the last 7 days (mirrors `autoAdapt`'s
    /// safeguard, so a proposal can't stack on an auto-ease) and there are future sessions to change.
    /// Returns `nil` when there's nothing to offer. Deterministic — this is what `apply` would do.
    static func proposeAdjustment(_ plan: TrainingPlan?, workouts: [Workout], today: Date = Date(),
                                  calendar: Calendar = .current) -> Proposal? {
        guard IllnessResponse.state(for: plan) == nil else { return nil }
        guard let plan, !plan.isSelfCoached else { return nil }   // no load proposals on their plan
        if let last = plan.lastAdaptedAt,
           (calendar.dateComponents([.day], from: last, to: today).day ?? .max) < 7 { return nil }
        // Only the consent-required direction. ease/rest are auto-applied; hold/start are advisory.
        guard ProgressInsights.loadRecommendation(workouts: workouts, now: today, calendar: calendar) == .increase
        else { return nil }
        let todayStart = calendar.startOfDay(for: today)
        let future = plan.sessions.filter {
            $0.status == .planned && $0.completedWorkout == nil
            && calendar.startOfDay(for: $0.date) >= todayStart
        }
        guard !future.isEmpty else { return nil }
        return Proposal(rec: .increase,
                        headline: "Review next week's load",
                        detail: "This week was lighter than your recent pattern. If that was intentional and the sessions felt good, add about 10% next week?",
                        sessionsAffected: future.count)
    }

    /// "Swamped this week" (the check-in's life-happens door): soften the next 7 days — targets to
    /// ~85%, hard quality work to easy — without touching anything beyond the week. User-initiated,
    /// so it does NOT check the weekly gate (the athlete's word bypasses the throttle, exactly like
    /// an injury report) — but it still ARMS it, so an auto-ease can't stack on top. Race day and
    /// injury-converted sessions stay untouched, self-coached plans are never rewritten, and the
    /// receipt (one `.ease` coaching event) carries delivery. Returns sessions changed.
    @discardableResult
    static func easeWeek(_ plan: TrainingPlan?, from today: Date, in context: ModelContext,
                         calendar: Calendar = .current) -> Int {
        if !PlanMutation.isStaging(context) {
            return PlanMutation.attempt(in: context, fallback: 0) { easeWeek(plan, from: today, in: context, calendar: calendar) }
        }
        guard let plan, !plan.isSelfCoached else { return 0 }
        let todayStart = calendar.startOfDay(for: today)
        guard let horizon = calendar.date(byAdding: .day, value: 7, to: todayStart) else { return 0 }
        let unit = displayUnit(in: context)
        let week = plan.sessions.filter {
            isOpen($0) && $0.runType != .race
            && !($0.rationale?.hasPrefix(InjuryResponse.marker) ?? false)
            && calendar.startOfDay(for: $0.date) >= todayStart && $0.date < horizon
        }
        guard !week.isEmpty else { return 0 }
        for s in week {
            if let d = s.targetDistanceM { s.targetDistanceM = RunRounding.snap(meters: d * 0.85, unit: unit) }
            if let dur = s.targetDurationS { s.targetDurationS = (dur * 0.85).rounded() }
            if let rt = s.runType, rt.isQuality {
                s.runType = .easy
                s.intervals = nil
                s.targetPaceSPerKm = RunRounding.snapPace(
                    sPerKm: PlanEngine.pace(.easy, p5k: plan.p5kSPerKm), unit: unit, type: .easy)
            }
            for pe in s.strengthTargets { pe.targetSets = max(2, pe.targetSets - 1) }
            s.rationale = "Eased for a busy week. Showing up small still counts."
        }
        plan.lastAdaptedAt = today
        CoachingEvent.record(kind: .ease, headline: "Eased for your busy week",
                             detail: "This week's sessions came down about 15% and hard work softened to easy. Next week picks back up as planned.",
                             on: today, in: context, calendar: calendar)
        try? PlanMutation.save(context)
        return week.count
    }

    /// Preview and apply share the final calendar, including sessions that cannot move.
    /// Uniform shifts preserve existing spacing; fixed events can block a move and cause a
    /// chain of other moves to become unsafe. Resolve that chain before writing any dates.
    private static func safeShiftPlacements(
        _ candidates: [(session: PlannedSession, date: Date)], in plan: TrainingPlan,
        calendar: Calendar
    ) -> [(session: PlannedSession, date: Date)] {
        guard let reference = plan.sessions.first.map({ calendar.startOfDay(for: $0.date) }) else { return [] }
        func dayIndex(_ date: Date) -> Int {
            calendar.dateComponents([.day], from: reference, to: calendar.startOfDay(for: date)).day ?? 0
        }
        var dates = Dictionary(uniqueKeysWithValues: candidates.map { ($0.session.id, $0.date) })
        let originalDays = Dictionary(uniqueKeysWithValues: plan.sessions.map {
            ($0.id, dayIndex($0.date))
        })
        let proposedDays = Dictionary(uniqueKeysWithValues: candidates.map { ($0.session.id, dayIndex($0.date)) })
        let demanding = Set(plan.sessions.filter { $0.status != .missed && isDemanding($0) }.map(\.id))
        // Each iteration removes at least one proposed move, so this terminates after at most
        // candidates.count iterations. Inspect a snapshot per pass: relationship order has no say.
        while !dates.isEmpty {
            var blocked = Set<UUID>()
            for move in candidates where dates[move.session.id] != nil {
                guard let original = originalDays[move.session.id], let target = proposedDays[move.session.id] else { continue }
                for other in plan.sessions where other.id != move.session.id {
                    guard let otherOriginal = originalDays[other.id] else { continue }
                    let otherTarget = dates[other.id] != nil ? (proposedDays[other.id] ?? otherOriginal) : otherOriginal
                    let oldGap = abs(original - otherOriginal)
                    let newGap = abs(target - otherTarget)
                    let newCollision = newGap == 0 && oldGap > 0
                    let squeezedRecovery = demanding.contains(move.session.id) && demanding.contains(other.id)
                        && newGap <= 1 && newGap < oldGap
                    if newCollision || squeezedRecovery {
                        blocked.insert(move.session.id)
                        break
                    }
                }
            }
            guard !blocked.isEmpty else { break }
            for id in blocked { dates.removeValue(forKey: id) }
        }
        return candidates.filter { dates[$0.session.id] != nil }
    }

    static func pausePlacements(_ plan: TrainingPlan, days: Int, from today: Date,
                                calendar: Calendar = .current) -> [(session: PlannedSession, date: Date)] {
        guard (1...28).contains(days) else { return [] }
        let start = calendar.startOfDay(for: today)
        let raceDay = plan.raceDate.map { calendar.startOfDay(for: $0) }
        let candidates: [(session: PlannedSession, date: Date)] = plan.sessions
            .sorted { ($0.date, $0.id.uuidString) > ($1.date, $1.id.uuidString) }
            .compactMap { session in
                guard isOpen(session), !isFixedDate(session), calendar.startOfDay(for: session.date) >= start,
                      let date = calendar.date(byAdding: .day, value: days, to: session.date) else { return nil }
                if let raceDay, calendar.startOfDay(for: date) >= raceDay { return nil }
                return (session, date)
            }
        return safeShiftPlacements(candidates, in: plan, calendar: calendar)
    }

    static func resumePlacements(_ plan: TrainingPlan, from today: Date,
                                 calendar: Calendar = .current) -> [(session: PlannedSession, date: Date)] {
        guard let until = plan.pausedUntil else { return [] }
        let start = calendar.startOfDay(for: today)
        let remaining = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: until)).day ?? 0
        guard remaining > 0 else { return [] }
        let shiftedDates = plan.coachingState?.pauseShiftedDates ?? [:]
        let candidates: [(session: PlannedSession, date: Date)] = plan.sessions
            .sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
            .compactMap { session in
                guard isOpen(session), !isFixedDate(session), shiftedDates[session.id.uuidString] == session.date,
                      let date = calendar.date(byAdding: .day, value: -remaining, to: session.date),
                      calendar.startOfDay(for: date) >= start else { return nil }
                return (session, date)
            }
        return safeShiftPlacements(candidates, in: plan, calendar: calendar)
    }

    /// Pause the plan (travel, illness, life): shift every future, still-planned session forward by
    /// `days` and stamp `pausedUntil`. Scheduling only — never load adaptation, so `lastAdaptedAt` is
    /// untouched. The race date is NEVER moved; the caller is honest about compressed runway instead.
    /// Returns the number of sessions shifted.
    @discardableResult
    static func pause(_ plan: TrainingPlan?, days: Int, from today: Date,
                      in context: ModelContext, calendar: Calendar = .current) -> Int {
        if !PlanMutation.isStaging(context) {
            return PlanMutation.attempt(in: context, fallback: 0) { pause(plan, days: days, from: today, in: context, calendar: calendar) }
        }
        guard let plan, (1...28).contains(days) else { return 0 }
        let todayStart = calendar.startOfDay(for: today)
        if let paused = plan.pausedUntil, calendar.startOfDay(for: paused) > todayStart { return 0 }
        guard let until = calendar.date(byAdding: .day, value: days, to: todayStart) else { return 0 }
        var shifted = 0
        // Race day never moves, and a tune-up sits on its own calendar date: a pause shifts the
        // training around them, never the start lines (every line of copy promises exactly that).
        let coachingState = PlanCoachingStateRecord.upsert(planID: plan.id, in: context)
        coachingState.pauseShiftedDates = [:]
        for move in pausePlacements(plan, days: days, from: today, calendar: calendar) {
            coachingState.pauseShiftedDates[move.session.id.uuidString] = move.date
            move.session.date = move.date
            shifted += 1
        }
        if shifted > 0 { plan.pausedUntil = until }
        try? PlanMutation.save(context)
        return shifted
    }

    /// End a pause early: pull the shifted sessions back by the *unused* remainder of the window and
    /// clear `pausedUntil`. Resuming on/after the window's end just clears the flag (nothing to pull).
    /// Returns the number of sessions moved back.
    @discardableResult
    static func resume(_ plan: TrainingPlan?, from today: Date,
                       in context: ModelContext, calendar: Calendar = .current) -> Int {
        if !PlanMutation.isStaging(context) {
            return PlanMutation.attempt(in: context, fallback: 0) { resume(plan, from: today, in: context, calendar: calendar) }
        }
        guard let plan, plan.pausedUntil != nil else { return 0 }
        let moves = resumePlacements(plan, from: today, calendar: calendar)
        for move in moves { move.session.date = move.date }
        plan.pausedUntil = nil
        PlanCoachingStateRecord.upsert(planID: plan.id, in: context).pauseShiftedDates = [:]
        try? PlanMutation.save(context)
        return moves.count
    }

    /// A session tied to a calendar date the athlete did not choose to move: the goal race, or a
    /// tune-up race on the season. Pauses and resumes shift the training around these.
    static func isFixedDate(_ session: PlannedSession) -> Bool {
        session.runType == .race || (session.intervals?.hasPrefix("Tune-up") ?? false)
    }

    /// Human pre-session brief (PRD §4.7), deterministic; the AI may rewrite it later.
    ///
    /// `dropLeadingType`: surfaces that already name the session's kind in an eyebrow ("TEMPO RUN")
    /// pass true so the line reads "4 mi ~8:05 /mi" instead of restating "Tempo" twice. Falls back
    /// to the full brief whenever dropping the label would leave nothing to say.
    static func brief(for session: PlannedSession, distanceUnit: DistanceUnit = .auto,
                      dropLeadingType: Bool = false) -> String {
        if session.discipline == .strength {
            // The persisted split label names the day ("Push day, 4 exercises"); plans built
            // before the label existed fall back to the old count heuristic.
            let label = StrengthSplit.dayTitle(forLabel: session.strengthLabel)
                ?? (session.strengthTargets.count >= 5 ? "Full body" : "Strength")
            let n = session.strengthTargets.count
            return n > 0 ? "\(label), \(n) exercise\(n == 1 ? "" : "s")" : "Strength session"
        }
        // Timed sports (swim, row, yoga, tennis…) — no distance/pace; show the sport + any duration.
        if let wt = session.workoutType, wt.isTimed {
            if let dur = session.targetDurationS, dur > 0 { return "\(wt.title) \(Formatters.duration(s: dur))" }
            return wt.title
        }
        // A structured quality session headlines its SHAPE — "10 × 400m @ 8:24 /mi" — never the
        // continuous-run reading. "Intervals 3.73 mi ~8:24 /mi" tells an athlete they're running
        // 3.7 steady miles at 8:24; the truth is 400 m REPS at 8:24 with jogs between, and the
        // total includes warm-up and cool-down. The shape is what a coach would say out loud.
        if let shape = structuredShape(session, unit: distanceUnit, dropLeadingType: dropLeadingType) {
            return shape
        }
        // GPS: a run keeps its plain session name (Easy run / Steady run / Long run — never the
        // raw enum, which put "Tempo" on the Today deck); ride/walk/etc. use the sport name.
        let label: String = {
            if let wt = session.workoutType, wt != .run { return wt.title }
            if session.discipline == .walking { return "Recovery walk" }
            return session.runType?.planTitle ?? "Session"
        }()
        let dist = session.targetDistanceM.map { Formatters.distance(meters: $0, unit: distanceUnit) } ?? ""
        let lead = (dropLeadingType && !dist.isEmpty) ? dist : "\(label) \(dist)"
        let base = lead.trimmingCharacters(in: .whitespaces)
        if let pace = session.targetPaceSPerKm, pace > 0 {
            return "\(base) ~\(Formatters.pace(secPerKm: pace, unit: distanceUnit))"
        }
        return base
    }

    /// The shape headline for a structured running session, parsed from the same `intervals`
    /// grammar the guided-run builder reads — so the words and the workout can never disagree.
    /// nil for plain runs (no grammar) → the caller's continuous distance/pace form is correct.
    private static func structuredShape(_ session: PlannedSession, unit: DistanceUnit,
                                        dropLeadingType: Bool) -> String? {
        guard session.discipline == .running, let type = session.runType else { return nil }
        let pace = session.targetPaceSPerKm.flatMap { p in
            p > 0 ? "@ \(Formatters.pace(secPerKm: p, unit: unit))" : nil
        }
        switch type {
        case .intervals:
            // Rep pace is the workout's defining number — "10 × 400m @ 8:24 /mi".
            if let d = StructuredWorkoutBuilder.parseIntervals(session.intervals) {
                let rep = StructuredWorkoutBuilder.repDistanceLabel(d.distanceM)
                return ["\(d.reps) × \(rep)", pace].compactMap(\.self).joined(separator: " ")
            }
            if let t = StructuredWorkoutBuilder.parseTimeReps(session.intervals) {
                return ["\(t.reps) × \(StructuredWorkoutBuilder.minLabel(t.seconds))", pace]
                    .compactMap(\.self).joined(separator: " ")
            }
            return nil
        case .fartlek:
            // Speed play runs by feel — no pace on the marquee.
            guard let f = StructuredWorkoutBuilder.parseFartlek(session.intervals) else { return nil }
            return "\(f.reps) × \(StructuredWorkoutBuilder.secLabel(f.onS)) surges"
        case .hills:
            guard let h = StructuredWorkoutBuilder.parseTimedReps(session.intervals, keyword: "hill")
            else { return nil }
            return "\(h.reps) × \(StructuredWorkoutBuilder.secLabel(h.seconds)) hills"
        case .strides:
            guard let st = StructuredWorkoutBuilder.parseTimedReps(session.intervals, keyword: "stride")
            else { return nil }
            let lead = session.targetDistanceM.map { Formatters.distance(meters: $0, unit: unit) + " easy" }
                ?? "Easy run"
            return "\(lead) + \(st.reps) strides"
        case .long:
            guard let finishM = StructuredWorkoutBuilder.parseRaceFinish(session.intervals),
                  let total = session.targetDistanceM, total > 0 else { return nil }
            let lead = dropLeadingType ? "" : "Long "
            return "\(lead)\(Formatters.distance(meters: total, unit: unit)) · last \(Formatters.distance(meters: finishM, unit: unit)) @ race pace"
        default:
            guard let rw = StructuredWorkoutBuilder.parseRunWalk(session.intervals) else { return nil }
            let ratio = "\(Int(rw.runS / 60)):\(Int(rw.walkS / 60))"
            let duration = session.targetDurationS.flatMap { $0 > 0 ? " · \(Formatters.duration(s: $0))" : nil } ?? ""
            return "Run/walk \(ratio)\(duration)"
        }
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
