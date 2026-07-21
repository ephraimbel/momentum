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
    @Query private var profiles: [UserProfile]
    @State private var summary: PresentedWorkout?

    private var plan: TrainingPlan? { profiles.first?.plan }
    private var distanceUnit: DistanceUnit { DistanceUnit(rawValue: profiles.first?.distanceUnit ?? "auto") ?? .auto }

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $launch) { liveScreen($0) }
            .fullScreenCover(item: $summary) { presented in
                // Strava-style: name + describe the workout, Save → celebration → back.
                if presented.type.isStrengthStyle {
                    StrengthSaveView(workoutId: presented.id) { summary = nil }
                } else if presented.type.isTimed {
                    TimedSaveView(workoutId: presented.id) { summary = nil }
                } else {
                    CardioSaveView(workoutId: presented.id, workoutType: presented.type) { summary = nil }
                }
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
                               guideRoute: guide, structured: structured) { id in
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
        if let workout = fetchWorkout(id) {
            // Deterministic active-energy estimate (body-mass aware) — drives the calorie stat and the
            // Apple Health energy sample. Recomputed on save if the sport type is corrected. Stays on
            // the synchronous path: the summary reads through a fresh context, so a calorie figure
            // written after that read would simply never appear.
            workout.calories = CalorieEstimator.kcal(for: workout, bodyMassKg: profiles.first?.bodyMassKg)
            try? context.save()   // persist now so the fresh-context strength summary reader sees it
            if let planned { PlanCoaching.markComplete(planned, with: workout, in: context) }
            else { PlanCoaching.creditWorkout(workout, to: plan, in: context) }
        }
        // Present FIRST. Everything below faults the whole workout history and rewrites the plan;
        // running it here used to stall the app at the exact moment the athlete crossed their finish
        // line. None of it changes what the summary displays, so it waits for the celebration.
        summary = PresentedWorkout(id: id, type: type)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(CompletionCelebration.duration + 0.2))
            adaptAfterFinish(id)
        }
    }

    /// The adaptive pass: protective load easing, pace recalibration, athlete-model ingest and
    /// reminder rescheduling. Deliberately deferred past the reveal — it's heavy, it's all
    /// main-actor SwiftData work, and nothing it produces is on screen yet.
    private func adaptAfterFinish(_ id: UUID) {
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
                    body: "Strong run — I updated your plan. Easy runs are now ~\(Formatters.pace(secPerKm: easy, unit: distanceUnit)).")
            } else if workout.type.isStrengthStyle,
                      let note = PlanCoaching.easeStrengthOnRPECreep(plan, workouts: recent, in: context) {
                services.notifications.notifyPlanUpdated(title: note.headline, body: note.detail)
            }
        }
        // Let the Athlete Model learn from this session (local, never blocks the summary).
        if let profile = profiles.first {
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
