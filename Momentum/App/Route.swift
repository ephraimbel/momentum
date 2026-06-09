import Foundation

/// The four tabs of the app shell (PRD §7.0): Today · Plan · History · You.
/// Named `AppTab` to avoid colliding with SwiftUI's iOS 18 `Tab` view.
enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case today, plan, history, you
    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .plan: "Plan"
        case .history: "History"
        case .you: "You"
        }
    }

    var systemImage: String {
        switch self {
        case .today: "bolt.heart"
        case .plan: "calendar"
        case .history: "list.bullet.rectangle"
        case .you: "person"
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
