import SwiftUI

/// The Instagram-style condensing tab bar (user call 2026-07-30): while the athlete scrolls down
/// through content — the profile grid, Trends, the Plan board — the bar shrinks out of the way,
/// and the first scroll back up restores it. The subtle give-and-take is what makes a browsing
/// surface feel premium instead of furniture-locked.
///
/// Implementation is the SYSTEM behavior, not a re-creation: iOS 26's Liquid Glass bars minimize
/// natively (`tabBarMinimizeBehavior`), which keeps the physics, haptics and accessibility exactly
/// as the OS ships them. On iOS 18–25 the modifier is a no-op and the bar stays fixed — graceful,
/// never broken. Lives on the root `TabView` only; individual screens need no wiring, which is
/// also why this arrives for free on every future scrolling surface.
extension View {
    @ViewBuilder
    func minimizingTabBar() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}
