import SwiftUI

/// The onboarding paywall (redesign 2026-08-05, after the Cal AI reference; settled the same day
/// at two pages): a two-page sequence. Page one is the tour — "Welcome to momentum." over a
/// large device mock paging through real screens; it asks for nothing (onboarding already asked
/// for notifications — the trial reminder is still scheduled at purchase). Page two is THE
/// paywall — the exact `PaywallView` the rest of the app shows, with its feature checklist
/// and the yearly-first plan pair. One paywall page everywhere; this flow only adds the tour in
/// front of it.
///
/// SOFT since 2026-08-06 (user call, reversing the 2026-07-28 hard flip): the checkout page
/// carries a close button (only there — the tour page has no X; its CTA is the way forward),
/// and closing is a decision, not a deferral — it clears `onboardingGatePending` so the wall
/// never re-raises, and onboarding continues to the account beat. A force-quit mid-wall still
/// re-raises it once (the flag arms before presentation), which is what `startAtCheckout`
/// serves: the relaunch gate re-enters at the checkout page, because the athlete already saw
/// the story.
struct OnboardingPaywallFlow: View {
    /// Relaunch gate: skip straight to the checkout page (the story was told last launch).
    var startAtCheckout = false
    /// Called INSTEAD of dismissing when the athlete becomes entitled — see PaywallCheckout.
    var onEntitled: (() -> Void)?
    /// Called INSTEAD of dismissing when the athlete closes the wall un-entitled. Same contract
    /// as `onEntitled`: a host that keeps this cover alive for a following beat (the relaunch
    /// gate) swaps content here rather than dismissing — tearing down and re-presenting a cover
    /// drops the second presentation under load.
    var onClose: (() -> Void)?

    @Environment(PaywallController.self) private var paywall
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: Int
    /// Direction of the last navigation, so the page transition slides the right way.
    @State private var goingBack = false
    /// Restore lives in the top chrome on every page (App Review 3.1.1: a hard wall must always
    /// offer a way to reclaim a past purchase) — it needs its own tiny state here because the
    /// tour page has no `PaywallCheckout` to host it.
    @State private var restoring = false
    @State private var nothingToRestore = false
    @State private var revealed = false

    private var offering: PaywallOffering { paywall.offering }

    init(startAtCheckout: Bool = false, onEntitled: (() -> Void)? = nil,
         onClose: (() -> Void)? = nil) {
        self.startAtCheckout = startAtCheckout
        self.onEntitled = onEntitled
        self.onClose = onClose
        _step = State(initialValue: startAtCheckout ? 1 : 0)
    }

