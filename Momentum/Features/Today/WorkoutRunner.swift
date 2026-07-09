import SwiftUI
import SwiftData

/// Presents the live recorder for a `TodayLaunch` and runs the full post-workout pipeline — calorie
/// estimate, plan crediting, adaptive pace recalibration + load auto-adapt, athlete-model ingest,
/// reminder rescheduling — then the save/summary sheet. Shared by Today and Plan so a workout started
/// from either place behaves identically (PRD §9). Attach via `.workoutRunner(launch:)`.
struct WorkoutRunner: ViewModifier {
    @Binding var launch: TodayLaunch?
    /// Whether this host checks for an interrupted workout at launch. Exactly one host opts in (Today),
    /// so the recovery prompt can't double-present across the two `.workoutRunner` call sites.
    var offersRecovery = false

    @Environment(\.modelContext) private var context
    @Environment(Services.self) private var services
    @Query private var profiles: [UserProfile]
    @State private var summary: PresentedWorkout?
    @State private var recovery: PendingRecovery?

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
                    CardioSaveView(workoutId: presented.id) { summary = nil }
                }
            }
            .sheet(item: $recovery) { pending in
                WorkoutRecoverySheet(type: pending.type, detail: pending.line,
                                     onRecover: { recover(pending) },
                                     onDiscard: { discard() })
                    .presentationDetents([.height(360)])
                    .presentationDragIndicator(.hidden)
            }
            // Only the recovery host runs this; it no-ops when there's nothing interrupted.
            .task { if offersRecovery { checkForInterruptedWorkout() } }
    }

    // MARK: Cold-launch recovery (PRD §8.3/§8.4)

    /// Surface an interrupted workout as "Recover / Discard". A begun-but-empty shell (killed before
    /// any data landed) is cleared silently — there's nothing to recover.
    private func checkForInterruptedWorkout() {
        guard offersRecovery, recovery == nil, summary == nil, launch == nil,
              let workout = WorkoutRecovery.pendingWorkout(in: context) else { return }
        if isEmptyShell(workout) {
            WorkoutRecovery.discardPending(in: context)
            return
        }
        recovery = PendingRecovery(id: workout.id, type: workout.type, line: recoveryLine(workout))
    }

    /// Finalize the interrupted workout from its persisted data, then hand it to the normal save sheet —
    /// so recovering feels exactly like finishing (name it, tweak the sport, save).
    private func recover(_ pending: PendingRecovery) {
        recovery = nil
        guard let workout = fetchWorkout(pending.id) else { return }
        Task {
            await WorkoutRecovery.finalize(workout, bodyMassKg: profiles.first?.bodyMassKg, in: context)
            summary = PresentedWorkout(id: pending.id, type: pending.type)
        }
    }

    private func discard() {
        recovery = nil
        WorkoutRecovery.discardPending(in: context)
    }

    /// A one-line recap for the recovery card: "2.31 mi · 18:42" (GPS) or "18:42 · 8 sets" (strength).
    private func recoveryLine(_ w: Workout) -> String {
        let time = Formatters.duration(s: w.durationS)
        if let gps = w.gps {
            return "\(Formatters.distance(meters: gps.distanceM, unit: distanceUnit)) · \(time)"
        }
        if let s = w.strength {
            let sets = s.exercises.flatMap(\.sets).filter(\.isComplete).count
            return "\(time) · \(sets) set\(sets == 1 ? "" : "s")"
        }
        return time
    }

    /// A shell begun by `beginWorkout` but killed before any data was captured — not worth recovering.
    private func isEmptyShell(_ w: Workout) -> Bool {
        if let gps = w.gps { return gps.samples.isEmpty && gps.distanceM == 0 }
        if let s = w.strength { return !s.exercises.flatMap(\.sets).contains(where: \.isComplete) }
        return w.durationS < 1   // timed activity
    }

    @ViewBuilder
    private func liveScreen(_ launch: TodayLaunch) -> some View {
        switch launch {
        case let .cardio(type, goal, planned, guide):
            // Expand a prescribed quality session (intervals/tempo/run-walk) into a guided structured
            // run; a plain free/easy run passes nil and shows just the hero metrics.
            let structured = planned.flatMap(StructuredWorkoutBuilder.build)
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
        var didNudge = false
        if let workout = fetchWorkout(id) {
            // Deterministic active-energy estimate (body-mass aware) — drives the calorie stat and the
            // Apple Health energy sample. Recomputed on save if the sport type is corrected.
            workout.calories = CalorieEstimator.kcal(for: workout, bodyMassKg: profiles.first?.bodyMassKg)
            try? context.save()   // persist now so the fresh-context strength summary reader sees it
            if let planned { PlanCoaching.markComplete(planned, with: workout, in: context) }
            else { PlanCoaching.creditWorkout(workout, to: plan, in: context) }
            // Adaptive coaching: a strong run re-calibrates future paces (deterministic + bounded),
            // and the coach tells you about it.
            if workout.type.discipline == .running,
               let rec = PlanCoaching.recalibratePaces(from: workout, plan: plan, in: context),
               rec.sessionsUpdated > 0 {
                let easy = PlanEngine.pace(.easy, p5k: rec.newP5kSPerKm)
                services.notifications.notifyPlanUpdated(
                    title: "Your paces just got faster",
                    body: "Strong run — I updated your plan. Easy runs are now ~\(Formatters.pace(secPerKm: easy, unit: distanceUnit)).")
                didNudge = true
            }
        }
        // Let the Athlete Model learn from this session (local, never blocks the summary).
        if let profile = profiles.first {
            services.athleteModel.ingest(profile: profile, in: context)
        }
        // Auto-protect from overreaching (ACWR-driven, ≤1×/week, never auto-increases load).
        let recent = (try? context.fetch(FetchDescriptor<Workout>())) ?? []
        if let rec = PlanCoaching.autoAdapt(plan, workouts: recent, in: context), !didNudge {
            services.notifications.notifyPlanUpdated(
                title: rec == .rest ? "Recovery banked" : "Eased your upcoming sessions",
                body: rec == .rest
                    ? "Your load's been climbing — I pulled the next sessions back so it lands. No streak lost."
                    : "Your load's been climbing — I eased the next sessions ~15%. Still on track.")
        }
        // Refresh next-workout reminders so they reflect the completed/credited/recalibrated/eased plan.
        services.notifications.schedulePlannedReminders(plan)
        summary = PresentedWorkout(id: id, type: type)
    }

    private func fetchWorkout(_ id: UUID) -> Workout? {
        ((try? context.fetch(FetchDescriptor<Workout>())) ?? []).first { $0.id == id }
    }
}

