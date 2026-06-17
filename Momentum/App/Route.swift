import Foundation

/// The tabs of the app shell: Today · Plan · Progress · World · Profile.
/// (Progress hosts trends, history, and the athlete-model "Coach" read via a segmented switch.
/// The immersive Coach chat moved off the tab bar — it's reachable from Settings; Profile takes its
/// slot as the athlete's dedicated identity + social page.) Named `AppTab` to avoid colliding with
/// SwiftUI's iOS 18 `Tab` view.
enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case today, plan, progress, world, profile
    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .plan: "Plan"
        case .progress: "Progress"
        case .world: "World"
        case .profile: "Profile"
        }
    }

    var systemImage: String {
        switch self {
        case .today: "map"
        case .plan: "calendar"
        case .progress: "chart.line.uptrend.xyaxis"
        case .world: "globe"
        case .profile: "person.crop.circle"
        }
    }
}

/// Destinations pushed within a tab's `NavigationStack` (PRD §13.10).
/// Expanded as features land; Phase 0 declares the shape.
enum Route: Hashable {
    case workoutDetail(UUID)
    case exerciseLibrary
    case exerciseDetail(UUID)
    case programs
    case settings
}