    var body: some View {
        GeometryReader { geo in
            let s = min(1, max(0.8, geo.size.height / 820))   // same size-adaptive scale as PaywallView
            ZStack {
                switch step {
                case 0: pageShowcase(s).transition(pageTransition)
                default: pagePaywall.transition(pageTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .top) { chrome }
        // The paywall page brings its OWN animated background inside `PaywallView` — rendering a
        // second one behind it doubled the costliest layer on screen (perf, 2026-08-05). The tour
        // gets the bloom; the paywall page gets flat charcoal behind its self-contained canvas.
        .background {
            if step == 0 { PaywallBackground() } else { Theme.background.ignoresSafeArea() }
        }
        // Warm-charcoal dark moment, same non-leaking mechanism as PaywallView (never
        // `.preferredColorScheme` — it flows up to the hosting window and sticks after dismiss).
        .environment(\.colorScheme, .dark)
        .interactiveDismissDisabled(true)   // the X is the one dismissal — it must clear the gate flag
        .alert("Nothing to restore", isPresented: $nothingToRestore) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("We couldn't find a past purchase on this Apple ID.")
        }
        // Analytics for the paywall itself are logged by `PaywallView` when its page shows —
        // logging here too would double-count the funnel.
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.5)) { revealed = true }
        }
    }

    // MARK: Navigation

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: goingBack ? .leading : .trailing).combined(with: .opacity),
            removal: .move(edge: goingBack ? .trailing : .leading).combined(with: .opacity))
    }

    private func advance() {
        goingBack = false
        withAnimation(reduceMotion ? nil : Motion.lively) { step += 1 }
    }

    private func back() {
        goingBack = true
        withAnimation(reduceMotion ? nil : Motion.lively) { step -= 1 }
    }

    /// Back chevron and the close button on the paywall page, Restore alone on the tour (the
    /// paywall's own fine print carries Restore there — two on one page would be noise). The gate
    /// is soft (2026-08-06) and the X is the one skip affordance, but it lives ONLY on the
    /// checkout page (user call, same day): the tour is a story, not an ask — its own CTA is the
    /// way forward, and the skip decision belongs where the money is.
    private var chrome: some View {
        HStack(spacing: Theme.Space.md) {
            if step > 0 {
                Button { back() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                        .frame(width: 34, height: 34).momentumGlass(in: Circle())
                }
                .accessibilityLabel("Back")
            }
            Spacer()
            if step == 0 {
                Button("Restore") { restore() }
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .disabled(restoring)
            } else {
                Button { close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.inkSecondary)
                        .frame(width: 34, height: 34).momentumGlass(in: Circle())
                }
                .accessibilityLabel("Close")
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .animation(reduceMotion ? nil : Motion.lively, value: step)
    }

    /// Skipping satisfies the gate: clear the persisted flag so the wall never re-raises —
    /// the X is a decision, not a deferral. Pro stays behind the contextual gates everywhere
    /// else in the app; this only ends the onboarding ask.
    private func close() {
        paywall.onboardingGatePending = false
        if let onClose { onClose() } else { dismiss() }
    }

    private func restore() {
        Task {
            restoring = true
            _ = await paywall.restore()
            restoring = false
            // Entitled → the gate's `isPro` binding (or the host's onEntitled) takes it from here.
            if paywall.isPro { onEntitled?() } else { nothingToRestore = true }
        }
    }

    // MARK: Page one — the app itself, on a device

    /// The opener (owner call 2026-08-05: the 3-page flow's try-free feature page was cut — the
    /// checklist lives on the in-app paywall). One serif line, then the device carries the page;
    /// the footer already whispers the price and the trial.
    private func pageShowcase(_ s: CGFloat) -> some View {
        // The deck bleeds edge to edge (its fanned neighbors peek at the screen sides), so the
        // horizontal padding lives on the copy and the footer, not the whole page.
        VStack(spacing: 0) {
            Spacer(minLength: Theme.Space.lg)
            Text("Welcome to momentum.")
                .font(.serif(29 * s, weight: .semibold)).foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Space.xl)
                .reveal(revealed, delay: 0.05, reduceMotion: reduceMotion)
            Spacer(minLength: Theme.Space.md)
            PaywallShowcase(height: 500 * s)
                .reveal(revealed, delay: 0.15, reduceMotion: reduceMotion)
            Spacer(minLength: Theme.Space.md)
            footer(cta: showcaseCTA, s: s) { advance() }
                .padding(.horizontal, Theme.Space.xl)
                .reveal(revealed, delay: 0.25, reduceMotion: reduceMotion)
        }
    }

    // MARK: Page two — the close

    /// THE paywall — the same `PaywallView` the rest of the app shows (owner call 2026-08-05:
    /// one paywall page everywhere; the bespoke trial-timeline page is gone). It brings its own
    /// background, checkout, analytics and entitlement handling; the flow just hosts it and adds
    /// the back chevron to the tour. `hard: true` here means only "render no close button of
    /// your own" — the flow's chrome owns the X, whose close path also clears the gate flag
    /// (PaywallView's own close is a plain dismiss, which would leave the flag armed and loop
    /// the relaunch gate).
    private var pagePaywall: some View {
        PaywallView(feature: .fullPlan, hard: true, onEntitled: onEntitled)
    }

    /// "Try now" is only honest when a trial is actually behind it, and whether one IS behind it is
    /// a STORE fact, not an app one: the live path reads `introductoryDiscount` off the product
    /// (`PaywallController.trialDays(of:)`), so a trial can be switched on or off in App Store
    /// Connect with no build. Hardcoded, this button promised a trial the store may not be
    /// offering — it read "Try now" over a plain $59.99 charge after the trial was retired
    /// (2026-08-20), which is both a conversion mismatch with the checkout page and the kind of
    /// subscription-presentation ambiguity App Review 3.1.2 exists for.
    ///
    /// Same guard as the trust line in `footer` and as `PaywallCheckout`'s own CTA: with
    /// placeholder pricing we do not yet know what the store offers, so we do not promise.
    /// Flip the offer in ASC and this reverts to "Try now" on its own.
    private var showcaseCTA: String {
        offering.annual.trialDays > 0 && paywall.pricingIsLive ? "Try now" : "Continue"
    }

    // MARK: The tour page's footer

    /// Trust line + black CTA + the price in plain words. These pages sell without transacting,
    /// so their fine print is one honest sentence rather than the checkout's full renewal terms.
    private func footer(cta: String, s: CGFloat, action: @escaping () -> Void) -> some View {
        VStack(spacing: Theme.Space.sm) {
            if offering.annual.trialDays > 0, paywall.pricingIsLive {
                Label("No payment due now", systemImage: "checkmark")
                    .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.ink)
            }
            Button {
                Haptics.light()
                action()
            } label: {
                Text(cta)
                    .font(.rounded(Theme.FontSize.body, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .foregroundStyle(Theme.background)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.ink))
            }
            .buttonStyle(.plain)
            Group {
                if paywall.pricingIsLive {
                    let perMonth = offering.annual.perMonthText ?? ""
                    // Middot, not parentheses — every other price line in the paywall separates
                    // clauses with "·", and this footer shouldn't be the odd one out.
                    Text("Just \(offering.annual.priceText) per year · \(perMonth)")
                } else {
                    Text("Pricing unavailable · cancel anytime")
                }
            }
            .font(.rounded(10, weight: .medium)).foregroundStyle(Theme.inkTertiary)
        }
        .padding(.bottom, Theme.Space.xs)
    }
}

#Preview {
    OnboardingPaywallFlow()
        .environment(PaywallController(isPro: false))
}
