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

    /// Unselected glyph — the OUTLINE variant, Instagram-style. The bar normally upgrades every
    /// symbol to its `.fill` variant automatically; the shell suppresses that so these actually
    /// render as outlines and selection can be carried by the glyph itself (see `selectedImage`).
    var systemImage: String {
        switch self {
        case .today: "map"
        case .plan: "calendar"
        // `chart.bar`, not `chart.line.uptrend.xyaxis`: the old glyph was the one symbol in the bar
        // with no fill pair and a fussy hairline drawing that sat visibly lighter than its
        // neighbours at tab size. Bars read instantly at 17 pt and give Progress the same
        // outline↔fill state change as Today.
        case .progress: "chart.bar"
        // `fork.knife.circle`, not bare `fork.knife`: SF Symbols ships no `fork.knife.fill`, so the
        // bare utensils are drawn solid at every size and Fuel was the one tab that looked
        // permanently selected. The circled pair reads as a plate — a ring at rest, filled with the
        // utensils knocked out when chosen — which is the same construction `person.crop.circle`
        // next door already uses, so Fuel finally gets the outline↔fill state change.
        case .fuel: "fork.knife.circle"
        case .profile: "person.crop.circle"
        }
    }

    /// Selected glyph — the FILLED variant where SF Symbols draws one. `calendar` has no fill pair;
    /// it carries selection through tint alone, exactly how Instagram handles its own odd one out.
    var selectedImage: String {
        switch self {
        case .today: "map.fill"
        case .plan: "calendar"
        case .progress: "chart.bar.fill"
        case .fuel: "fork.knife.circle.fill"
        case .profile: "person.crop.circle.fill"
        }
    }
}