extension View {
    /// Present + run a workout launched from anywhere (Today, Plan) through the shared pipeline.
    /// `offersRecovery` opts this host into the cold-launch "recover an interrupted workout" prompt —
    /// pass `true` from exactly one place (Today) so it can't double-present.
    func workoutRunner(launch: Binding<TodayLaunch?>, offersRecovery: Bool = false) -> some View {
        modifier(WorkoutRunner(launch: launch, offersRecovery: offersRecovery))
    }
}

/// A lightweight, `Identifiable` snapshot of an interrupted workout for the recovery sheet — built once
/// on the main context so the sheet stays a pure function of plain values.
struct PendingRecovery: Identifiable {
    let id: UUID
    let type: WorkoutType
    let line: String
}

/// Cold-launch prompt shown when a workout was still recording when the app died. No-shame framing —
/// nothing was lost; the athlete chooses to save it to history or discard it.
private struct WorkoutRecoverySheet: View {
    let type: WorkoutType
    let detail: String
    var onRecover: () -> Void
    var onDiscard: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var confirmDiscard = false

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            ZStack {
                Circle().fill(IridescentMaterial()).frame(width: 66, height: 66).opacity(0.5)
                    .scaleEffect(pulse && !reduceMotion ? 1.1 : 0.92)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: pulse)
                Image(systemName: type.systemImage)
                    .font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.ink)
            }
            .padding(.top, Theme.Space.xl)

            VStack(spacing: 6) {
                Text("Unfinished \(type.title.lowercased())")
                    .font(.display(22, weight: .bold)).foregroundStyle(Theme.ink)
                Text(detail)
                    .font(.rounded(Theme.FontSize.body, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.inkSecondary)
                Text("Your app closed mid-workout — nothing was lost. Save it to your history or discard it.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    .multilineTextAlignment(.center).padding(.horizontal, Theme.Space.md).padding(.top, 2)
            }

            Spacer(minLength: 0)

            VStack(spacing: Theme.Space.sm) {
                OversizedButton(title: "Recover workout", systemImage: "checkmark") { onRecover() }
                Button {
                    confirmDiscard = true
                } label: {
                    Text("Discard").font(.rounded(Theme.FontSize.body, weight: .bold))
                        .foregroundStyle(Theme.inkSecondary).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .accessibilityIdentifier("recoveryDiscard")
            }
            .padding(.bottom, Theme.Space.md)
        }
        .padding(.horizontal, Theme.Space.xl)
        .presentationBackground(Theme.background)
        .onAppear { pulse = true }
        .confirmationDialog("Discard this workout?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { onDiscard(); dismiss() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("This permanently deletes the recorded route and stats.")
        }
    }
}
