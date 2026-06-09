import Foundation

/// The post-workout AI read client (PRD §8.8). When the Supabase Edge Function + key are
/// configured, this would POST to `workout-analysis` (JWT auth, ≤4s timeout) and use its
/// strict-JSON narrative. Until then — and whenever the model is slow or down — it renders the
/// deterministic template, so the moment never blocks (the core §8.8 reliability guarantee).
@MainActor
final class AIService: AIServing {
    func workoutRead(for workout: Workout, planned: Bool,
                     weightUnit: WeightUnit, distanceUnit: DistanceUnit) async -> WorkoutRead {
        // Remote path lives in supabase/functions/workout-analysis (committed, deploy in Phase 4).
        // Not configured in this build → render the deterministic template immediately.
        WorkoutReadTemplates.read(for: workout, planned: planned,
                                  weightUnit: weightUnit, distanceUnit: distanceUnit)
    }
}
