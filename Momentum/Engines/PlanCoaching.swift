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
        guard let plan else { return }
        // While paused, sessions were deliberately shifted out — rolling them "forward" again would
        // undo the pause. Stand down until the window passes (resume clears it early).
        if let paused = plan.pausedUntil, calendar.startOfDay(for: today) < calendar.startOfDay(for: paused) { return }
        let todayStart = calendar.startOfDay(for: today)
        var occupied = Set(plan.sessions.map { calendar.startOfDay(for: $0.date) })
        var changed = false
        var movedCount = 0
        // The first landed move, kept for the coaching headline ("Tuesday's run moved to Thursday").
        var firstMove: (from: String, to: String, word: String)?
        // Slips are counted by ORIGINAL weekday here, at the only moment it still exists — the
        // Athlete Model's avoid-day evidence (a recompute after the move sees only the new date).
        let athlete = (try? context.fetch(FetchDescriptor<UserProfile>()))?.first?.athlete

        for session in plan.sessions
            where session.status == .planned
            && session.completedWorkout == nil
            && session.runType != .race        // a missed race never auto-reschedules — that's the athlete's call
            && calendar.startOfDay(for: session.date) < todayStart {

            let originalWeekday = calendar.component(.weekday, from: session.date) - 1
            if let athlete, athlete.missedWeekdayHistogram.indices.contains(originalWeekday) {
                athlete.missedWeekdayHistogram[originalWeekday] += 1
            }
            var moved = false
            for delta in 0..<7 {
                guard let cand = calendar.date(byAdding: .day, value: delta, to: todayStart) else { continue }
                if !occupied.contains(cand) {
                    occupied.remove(calendar.startOfDay(for: session.date))
                    if firstMove == nil {
                        firstMove = (from: session.date.formatted(.dateTime.weekday(.wide)),
                                     to: cand.formatted(.dateTime.weekday(.wide)),
                                     word: sessionWord(session.discipline))
                    }
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
        if movedCount >= 3, !recentlyAdapted, !plan.isSelfCoached,
           let horizon = calendar.date(byAdding: .day, value: 7, to: todayStart) {
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
                s.targetPaceSPerKm = RunRounding.snapPace(
                    sPerKm: PlanEngine.sessionPace(rt, p5k: plan.p5kSPerKm, intervals: s.intervals,
                                                   raceDistanceM: goalRaceDistanceM(in: context),
                                               goalRacePaceSPerKm: plan.goalRacePaceSPerKm),
                    unit: unit, type: rt)
            }
            plan.lastAdaptedAt = today   // arm the weekly gate so no other ease/bump stacks on this
            CoachingEvent.record(kind: .ease, headline: "Welcome back — rebuild week",
                                 detail: "You were away a bit, so this week restarts at about 70% and your paces ease a touch. One good session earns them right back.",
                                 on: today, in: context, calendar: calendar)
        } else if movedCount > 0 {
            // No rebuild — just the quiet reflow. One receipt covers however many sessions slid,
            // so a three-day trip lands one line, not three.
            let headline: String
            if movedCount == 1, let move = firstMove {
                headline = "\(move.from)'s \(move.word) moved to \(move.to)"
            } else {
                headline = "\(movedCount) sessions moved forward"
            }
            CoachingEvent.record(kind: .moved, headline: headline,
                                 detail: "Nothing was lost. Your week reflowed around the days you missed, and every session kept its purpose.",
                                 on: today, in: context, calendar: calendar)
        }
        if changed { try? context.save() }
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
        guard let plan, workout.type.discipline == .running, let gps = workout.gps else { return nil }
        guard !plan.isSelfCoached else { return nil }   // their targets are theirs — never rewritten
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
        guard equivalent < current else { return nil }       // only ever faster from evidence
        let bounded = max(equivalent, current * 0.97, 150)   // ≤3%/update; sane floor
        guard current - bounded >= 0.5 else { return nil }   // ignore sub-second-per-km noise

        // Weekly cap on APPLIED updates: strong runs can come daily; the plan sharpens once a week.
        if let last = plan.lastRecalibratedAt,
           (calendar.dateComponents([.day], from: last, to: today).day ?? .max) < 7 { return nil }

        // Two-run confirmation. A race result is maximal, definitive evidence — apply immediately.
        let isRaceResult = workout.plannedSession?.runType == .race
        let hasFreshEvidence = plan.pendingP5kAt.map {
            (calendar.dateComponents([.day], from: $0, to: today).day ?? .max) <= 14
        } ?? false
        guard isRaceResult || hasFreshEvidence else {
            plan.pendingP5kSPerKm = equivalent
            plan.pendingP5kAt = today
            try? context.save()
            CoachingEvent.record(kind: .recalibrate, headline: "Strong run banked",
                                 detail: "That looked faster than your training paces assume. One more strong session in the next two weeks and I'll sharpen them — real fitness shows up twice.",
                                 on: today, in: context, calendar: calendar)
            return nil
        }
        plan.pendingP5kSPerKm = nil
        plan.pendingP5kAt = nil
        plan.lastRecalibratedAt = today
        plan.p5kSPerKm = bounded

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
                                               goalRacePaceSPerKm: plan.goalRacePaceSPerKm),
                unit: displayUnit(in: context), type: runType)
            updated += 1
        }
        try? context.save()
        if updated > 0 {
            let delta = Int((current - bounded).rounded())
            let why = isRaceResult
                ? "A race is the truest fitness test there is, so I sharpened your target paces by about \(delta) s/km. You've earned it."
                : "Two strong runs in two weeks — that's real fitness, so I sharpened your target paces by about \(delta) s/km. You've earned it."
            CoachingEvent.record(kind: .recalibrate, headline: "Your paces got faster",
                                 detail: why, on: today, in: context, calendar: calendar)
        }
        return Recalibration(oldP5kSPerKm: current, newP5kSPerKm: bounded, sessionsUpdated: updated)
    }

    /// Whether a consented pace-ease is currently available — false inside the 7-day cooldown after
    /// the last one, so every offer surface (post-run card, coach intent) can hide/decline instead
    /// of silently no-oping. The +2% ease is honest once; tapped after every session it's a slow
    /// downward ratchet with no brake, which is exactly what the cooldown is.
    static func canEasePaces(_ plan: TrainingPlan?, today: Date = Date(),
                             calendar: Calendar = .current) -> Bool {
        guard let plan else { return false }
        guard let last = plan.lastPaceEasedAt else { return true }
        return (calendar.dateComponents([.day], from: last, to: today).day ?? .max) >= 7
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
        guard let plan, plan.p5kSPerKm > 0 else { return 0 }
        guard canEasePaces(plan, today: date, calendar: calendar) else { return 0 }
        let newP5k = plan.p5kSPerKm * 1.02
        let todayStart = calendar.startOfDay(for: date)
        var updated = 0
        for s in plan.sessions
            where isOpen(s) && calendar.startOfDay(for: s.date) >= todayStart {
            guard let runType = s.runType, (s.targetPaceSPerKm ?? 0) > 0 else { continue }
            s.targetPaceSPerKm = RunRounding.snapPace(
                sPerKm: PlanEngine.sessionPace(runType, p5k: newP5k, intervals: s.intervals,
                                               raceDistanceM: goalRaceDistanceM(in: context),
                                               goalRacePaceSPerKm: plan.goalRacePaceSPerKm),
                unit: displayUnit(in: context), type: runType)
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
        try? context.save()
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
        guard let plan, !plan.isSelfCoached else { return nil }   // no load proposals on their plan
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
            s.rationale = "Eased for a busy week — showing up small still counts."
        }
        plan.lastAdaptedAt = today
        CoachingEvent.record(kind: .ease, headline: "Eased for your busy week",
                             detail: "This week's sessions came down about 15% and hard work softened to easy. Next week picks back up as planned.",
                             on: today, in: context, calendar: calendar)
        try? context.save()
        return week.count
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
    ///
    /// `dropLeadingType`: surfaces that already name the session's kind in an eyebrow ("TEMPO RUN")
    /// pass true so the line reads "4 mi ~8:05 /mi" instead of restating "Tempo" twice. Falls back
    /// to the full brief whenever dropping the label would leave nothing to say.
    static func brief(for session: PlannedSession, distanceUnit: DistanceUnit = .auto,
                      dropLeadingType: Bool = false) -> String {
        if session.discipline == .strength {
            // The persisted split label names the day ("Push day — 4 exercises"); plans built
            // before the label existed fall back to the old count heuristic.
            let label = StrengthSplit.dayTitle(forLabel: session.strengthLabel)
                ?? (session.strengthTargets.count >= 5 ? "Full body" : "Strength")
            let n = session.strengthTargets.count
            return n > 0 ? "\(label) — \(n) exercise\(n == 1 ? "" : "s")" : "Strength session"
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
