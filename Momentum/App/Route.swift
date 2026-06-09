import Foundation

/// The four tabs of the app shell (PRD §7.0): Today · Plan · History · You.
/// Named `AppTab` to avoid colliding with SwiftUI's iOS 18 `Tab` view.
enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case today, plan, progress, history
    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .plan: "Plan"
        case .progress: "Progress"
        case .history: "History"
        }
    }

    var systemImage: String {
        switch self {
        case .today: "map"
        case .plan: "calendar"
        case .progress: "chart.line.uptrend.xyaxis"
        case .history: "list.bullet.rectangle"
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
