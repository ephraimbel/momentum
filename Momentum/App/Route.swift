import Foundation

/// The tabs of the app shell: Today · Plan · Progress · Profile.
/// (Progress hosts trends, history, and the athlete-model "Coach" read via a segmented switch.
/// The immersive Coach chat moved off the tab bar — it's reachable from Settings; Profile is the
/// athlete's dedicated identity + social page. **The World globe is no longer a tab** — it lives as a
/// zoom-out from the Today map, see `TodayView`.) Named `AppTab` to avoid colliding with SwiftUI's
/// iOS 18 `Tab` view.
enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case today, plan, progress, profile
    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .plan: "Plan"
        case .progress: "Progress"
        case .profile: "Profile"
        }
    }

    var systemImage: String {
        switch self {
        case .today: "map"
        case .plan: "calendar"
        case .progress: "chart.line.uptrend.xyaxis"
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
