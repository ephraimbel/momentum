import Foundation

/// Infers which muscles a strength/HIIT feed post worked from its title, so lift posts can render a
/// glowing `MuscleMapView` the way cardio posts render a route map. Used for the seeded community
/// (where we have a title but no logged sets); the user's own posts derive activation from real
/// logged sets via `MuscleActivation`. Values are relative weights — `MuscleMapView` scales by the max.
enum StrengthFeedMuscles {
    static func activation(forTitle title: String, type: WorkoutType) -> [MuscleGroup: Double] {
        let t = title.lowercased()
        switch true {
        case t.contains("push"):
            return [.chest: 1.0, .shoulders: 0.75, .triceps: 0.7, .core: 0.3]
        case t.contains("pull"):
            return [.back: 1.0, .biceps: 0.8, .forearms: 0.5, .core: 0.3]
        case t.contains("leg"), t.contains("lower"):
            return [.quads: 1.0, .glutes: 0.9, .hamstrings: 0.8, .calves: 0.5, .core: 0.3]
        case t.contains("upper"):
            return [.chest: 0.85, .back: 0.9, .shoulders: 0.7, .biceps: 0.6, .triceps: 0.6]
        case t.contains("full"):
            return [.chest: 0.7, .back: 0.7, .quads: 0.8, .glutes: 0.6, .shoulders: 0.5, .core: 0.6]
        case t.contains("condition"), type == .hiit, type == .crossfit:
            return [.quads: 0.75, .core: 0.95, .shoulders: 0.6, .back: 0.6, .glutes: 0.6, .calves: 0.4]
        default:
            return [.chest: 0.7, .back: 0.7, .shoulders: 0.6, .core: 0.5, .quads: 0.6]
        }
    }
}
