import SwiftUI
import SwiftData

/// App-level workout launcher so a quick action (the global FAB) can start a workout from any tab.
/// Holds the presented recording/summary and the location prompt is fired here on a cardio start —
/// exactly when the user chooses to begin (never up front).
@MainActor
@Observable
final class WorkoutLauncher {
    var launch: TodayLaunch?
    var summary: PresentedWorkout?
    @ObservationIgnored private let location = LocationService()

    func startCardio(_ type: WorkoutType, goalMeters: Double? = nil, planned: PlannedSession? = nil) {
        location.requestAuthorization()
        launch = .cardio(type: type, goalMeters: goalMeters, planned: planned)
    }

    func startStrength(planned: PlannedSession? = nil) {
        launch = .strength(planned: planned)
    }
}

/// Hosts the recording + summary covers for a `WorkoutLauncher`, plus the no-shame plan crediting
/// on finish. Applied once at the app shell so the FAB can launch over any tab.
struct WorkoutLaunchHost: ViewModifier {
    let launcher: WorkoutLauncher
    @Environment(\.modelContext) private var context
    @Query private var profiles: [UserProfile]
    private var plan: TrainingPlan? { profiles.first?.plan }

    func body(content: Content) -> some View {
        @Bindable var launcher = launcher
        return content
            .fullScreenCover(item: $launcher.launch) { live($0) }
            .fullScreenCover(item: $launcher.summary) { presented in
                if presented.type == .strength {
                    StrengthSummaryView(workoutId: presented.id) { launcher.summary = nil }
                } else {
                    CardioSummaryView(workoutId: presented.id) { launcher.summary = nil }
                }
            }
    }

    @ViewBuilder
    private func live(_ launch: TodayLaunch) -> some View {
        switch launch {
        case let .cardio(type, goal, planned):
            CardioTrackingView(type: type, goalMeters: goal, container: context.container) { id in
                finish(id, type: type, planned: planned)
            }
        case let .strength(planned):
            StrengthLiveView(container: context.container, plannedSession: planned) { id in
                finish(id, type: .strength, planned: planned)
            }
        }
    }

    private func finish(_ id: UUID?, type: WorkoutType, planned: PlannedSession?) {
        launcher.launch = nil
        guard let id else { return }
        if let workout = ((try? context.fetch(FetchDescriptor<Workout>())) ?? []).first(where: { $0.id == id }) {
            if let planned { PlanCoaching.markComplete(planned, with: workout, in: context) }
            else { PlanCoaching.creditWorkout(workout, to: plan, in: context) }
        }
        launcher.summary = PresentedWorkout(id: id, type: type)
    }
}

extension View {
    func workoutLaunchHost(_ launcher: WorkoutLauncher) -> some View {
        modifier(WorkoutLaunchHost(launcher: launcher))
    }
}
