import Foundation

/// The tabs of the app shell: Today · Plan · Progress · Community · Fuel.
/// (Progress hosts trends, history, and the athlete-model "Coach" read via a segmented switch.
/// The immersive Coach chat moved off the tab bar — it's reachable from Settings. **Community
/// returned as a tab 2026-07-09** — the reverse-chronological feed stream, see `CommunityView` +
/// docs/SOCIAL-LAYER.md. **Fuel took Profile's slot 2026-07-16** — meal logging is a several-times-
/// a-day habit and the bar mirrors real frequency; Profile (identity + grid) keeps its second front
/// door, the avatar on Today's header (sheet, already shipped). **The World globe is no longer a
/// tab** — it lives as a zoom-out from the Today map, see `TodayView`. Five tabs is the iOS ceiling
/// before "More"; this bar is full.) Named `AppTab` to avoid colliding with SwiftUI's iOS 18 `Tab`.
enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case today, plan, progress, community, fuel
    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .plan: "Plan"
        case .progress: "Progress"
        case .community: "Community"
        case .fuel: "Fuel"
        }
    }

    var systemImage: String {
        switch self {
        case .today: "map"
        case .plan: "calendar"
        case .progress: "chart.line.uptrend.xyaxis"
        case .community: "person.2"
        case .fuel: "fork.knife"
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
