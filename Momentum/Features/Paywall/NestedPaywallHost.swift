import SwiftUI

extension View {
    /// Host the paywall cover for a context the ROOT host cannot reach.
    ///
    /// `RootView` presents the paywall for the whole app, but a `fullScreenCover` cannot be
    /// presented on top of another cover, and the app has several contexts that are themselves a
    /// cover or a full-screen overlay:
    ///
    ///   * the workout recorder overlay (`WorkoutRunner`) — the live screen AND all three save
    ///     editors inside it,
    ///   * the crash-recovery save editor (`RootView.recoverySave`),
    ///   * the manual-log review editor (`LogWorkoutView`),
    ///   * the DEBUG `--save-screen` / `--strength-save` harnesses,
    ///   * the coach chat, which keeps its own bespoke host for the gate-on-send moment.
    ///
    /// Apply this ONCE at the root of each such context. It hosts the cover and registers with
    /// `PaywallController.nestedHostDepth`, which the root host watches so it stands down — exactly
    /// one host is ever bound to `presentedFeature`, never two (the double-present bug).
    ///
    /// ⚠️ Apply it at the CONTAINER, never on the individual save editors. A save editor can appear
    /// inside any of the contexts above; if it hosted its own, it would be the second host inside a
    /// container that already has one.
    func nestedPaywallHost() -> some View { modifier(NestedPaywallHost()) }
}

/// The cover plus the bookkeeping that keeps every other host out of the way.
/// See `nestedPaywallHost()`.
private struct NestedPaywallHost: ViewModifier {
    @Environment(PaywallController.self) private var paywall
    /// This host's registration token; 0 until `onAppear`.
    @State private var token = 0

    func body(content: Content) -> some View {
        @Bindable var paywall = paywall
        // Hosts nest — a share composer sheet opens from a save editor that is already inside the
        // recorder overlay — and only the INNERMOST can actually present, because a cover cannot
        // rise above a sheet that is already up. Everyone else reads `nil` and stays quiet, so one
        // host is live per depth and never two bound to the same item.
        let isTop = token != 0 && paywall.topHostToken == token
        return content
            .fullScreenCover(item: Binding(
                get: { isTop ? paywall.presentedFeature : nil },
                set: { if isTop { paywall.presentedFeature = $0 } })) { feature in
                PaywallView(feature: feature)
            }
            // `onAppear`/`onDisappear`, not `task`: the pairing has to survive the view being
            // rebuilt without being torn down, and it must release the instant the context leaves
            // the screen. Presenting the paywall OVER this content does not fire `onDisappear`
            // (a cover or sheet leaves its presenter mounted), so a host stays registered while its
            // own paywall is up — which is what keeps the stack honest.
            .onAppear { if token == 0 { token = paywall.retainNestedHost() } }
            .onDisappear {
                guard token != 0 else { return }
                paywall.releaseNestedHost(token)
                token = 0
            }
    }
}
