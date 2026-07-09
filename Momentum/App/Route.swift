import Foundation

/// The tabs of the app shell: Today · Plan · Progress · Community · Profile.
/// (Progress hosts trends, history, and the athlete-model "Coach" read via a segmented switch.
/// The immersive Coach chat moved off the tab bar — it's reachable from Settings; Profile is the
/// athlete's dedicated identity + social page. **The World globe is no longer a tab** — it lives as a
/// zoom-out from the Today map, see `TodayView`. **Community returned as a tab 2026-07-09** — the
/// reverse-chronological feed stream, see `CommunityView` + docs/SOCIAL-LAYER.md. Five tabs is the
/// iOS ceiling before "More"; this bar is full.) Named `AppTab` to avoid colliding with SwiftUI's
/// iOS 18 `Tab` view.
enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case today, plan, progress, community, profile
    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .plan: "Plan"
        case .progress: "Progress"
        case .community: "Community"
        case .profile: "Profile"
        }
    }

    var systemImage: String {
        switch self {
        case .today: "map"
        case .plan: "calendar"
        case .progress: "chart.line.uptrend.xyaxis"
        case .community: "person.2"
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
