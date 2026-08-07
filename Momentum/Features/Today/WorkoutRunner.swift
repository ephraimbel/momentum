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
    /// The one-line "Logged" receipt, shown as a transient toast on the destination screen once
    /// the cover resolves — the quiet confirmation that the activity is in the book.
    @State private var receipt: String?
    @State private var receiptDismiss: Task<Void, Never>?

    private var plan: TrainingPlan? { profiles.first?.plan }
    private var distanceUnit: DistanceUnit { DistanceUnit(rawValue: profiles.first?.distanceUnit ?? "auto") ?? .auto }

    func body(content: Content) -> some View {
        content
            // ONE cover carries the whole journey: live recorder → (content crossfade) → save
            // screen → celebration → dismiss. It used to be two covers — dismiss the live one,
            // present the summary — which serialized two full-screen animations back to back:
            // most of the reported ~1s "pause" at the finish line, and a presentation SwiftUI can
            // drop under load (the same lesson as the onboarding relaunch gate: swap a cover's
            // content, never dismiss-and-re-present to chain beats).
            .fullScreenCover(item: $launch, onDismiss: {
                let saved = summary
                summary = nil
                afterCoverResolved(saved)
            }) { launch in
                ZStack {
                    if let presented = summary {
                        saveScreen(presented).transition(.opacity)
                    } else {
                        liveScreen(launch)
                    }
                }
                .animation(.easeOut(duration: 0.28), value: summary != nil)
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
            // The "Logged" receipt — a brief capsule at the top of the destination screen (Today
            // or Plan), auto-dismissing; tap to dismiss early.
            .overlay(alignment: .top) {
                if let receipt { receiptToast(receipt) }
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

    /// Strava-style: name + describe the workout, Save → celebration → back. Rendered INSIDE the
    /// launch cover (content swap), so finishing never chains two full-screen presentations.
    @ViewBuilder
    private func saveScreen(_ presented: PresentedWorkout) -> some View {
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

    /// Close the whole cover. `summary` deliberately stays set until `onDismiss` — clearing it here
    /// would swap the content back to the live recorder for the length of the dismissal animation.
    private func dismissSummary() {
        launch = nil
    }

    /// The cover fully resolved. Show the "Logged" receipt for a KEPT workout (a discard deleted
    /// the row, so its fetch quietly finds nothing), then — at the finished-workout moment, the
    /// app's positive peak — raise the "Enjoying momentum?" soft-ask if the athlete has now saved
    /// enough workouts to count as engaged. The save views count only KEPT workouts, so a discard
    /// never reaches the threshold, and the gate latches once, so this fires at most once ever.
    /// Delayed so the cover is fully gone before the sheet presents.
    private func afterCoverResolved(_ saved: PresentedWorkout?) {
        guard let saved else { return }   // live-screen discard: nothing reached the save flow
        if let line = Self.receiptLine(for: saved.id, container: context.container, unit: distanceUnit) {
            withAnimation(.easeOut(duration: 0.3)) { receipt = line }
            receiptDismiss?.cancel()
            receiptDismiss = Task { @MainActor in
                try? await Task.sleep(for: .seconds(3.2))
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.3)) { receipt = nil }
            }
        }
        guard AppReview.shouldRequestReview() else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.6))
            showRatingPrompt = true
        }
    }

    /// One honest line about what was just logged. Cardio speaks distance + pace (speed for
    /// rides), timed sports their minutes, strength just the day's name — never tonnage (user
    /// call 2026-07-29: no prescribed or headline weights). Read through a FRESH context: the
    /// title was written on the save screen's private context, and the main context can still
    /// hold the un-named copy.
    private static func receiptLine(for id: UUID, container: ModelContainer,
                                    unit: DistanceUnit) -> String? {
        let ctx = ModelContext(container)
        var d = FetchDescriptor<Workout>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        guard let w = (try? ctx.fetch(d))?.first else { return nil }   // discarded → no receipt
        let name = w.title.isEmpty ? w.type.title : w.title
        if w.type.isGPS, let gps = w.gps, gps.distanceM > 50 {
            let dist = Formatters.distance(meters: gps.distanceM, unit: unit)
            if w.type.isCycling {
                let speed = w.durationS > 0 ? gps.distanceM / w.durationS : 0
                return "\(name) logged · \(dist) · \(Formatters.speed(ms: speed, unit: unit))"
            }
            let pace = gps.distanceM > 0 ? w.durationS / (gps.distanceM / 1000) : 0
            return "\(name) logged · \(dist) · \(Formatters.pace(secPerKm: pace, unit: unit))"
        }
        if w.type.isStrengthStyle { return "\(name) logged" }
        let minutes = max(1, Int((w.durationS / 60).rounded()))
        return "\(name) logged · \(minutes) min"
    }

    /// The receipt capsule — the app's toast grammar (surface fill, hairline stroke), with the
    /// checkmark carrying the "it's saved" claim.
    private func receiptToast(_ line: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(line)
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.85)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 10)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, Theme.Space.sm)
        .transition(.move(edge: .top).combined(with: .opacity))
        .onTapGesture {
            receiptDismiss?.cancel()
            withAnimation(.easeIn(duration: 0.2)) { receipt = nil }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line)
        .accessibilityAddTraits(.isStaticText)
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
        guard let id else { launch = nil; return }   // discarded from the live screen — just close
        // Cleared up front: it's only recomputed inside the branch below, so a workout that failed
        // to fetch would otherwise have shown the PREVIOUS session's ring.
        weekRing = nil
        if let workout = fetchWorkout(id) {
            weekRing = WorkoutCompletion.credit(workout, launched: planned, plan: plan,
                                                profile: profiles.first, in: context)
        }
        // Swap the cover's CONTENT to the save screen — the cover itself stays up, so the athlete
        // crossfades from the live recorder straight to their summary instead of paying a full
        // dismiss animation followed by a full present. Everything below faults the whole workout
        // history and rewrites the plan; running it here used to stall the app at the exact moment
        // the athlete crossed their finish line, so it waits out the transition.
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
        guard let workout = WorkoutCompletion.fetch(id, in: context) else { return }
        WorkoutCompletion.adapt(workout, plan: plan, profile: profile, unit: unit,
                                services: services, in: context)
    }

    private func fetchWorkout(_ id: UUID) -> Workout? { WorkoutCompletion.fetch(id, in: context) }
}

