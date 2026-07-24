import SwiftUI
import SwiftData

/// Presents the live recorder for a `TodayLaunch` and runs the full post-workout pipeline — calorie
/// estimate, plan crediting, adaptive pace recalibration + load auto-adapt, athlete-model ingest,
/// reminder rescheduling — then the save/summary sheet. Shared by Today and Plan so a workout started
/// from either place behaves identically (PRD §9). Attach via `.workoutRunner(launch:)`.
struct WorkoutRunner: ViewModifier {
    @Binding var launch: TodayLaunch?

    @Environment(\.modelContext) private var context
    @Environment(Services.self) private var services
    /// The native App Store rating prompt. Reached ONLY through the styled "Enjoying momentum?"
    /// pre-prompt below, at the finished-workout moment after a genuine save (`AppReview`) — never
    /// during onboarding, which is what got the app rejected under guideline 5.6.3.
    @Environment(\.requestReview) private var requestReview
    @Query private var profiles: [UserProfile]
    @State private var summary: PresentedWorkout?
    /// The one-time "Enjoying momentum?" soft-ask (`RatingPromptView`), raised after the summary
    /// cover dismisses when the engagement gate first opens.
    @State private var showRatingPrompt = false
    /// The athlete's running week and the arc this session just added to it — computed at finish,
    /// while the workout is still in hand, so the celebration can draw something true on its very
    /// first frame (the summary's own reader hasn't loaded by then).
    @State private var weekRing: WeekRing.Reading?

