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

        // A hard 5k in 1600 s ⇒ ~320 s/km equivalent (within the 3% bound of 322).
        let w = run(in: ctx, distanceM: 5000, durationS: 1600, rpe: 8)
        let rec = PlanCoaching.recalibratePaces(from: w, plan: plan, in: ctx)

        #expect(rec != nil)
        #expect(abs(plan.p5kSPerKm - 320) < 1)                              // lowered to the equivalent
        #expect(rec?.sessionsUpdated == 1)
        #expect(abs((future.targetPaceSPerKm ?? 0) - PlanEngine.pace(.easy, p5k: 320)) < 1)  // future pace re-derived
    }

    @Test func bigImprovementIsCappedAtThreePercent() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let future = futureEasyRun(in: ctx, p5k: 360)
        let plan = makePlan(in: ctx, sessions: [future]); plan.p5kSPerKm = 360

        // A blazing 5k in 1500 s ⇒ 300 s/km equivalent, but a single run may only drop p5k ~3%.
        let w = run(in: ctx, distanceM: 5000, durationS: 1500, rpe: 9)
        _ = PlanCoaching.recalibratePaces(from: w, plan: plan, in: ctx)

        #expect(abs(plan.p5kSPerKm - 360 * 0.97) < 1)   // 349.2, not 300
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
    private func raceProfile(in ctx: ModelContext, raceDaysAgo: Int) -> UserProfile {
        let cal = Calendar.current
        let profile = UserProfile()
        profile.distanceUnit = "metric"
        profile.disciplines = ["running"]
        profile.goal = .raceDistance
        profile.daysPerWeek = 4
        profile.raceDate = cal.date(byAdding: .day, value: -raceDaysAgo, to: cal.startOfDay(for: Date()))
        profile.raceDistanceM = 42_195
        ctx.insert(profile)
        let start = cal.date(byAdding: .weekOfYear, value: -8, to: Date())!
        PlanService.regenerate(for: profile, startDate: start, in: ctx)
        return profile
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
        // Marathon ⇒ the new block opens with a 2-week recovery lead-in, all easy.
        #expect(next.weekPhases.prefix(2).allSatisfy { $0 == PlanPhase.recovery.rawValue })
        let cal = Calendar.current
        let fortnight = cal.date(byAdding: .day, value: 14, to: cal.startOfDay(for: Date()))!
        let leadIn = next.sessions.filter { $0.date < fortnight && $0.discipline == .running }
        #expect(!leadIn.isEmpty)
        #expect(leadIn.allSatisfy { !($0.runType?.isQuality ?? false) })
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
}