/// Everything that has to happen once a workout becomes real, in one place so **every** path into
/// the journal behaves identically: the live finish (`WorkoutRunner`) and cold-launch crash recovery
/// (`RootView`). Recovery used to skip all of it — a run interrupted by a force-quit was saved to
/// history but never credited its planned session, never recalibrated paces, never eased load, and
/// never rescheduled reminders, so the athlete who actually did the work still saw the session open.
@MainActor
enum WorkoutCompletion {

    /// Calories, plan credit, and the week's ring — the synchronous half, done before the summary
    /// presents. `launched` is the session the athlete started FROM the plan (nil for a free
    /// workout or a recovered one); crediting is magnitude-aware either way.
    @discardableResult
    static func credit(_ workout: Workout, launched: PlannedSession?, plan: TrainingPlan?,
                       profile: UserProfile?, in context: ModelContext) -> WeekRing.Reading? {
        // Deterministic active-energy estimate (body-mass aware) — drives the calorie stat and the
        // Apple Health energy sample. Recomputed on save if the sport type is corrected. Stays on
        // the synchronous path: the summary reads through a fresh context, so a calorie figure
        // written after that read would simply never appear.
        workout.calories = CalorieEstimator.kcal(for: workout, bodyMassKg: profile?.bodyMassKg)
        try? context.save()   // persist now so the fresh-context strength summary reader sees it
        if let launched {
            PlanCoaching.creditLaunched(launched, with: workout, to: plan, in: context)
        } else {
            PlanCoaching.creditWorkout(workout, to: plan, in: context)
        }
        return WeekRingReader.reading(for: workout, plan: plan, profile: profile, in: context)
    }

    /// The adaptive pass: protective load easing, pace recalibration, athlete-model ingest and
    /// reminder rescheduling.
    static func adapt(_ workout: Workout, plan: TrainingPlan?, profile: UserProfile?,
                      unit: DistanceUnit, services: Services, in context: ModelContext) {
        // Protective adaptation first (ACWR-driven, ≤1×/week, never auto-increases load) —
        // then pace recalibration only when the plan was NOT just eased. The old order could
        // announce "paces got faster" and ease those same sessions in one save.
        let recent = (try? context.fetch(FetchDescriptor<Workout>())) ?? []
        if let rec = PlanCoaching.autoAdapt(plan, workouts: recent, in: context) {
            services.notifications.notifyPlanUpdated(
                title: rec == .rest ? "Recovery banked" : "Eased your upcoming sessions",
                body: rec == .rest
                    ? "Your load's been climbing. I pulled the next sessions back so it lands. No streak lost."
                    : "Your load's been climbing, so I eased the next sessions about 15%. Still on track.")
        } else if workout.type.discipline == .running,
                  let rec = PlanCoaching.recalibratePaces(from: workout, plan: plan, in: context),
                  rec.sessionsUpdated > 0 {
            let easy = PlanEngine.pace(.easy, p5k: rec.newP5kSPerKm)
            services.notifications.notifyPlanUpdated(
                title: "Your paces just got faster",
                body: "That run moved your numbers, so I updated the plan. Easy runs are now \(Formatters.pace(secPerKm: easy, unit: unit)).")
        } else if workout.type.isStrengthStyle,
                  let note = PlanCoaching.easeStrengthOnRPECreep(plan, workouts: recent, in: context) {
            services.notifications.notifyPlanUpdated(title: note.headline, body: note.detail)
        }
        // Let the Athlete Model learn from this session (local, never blocks the summary).
        if let profile {
            services.athleteModel.ingest(profile: profile, in: context)
        }
        // Refresh next-workout reminders so they reflect the completed/credited/recalibrated/eased plan.
        services.notifications.schedulePlannedReminders(plan)
    }

    /// One row by id — fetching the whole table to find it faulted every workout right at the
    /// moment the finish/summary screen is trying to present.
    static func fetch(_ id: UUID, in context: ModelContext) -> Workout? {
        var descriptor = FetchDescriptor<Workout>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}

extension View {
    /// Present + run a workout launched from anywhere (Today, Plan) through the shared pipeline.
    func workoutRunner(launch: Binding<TodayLaunch?>) -> some View { modifier(WorkoutRunner(launch: launch)) }
}