    private var plan: TrainingPlan? { profiles.first?.plan }
    private var distanceUnit: DistanceUnit { DistanceUnit(rawValue: profiles.first?.distanceUnit ?? "auto") ?? .auto }

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $launch) { liveScreen($0) }
            .fullScreenCover(item: $summary) { presented in
                // Strava-style: name + describe the workout, Save → celebration → back.
                if presented.type.isStrengthStyle {
                    StrengthSaveView(workoutId: presented.id) { dismissSummary() }
                } else if presented.type.isTimed {
                    TimedSaveView(workoutId: presented.id) { dismissSummary() }
                } else {
                    // `distanceUnit` was never passed, so the whole cardio summary silently fell back
                    // to `.auto` (locale) and ignored an explicit metric/imperial choice.
                    CardioSaveView(workoutId: presented.id, distanceUnit: distanceUnit,
                                   workoutType: presented.type, weekRing: weekRing) { dismissSummary() }
                }
            }
            // The one-time "Enjoying momentum?" soft-ask — a centered modal over a dimmed backdrop
            // (clear cover background; the card draws its own dim + centering). The positive branch
            // fires the native ask AFTER it closes (presenting the system prompt over a dismissing
            // modal cancels it).
            .fullScreenCover(isPresented: $showRatingPrompt) {
                RatingPromptView(
                    onRate: {
                        showRatingPrompt = false
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(0.6))
                            requestReview()
                        }
                    },
                    onDismiss: { showRatingPrompt = false })
                .presentationBackground(.clear)
            }
            #if DEBUG
            // `--rating-prompt`: raise the soft-ask straight away for sim verification (the real
            // trigger needs a saved workout first).
            .onAppear {
                guard ProcessInfo.processInfo.arguments.contains("--rating-prompt"), !showRatingPrompt else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { showRatingPrompt = true }
            }
            #endif
    }

    /// Close the summary, and — at the finished-workout moment, the app's positive peak — raise the
    /// "Enjoying momentum?" soft-ask if the athlete has now saved enough workouts to count as engaged.
    /// The save views count only KEPT workouts, so a discard never reaches the threshold, and the gate
    /// latches once, so this fires at most once ever. Delayed so the summary cover is fully gone before
    /// the sheet presents (stacking a sheet on a dismissing cover misbehaves).
    private func dismissSummary() {
        summary = nil
        guard AppReview.shouldRequestReview() else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.6))
            showRatingPrompt = true
        }
    }

    @ViewBuilder
    private func liveScreen(_ launch: TodayLaunch) -> some View {
        switch launch {
        case let .cardio(type, goal, planned, guide):
            // Expand a prescribed quality session (intervals/tempo/run-walk) into a guided structured
            // run; a plain free/easy run passes nil and shows just the hero metrics.
            let structured = planned.flatMap { StructuredWorkoutBuilder.build(from: $0, p5kSPerKm: plan?.p5kSPerKm,
                                                                              raceDistanceM: profiles.first?.raceDistanceM) }
            CardioTrackingView(type: type, goalMeters: goal, container: context.container,
                               distanceUnit: distanceUnit,
                               guideRoute: guide, structured: structured,
                               targetPaceSPerKm: structured == nil ? planned?.targetPaceSPerKm : nil) { id in
                finish(id, type: type, planned: planned)
            }
        case let .strength(type, planned):
            StrengthLiveView(container: context.container, type: type, plannedSession: planned) { id in
                finish(id, type: type, planned: planned)
            }
        case let .timed(type):
            TimedTrackingView(type: type, container: context.container) { id in
                finish(id, type: type, planned: nil)
            }
        }
    }

    private func finish(_ id: UUID?, type: WorkoutType, planned: PlannedSession?) {
        launch = nil
        guard let id else { return }
        // Cleared up front: it's only recomputed inside the branch below, so a workout that failed
        // to fetch would otherwise have shown the PREVIOUS session's ring.
        weekRing = nil
        if let workout = fetchWorkout(id) {
            // Deterministic active-energy estimate (body-mass aware) — drives the calorie stat and the
            // Apple Health energy sample. Recomputed on save if the sport type is corrected. Stays on
            // the synchronous path: the summary reads through a fresh context, so a calorie figure
            // written after that read would simply never appear.
            workout.calories = CalorieEstimator.kcal(for: workout, bodyMassKg: profiles.first?.bodyMassKg)
            try? context.save()   // persist now so the fresh-context strength summary reader sees it
            if let planned { PlanCoaching.markComplete(planned, with: workout, in: context) }
            else { PlanCoaching.creditWorkout(workout, to: plan, in: context) }
            weekRing = WeekRingReader.reading(for: workout, plan: plan, profile: profiles.first, in: context)
        }
        // Present FIRST. Everything below faults the whole workout history and rewrites the plan;
        // running it here used to stall the app at the exact moment the athlete crossed their finish
        // line. None of it changes what the summary displays, so it waits out the present
        // transition (the celebration itself plays later, when the athlete saves).
        summary = PresentedWorkout(id: id, type: type)
        // Captured HERE, while we're still inside a view update. `plan`/`profiles` read through
        // `@Query`, and reaching for a property wrapper from a detached Task a second later is not
        // reliable — a nil profile would have meant `schedulePlannedReminders(nil)`, quietly wiping
        // the athlete's reminders. SwiftData models are references, so holding them is safe.
        let capturedPlan = plan
        let capturedProfile = profiles.first
        let capturedUnit = distanceUnit
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(CompletionCelebration.duration + 0.2))
            adaptAfterFinish(id, plan: capturedPlan, profile: capturedProfile, unit: capturedUnit)
        }
    }

    /// The adaptive pass: protective load easing, pace recalibration, athlete-model ingest and
    /// reminder rescheduling. Deliberately deferred past the reveal — it's heavy, it's all
    /// main-actor SwiftData work, and nothing it produces is on screen yet.
    private func adaptAfterFinish(_ id: UUID, plan: TrainingPlan?, profile: UserProfile?,
                                  unit: DistanceUnit) {
        if let workout = fetchWorkout(id) {
            // Protective adaptation first (ACWR-driven, ≤1×/week, never auto-increases load) —
            // then pace recalibration only when the plan was NOT just eased. The old order could
            // announce "paces got faster" and ease those same sessions in one save.
            let recent = (try? context.fetch(FetchDescriptor<Workout>())) ?? []
            if let rec = PlanCoaching.autoAdapt(plan, workouts: recent, in: context) {
                services.notifications.notifyPlanUpdated(
                    title: rec == .rest ? "Recovery banked" : "Eased your upcoming sessions",
                    body: rec == .rest
                        ? "Your load's been climbing — I pulled the next sessions back so it lands. No streak lost."
                        : "Your load's been climbing — I eased the next sessions ~15%. Still on track.")
            } else if workout.type.discipline == .running,
                      let rec = PlanCoaching.recalibratePaces(from: workout, plan: plan, in: context),
                      rec.sessionsUpdated > 0 {
                let easy = PlanEngine.pace(.easy, p5k: rec.newP5kSPerKm)
                services.notifications.notifyPlanUpdated(
                    title: "Your paces just got faster",
                    body: "Strong run — I updated your plan. Easy runs are now ~\(Formatters.pace(secPerKm: easy, unit: unit)).")
            } else if workout.type.isStrengthStyle,
                      let note = PlanCoaching.easeStrengthOnRPECreep(plan, workouts: recent, in: context) {
                services.notifications.notifyPlanUpdated(title: note.headline, body: note.detail)
            }
        }
        // Let the Athlete Model learn from this session (local, never blocks the summary).
        if let profile {
            services.athleteModel.ingest(profile: profile, in: context)
        }
        // Refresh next-workout reminders so they reflect the completed/credited/recalibrated/eased plan.
        services.notifications.schedulePlannedReminders(plan)
    }

    private func fetchWorkout(_ id: UUID) -> Workout? {
        // One row by id — fetching the whole table to find it faulted every workout right at the
        // moment the finish/summary screen is trying to present.
        var descriptor = FetchDescriptor<Workout>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}

extension View {
    /// Present + run a workout launched from anywhere (Today, Plan) through the shared pipeline.
    func workoutRunner(launch: Binding<TodayLaunch?>) -> some View { modifier(WorkoutRunner(launch: launch)) }
}
