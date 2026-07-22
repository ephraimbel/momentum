import Testing
import Foundation
import SwiftData
@testable import Momentum

/// Verifies plan crediting and no-shame adaptation (PRD §4.7, §9.4).
@MainActor
struct PlanCoachingTests {

    /// Build an in-memory container (retained by the caller so it doesn't dealloc mid-test).
    func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private func makePlan(in ctx: ModelContext, sessions: [PlannedSession]) -> TrainingPlan {
        let profile = UserProfile()
        profile.distanceUnit = "metric"   // deterministic clean-km snapping (RunRounding), locale-independent
        let plan = TrainingPlan()
        ctx.insert(profile)
        ctx.insert(plan)
        for s in sessions { ctx.insert(s) }
        plan.sessions = sessions
        profile.plan = plan
        try? ctx.save()
        return plan
    }

    @Test func creditsMatchingWorkoutToToday() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let session = PlannedSession()
        session.date = Calendar.current.startOfDay(for: Date())
        session.discipline = .strength
        session.status = .planned
        let plan = makePlan(in: ctx, sessions: [session])

        let workout = Workout()
        workout.type = .strength
        workout.startedAt = Date()
        ctx.insert(workout)

        let credited = PlanCoaching.creditWorkout(workout, to: plan, in: ctx)
        #expect(credited != nil)
        #expect(session.status == .completed)
        #expect(session.completedWorkout?.id == workout.id)
    }

    @Test func creditsMovedSessionsToo() throws {
        // reconcileMissed rolls slipped days forward as `.moved` — an athlete who then does the work
        // must get the credit (the old `.planned`-only filter left the day reading as undone).
        let container = try makeContainer()
        let ctx = container.mainContext
        let session = PlannedSession()
        session.date = Calendar.current.startOfDay(for: Date())
        session.discipline = .strength
        session.status = .moved
        let plan = makePlan(in: ctx, sessions: [session])

        let workout = Workout()
        workout.type = .strength
        workout.startedAt = Date()
        ctx.insert(workout)

        #expect(PlanCoaching.creditWorkout(workout, to: plan, in: ctx) != nil)
        #expect(session.status == .completed)
    }

    @Test func doesNotCreditWrongDiscipline() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let session = PlannedSession()
        session.date = Calendar.current.startOfDay(for: Date())
        session.discipline = .running
        session.status = .planned
        let plan = makePlan(in: ctx, sessions: [session])

        let workout = Workout(); workout.type = .strength; workout.startedAt = Date()
        ctx.insert(workout)
        #expect(PlanCoaching.creditWorkout(workout, to: plan, in: ctx) == nil)
        #expect(session.status == .planned)
    }

    // MARK: Pace recalibration (P1 — the adaptive loop for runners)

    /// A future easy running session whose pace targets the given p5k.
    private func futureEasyRun(in ctx: ModelContext, p5k: Double) -> PlannedSession {
        let s = PlannedSession()
        s.date = Calendar.current.date(byAdding: .day, value: 2, to: Date())!
        s.discipline = .running
        s.runType = .easy
        s.status = .planned
        s.targetDistanceM = 6000
        s.targetPaceSPerKm = PlanEngine.pace(.easy, p5k: p5k)
        return s
    }

    private func run(in ctx: ModelContext, distanceM: Double, durationS: Double, rpe: Int? = nil) -> Workout {
        let w = Workout()
        w.type = .run
        w.startedAt = Date()
        w.durationS = durationS
        w.perceivedEffort = rpe
        let g = GPSDetail(); g.distanceM = distanceM
        w.gps = g
        ctx.insert(w)
        return w
    }

    @Test func fasterRunLowersP5kAndReDerivesFuturePaces() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let future = futureEasyRun(in: ctx, p5k: 322)
        let plan = makePlan(in: ctx, sessions: [future]); plan.p5kSPerKm = 322

        // Two-run confirmation: the first hard 5k (~320 s/km equivalent) BANKS evidence only.
        let first = run(in: ctx, distanceM: 5000, durationS: 1600, rpe: 8)
        #expect(PlanCoaching.recalibratePaces(from: first, plan: plan, in: ctx) == nil)
        #expect(plan.p5kSPerKm == 322)                   // untouched — one great day proves nothing
        #expect(plan.pendingP5kAt != nil)                // …but the evidence is banked

        // The second qualifying run confirms and applies.
        let second = run(in: ctx, distanceM: 5000, durationS: 1600, rpe: 8)
        let rec = PlanCoaching.recalibratePaces(from: second, plan: plan, in: ctx)

        #expect(rec != nil)
        #expect(abs(plan.p5kSPerKm - 320) < 1)                              // lowered to the equivalent
        #expect(rec?.sessionsUpdated == 1)
        #expect(abs((future.targetPaceSPerKm ?? 0) - PlanEngine.pace(.easy, p5k: 320)) < 1)  // future pace re-derived
        #expect(plan.pendingP5kAt == nil)                // evidence consumed
        #expect(plan.lastRecalibratedAt != nil)          // weekly cap armed
    }

    @Test func bigImprovementIsCappedAtThreePercent() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let future = futureEasyRun(in: ctx, p5k: 360)
        let plan = makePlan(in: ctx, sessions: [future]); plan.p5kSPerKm = 360

        // Two blazing 5ks (300 s/km equivalent) confirm — but an applied update still moves ≤3%.
        _ = PlanCoaching.recalibratePaces(from: run(in: ctx, distanceM: 5000, durationS: 1500, rpe: 9),
                                          plan: plan, in: ctx)
        _ = PlanCoaching.recalibratePaces(from: run(in: ctx, distanceM: 5000, durationS: 1500, rpe: 9),
                                          plan: plan, in: ctx)

        #expect(abs(plan.p5kSPerKm - 360 * 0.97) < 1)   // 349.2, not 300
    }

    @Test func raceResultBypassesTwoRunConfirmation() throws {
        // A finished goal race is maximal, definitive evidence — no second run required.
        let container = try makeContainer()
        let ctx = container.mainContext
        let raceDay = PlannedSession()
        raceDay.date = Calendar.current.startOfDay(for: Date())
        raceDay.discipline = .running; raceDay.runType = .race; raceDay.status = .planned
        let future = futureEasyRun(in: ctx, p5k: 322)
        let plan = makePlan(in: ctx, sessions: [raceDay, future]); plan.p5kSPerKm = 322

        let w = run(in: ctx, distanceM: 5000, durationS: 1600, rpe: 9)
        PlanCoaching.markComplete(raceDay, with: w, in: ctx)
        let rec = PlanCoaching.recalibratePaces(from: w, plan: plan, in: ctx)

        #expect(rec != nil)
        #expect(abs(plan.p5kSPerKm - 320) < 1)
    }

    @Test func appliedRecalibrationIsCappedToOncePerWeek() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let future = futureEasyRun(in: ctx, p5k: 340)
        let plan = makePlan(in: ctx, sessions: [future]); plan.p5kSPerKm = 340
        plan.lastRecalibratedAt = Calendar.current.date(byAdding: .day, value: -2, to: Date())

        // A qualifying faster run two days after an applied update: nothing moves, nothing banks.
        let w = run(in: ctx, distanceM: 5000, durationS: 1650, rpe: 8)
        #expect(PlanCoaching.recalibratePaces(from: w, plan: plan, in: ctx) == nil)
        #expect(plan.p5kSPerKm == 340)
        #expect(plan.pendingP5kAt == nil)
    }

    @Test func movedSessionsGetAdaptedToo() throws {
        // reconcileMissed rolls slipped sessions forward as `.moved` — they must still receive
        // eases and pace updates, or the athlete who misses days keeps stale prescriptions on
        // exactly the sessions ahead of them.
        let container = try makeContainer()
        let ctx = container.mainContext
        let moved = PlannedSession()
        moved.date = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        moved.discipline = .running; moved.runType = .tempo; moved.status = .moved
        moved.targetDistanceM = 8000
        moved.targetPaceSPerKm = PlanEngine.sessionPace(.tempo, p5k: 330, intervals: nil, raceDistanceM: nil)
        let plan = makePlan(in: ctx, sessions: [moved]); plan.p5kSPerKm = 330

        #expect(PlanCoaching.apply(.ease, to: plan, in: ctx) == 1)   // the moved session was eased
        #expect((moved.targetDistanceM ?? 0) < 8000)
    }

    @Test func easeQualityPacesHasAWeeklyCooldown() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let future = futureEasyRun(in: ctx, p5k: 330)
        let plan = makePlan(in: ctx, sessions: [future]); plan.p5kSPerKm = 330

        #expect(PlanCoaching.canEasePaces(plan))
        #expect(PlanCoaching.easeQualityPaces(plan, in: ctx) == 1)   // first ease applies (+2%)
        let eased = plan.p5kSPerKm
        #expect(abs(eased - 330 * 1.02) < 0.01)

        // A second tap inside the week is refused — the ratchet has a brake.
        #expect(!PlanCoaching.canEasePaces(plan))
        #expect(PlanCoaching.easeQualityPaces(plan, in: ctx) == 0)
        #expect(plan.p5kSPerKm == eased)
    }

    @Test func easyRunDoesNotChangePaces() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let future = futureEasyRun(in: ctx, p5k: 330)
        let plan = makePlan(in: ctx, sessions: [future]); plan.p5kSPerKm = 330

        // 8 km at easy pace (410 s/km), no reported effort, no planned quality ⇒ not a fitness signal.
        let w = run(in: ctx, distanceM: 8000, durationS: 8 * 410, rpe: nil)
        let rec = PlanCoaching.recalibratePaces(from: w, plan: plan, in: ctx)

        #expect(rec == nil)
        #expect(plan.p5kSPerKm == 330)                  // unchanged
    }

    @Test func slowHardEffortNeverRaisesPaces() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let future = futureEasyRun(in: ctx, p5k: 300)
        let plan = makePlan(in: ctx, sessions: [future]); plan.p5kSPerKm = 300

        // A hard run (RPE 8) but slow (5k in 1700 s ⇒ 340 equivalent, slower than the stored 300).
        let w = run(in: ctx, distanceM: 5000, durationS: 1700, rpe: 8)
        let rec = PlanCoaching.recalibratePaces(from: w, plan: plan, in: ctx)

        #expect(rec == nil)
        #expect(plan.p5kSPerKm == 300)                  // a bad day never slows you down (no-shame)
    }

    // MARK: Auto-adaptive load (P3 — ACWR ease/rest, never auto-increase, ≤1/week)

    private func loggedWorkout(in ctx: ModelContext, daysAgo: Int, minutes: Double = 60, rpe: Int = 6) -> Workout {
        let w = Workout()
        w.type = .run
        w.startedAt = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        w.durationS = minutes * 60
        w.perceivedEffort = rpe
        let g = GPSDetail(); g.distanceM = 5000; w.gps = g
        ctx.insert(w)
        return w
    }

    /// 10 equal sessions weighted so the acute:chronic ratio lands ~1.54 ⇒ "ease".
    /// (Chronic load is normalized to the history that exists — oldest at day 27 keeps the
    /// divisor ≈ 3.86 and this genuinely overreaching; day 28 would sit on the window boundary.)
    private func overreachingHistory(in ctx: ModelContext) {
        for d in [0, 2, 4, 6] { _ = loggedWorkout(in: ctx, daysAgo: d) }       // acute (last 7d)
        for d in [10, 12, 14, 18, 22, 27] { _ = loggedWorkout(in: ctx, daysAgo: d) }  // chronic-only
    }

    @Test func autoEasesWhenOverreaching() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        overreachingHistory(in: ctx)

        let future = PlannedSession()
        future.date = Calendar.current.date(byAdding: .day, value: 2, to: Date())!
        future.discipline = .running; future.runType = .tempo; future.status = .planned
        future.targetDistanceM = 8000; future.targetPaceSPerKm = 320
        let plan = makePlan(in: ctx, sessions: [future]); plan.p5kSPerKm = 330

        let workouts = (try? ctx.fetch(FetchDescriptor<Workout>())) ?? []
        let rec = PlanCoaching.autoAdapt(plan, workouts: workouts, in: ctx)

        #expect(rec == .ease)
        #expect(plan.lastAdaptedAt != nil)
        #expect(future.runType == .easy)                  // hard work softened (no-shame)
        #expect((future.targetDistanceM ?? 0) < 8000)     // volume eased
    }

    @Test func autoAdaptGatedToOncePerWeek() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        overreachingHistory(in: ctx)
        let future = PlannedSession()
        future.date = Calendar.current.date(byAdding: .day, value: 2, to: Date())!
        future.discipline = .running; future.runType = .easy; future.status = .planned
        future.targetDistanceM = 8000; future.targetPaceSPerKm = 400
        let plan = makePlan(in: ctx, sessions: [future]); plan.p5kSPerKm = 330
        let workouts = (try? ctx.fetch(FetchDescriptor<Workout>())) ?? []

        #expect(PlanCoaching.autoAdapt(plan, workouts: workouts, in: ctx) == .ease)
        #expect(PlanCoaching.autoAdapt(plan, workouts: workouts, in: ctx) == nil)   // gated, no compounding
    }

    @Test func autoAdaptNeverIncreasesLoad() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        // Low acute:chronic (~0.67) ⇒ the rec would be .increase — which auto-adapt declines to apply.
        _ = loggedWorkout(in: ctx, daysAgo: 3)
        for d in [10, 14, 18, 22, 26] { _ = loggedWorkout(in: ctx, daysAgo: d) }
        let future = PlannedSession()
        future.date = Calendar.current.date(byAdding: .day, value: 2, to: Date())!
        future.discipline = .running; future.runType = .easy; future.status = .planned
        future.targetDistanceM = 6000
        let plan = makePlan(in: ctx, sessions: [future]); plan.p5kSPerKm = 330
        let workouts = (try? ctx.fetch(FetchDescriptor<Workout>())) ?? []

        #expect(PlanCoaching.autoAdapt(plan, workouts: workouts, in: ctx) == nil)
        #expect(plan.lastAdaptedAt == nil)
        #expect(future.targetDistanceM == 6000)            // untouched — never auto-increases
    }

    // MARK: Next-workout reminders (P4 — the "updates" half)

    @Test func reminderPayloadsCoverUpcomingSessionsOnly() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        let far = cal.date(byAdding: .day, value: 9, to: today)!

        let run = PlannedSession()
        run.date = tomorrow; run.discipline = .running; run.runType = .easy
        run.status = .planned; run.targetDistanceM = 8000; run.targetPaceSPerKm = 370
        let doneToday = PlannedSession()
        doneToday.date = today; doneToday.discipline = .strength; doneToday.status = .completed
        let farRun = PlannedSession()
        farRun.date = far; farRun.discipline = .running; farRun.runType = .long; farRun.status = .planned
        let plan = makePlan(in: ctx, sessions: [run, doneToday, farRun])

        let payloads = NotificationService.reminderPayloads(for: plan, now: today, hour: 7, minute: 30)

        #expect(payloads.count == 1)                                     // completed + far-future excluded
        #expect(payloads.first?.id == "momentum.session.\(run.id.uuidString)")
        #expect(payloads.first?.title == "Run day")
        #expect(payloads.first?.body == PlanCoaching.brief(for: run))    // carries the current prescription
        #expect(payloads.first?.fireComponents.hour == 7)
        #expect(payloads.first?.fireComponents.minute == 30)
    }

    @Test func missedSessionMovesNeverFails() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!
        let session = PlannedSession()
        session.date = yesterday
        session.discipline = .running
        session.status = .planned
        let plan = makePlan(in: ctx, sessions: [session])

        PlanCoaching.reconcileMissed(plan, today: Date(), in: ctx)

        #expect(session.status == .moved)                         // never a red miss
        #expect(session.rationale != nil)
        #expect(cal.startOfDay(for: session.date) >= cal.startOfDay(for: Date()))
    }

    // MARK: Opt-in load increase (P5 — AI proposes / engine computes / user confirms)

    /// Solid chronic load with a deliberately light last week ⇒ ACWR < 0.8 ⇒ "increase".
    private func underloadedHistory(in ctx: ModelContext) {
        _ = loggedWorkout(in: ctx, daysAgo: 3, minutes: 20, rpe: 5)                  // light acute week
        for d in [10, 12, 14, 18, 22, 26] { _ = loggedWorkout(in: ctx, daysAgo: d) } // solid chronic
    }

    private func futureRun(in ctx: ModelContext, distanceM: Double = 6000) -> PlannedSession {
        let s = PlannedSession()
        s.date = Calendar.current.date(byAdding: .day, value: 2, to: Date())!
        s.discipline = .running; s.runType = .easy; s.status = .planned
        s.targetDistanceM = distanceM; s.targetPaceSPerKm = 400
        return s
    }

    @Test func proposesIncreaseWhenUnderloaded() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        underloadedHistory(in: ctx)
        let plan = makePlan(in: ctx, sessions: [futureRun(in: ctx)])
        let workouts = (try? ctx.fetch(FetchDescriptor<Workout>())) ?? []

        let proposal = PlanCoaching.proposeAdjustment(plan, workouts: workouts)
        #expect(proposal?.rec == .increase)
        #expect(proposal?.sessionsAffected == 1)
    }

    @Test func confirmingProposalBumpsFutureSessions() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        underloadedHistory(in: ctx)
        let future = futureRun(in: ctx, distanceM: 6000)
        let plan = makePlan(in: ctx, sessions: [future])
        let workouts = (try? ctx.fetch(FetchDescriptor<Workout>())) ?? []

        let proposal = try #require(PlanCoaching.proposeAdjustment(plan, workouts: workouts))
        let changed = PlanCoaching.apply(proposal.rec, to: plan, in: ctx)

        #expect(changed == 1)
        #expect((future.targetDistanceM ?? 0) == 6500)   // bumped ~10% (6000→6600), snapped to a clean 6.5 km
        #expect(plan.lastAdaptedAt != nil)
    }

    @Test func noProposalRightAfterAnAdaptation() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        underloadedHistory(in: ctx)
        let plan = makePlan(in: ctx, sessions: [futureRun(in: ctx)])
        plan.lastAdaptedAt = Date()                       // adapted moments ago
        let workouts = (try? ctx.fetch(FetchDescriptor<Workout>())) ?? []

        #expect(PlanCoaching.proposeAdjustment(plan, workouts: workouts) == nil)  // never stack
    }

    @Test func noProposalWhenNotUnderloaded() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        overreachingHistory(in: ctx)                      // ACWR high ⇒ ease (auto-applied, not offered)
        let plan = makePlan(in: ctx, sessions: [futureRun(in: ctx)])
        let workouts = (try? ctx.fetch(FetchDescriptor<Workout>())) ?? []

        #expect(PlanCoaching.proposeAdjustment(plan, workouts: workouts) == nil)
    }

    // MARK: RPE → adaptation (the subjective loop)

    @Test func rpeAdaptationEasesAndIsGatedWeekly() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        // A future quality session + a just-completed easy run that "felt brutal" (RPE 8).
        let future = PlannedSession()
        future.date = Calendar.current.date(byAdding: .day, value: 2, to: Date())!
        future.discipline = .running; future.runType = .intervals; future.status = .planned
        future.targetDistanceM = 6000; future.targetPaceSPerKm = 300; future.intervals = "6×400m @ 5K"
        let easyDone = PlannedSession()
        easyDone.date = Calendar.current.startOfDay(for: Date())
        easyDone.discipline = .running; easyDone.runType = .easy; easyDone.status = .completed
        let plan = makePlan(in: ctx, sessions: [future, easyDone])
        plan.p5kSPerKm = 300

        let workout = Workout(); workout.type = .run; workout.startedAt = Date()
        workout.perceivedEffort = 8
        workout.plannedSession = easyDone; easyDone.completedWorkout = workout
        ctx.insert(workout)

        let note = PlanCoaching.adaptToEffort(workout, plan: plan, in: ctx)
        #expect(note != nil)                          // it changed the plan and narrated it
        #expect(note?.detail.contains("easy run") == true)   // names the session that felt hard
        #expect(future.runType == .recovery)          // the next hard session became a recovery day
        #expect(plan.lastAdaptedAt != nil)
        // A coaching event is recorded for the adaptation-history timeline.
        let events = (try? ctx.fetch(FetchDescriptor<CoachingEvent>())) ?? []
        #expect(events.count == 1 && events.first?.kind == .recover)
        // The ≤1/week gate blocks a second adaptation.
        #expect(PlanCoaching.adaptToEffort(workout, plan: plan, in: ctx) == nil)
    }

    @Test func coachingEventRecordDedupesOnKindAndHeadline() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let today = Date(timeIntervalSince1970: 1_000_000)
        CoachingEvent.record(kind: .ease, headline: "A", detail: "a", on: today, in: ctx)
        CoachingEvent.record(kind: .ease, headline: "A", detail: "again", on: today, in: ctx)  // same decision re-run → skipped
        CoachingEvent.record(kind: .ease, headline: "B", detail: "b", on: today, in: ctx)      // DIFFERENT decision, same kind → kept
        CoachingEvent.record(kind: .recover, headline: "C", detail: "c", on: today, in: ctx)   // different kind → kept
        let events = (try? ctx.fetch(FetchDescriptor<CoachingEvent>())) ?? []
        // An injury report and an overtraining cutback can share a kind on one day — both must
        // keep their receipt (and their inbox notification); only true re-runs dedupe.
        #expect(events.count == 3)
    }

    @Test func rpeAdaptationNoOpWhenEffortMatchesPrescription() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let done = PlannedSession()
        done.date = Calendar.current.startOfDay(for: Date())
        done.discipline = .running; done.runType = .intervals; done.status = .completed
        let plan = makePlan(in: ctx, sessions: [done])
        let workout = Workout(); workout.type = .run; workout.startedAt = Date()
        workout.perceivedEffort = 8                   // a hard session that felt appropriately hard
        workout.plannedSession = done; done.completedWorkout = workout
        ctx.insert(workout)
        #expect(PlanCoaching.adaptToEffort(workout, plan: plan, in: ctx) == nil)
        #expect(plan.lastAdaptedAt == nil)            // nothing changed
    }

    // MARK: Strength RPE-creep deload (plan-quality audit #4 — the plan-level strength loop)

    private func strengthWorkout(in ctx: ModelContext, daysAgo: Int, rpes: [Double]) -> Workout {
        let w = Workout()
        w.type = .strength
        w.startedAt = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        let session = StrengthSession()
        let ex = WorkoutExercise()
        ex.sets = rpes.enumerated().map { i, r in
            let e = SetEntry()
            e.index = i; e.weightKg = 60; e.reps = 8; e.rpe = r
            e.type = .working; e.isComplete = true
            return e
        }
        session.exercises = [ex]
        w.strength = session
        ctx.insert(w)
        return w
    }

    private func futureStrengthDay(in ctx: ModelContext, sets: Int) -> (PlannedSession, PlannedExercise) {
        let s = PlannedSession()
        s.date = Calendar.current.date(byAdding: .day, value: 2, to: Date())!
        s.discipline = .strength
        s.status = .planned
        let pe = PlannedExercise(); pe.targetSets = sets
        ctx.insert(pe)
        s.strengthTargets = [pe]
        return (s, pe)
    }

    @Test func rpeCreepDeloadsTheComingStrengthWeek() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (future, pe) = futureStrengthDay(in: ctx, sets: 4)
        let plan = makePlan(in: ctx, sessions: [future])

        // Two sessions pinned near max ⇒ autoregulated deload: 4 sets → 2 (~40% cut), note attached.
        let w1 = strengthWorkout(in: ctx, daysAgo: 3, rpes: [9, 9, 8.5, 9])
        let w2 = strengthWorkout(in: ctx, daysAgo: 0, rpes: [9, 8.5, 9])
        let note = PlanCoaching.easeStrengthOnRPECreep(plan, workouts: [w1, w2], in: ctx)
        #expect(note != nil)
        #expect(pe.targetSets == 2)
        #expect(future.rationale?.lowercased().contains("deload") == true)
        #expect(plan.lastAdaptedAt != nil)

        // Gated ≤1/week: a second pass can't compound the cut.
        pe.targetSets = 4
        #expect(PlanCoaching.easeStrengthOnRPECreep(plan, workouts: [w1, w2], in: ctx) == nil)
        #expect(pe.targetSets == 4)
    }

    // MARK: Rebuild week after absence (PRD §9.4: ≥3 misses → restart at ~70%)

    private func plannedRun(in ctx: ModelContext, daysFromNow: Int, type: RunType,
                            distanceM: Double) -> PlannedSession {
        let s = PlannedSession()
        s.date = Calendar.current.date(byAdding: .day, value: daysFromNow, to: Calendar.current.startOfDay(for: Date()))!
        s.discipline = .running
        s.runType = type
        s.status = .planned
        s.targetDistanceM = distanceM
        s.targetPaceSPerKm = 380
        return s
    }

    @Test func threeMissesTriggerSeventyPercentRebuildWeek() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        // Three sessions slipped past (a real absence) + a quality day coming up this week.
        let missed = [plannedRun(in: ctx, daysFromNow: -5, type: .easy, distanceM: 6000),
                      plannedRun(in: ctx, daysFromNow: -3, type: .long, distanceM: 12000),
                      plannedRun(in: ctx, daysFromNow: -2, type: .easy, distanceM: 6000)]
        let upcoming = plannedRun(in: ctx, daysFromNow: 4, type: .tempo, distanceM: 8000)
        let plan = makePlan(in: ctx, sessions: missed + [upcoming]); plan.p5kSPerKm = 330

        PlanCoaching.reconcileMissed(plan, today: Date(), in: ctx)

        #expect(missed.allSatisfy { $0.status == .moved })
        #expect(upcoming.runType == .easy)                        // hard work softened for re-entry
        #expect(upcoming.targetDistanceM == 5500)                 // 8000 × 0.7 = 5600, snapped to a clean 5.5 km
        #expect(upcoming.rationale?.lowercased().contains("rebuild") == true)
        // Idempotent: a second reconcile finds nothing past-due and can't re-shrink.
        PlanCoaching.reconcileMissed(plan, today: Date(), in: ctx)
        #expect(upcoming.targetDistanceM == 5500)
    }

    @Test func twoMissesJustRescheduleWithoutRebuild() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let missed = [plannedRun(in: ctx, daysFromNow: -2, type: .easy, distanceM: 6000),
                      plannedRun(in: ctx, daysFromNow: -1, type: .easy, distanceM: 6000)]
        let upcoming = plannedRun(in: ctx, daysFromNow: 4, type: .tempo, distanceM: 8000)
        let plan = makePlan(in: ctx, sessions: missed + [upcoming]); plan.p5kSPerKm = 330

        PlanCoaching.reconcileMissed(plan, today: Date(), in: ctx)

        #expect(missed.allSatisfy { $0.status == .moved })        // still rescheduled, never red
        #expect(upcoming.runType == .tempo)                       // but no rebuild for a small slip
        #expect(upcoming.targetDistanceM == 8000)
    }

    @Test func moderateEffortNeverTriggersStrengthDeload() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (_, pe) = futureStrengthDay(in: ctx, sets: 4)
        let plan = makePlan(in: ctx, sessions: [])

        // Second session at sane effort ⇒ no creep, nothing changes.
        let w1 = strengthWorkout(in: ctx, daysAgo: 3, rpes: [9, 9, 9])
        let w2 = strengthWorkout(in: ctx, daysAgo: 0, rpes: [7, 7.5, 8])
        #expect(PlanCoaching.easeStrengthOnRPECreep(plan, workouts: [w1, w2], in: ctx) == nil)
        #expect(pe.targetSets == 4)
        #expect(plan.lastAdaptedAt == nil)
    }

    // MARK: Post-race continuation (PlanService.completeRace — the arc's close)

    /// A real race plan whose race date is already `raceDaysAgo` in the past: generated from far
    /// enough back that the race session landed on the calendar.
    /// `now` is injectable so a fixture can pin the weekday — the post-race carry-over behaves
    /// differently depending on whether race day falls in the same calendar week as the rebuild.
    private func raceProfile(in ctx: ModelContext, raceDaysAgo: Int, now: Date = Date()) -> UserProfile {
        let cal = Calendar.current
        let profile = UserProfile()
        profile.distanceUnit = "metric"
        profile.disciplines = ["running"]
        profile.goal = .raceDistance
        profile.daysPerWeek = 4
        profile.raceDate = cal.date(byAdding: .day, value: -raceDaysAgo, to: cal.startOfDay(for: now))
        profile.raceDistanceM = 42_195
        ctx.insert(profile)
        let start = cal.date(byAdding: .weekOfYear, value: -8, to: now)!
        PlanService.regenerate(for: profile, startDate: start, in: ctx)
        return profile
    }

    /// A goal race that lands in the PREVIOUS calendar week still survives the post-race rebuild.
    /// `PlanService.persist` scopes its carry-over to the current week, and `completeRace` runs the
    /// day AFTER race day — so a Saturday race opened on Monday fell outside that window and the
    /// finished race was cascade-deleted, erasing the season's defining session at its emotional peak.
    /// The dates are pinned because the bug only reproduced on the ~3 weekdays where race day crosses
    /// the boundary: a `Date()`-relative test passed four days in seven. Saturday→Monday straddles the
    /// boundary whether the locale starts its weeks on Sunday or Monday, so this holds anywhere.
    @Test func raceInThePreviousCalendarWeekSurvivesTheRebuild() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = Calendar.current
        let raceDay = try #require(DateComponents(calendar: cal, year: 2026, month: 9, day: 12).date)  // Saturday
        let monday = try #require(DateComponents(calendar: cal, year: 2026, month: 9, day: 14).date)   // Monday
        #expect(!cal.isDate(raceDay, equalTo: monday, toGranularity: .weekOfYear),
                "fixture must straddle a week boundary or it isn't exercising the bug")

        let profile = raceProfile(in: ctx, raceDaysAgo: 2, now: monday)
        let plan = try #require(profile.plan)
        let raceSession = try #require(plan.sessions.first { $0.runType == .race },
                                       "race plan must carry its race session")
        let race = Workout()
        race.type = .run
        race.startedAt = raceSession.date
        race.durationS = 10_800
        ctx.insert(race)
        PlanCoaching.markComplete(raceSession, with: race, in: ctx)

        #expect(PlanService.completeRace(for: profile, today: monday, in: ctx) != nil)
        let next = try #require(profile.plan)
        // The race the athlete just ran is still on the board, completed — never erased.
        #expect(next.sessions.contains { $0.runType == .race && $0.status == .completed })
        // And carrying it did NOT drag the block's anchor back into last week: the macrocycle still
        // starts on the rebuild day, so week 1 stays week 1 and the phase labels don't slide.
        #expect(next.blockStart.map { cal.isDate($0, inSameDayAs: monday) } == true)
    }

    @Test func completeRaceRecalibratesAndOpensRecoveryBlock() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = raceProfile(in: ctx, raceDaysAgo: 2)
        let plan = try #require(profile.plan)
        let raceSession = try #require(plan.sessions.first { $0.runType == .race },
                                       "race plan must carry its race session")
        // The athlete ran a 3:00 marathon — a big fitness statement vs the assumed 330 s/km 5K.
        let race = Workout()
        race.type = .run
        race.startedAt = raceSession.date
        race.durationS = 10_800
        ctx.insert(race)
        PlanCoaching.markComplete(raceSession, with: race, in: ctx)

        let headline = PlanService.completeRace(for: profile, today: Date(), in: ctx)
        #expect(headline != nil)
        let next = try #require(profile.plan)
        // The goal cleared; the season's name went with it; the block counter advanced.
        #expect(profile.raceDate == nil && profile.raceDistanceM == nil)
        #expect(next.raceDate == nil)
        #expect(next.blockIndex == 1)
        #expect(next.name.isEmpty)
        // The race result set the paces (3:00 marathon ⇒ Riegel 5k ≈ 225 s/km, was 330).
        #expect(abs(next.p5kSPerKm - 225) < 3, "race result should recalibrate, got \(next.p5kSPerKm)")
        // Marathon ⇒ the new block opens with a 2-week recovery lead-in, all easy. The finished
        // race itself carries over as COMPLETED history (this week's story survives the rebuild) —
        // the invariant is about what's PRESCRIBED, so completed sessions are excluded.
        #expect(next.weekPhases.prefix(2).allSatisfy { $0 == PlanPhase.recovery.rawValue })
        let cal = Calendar.current
        let fortnight = cal.date(byAdding: .day, value: 14, to: cal.startOfDay(for: Date()))!
        let leadIn = next.sessions.filter {
            $0.date < fortnight && $0.discipline == .running && $0.status != .completed
        }
        #expect(!leadIn.isEmpty)
        #expect(leadIn.allSatisfy { !($0.runType?.isQuality ?? false) })
        // And the race the athlete just ran is still on the board, completed — never erased.
        #expect(next.sessions.contains { $0.runType == .race && $0.status == .completed })
        // Idempotent: the race is behind them — a second pass changes nothing.
        #expect(PlanService.completeRace(for: profile, today: Date(), in: ctx) == nil)
    }

    @Test func missedRaceRollsForwardWithoutRecovery() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = raceProfile(in: ctx, raceDaysAgo: 3)   // race day passed, never run
        let oldP5k = try #require(profile.plan).p5kSPerKm

        let headline = PlanService.completeRace(for: profile, today: Date(), in: ctx)
        #expect(headline != nil)
        let next = try #require(profile.plan)
        #expect(profile.raceDate == nil)
        #expect(next.blockIndex == 1)
        #expect(next.p5kSPerKm == oldP5k)                     // nothing to recalibrate from
        // No race run ⇒ nothing to recover from ⇒ the block starts training immediately.
        #expect(next.weekPhases.first != PlanPhase.recovery.rawValue)
    }

    @Test func completeRaceWaitsForRaceDayToPass() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = raceProfile(in: ctx, raceDaysAgo: 0)    // race is TODAY — hands off
        #expect(PlanService.completeRace(for: profile, today: Date(), in: ctx) == nil)
        #expect(profile.raceDate != nil)                      // the goal stands until the day passes
        #expect(profile.plan?.blockIndex == 0)
    }

    // MARK: Rebuild keeps this week's finished work (Plan Settings' "Rebuild plan")

    @Test func rebuildCarriesThisWeeksCompletedSessions() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = Calendar.current
        let profile = UserProfile()
        profile.distanceUnit = "metric"
        profile.disciplines = ["running"]
        profile.goal = .endurance
        profile.daysPerWeek = 4
        ctx.insert(profile)
        PlanService.regenerate(for: profile, in: ctx)
        let plan = try #require(profile.plan)

        // Complete a session earlier THIS week (backdate it to the week's start so the rebuild
        // happens "later in the week"), and one from BEFORE this week (older history).
        let weekStart = try #require(cal.dateInterval(of: .weekOfYear, for: Date())?.start)
        let doneThisWeek = try #require(plan.sessions.min { $0.date < $1.date })
        doneThisWeek.date = weekStart
        doneThisWeek.status = .completed
        let doneID = doneThisWeek.id
        let oldDone = PlannedSession()
        oldDone.date = cal.date(byAdding: .day, value: -10, to: Date())!
        oldDone.discipline = .running
        oldDone.status = .completed
        ctx.insert(oldDone)
        plan.sessions.append(oldDone)
        try ctx.save()

        // The Plan Settings sheet's structural save path.
        PlanService.rebuild(for: profile, in: ctx)

        let next = try #require(profile.plan)
        // Monday's finished run is still on the new plan — never a retroactive "Rest day".
        #expect(next.sessions.contains { $0.id == doneID && $0.status == .completed })
        // Older history stays with the replaced block (the strip anchors on the new block).
        #expect(!next.sessions.contains { $0.id == oldDone.id })
        // And the new block still generated real upcoming work.
        #expect(next.sessions.contains { $0.status == .planned })
    }

    // MARK: Adjacent-day long-run credit (the ±1-day grace)

    /// Saturday's long run planned, the athlete runs it Friday: same-day matching finds nothing,
    /// so the long-run grace credits tomorrow's prescription — the week's marquee session must
    /// never read as skipped because life moved it a day.
    @Test func longRunDoneDayEarlyCreditsTomorrowsPrescription() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = Calendar.current
        let long = PlannedSession()
        long.date = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
        long.discipline = .running
        long.runType = .long
        long.targetDistanceM = 16000
        long.status = .planned
        let plan = makePlan(in: ctx, sessions: [long])

        let w = Workout(); w.type = .run; w.startedAt = Date(); w.durationS = 5400
        let g = GPSDetail(); g.distanceM = 15500; w.gps = g
        ctx.insert(w)

        #expect(PlanCoaching.creditWorkout(w, to: plan, in: ctx)?.id == long.id)
        #expect(long.status == .completed)
    }

    /// The grace never weakens the fulfillment rule: a short Friday jog leaves Saturday's long run
    /// exactly where it was.
    @Test func shortJogNeverCreditsAdjacentLongRun() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = Calendar.current
        let long = PlannedSession()
        long.date = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
        long.discipline = .running
        long.runType = .long
        long.targetDistanceM = 16000
        long.status = .planned
        let plan = makePlan(in: ctx, sessions: [long])

        let w = Workout(); w.type = .run; w.startedAt = Date(); w.durationS = 1200
        let g = GPSDetail(); g.distanceM = 4000; w.gps = g
        ctx.insert(w)

        #expect(PlanCoaching.creditWorkout(w, to: plan, in: ctx) == nil)
        #expect(long.status == .planned)
    }

    /// A same-day session always wins over an adjacent long run — the grace is a fallback, never
    /// a competitor.
    @Test func sameDaySessionOutranksAdjacentLongRun() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = Calendar.current
        let today = PlannedSession()
        today.date = cal.startOfDay(for: Date())
        today.discipline = .running
        today.runType = .easy
        today.targetDistanceM = 14000
        today.status = .planned
        let tomorrowLong = PlannedSession()
        tomorrowLong.date = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
        tomorrowLong.discipline = .running
        tomorrowLong.runType = .long
        tomorrowLong.targetDistanceM = 16000
        tomorrowLong.status = .planned
        let plan = makePlan(in: ctx, sessions: [today, tomorrowLong])

        let w = Workout(); w.type = .run; w.startedAt = Date(); w.durationS = 5000
        let g = GPSDetail(); g.distanceM = 15000; w.gps = g
        ctx.insert(w)

        #expect(PlanCoaching.creditWorkout(w, to: plan, in: ctx)?.id == today.id)
        #expect(today.status == .completed)
        #expect(tomorrowLong.status == .planned)
    }

    /// The grace applies only to long runs — an adjacent-day interval session is never swallowed
    /// by a free run the day before.
    @Test func adjacentQualitySessionNeverCredited() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = Calendar.current
        let intervals = PlannedSession()
        intervals.date = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
        intervals.discipline = .running
        intervals.runType = .intervals
        intervals.targetDistanceM = 8000
        intervals.status = .planned
        let plan = makePlan(in: ctx, sessions: [intervals])

        let w = Workout(); w.type = .run; w.startedAt = Date(); w.durationS = 3000
        let g = GPSDetail(); g.distanceM = 8000; w.gps = g
        ctx.insert(w)

        #expect(PlanCoaching.creditWorkout(w, to: plan, in: ctx) == nil)
        #expect(intervals.status == .planned)
    }

    // MARK: Brief — the eyebrow variant

    /// Surfaces whose eyebrow already names the kind drop the leading type word; the full brief is
    /// untouched (default), and dropping never produces an empty line.
    @Test func briefDropsLeadingTypeUnderAnEyebrow() {
        let s = PlannedSession()
        s.discipline = .running
        s.runType = .tempo
        s.targetDistanceM = 6000
        s.targetPaceSPerKm = 300
        let full = PlanCoaching.brief(for: s, distanceUnit: .metric)
        let bare = PlanCoaching.brief(for: s, distanceUnit: .metric, dropLeadingType: true)
        #expect(full.hasPrefix("Tempo "))
        #expect(!bare.hasPrefix("Tempo"))
        #expect(bare.contains("6 km"))
        #expect(bare.contains("5:00"))

        // No distance to carry the line → the label stays, even when asked to drop it.
        let bareOnly = PlannedSession()
        bareOnly.discipline = .running
        bareOnly.runType = .easy
        #expect(!PlanCoaching.brief(for: bareOnly, distanceUnit: .metric, dropLeadingType: true).isEmpty)
    }

    // MARK: Race countdown — one unit scheme everywhere

    @Test func raceCountdownSpeaksDaysInsideTwoWeeksWeeksBeyond() {
        #expect(Formatters.raceCountdown(days: 0) == "Race day")
        #expect(Formatters.raceCountdown(days: 1) == "1 day to go")
        #expect(Formatters.raceCountdown(days: 13) == "13 days to go")
        #expect(Formatters.raceCountdown(days: 14) == "2 weeks to go")
        #expect(Formatters.raceCountdown(days: 84) == "12 weeks to go")
        #expect(Formatters.raceCountdown(days: 85) == "13 weeks to go")
    }
}
