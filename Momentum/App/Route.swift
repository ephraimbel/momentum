import Foundation

/// The tabs of the app shell: Today · Plan · Progress · Fuel · Profile.
/// (Progress hosts trends, history, and the athlete-model "Coach" read via a segmented switch; the
/// immersive Coach chat is reachable from the Today header + Settings. **Community is back-burnered
/// from v1 (2026-07-16)** — the app ships solo-first ("Bevel for endurance athletes"): track, plan,
/// fuel, reflect. The feed/backend code stays in the repo, dormant, and the tab returns when a real
/// user base exists. **Fuel joined the bar 2026-07-16** — meal logging is a several-times-a-day
/// habit. **The World globe is not a tab** — it's a zoom-out from the Today map, see `TodayView`.
/// Five tabs is the iOS ceiling before "More"; this bar is full.) Named `AppTab` to avoid colliding
/// with SwiftUI's iOS 18 `Tab`.
enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case today, plan, progress, fuel, profile
    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .plan: "Plan"
        case .progress: "Progress"
        case .fuel: "Fuel"
        case .profile: "Profile"
        }
    }

    var systemImage: String {
        switch self {
        case .today: "map"
        case .plan: "calendar"
        case .progress: "chart.line.uptrend.xyaxis"
        case .fuel: "fork.knife"
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
